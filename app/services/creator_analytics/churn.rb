# frozen_string_literal: true

class CreatorAnalytics::Churn
  AGGREGATE_BY_DAY = "day"
  AGGREGATE_BY_MONTH = "month"

  AGGREGATE_OPTIONS = {
    AGGREGATE_BY_DAY => {
      title: "Daily",
      date_format: "yyyy-MM-dd",
      calendar_interval: "day"
    },
    AGGREGATE_BY_MONTH => {
      title: "Monthly",
      date_format: "yyyy-MM",
      calendar_interval: "month"
    }
  }.freeze

  ZERO_STATS = {
    churned_users: 0,
    revenue_lost_cents: 0,
    churn_rate: 0.0,
    avg_active_base: 0
  }.freeze

  def initialize(seller:, products: nil, dates: nil, aggregate_by: AGGREGATE_BY_DAY)
    @seller = seller
    @products = products
    @dates = dates ? constrain_dates(dates) : nil
    @aggregate_by = aggregate_by
    @query = build_query if @products && @dates
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

    @products = selected_products
    @dates = constrain_dates(dates)
    @aggregate_by = AGGREGATE_OPTIONS.key?(aggregate_by) ? aggregate_by : AGGREGATE_BY_DAY
    @query = build_query

    data
  end

  def data
    period_data = period_data_with_churn_metrics

    total_stats = calculate_summary_stats(period_data.values)
    date_keys, formatted_dates = format_dates_for_display
    by_date_arrays = build_by_date_arrays(date_keys, period_data)
    last_period_stats = calculate_last_period_stats

    {
      dates: formatted_dates,
      start_date: formatted_dates.first,
      end_date: formatted_dates.last,
      by_date: by_date_arrays,
      total: total_stats,
      last_period: last_period_stats,
      first_sale_date: format_first_sale_date
    }
  end

  def period_data_with_churn_metrics
    raw_data = fetch_raw_churn_data
    calculate_churn_metrics(raw_data)
  end

  private
    def product_ids
      @product_ids ||= @products.map(&:id)
    end

    def period_dates
      @period_dates ||= generate_period_dates
    end

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

    def generate_period_dates
      period_dates = {}

      if @aggregate_by == AGGREGATE_BY_MONTH
        @dates.group_by { it.strftime("%Y-%m") }.each do |month_key, month_dates|
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

    # Returns a hash date_key => active_subscriber_count
    def bulk_active_subscribers
      filters_hash = {}
      period_dates.each do |period_key, period_date|
        start_dt = @aggregate_by == AGGREGATE_BY_MONTH ? period_date.beginning_of_month : period_date

        filters_hash[period_key] = {
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
              { range: { subscription_deactivated_at: { gte: start_dt.beginning_of_day.iso8601 } } }
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

      response.transform_values { it.unique_subscriptions.value.to_i }
    end

    def build_query
      search_service = PurchaseSearchService.new(Purchase::CHARGED_SALES_SEARCH_OPTIONS)
      query = search_service.body[:query]

      query[:bool][:must] << { exists: { field: "subscription_deactivated_at" } }
      query[:bool][:must] << { term: { selected_flags: "is_original_subscription_purchase" } }
      query[:bool][:filter] << { terms: { product_id: product_ids } }
      query[:bool][:filter] << { range: { subscription_deactivated_at: { time_zone: @seller.timezone_formatted_offset, gte: @dates.first.to_s, lte: @dates.last.to_s } } }

      query
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

    def fetch_raw_churn_data
      aggregate_config = AGGREGATE_OPTIONS[@aggregate_by]
      calendar_interval = aggregate_config[:calendar_interval]
      date_format = aggregate_config[:date_format]

      sources = [
        { date: { date_histogram: { time_zone: @seller.timezone_formatted_offset, field: "subscription_deactivated_at", calendar_interval: calendar_interval, format: date_format } } }
      ]
      paginate(sources:).each_with_object({}) do |bucket, result|
        result[bucket["key"]["date"]] = {
          churned_users: bucket["doc_count"],
          revenue_lost_cents: bucket["revenue_lost"]["value"].to_i,
        }
      end
    end

    # Takes raw churn data and calculates churn rate % and adds active subscriber counts
    def calculate_churn_metrics(churn_data)
      active_counts = bulk_active_subscribers

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

    def calculate_last_period_stats
      last_start, last_end = calculate_last_period_dates

      first_sale_created_at = @seller.first_sale_created_at_for_analytics
      if first_sale_created_at
        earliest_date = first_sale_created_at.in_time_zone(@seller.timezone).to_date
        return ZERO_STATS if last_start < earliest_date
      end
      return ZERO_STATS if last_start >= last_end

      last_period_service = self.class.new(
        seller: @seller,
        products: @products,
        dates: (last_start..last_end),
        aggregate_by: @aggregate_by
      )
      last_period_data = last_period_service.period_data_with_churn_metrics
      calculate_summary_stats(last_period_data.values)
    end

    def calculate_last_period_dates
      start_date = @dates.first
      end_date = @dates.last

      if @aggregate_by == AGGREGATE_BY_MONTH
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

    def format_dates_for_display
      start_date = @dates.first
      end_date = @dates.last

      if @aggregate_by == AGGREGATE_BY_MONTH
        date_keys = (start_date..end_date).to_a.group_by { it.strftime("%Y-%m") }.keys.sort
        formatted = date_keys.map { Date.strptime("#{it}-01", "%Y-%m-%d").strftime("%B %Y") }
      else
        date_keys = (start_date..end_date).to_a.map(&:to_s)
        formatted = date_keys.map do |d|
          date = Date.parse(d)
          date.strftime("%A, %B #{date.day.ordinalize}")
        end
      end
      [date_keys, formatted]
    end

    def build_by_date_arrays(date_keys, service_data)
      {
        churn_rate: date_keys.map { service_data.dig(it, :churn_rate) || 0.0 },
        churned_users: date_keys.map { service_data.dig(it, :churned_users) || 0 },
        revenue_lost_cents: date_keys.map { service_data.dig(it, :revenue_lost_cents) || 0 }
      }
    end

    def format_first_sale_date
      first_sale_created_at = @seller.first_sale_created_at_for_analytics
      return nil unless first_sale_created_at
      first_sale_created_at.in_time_zone(@seller.timezone).strftime("%B %d, %Y")
    end
end
