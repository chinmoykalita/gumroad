# frozen_string_literal: true

module CreatorAnalytics
  module Shared
    class ChurnUtilities
      ZERO_STATS = {
        churned_users: 0,
        revenue_lost_cents: 0,
        churn_rate: 0.0,
        avg_active_base: 0
      }.freeze

      # Calculate total stats from period data using weighted average approach
      # This method handles both cached data (with nil protection) and service data
      def self.calculate_total_stats_from_data(periods_data)
        return ZERO_STATS if periods_data.empty?

        total_churned = periods_data.sum { |period| period[:churned_users] || 0 }
        total_revenue_lost = periods_data.sum { |period| period[:revenue_lost_cents] || 0 }

        # Calculate weighted average churn rate
        # This approach:
        # 1. Gives more weight to periods with larger subscriber bases
        # 2. Prevents >100% churn rates for growing businesses
        # 3. Provides meaningful aggregate churn rate across entire period
        periods_with_data = periods_data.select { |period| (period[:active_subscribers] || 0) > 0 }

        if periods_with_data.any?
          total_weighted_churn = periods_with_data.sum { |period|
            (period[:churn_rate] || 0) * (period[:active_subscribers] || 0)
          }
          total_subscriber_base = periods_with_data.sum { |period| period[:active_subscribers] || 0 }
          avg_churn_rate = total_subscriber_base > 0 ? (total_weighted_churn / total_subscriber_base).round(2) : 0.0
          avg_churn_rate = avg_churn_rate.clamp(0.0, 100.0)
        else
          avg_churn_rate = 0.0
        end

        active_bases = periods_data.map { |period| period[:active_subscribers] || 0 }
        avg_active_base = active_bases.empty? ? 0 : active_bases.sum / active_bases.size.to_f

        {
          churned_users: total_churned,
          revenue_lost_cents: total_revenue_lost,
          churn_rate: avg_churn_rate,
          avg_active_base: avg_active_base.to_i
        }
      end

      # Calculate last period date range based on current period
      def self.calculate_last_period_dates(start_date, end_date, aggregate_by)
        if aggregate_by == "monthly"
          # For monthly aggregation, work with complete months
          # Calculate how many months the current period spans
          months_in_period = (end_date.year - start_date.year) * 12 + (end_date.month - start_date.month) + 1

          # Calculate last period by going back the same number of months
          last_period_end = start_date.beginning_of_month - 1.day
          last_period_start = (last_period_end + 1.day - months_in_period.months).beginning_of_month
        else
          period_length_days = (end_date - start_date).to_i + 1
          last_period_end = start_date - 1.day
          last_period_start = last_period_end - (period_length_days - 1).days
        end

        [last_period_start, last_period_end]
      end

      # Format dates for API response display
      def self.format_dates_for_display(start_date, end_date, aggregate_by)
        if aggregate_by == "monthly"
          date_keys = (start_date..end_date).to_a.group_by { |date| date.strftime("%Y-%m") }.keys.sort
          formatted_dates = date_keys.map { |ym| Date.strptime("#{ym}-01", "%Y-%m-%d").strftime("%B %Y") }
        else
          date_keys = (start_date..end_date).to_a.map(&:to_s)
          formatted_dates = date_keys.map do |d|
            date = Date.parse(d)
            date.strftime("%A, %B #{date.day.ordinalize}")
          end
        end

        [date_keys, formatted_dates]
      end

      # Build arrays for chart data from service data
      def self.build_by_date_arrays(date_keys, service_data)
        churned_users_arr = []
        revenue_lost_arr = []
        churn_rate_arr = []

        date_keys.each do |date_key|
          period_data = service_data[date_key]
          churned = period_data ? period_data[:churned_users] : 0
          revenue = period_data ? period_data[:revenue_lost_cents] : 0
          churn_rate = period_data ? period_data[:churn_rate] : 0.0

          churned_users_arr << churned
          revenue_lost_arr << revenue
          churn_rate_arr << churn_rate
        end

        {
          churn_rate: churn_rate_arr,
          churned_users: churned_users_arr,
          revenue_lost_cents: revenue_lost_arr
        }
      end

      # Format first sale date
      def self.format_first_sale_date(user)
        first_sale_created_at = user.first_sale_created_at_for_analytics
        return nil unless first_sale_created_at

        first_sale_created_at.in_time_zone(user.timezone).strftime("%B %d, %Y")
      end

      # Calculate last period stats using any data source (cached or real-time)
      def self.calculate_last_period_stats(user, start_date, end_date, aggregate_by, products, data_source)
        last_period_start, last_period_end = calculate_last_period_dates(start_date, end_date, aggregate_by)

        first_sale_created_at = user.first_sale_created_at_for_analytics
        if first_sale_created_at
          earliest_date = first_sale_created_at.in_time_zone(user.timezone).to_date
          return ZERO_STATS if last_period_start < earliest_date
        end

        return ZERO_STATS if last_period_start >= last_period_end

        last_period_data = data_source.call(last_period_start, last_period_end, aggregate_by, products)

        calculate_total_stats_from_data(last_period_data.values)
      rescue => e
        Rails.logger.warn("Failed to calculate last period churn stats: #{e.message}")
        ZERO_STATS
      end
    end
  end
end
