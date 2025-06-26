# frozen_string_literal: true

class CreatorAnalytics::ChurnCachingProxy
  def initialize(user)
    @user = user
  end

  # Proxy for cached values of CreatorAnalytics::Churn
  # - Gets cached values for all dates in one SELECT operation
  # - If some are missing, run original method for missing ranges
  # - Returns merged data
  def data_for_dates(start_date, end_date, aggregate_by: "daily", options: {}, products: nil)
    dates = requested_dates(start_date, end_date)

    # For product-specific queries we always bypass the cache just like sales analytics does.
    if products.present?
      return analytics_data(dates.first, dates.last, aggregate_by: aggregate_by, products: products)
    end

    # When grouping by month we only need one cache entry per calendar month.
    cache_dates = if aggregate_by == "monthly"
      dates.map(&:beginning_of_month).uniq
    else
      dates
    end

    data = if use_cache? && should_cache_churn?
      data_for_dates_hash = fetch_data_for_dates(cache_dates, aggregate_by: aggregate_by)
      compiled_data = compile_data_for_dates_and_fill_missing(data_for_dates_hash, aggregate_by: aggregate_by)
      merge_churn_data_by_date(compiled_data, dates)
    else
      analytics_data(dates.first, dates.last, aggregate_by: aggregate_by)
    end

    data
  end

  def generate_cache
    return if @user.suspended?

    first_sale_created_at = @user.first_sale_created_at_for_analytics
    return if first_sale_created_at.nil?

    first_sale_date = first_sale_created_at.in_time_zone(@user.timezone).to_date
    dates = (first_sale_date .. last_date_to_cache).to_a

    ActiveRecord::Base.connection.cache do
      ["daily", "monthly"].each do |aggregate_type|
        Makara::Context.release_all

        dates_to_iterate = if aggregate_type == "monthly"
          # Only compute once per calendar month, we pick the last day.
          dates.select { |d| d == d.end_of_month }
        else
          dates
        end

        uncached_dates(dates_to_iterate, aggregate_by: aggregate_type).each do |date|
          Makara::Context.release_all
          fetch_data(date, aggregate_by: aggregate_type)
        end
      end
    end
  end

  # Regenerate cached data for a date, useful when a subscription was cancelled/refunded
  def overwrite_cache(date, aggregate_by: "daily")
    return if date > last_date_to_cache
    return unless use_cache?

    ComputedChurnAnalyticsDay.upsert_data_from_key(
      cache_key_for_churn_data(date, aggregate_by: aggregate_by),
      analytics_data(date, date, aggregate_by: aggregate_by)
    )
  end

  private

  def use_cache?
    @_use_cache ||= LargeSeller.where(user: @user).exists?
  end

  def should_cache_churn?
    # Only cache if user has subscriptions
    @user.sales.joins(:subscription).exists?
  end

  # Returns a cache key based on the granularity we are storing.
  # • Daily  → one key per yyyy-mm-dd
  # • Monthly → one key per yyyy-mm
  def cache_key_for_churn_data(date, aggregate_by: "daily")
    if aggregate_by == "monthly"
      month_key = date.strftime("%Y-%m")
      "#{user_cache_key}_churn_monthly_for_#{month_key}"
    else
      "#{user_cache_key}_churn_daily_for_#{date}"
    end
  end

  def today_date
    Time.now.in_time_zone(@user.timezone).to_date
  end

  def last_date_to_cache
    today_date - 2.days
  end

  def user_cache_key
    return @_user_cache_key if @_user_cache_key
    version = $redis.get(RedisKey.seller_analytics_cache_version) || 0
    @_user_cache_key = "seller_churn_analytics_v#{version}_user_#{@user.id}_#{@user.timezone}"
  end

  # Returns array of dates missing from the cache
  def uncached_dates(dates, aggregate_by: "daily")
    dates_to_keys = dates.index_with { |date| cache_key_for_churn_data(date, aggregate_by: aggregate_by) }
    existing_keys = ComputedChurnAnalyticsDay.where(key: dates_to_keys.values).pluck(:key)
    missing_keys = dates_to_keys.values - existing_keys
    dates_to_keys.invert.values_at(*missing_keys)
  end

  # Constrains the date range coming from the web browser
  # Uses first_sale_created_at_for_analytics like sales analytics
  def requested_dates(start_date, end_date)
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

  # Direct proxy for CreatorAnalytics::Churn
  def analytics_data(start_date, end_date, aggregate_by: "daily", products: nil)
    CreatorAnalytics::Churn.new(
      user: @user,
      products: products || @user.products_for_creator_analytics,
      dates: (start_date .. end_date).to_a,
      aggregate_by: aggregate_by
    ).by_date
  end

  # Fetches and caches the churn data for one specific date
  def fetch_data(date, aggregate_by: "daily")
    # Don't cache today or yesterday
    return analytics_data(date.beginning_of_month, date.end_of_month, aggregate_by: aggregate_by) if date > last_date_to_cache

    range_start, range_end = if aggregate_by == "monthly"
      [date.beginning_of_month, date.end_of_month]
    else
      [date, date]
    end

    ComputedChurnAnalyticsDay.fetch_data_from_key(cache_key_for_churn_data(date, aggregate_by: aggregate_by)) do
      analytics_data(range_start, range_end, aggregate_by: aggregate_by)
    end
  end

  # Takes an array of dates, returns a hash with matching stored data, or nil if missing.
  def fetch_data_for_dates(dates, aggregate_by: "daily")
    keys_to_dates = dates.index_by { |date| cache_key_for_churn_data(date, aggregate_by: aggregate_by) }
    existing_data_with_keys = ComputedChurnAnalyticsDay.read_data_from_keys(keys_to_dates.keys)
    existing_data_with_keys.transform_keys { |key| keys_to_dates[key] }
  end

  # Takes a hash of { date => (data | nil) }, returns an array of data for all days.
  def compile_data_for_dates_and_fill_missing(data_for_dates, aggregate_by: "daily")
    missing_date_ranges = find_missing_date_ranges(data_for_dates)
    data_for_dates.flat_map do |date, day_data|
      next day_data if day_data
      missing_range = missing_date_ranges.find { |range| range.begin == date }
      analytics_data(missing_range.begin, missing_range.end, aggregate_by: aggregate_by) if missing_range
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

  # Merges several churn results into singular data.
  # Similar to merge_data_by_date in sales analytics
  def merge_churn_data_by_date(days_data, dates)
    return {} if days_data.empty?

    # It's a hash with date keys mapping to { churned_users:, revenue_lost_cents:, churn_rate:, active_subscribers: }
    merged_data = {}

    days_data.each do |day_data|
      day_data.each do |date_key, metrics|
        merged_data[date_key] = metrics
      end
    end

    merged_data
  end
end
