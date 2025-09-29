# frozen_string_literal: true

class CreatorAnalytics::Churn
  AGGREGATE_BY_DAY = "day"
  AGGREGATE_BY_MONTH = "month"

  AGGREGATE_OPTIONS = {
    AGGREGATE_BY_DAY => {
      title: "Daily",
      calendar_interval: "day"
    },
    AGGREGATE_BY_MONTH => {
      title: "Monthly",
      calendar_interval: "month"
    }
  }.freeze

  ZERO_STATS = {
    churned_users: 0,
    revenue_lost_cents: 0,
    churn_rate: 0.0,
    avg_active_base: 0
  }.freeze

  def initialize(seller:)
    @seller = seller
  end

  def subscription_products
    @subscription_products ||= @seller
      .products_for_creator_analytics
      .select { it.is_recurring_billing? || it.is_tiered_membership? }
  end

  def generate_data(product_ids:, dates:, aggregate_by: AGGREGATE_BY_DAY)
    selected_products = if product_ids.blank?
      []
    else
      subscription_products.select { product_ids.include?(it.external_id) }
    end

    constrained_dates = constrain_dates(dates)

    period_data = calculate_period_data_with_churn_metrics_for_dates(
      products: selected_products,
      start_date: constrained_dates.first,
      end_date: constrained_dates.last,
      aggregate_by: aggregate_by
    )

    total_stats = calculate_summary_stats(period_data.values)
    last_period_stats = calculate_last_period_stats(products: selected_products, dates: constrained_dates, aggregate_by: aggregate_by)

    {
      period_data: period_data,
      start_date: constrained_dates.first,
      end_date: constrained_dates.last,
      total: total_stats,
      last_period: last_period_stats,
      first_sale_date: first_sale_date
    }
  end


  private
    def constrain_dates(dates)
      today_date = Time.now.in_time_zone(@seller.timezone).to_date

      first_sale_created_at = @seller.first_sale_created_at_for_analytics
      earliest_meaningful_date = if first_sale_created_at
        first_sale_created_at.in_time_zone(@seller.timezone).to_date
      else
        @seller.created_at.in_time_zone(@seller.timezone).to_date
      end

      constrained_start = dates.begin.clamp(earliest_meaningful_date, today_date)
      constrained_end = dates.end.clamp(constrained_start, today_date)

      (constrained_start..constrained_end).to_a
    end

    def generate_period_dates(dates, aggregate_by)
      period_dates = {}

      if aggregate_by == AGGREGATE_BY_MONTH
        dates.group_by { Date.new(it.year, it.month, 1) }.each do |month_start_date, _month_dates|
          period_dates[month_start_date] = month_start_date
        end
      else
        dates.each do |date|
          period_dates[date] = date
        end
      end

      period_dates
    end

    # Returns a hash Date => active_subscriber_count
    # Examples (keys are Date objects):
    # - Day aggregation: { Date.new(2025,6,1) => 120, Date.new(2025,6,2) => 118 }
    # - Month aggregation: { Date.new(2025,6,1) => 120, Date.new(2025,7,1) => 135 }
    def bulk_active_subscribers(products:, period_dates:, aggregate_by:, period_start_date:)
      filters_hash = {}
      label_to_date = {}
      product_ids = products.map(&:id)
      period_dates.each do |period_key, period_date|
        start_dt = if aggregate_by == AGGREGATE_BY_MONTH
          # Monthly baseline: later of report start or month start (partial-month alignment) to match the actual date range
          [period_start_date, period_date.beginning_of_month].max
        else
          period_date
        end

        label = period_key.strftime("%Y-%m-%d")
        label_to_date[label] = period_key

        filters_hash[label] = {
          bool: {
            must: [
              { exists: { field: "subscription_id" } },
              { term: { selected_flags: "is_original_subscription_purchase" } }
            ],
            filter: [
              { terms: { product_id: product_ids } },
              { range: { created_at: { lt: start_dt.beginning_of_day.iso8601 } } }
            ],
            should: [
              { bool: { must_not: { exists: { field: "subscription_deactivated_at" } } } },
              { range: { subscription_deactivated_at: { gt: start_dt.beginning_of_day.iso8601 } } }
            ],
            minimum_should_match: 1
          }
        }
      end

      body = {
        query: { bool: { must: [{ exists: { field: "subscription_id" } }, { term: { selected_flags: "is_original_subscription_purchase" } }], filter: [{ terms: { product_id: product_ids } }] } },
        size: 0,
        aggs: {
          active_subscribers: {
            filters: {
              filters: filters_hash
            },
            aggs: {
              unique_subscriptions: { cardinality: { field: "subscription_id" } }
            }
          }
        }
      }

      response = Purchase.search(body).aggregations.active_subscribers.buckets

      response.each_with_object({}) do |(label, bucket), result|
        date_key = label_to_date[label]
        result[date_key] = bucket.unique_subscriptions.value.to_i
      end
    end

    def calculate_period_data_with_churn_metrics_for_dates(products:, start_date:, end_date:, aggregate_by: AGGREGATE_BY_DAY)
      raw_data = fetch_raw_churn_data(products:, start_date:, end_date:, aggregate_by:)
      calculate_churn_metrics(churn_data: raw_data, products:, start_date:, end_date:, aggregate_by:)
    end

    def build_query(product_ids:, start_date:, end_date:)
      search_service = PurchaseSearchService.new(Purchase::CHARGED_SALES_SEARCH_OPTIONS)
      query = search_service.body[:query]

      query[:bool][:must] << { exists: { field: "subscription_deactivated_at" } }
      query[:bool][:must] << { term: { selected_flags: "is_original_subscription_purchase" } }
      query[:bool][:filter] << { terms: { product_id: product_ids } }
      query[:bool][:filter] << { range: { subscription_deactivated_at: { time_zone: @seller.timezone_formatted_offset, gte: start_date.beginning_of_day.iso8601, lte: end_date.end_of_day.iso8601 } } }

      query
    end

    def paginate(query:, sources:)
      after_key = nil
      body = build_body(query, sources)
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

    def build_body(query, sources)
      {
        query: query,
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

    def fetch_raw_churn_data(products:, start_date:, end_date:, aggregate_by:)
      aggregate_config = AGGREGATE_OPTIONS[aggregate_by]
      calendar_interval = aggregate_config[:calendar_interval]
      product_ids = products.map(&:id)
      query = build_query(product_ids:, start_date:, end_date:)

      sources = [
        { date: { date_histogram: { time_zone: @seller.timezone_formatted_offset, field: "subscription_deactivated_at", calendar_interval: calendar_interval } } }
      ]
      paginate(query:, sources:).each_with_object({}) do |bucket, result|
        key_ms = bucket["key"]["date"]
        ms = key_ms.is_a?(String) ? key_ms.to_i : key_ms.to_i
        date_key = Time.at(ms / 1000.0).in_time_zone(@seller.timezone).to_date
        result[date_key] = {
          churned_users: bucket["doc_count"],
          revenue_lost_cents: bucket["revenue_lost"]["value"].to_i,
        }
      end
    end

    def calculate_churn_metrics(churn_data:, products:, start_date:, end_date:, aggregate_by:)
      dates = (start_date..end_date).to_a
      period_dates = generate_period_dates(dates, aggregate_by)
      active_counts = bulk_active_subscribers(products:, period_dates:, aggregate_by:, period_start_date: start_date)

      period_dates.each do |period_key, _period_date|
        churned_users = churn_data.dig(period_key, :churned_users) || 0
        active_subscribers = active_counts[period_key] || 0
        churn_rate = active_subscribers.positive? ? (churned_users.to_f / active_subscribers * 100).round(2) : 0.0

        churn_data[period_key] = (churn_data[period_key] || { churned_users: 0, revenue_lost_cents: 0 }).merge(
          churn_rate: churn_rate,
          active_subscribers: active_subscribers
        )
      end

      churn_data
    end

    def calculate_summary_stats(periods_data)
      return ZERO_STATS if periods_data.empty?

      total_churned = periods_data.sum { it[:churned_users] || 0 }
      total_revenue_lost = periods_data.sum { it[:revenue_lost_cents] || 0 }

      periods_with_base = periods_data.select { (it[:active_subscribers] || 0) > 0 }
      avg_churn_rate = if periods_with_base.any?
        total_weighted = periods_with_base.sum { (it[:churn_rate] || 0) * (it[:active_subscribers] || 0) }
        base_sum = periods_with_base.sum { it[:active_subscribers] || 0 }
        (base_sum > 0 ? (total_weighted / base_sum).round(2) : 0.0)
      else
        0.0
      end
      avg_churn_rate = avg_churn_rate.clamp(0.0, 100.0)

      active_bases = periods_data.map { it[:active_subscribers] || 0 }
      avg_active_base = active_bases.empty? ? 0 : (active_bases.sum / active_bases.size.to_f)

      {
        churned_users: total_churned,
        revenue_lost_cents: total_revenue_lost,
        churn_rate: avg_churn_rate,
        avg_active_base: avg_active_base.to_i
      }
    end

    def calculate_last_period_stats(products:, dates:, aggregate_by:)
      last_start, last_end = calculate_last_period_dates(dates:, aggregate_by:)

      first_sale_created_at = @seller.first_sale_created_at_for_analytics
      if first_sale_created_at
        earliest_date = first_sale_created_at.in_time_zone(@seller.timezone).to_date
        if last_start < earliest_date
          Rails.logger.warn("CreatorAnalytics::Churn#calculate_last_period_stats Skipping last period: starts_before_earliest_date seller_id=#{@seller.id} aggregate_by=#{aggregate_by} last_start=#{last_start} last_end=#{last_end} earliest_date=#{earliest_date}")
          return ZERO_STATS
        end
      end
      if last_start > last_end
        Rails.logger.warn("CreatorAnalytics::Churn#calculate_last_period_stats Skipping last period: invalid_window seller_id=#{@seller.id} aggregate_by=#{aggregate_by} last_start=#{last_start} last_end=#{last_end}")
        return ZERO_STATS
      end

      last_period_data = calculate_period_data_with_churn_metrics_for_dates(products:, start_date: last_start, end_date: last_end, aggregate_by:)
      calculate_summary_stats(last_period_data.values)
    end

    def calculate_last_period_dates(dates:, aggregate_by:)
      start_date = dates.first
      end_date = dates.last

      if aggregate_by == AGGREGATE_BY_MONTH
        months = (end_date.year - start_date.year) * 12 + (end_date.month - start_date.month) + 1
        last_end = start_date.beginning_of_month - 1.day
        last_start = (last_end + 1.day - months.months).beginning_of_month
      else
        days = (end_date - start_date).to_i + 1
        last_end = start_date - 1.day
        last_start = last_end - (days - 1).days
      end
      [last_start, last_end]
    end

    def first_sale_date
      first_sale_created_at = @seller.first_sale_created_at_for_analytics
      return nil unless first_sale_created_at
      first_sale_created_at.in_time_zone(@seller.timezone).to_date
    end
end
