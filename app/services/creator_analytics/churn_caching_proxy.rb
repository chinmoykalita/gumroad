# frozen_string_literal: true

require "set"

class CreatorAnalytics::ChurnCachingProxy
  def initialize(user)
    @user = user
  end

  # Proxy for cached values of CreatorAnalytics::Churn with product breakdown support
  # - Gets cached values for all dates in one SELECT operation
  # - If specific products are filtered, tries to filter from cached product breakdown first
  # - Falls back to real-time computation if needed
  # - Returns merged data
  def data_for_dates(start_date, end_date, aggregate_by: "daily", products: nil)
    dates = requested_dates(start_date, end_date, aggregate_by: aggregate_by)

    if use_cache?
      if aggregate_by == "monthly" && has_partial_months?(start_date, end_date)
        return fetch_monthly_data_with_partial_month_handling(start_date, end_date, products)
      end

      # Standard caching flow for daily or complete monthly ranges
      is_filtered_request = products.present? && products.map(&:id).sort != subscription_product_ids

      if is_filtered_request
        cached_data = fetch_and_filter_cached_data(dates, products, aggregate_by)
        return cached_data if cached_data.present?
      else
        data_for_dates_hash = fetch_data_for_dates(dates, aggregate_by: aggregate_by)
        compiled_data = compile_data_for_dates_and_fill_missing(data_for_dates_hash, aggregate_by: aggregate_by)
        return merge_churn_data_by_date(compiled_data, dates, aggregate_by: aggregate_by)
      end
    end

    analytics_data(dates.first, dates.last, aggregate_by: aggregate_by, products: products)
  end

  def generate_cache
    return if @user.suspended?

    first_sale_created_at = @user.first_sale_created_at_for_analytics
    return if first_sale_created_at.nil?

    return unless @user.sales.joins(:subscription).exists?

    first_sale_date = first_sale_created_at.in_time_zone(@user.timezone).to_date
    dates = (first_sale_date .. last_date_to_cache).to_a

    ActiveRecord::Base.connection.cache do
      ["daily", "monthly"].each do |aggregate_type|
        Makara::Context.release_all

        dates.each_slice(100) do |date_batch|
          dates_to_iterate = if aggregate_type == "monthly"
            # For monthly, only process the first day of each month
            date_batch.select { |d| d.day == 1 }
          else
            date_batch
          end

          uncached_dates(dates_to_iterate, aggregate_by: aggregate_type).each do |date|
            Makara::Context.release_all
            fetch_data(date, aggregate_by: aggregate_type)
          end
        end
      end
    end
  end

  def overwrite_cache(date, aggregate_by: "daily")
    return if date > last_date_to_cache
    return unless use_cache?

    # For monthly aggregation, always use the first day of the month as cache key
    cache_date = if aggregate_by == "monthly"
      date.day == 1 ? date : date.beginning_of_month
    else
      date
    end

    # For monthly, fetch data for the entire month
    data_start, data_end = if aggregate_by == "monthly"
      [cache_date, cache_date.end_of_month]
    else
      [date, date]
    end

    ComputedChurnAnalyticsDay.upsert_data_from_key(
      cache_key_for_churn_data(cache_date, aggregate_by: aggregate_by),
      analytics_data_with_product_breakdown(data_start, data_end, aggregate_by: aggregate_by)
    )
  end

  private
    def use_cache?
      @_use_cache = LargeSeller.where(user: @user).exists?
    end

    # Check if the date range includes any partial months
    def has_partial_months?(start_date, end_date)
      start_date.day != 1 || end_date != end_date.end_of_month
    end

    # cache for complete months, real-time for partial months
    def fetch_monthly_data_with_partial_month_handling(start_date, end_date, products)
      result_data = {}

      current_date = start_date
      while current_date <= end_date
        month_start = current_date.beginning_of_month
        month_end = current_date.end_of_month

        range_start = [current_date, month_start].max
        range_end = [end_date, month_end].min

        if range_start == month_start && range_end == month_end
          month_data = fetch_cached_data_for_complete_month(month_start, products)
          result_data.merge!(month_data)
        else
          # Partial month - real-time computation
          partial_data = analytics_data(range_start, range_end, aggregate_by: "monthly", products: products)
          result_data.merge!(partial_data)
        end

        current_date = month_end + 1.day
      end

      result_data
    end

    # Fetch complete month data using existing cache infrastructure
    # This reuses the standard caching flow including product filtering
    def fetch_cached_data_for_complete_month(month_start_date, products)
      is_filtered_request = products.present? && products.map(&:id).sort != subscription_product_ids
      dates = [month_start_date]

      if is_filtered_request
        cached_data = fetch_and_filter_cached_data(dates, products, "monthly")
        return cached_data if cached_data.present?

        # Fall back to real-time if cached product filtering fails
        analytics_data(month_start_date, month_start_date.end_of_month, aggregate_by: "monthly", products: products)
      else
        # Use standard cache flow for all products
        data_for_dates_hash = fetch_data_for_dates(dates, aggregate_by: "monthly")
        compiled_data = compile_data_for_dates_and_fill_missing(data_for_dates_hash, aggregate_by: "monthly")
        merge_churn_data_by_date(compiled_data, dates, aggregate_by: "monthly")
      end
    end

    # Fetch cached data and filter by products
    def fetch_and_filter_cached_data(dates, products, aggregate_by)
      # For monthly aggregation, fetch cache using the first day of each month
      # return data keyed by the YYYY-MM format
      data_for_dates_hash = fetch_data_for_dates(dates, aggregate_by: aggregate_by)

      all_have_product_breakdown = data_for_dates_hash.values.all? do |data|
        if data && data.is_a?(Hash)
          data.values.all? { |entry| entry.is_a?(Hash) && entry["by_product"] }
        else
          false
        end
      end

      return nil unless all_have_product_breakdown

      product_ids = products.map(&:id).to_set
      filtered_data = {}

      data_for_dates_hash.each do |date, cached_metrics|
        next unless cached_metrics

        # For monthly data, the structure is { "2025-06" => { metrics } }
        cached_metrics.each do |date_key, metrics|
          next unless metrics && metrics["by_product"]

          filtered_metrics = filter_metrics_by_products(metrics, product_ids)
          filtered_data[date_key] = filtered_metrics
        end
      end

      filtered_data.present? ? filtered_data : nil
    end

    # Filter cached metrics by specific products
    def filter_metrics_by_products(cached_metrics, product_ids)
      filtered_metrics = {
        churned_users: 0,
        revenue_lost_cents: 0,
        active_subscribers: 0
      }

      cached_metrics["by_product"].each do |product_id, product_metrics|
        if product_ids.include?(product_id.to_i)
          filtered_metrics[:churned_users] += (product_metrics["churned_users"] || 0)
          filtered_metrics[:revenue_lost_cents] += (product_metrics["revenue_lost_cents"] || 0)
          filtered_metrics[:active_subscribers] += (product_metrics["active_subscribers"] || 0)
        end
      end

      filtered_metrics[:churn_rate] = if filtered_metrics[:active_subscribers] > 0
        (filtered_metrics[:churned_users].to_f / filtered_metrics[:active_subscribers] * 100).round(2)
      else
        0.0
      end

      filtered_metrics
    end

    def format_date_key(date, aggregate_by)
      if aggregate_by == "monthly"
        date.strftime("%Y-%m")
      else
        date.to_s
      end
    end

    # Returns a cache key based on the granularity we are storing.
    def cache_key_for_churn_data(date, aggregate_by: "daily")
      "#{user_cache_key}_churn_by_#{aggregate_by}_for_#{date}"
    end

    def today_date
      Time.current.in_time_zone(@user.timezone).to_date
    end

    def last_date_to_cache
      today_date - 2.days
    end

    def user_cache_key
      return @_user_cache_key if @_user_cache_key

      begin
        version = $redis.get(RedisKey.seller_analytics_cache_version) || 0
      rescue => e
        Rails.logger.warn "Redis unavailable for cache version, using default: #{e.message}"
        version = 0
      end

      @_user_cache_key = "seller_churn_analytics_v#{version}_user_#{@user.id}_#{@user.timezone}"
    end

    # Returns array of dates missing from the cache
    def uncached_dates(dates, aggregate_by: "daily")
      cache_dates = aggregate_by == "monthly" ? dates_to_monthly_cache_dates(dates) : dates
      dates_to_keys = cache_dates.index_with { |date| cache_key_for_churn_data(date, aggregate_by: aggregate_by) }
      existing_keys = ComputedChurnAnalyticsDay.where(key: dates_to_keys.values).pluck(:key)
      missing_keys = dates_to_keys.values - existing_keys
      dates_to_keys.invert.values_at(*missing_keys)
    end

    # Convert a date range to monthly cache dates (first day of each month)
    def dates_to_monthly_cache_dates(dates)
      dates.group_by { |date| date.strftime("%Y-%m") }.map do |month_key, month_dates|
        Date.parse("#{month_key}-01")
      end.sort
    end

    def requested_dates(start_date, end_date, aggregate_by: "daily")
      today = today_date

      # Use first sale date as earliest meaningful date for churn
      first_sale_created_at = @user.first_sale_created_at_for_analytics
      earliest_date = if first_sale_created_at
        first_sale_created_at.in_time_zone(@user.timezone).to_date
      else
        @user.created_at.in_time_zone(@user.timezone).to_date
      end

      constrained_start = start_date.clamp(earliest_date, today)
      constrained_end = end_date.clamp(constrained_start, today)

      (constrained_start .. constrained_end).to_a
    end

    def analytics_data(start_date, end_date, aggregate_by: "daily", products: nil)
      CreatorAnalytics::Churn.new(
        user: @user,
        products: (products.present? ? products : @user.products_for_creator_analytics),
        dates: (start_date .. end_date).to_a,
        aggregate_by: aggregate_by
      ).by_date
    end

    def analytics_data_with_product_breakdown(start_date, end_date, aggregate_by: "daily")
      CreatorAnalytics::Churn.new(
        user: @user,
        products: @user.products_for_creator_analytics,
        dates: (start_date .. end_date).to_a,
        aggregate_by: aggregate_by
      ).by_date_with_product_breakdown
    end

    # Fetches and caches the churn data for one specific date
    def fetch_data(date, aggregate_by: "daily")
      return analytics_data_with_product_breakdown(date, date, aggregate_by: aggregate_by) if date > last_date_to_cache

      range_start, range_end = if aggregate_by == "monthly"
        # For monthly aggregation, always use the first day of the month as the cache key date
        # But fetch data for the entire month range
        cache_date = date.day == 1 ? date : date.beginning_of_month
        [cache_date, cache_date.end_of_month]
      else
        [date, date]
      end

      # Normalized cache date for the key
      cache_key_date = aggregate_by == "monthly" ? range_start : date

      ComputedChurnAnalyticsDay.fetch_data_from_key(cache_key_for_churn_data(cache_key_date, aggregate_by: aggregate_by)) do
        analytics_data_with_product_breakdown(range_start, range_end, aggregate_by: aggregate_by)
      end
    end

    # Takes an array of dates, returns a hash with matching stored data, or nil if missing.
    def fetch_data_for_dates(dates, aggregate_by: "daily")
      cache_dates = aggregate_by == "monthly" ? dates_to_monthly_cache_dates(dates) : dates
      keys_to_dates = cache_dates.index_by { |date| cache_key_for_churn_data(date, aggregate_by: aggregate_by) }
      existing_data_with_keys = ComputedChurnAnalyticsDay.read_data_from_keys(keys_to_dates.keys)
      existing_data_with_keys.transform_keys { |key| keys_to_dates[key] }
    end

    # Takes a hash of { date => (data | nil) }, returns an array of data for all days.
    def compile_data_for_dates_and_fill_missing(data_for_dates, aggregate_by: "daily")
      missing_date_ranges = find_missing_date_ranges(data_for_dates)
      processed_ranges = Set.new

      data_for_dates.flat_map do |date, day_data|
        next day_data if day_data

        missing_range = missing_date_ranges.find { |range| range.begin == date }
        if missing_range && !processed_ranges.include?(missing_range)
          processed_ranges.add(missing_range)
          # Process each date in the missing range individually to enable proper caching
          missing_range.map do |missing_date|
            fetch_data(missing_date, aggregate_by: aggregate_by)
          end.flatten
        end
      end.compact.map(&:with_indifferent_access)
    end

    # Returns contiguous missing dates as ranges.
    # In: { date => (data or nil), ... }
    # Out: [ (from .. to), ... ]
    def find_missing_date_ranges(data)
      hash_result = data.each_with_object({}) do |(date, value), hash|
        next if value
        hash[ hash.key(date - 1) || date ] = date
      end
      hash_result.map { |array| Range.new(*array) }
    end

    # Merges several churn results into singular data
    def merge_churn_data_by_date(days_data, dates, aggregate_by: "daily")
      return {} if days_data.empty?

      # It's a hash with date keys mapping to { churned_users:, revenue_lost_cents:, churn_rate:, active_subscribers: }
      merged_data = {}

      if aggregate_by == "monthly"
        # For monthly aggregation, group by month key
        days_data.each do |day_data|
          day_data.each do |date_key, metrics|
            # Ensure we use consistent month keys (YYYY-MM format)
            month_key = if date_key.length == 7
              date_key
            else
              Date.parse(date_key).strftime("%Y-%m")
            end
            merged_data[month_key] = metrics
          end
        end
      else
        days_data.each do |day_data|
          day_data.each do |date_key, metrics|
            merged_data[date_key] = metrics
          end
        end
      end

      merged_data
    end

    def subscription_product_ids
      @subscription_product_ids ||= @user.products_for_creator_analytics
        .filter_map { |p| p.id if p.is_recurring_billing? || p.is_tiered_membership? }
        .sort
    end
end
