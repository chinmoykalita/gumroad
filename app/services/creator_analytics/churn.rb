# frozen_string_literal: true

class CreatorAnalytics::Churn

  def initialize(user:, products:, dates:, aggregate_by: "daily")
    @user = user
    @products = products
    @dates = constrain_dates(dates)
    @aggregate_by = aggregate_by
    build_query
  end

  def by_date
    calendar_interval = @aggregate_by == "monthly" ? "month" : "day"
    date_format = @aggregate_by == "monthly" ? "yyyy-MM" : "yyyy-MM-dd"

    sources = [
      { date: { date_histogram: { time_zone: @user.timezone_formatted_offset, field: "subscription_deactivated_at", calendar_interval: calendar_interval, format: date_format } } }
    ]
    churn_data = paginate(sources:).each_with_object({}) do |bucket, result|
      result[bucket["key"]["date"]] = {
        churned_users: bucket["doc_count"],
        revenue_lost_cents: bucket["revenue_lost"]["value"].to_i,
      }
    end

    period_dates = generate_period_dates
    period_dates.each do |period_key, period_date|
      churned_users = churn_data.dig(period_key, :churned_users) || 0

      if @aggregate_by == "monthly"
        period_start_date = period_date.beginning_of_month
      else
        period_start_date = period_date
      end

      active_subscribers = active_subscribers_on_date(period_start_date)

      churn_rate = if active_subscribers > 0
        (churned_users.to_f / active_subscribers * 100).round(2)
      else
        0.0
      end

      if churn_data[period_key]
        churn_data[period_key][:churn_rate] = churn_rate
        churn_data[period_key][:active_subscribers] = active_subscribers.round
      else
        churn_data[period_key] = {
          churned_users: 0,
          revenue_lost_cents: 0,
          churn_rate: churn_rate,
          active_subscribers: active_subscribers.round
        }
      end
    end

    churn_data
  end

  def total_stats
    by_date_data = by_date

    total_churned = by_date_data.values.sum { |period| period[:churned_users] }
    total_revenue_lost = by_date_data.values.sum { |period| period[:revenue_lost_cents] }

    # Used weighted average churn rate calculation for total stats
    # This approach:
    # 1. Gives more weight to periods with larger subscriber bases and time periods
    # 2. Prevents >100% churn rates for growing businesses
    # 3. Provides meaningful aggregate churn rate across entire period

    periods_with_data = by_date_data.values.select { |period| period[:active_subscribers] > 0 }

    if periods_with_data.any?
      total_weighted_churn = periods_with_data.sum { |period| period[:churn_rate] * period[:active_subscribers] }
      total_subscriber_base = periods_with_data.sum { |period| period[:active_subscribers] }
      avg_churn_rate = total_subscriber_base > 0 ? (total_weighted_churn / total_subscriber_base).round(2) : 0.0

      avg_churn_rate = avg_churn_rate.clamp(0.0, 100.0)
    else
      avg_churn_rate = 0.0
    end

    active_bases = by_date_data.values.map { |period| period[:active_subscribers] }
    avg_active_base = active_bases.empty? ? 0 : active_bases.sum / active_bases.size.to_f

    {
      churned_users: total_churned,
      revenue_lost_cents: total_revenue_lost,
      churn_rate: avg_churn_rate,
      avg_active_base: avg_active_base.to_i
    }
  end

  def last_period_stats
    if @aggregate_by == "monthly"
      current_start = @dates.first
      current_end = @dates.last
      period_length_days = (current_end - current_start).to_i + 1

      # Used day-based calculation for consistency
      # This ensures we compare equivalent time periods regardless of month/year boundaries
      last_period_end = current_start - 1.day
      last_period_start = last_period_end - (period_length_days - 1).days
    else
      period_length = @dates.length
      last_period_end = @dates.first - 1.day
      last_period_start = last_period_end - (period_length - 1).days
    end

    first_sale_created_at = @user.first_sale_created_at_for_analytics
    if first_sale_created_at
      earliest_date = first_sale_created_at.in_time_zone(@user.timezone).to_date
      return zero_stats if last_period_start < earliest_date
    end

    last_period_dates = (last_period_start..last_period_end).to_a

    return zero_stats if last_period_dates.empty?

    last_period_service = self.class.new(
      user: @user,
      products: @products,
      dates: last_period_dates,
      aggregate_by: @aggregate_by
    )

    last_period_service.total_stats
  rescue => e
    Rails.logger.warn("Failed to calculate last period churn stats: #{e.message}")
    zero_stats
  end

  private


  def constrain_dates(dates)
    today_date = Time.now.in_time_zone(@user.timezone).to_date

    first_sale_created_at = @user.first_sale_created_at_for_analytics
    earliest_meaningful_date = if first_sale_created_at
      first_sale_created_at.in_time_zone(@user.timezone).to_date
    else
      @user.created_at.in_time_zone(@user.timezone).to_date
    end

    constrained_start = dates.first.clamp(earliest_meaningful_date, today_date)
    constrained_end = dates.last.clamp(constrained_start, today_date)

    (constrained_start..constrained_end).to_a
  end

  def generate_period_dates
    period_dates = {}

    if @aggregate_by == "monthly"
      @dates.group_by { |date| date.strftime("%Y-%m") }.each do |month_key, month_dates|
        period_dates[month_key] = month_dates.last
      end
    else
      @dates.each do |date|
        date_key = date.strftime("%Y-%m-%d")
        period_dates[date_key] = date
      end
    end

    period_dates
  end

  def active_subscribers_on_date(date)
    search_service = PurchaseSearchService.new(Purchase::CHARGED_SALES_SEARCH_OPTIONS)
    active_query = search_service.body[:query]

    active_query[:bool][:must] << { exists: { field: "subscription_id" } }
    active_query[:bool][:must] << { term: { selected_flags: "is_original_subscription_purchase" } }
    active_query[:bool][:filter] << { terms: { product_id: @products.map(&:id) } }
    active_query[:bool][:filter] << { range: { created_at: { lt: date.beginning_of_day.iso8601 } } }

    active_query[:bool][:should] = [
      { bool: { must_not: { exists: { field: "subscription_deactivated_at" } } } },
      { range: { subscription_deactivated_at: { gte: date.beginning_of_day.iso8601 } } }
    ]
    active_query[:bool][:minimum_should_match] = 1

    response = Purchase.search({
      query: active_query,
      size: 0,
      aggs: {
        unique_subscriptions: {
          cardinality: { field: "subscription_id" }
        }
      }
    })

    response.aggregations.unique_subscriptions.value.to_i
  end

  def build_query
    search_service = PurchaseSearchService.new(Purchase::CHARGED_SALES_SEARCH_OPTIONS)
    @query = search_service.body[:query]

    @query[:bool][:must] << { exists: { field: "subscription_deactivated_at" } }
    @query[:bool][:must] << { term: { selected_flags: "is_original_subscription_purchase" } }
    @query[:bool][:filter] << { terms: { product_id: @products.map(&:id) } }
    @query[:bool][:filter] << { range: { subscription_deactivated_at: { time_zone: @user.timezone_formatted_offset, gte: @dates.first.to_s, lte: @dates.last.to_s } } }
  end

  def paginate(sources:)
    after_key = nil
    body = build_body(sources)
    buckets = []
    loop do
      body[:aggs][:composite_agg][:composite][:after] = after_key if after_key
      response_agg = Purchase.search(body).aggregations.composite_agg
      buckets += response_agg.buckets
      break if response_agg.buckets.size < ES_MAX_BUCKET_SIZE
      after_key = response_agg["after_key"]
    end
    buckets
  end

  def build_body(sources)
    {
      query: @query,
      size: 0,
      aggs: {
        composite_agg: {
          composite: { size: ES_MAX_BUCKET_SIZE, sources: },
          aggs: {
            revenue_lost: { sum: { field: "price_cents" } },
          },
        },
      },
    }
  end

  def zero_stats
    {
      churned_users: 0,
      revenue_lost_cents: 0,
      churn_rate: 0.0,
      avg_active_base: 0
    }
  end
end
