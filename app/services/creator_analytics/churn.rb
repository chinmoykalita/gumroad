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

  def initialize(seller:, products:, dates:, aggregate_by: AGGREGATE_BY_DAY)
    @seller = seller
    @products = products
    @dates = constrain_dates(dates)
    @aggregate_by = aggregate_by
    @query = build_query
  end

  def data
    aggregate_config = AGGREGATE_OPTIONS[@aggregate_by]
    calendar_interval = aggregate_config[:calendar_interval]
    date_format = aggregate_config[:date_format]

    sources = [
      { date: { date_histogram: { time_zone: @seller.timezone_formatted_offset, field: "subscription_deactivated_at", calendar_interval: calendar_interval, format: date_format } } }
    ]
    churn_data = paginate(sources:).each_with_object({}) do |bucket, result|
      result[bucket["key"]["date"]] = {
        churned_users: bucket["doc_count"],
        revenue_lost_cents: bucket["revenue_lost"]["value"].to_i,
      }
    end

    period_dates = generate_period_dates

    active_counts = bulk_active_subscribers

    period_dates.each do |period_key, _period_date|
      churned_users = churn_data.dig(period_key, :churned_users) || 0

      active_subscribers = active_counts[period_key] || 0

      churn_rate = active_subscribers.positive? ? (churned_users.to_f / active_subscribers * 100).round(2) : 0.0

      if churn_data[period_key]
        churn_data[period_key][:churn_rate] = churn_rate
        churn_data[period_key][:active_subscribers] = active_subscribers
      else
        churn_data[period_key] = {
          churned_users: 0,
          revenue_lost_cents: 0,
          churn_rate: churn_rate,
          active_subscribers: active_subscribers
        }
      end
    end

    churn_data
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

      constrained_start = dates.first.clamp(earliest_meaningful_date, today_date)
      constrained_end = dates.last.clamp(constrained_start, today_date)

      (constrained_start..constrained_end).to_a
    end

    def generate_period_dates
      period_dates = {}

      if @aggregate_by == AGGREGATE_BY_MONTH
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

    # Returns a hash date_key => active_subscriber_count
    def bulk_active_subscribers
      period_dates = generate_period_dates

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
              { terms: { product_id: @products.map(&:id) } },
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
        query: { bool: { must: [{ exists: { field: "subscription_id" } }, { term: { selected_flags: "is_original_subscription_purchase" } }], filter: [{ terms: { product_id: @products.map(&:id) } }] } },
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

      response.transform_values { |data| data.unique_subscriptions.value.to_i }
    end

    def build_query
      search_service = PurchaseSearchService.new(Purchase::CHARGED_SALES_SEARCH_OPTIONS)
      query = search_service.body[:query]

      query[:bool][:must] << { exists: { field: "subscription_deactivated_at" } }
      query[:bool][:must] << { term: { selected_flags: "is_original_subscription_purchase" } }
      query[:bool][:filter] << { terms: { product_id: @products.map(&:id) } }
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
end
