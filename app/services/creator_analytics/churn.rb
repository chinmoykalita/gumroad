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

  def by_date_with_product_breakdown
    calendar_interval = @aggregate_by == "monthly" ? "month" : "day"
    date_format = @aggregate_by == "monthly" ? "yyyy-MM" : "yyyy-MM-dd"

    sources = [
      { date: { date_histogram: { time_zone: @user.timezone_formatted_offset, field: "subscription_deactivated_at", calendar_interval: calendar_interval, format: date_format } } },
      { product_id: { terms: { field: "product_id" } } }
    ]

    churn_by_date_and_product = paginate(sources:).each_with_object({}) do |bucket, result|
      date_key = bucket["key"]["date"]
      product_id = bucket["key"]["product_id"]

      result[date_key] ||= { by_product: {}, churned_users: 0, revenue_lost_cents: 0 }
      result[date_key][:by_product][product_id] = {
        churned_users: bucket["doc_count"],
        revenue_lost_cents: bucket["revenue_lost"]["value"].to_i
      }

      result[date_key][:churned_users] += bucket["doc_count"]
      result[date_key][:revenue_lost_cents] += bucket["revenue_lost"]["value"].to_i
    end

    active_breakdowns_by_date = bulk_active_subscribers_with_product_breakdown

    active_breakdowns_by_date.each do |period_key, active_info|
      total_active = active_info[:total]

      churn_by_date_and_product[period_key] ||= { by_product: {}, churned_users: 0, revenue_lost_cents: 0 }

      active_info[:by_product].each do |product_id, active_count|
        churn_by_date_and_product[period_key][:by_product][product_id] ||= { churned_users: 0, revenue_lost_cents: 0 }
        churn_by_date_and_product[period_key][:by_product][product_id][:active_subscribers] = active_count
      end

      churn_by_date_and_product[period_key][:by_product].each do |product_id, pdata|
        pdata[:active_subscribers] ||= 0
      end

      total_churned = churn_by_date_and_product[period_key][:churned_users]
      churn_rate = total_active.positive? ? (total_churned.to_f / total_active * 100).round(2) : 0.0

      churn_by_date_and_product[period_key].merge!(
        churn_rate: churn_rate,
        active_subscribers: total_active
      )
    end

    churn_by_date_and_product
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

    # Returns a hash date_key => active_subscriber_count
    def bulk_active_subscribers
      period_dates = generate_period_dates

      filters_hash = {}
      period_dates.each do |period_key, period_date|
        start_dt = @aggregate_by == "monthly" ? period_date.beginning_of_month : period_date

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
        query: { bool: { must: [ { exists: { field: "subscription_id" } }, { term: { selected_flags: "is_original_subscription_purchase" } } ], filter: [ { terms: { product_id: @products.map(&:id) } } ] } },
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

      response.each_with_object({}) do |(key, data), result|
        result[key] = data.unique_subscriptions.value.to_i
      end
    end

    # Returns hash date_key => { total: X, by_product: { product_id => count } }
    def bulk_active_subscribers_with_product_breakdown
      period_dates = generate_period_dates

      filters_hash = {}
      period_dates.each do |period_key, period_date|
        start_dt = @aggregate_by == "monthly" ? period_date.beginning_of_month : period_date

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
        query: { bool: { must: [ { exists: { field: "subscription_id" } }, { term: { selected_flags: "is_original_subscription_purchase" } } ], filter: [ { terms: { product_id: @products.map(&:id) } } ] } },
        size: 0,
        aggs: {
          active_subscribers: {
            filters: {
              filters: filters_hash
            },
            aggs: {
              by_product: {
                terms: { field: "product_id", size: 1000 },
                aggs: {
                  unique_subscriptions: { cardinality: { field: "subscription_id" } }
                }
              },
              unique_subscriptions: { cardinality: { field: "subscription_id" } }
            }
          }
        }
      }

      buckets = Purchase.search(body).aggregations.active_subscribers.buckets

      buckets.each_with_object({}) do |(key, data), result|
        by_product_counts = data.by_product.buckets.each_with_object({}) do |prod_bucket, p_hash|
          p_hash[prod_bucket['key']] = prod_bucket.unique_subscriptions.value.to_i
        end

        result[key] = {
          total: data.unique_subscriptions.value.to_i,
          by_product: by_product_counts
        }
      end
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
end
