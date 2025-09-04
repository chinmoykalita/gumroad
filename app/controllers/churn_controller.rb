# frozen_string_literal: true

class ChurnController < Sellers::BaseController
  before_action :set_body_id_as_app
  before_action :check_payment_details, only: :index
  before_action :set_time_range, only: :data

  def index
    authorize :analytics, :index?

    @churn_props = ChurnPresenter.new(seller: current_seller).page_props
  end

  def data
    authorize :analytics, :index?

    aggregate_by = CreatorAnalytics::Churn::AGGREGATE_OPTIONS.key?(params[:aggregate_by]) ? params[:aggregate_by] : CreatorAnalytics::Churn::AGGREGATE_BY_DAY

    subscription_products = current_seller.products_for_creator_analytics
                                        .select { |p| p.is_recurring_billing? || p.is_tiered_membership? }

    products = if params[:product_ids].present?
      subscription_products.select { |p| params[:product_ids].include?(p.external_id) }
    else
      subscription_products
    end

    service_data = CreatorAnalytics::Churn.new(
      user: current_seller,
      products: products,
      dates: (@start_date..@end_date).to_a,
      aggregate_by: aggregate_by
    ).data

    total_stats = calculate_total_stats_from_data(service_data.values)

    data_source = lambda do |start_date, end_date, agg, prods|
      CreatorAnalytics::Churn.new(
        user: current_seller,
        products: (prods.presence || subscription_products),
        dates: (start_date..end_date).to_a,
        aggregate_by: agg
      ).data
    end

    last_period_stats = calculate_last_period_stats(current_seller, @start_date, @end_date, aggregate_by, products, data_source)

    date_keys, formatted_dates = format_dates_for_display(@start_date, @end_date, aggregate_by)
    by_date_arrays = build_by_date_arrays(date_keys, service_data)

    analytics_data = {
      dates: formatted_dates,
      start_date: formatted_dates.first,
      end_date: formatted_dates.last,
      by_date: by_date_arrays,
      total: total_stats,
      last_period: last_period_stats,
      first_sale_date: format_first_sale_date(current_seller)
    }

    render json: analytics_data
  end

  protected
    def set_title
      @title = "Analytics"
    end

    def set_time_range
      begin
        end_time = Date.parse(strip_timestamp_location(params[:end_time]))
        start_date = Date.parse(strip_timestamp_location(params[:start_time]))
      rescue StandardError
        end_time = Date.current
        start_date = end_time.ago(29.days).to_date
      end

      first_sale_created_at = current_seller.first_sale_created_at_for_analytics
      earliest_date = if first_sale_created_at
        first_sale_created_at.in_time_zone(current_seller.timezone).to_date
      else
        current_seller.created_at.in_time_zone(current_seller.timezone).to_date
      end

      today = Date.current
      earliest_date = [earliest_date, today].min
      @start_date = start_date.clamp(earliest_date, today)
      @end_date = end_time.clamp(@start_date, today)
    end

  private
    ZERO_STATS = {
      churned_users: 0,
      revenue_lost_cents: 0,
      churn_rate: 0.0,
      avg_active_base: 0
    }.freeze

    def calculate_total_stats_from_data(periods_data)
      return ZERO_STATS if periods_data.empty?

      total_churned = periods_data.sum { |p| p[:churned_users] || 0 }
      total_revenue_lost = periods_data.sum { |p| p[:revenue_lost_cents] || 0 }

      periods_with_base = periods_data.select { |p| (p[:active_subscribers] || 0) > 0 }
      avg_churn_rate = if periods_with_base.any?
        total_weighted = periods_with_base.sum { |p| (p[:churn_rate] || 0) * (p[:active_subscribers] || 0) }
        base_sum = periods_with_base.sum { |p| p[:active_subscribers] || 0 }
        (base_sum > 0 ? (total_weighted / base_sum).round(2) : 0.0)
      else
        0.0
      end
      avg_churn_rate = avg_churn_rate.clamp(0.0, 100.0)

      active_bases = periods_data.map { |p| p[:active_subscribers] || 0 }
      avg_active_base = active_bases.empty? ? 0 : (active_bases.sum / active_bases.size.to_f)

      {
        churned_users: total_churned,
        revenue_lost_cents: total_revenue_lost,
        churn_rate: avg_churn_rate,
        avg_active_base: avg_active_base.to_i
      }
    end

    def calculate_last_period_stats(user, start_date, end_date, aggregate_by, products, data_source)
      last_start, last_end = calculate_last_period_dates(start_date, end_date, aggregate_by)

      first_sale_created_at = user.first_sale_created_at_for_analytics
      if first_sale_created_at
        earliest_date = first_sale_created_at.in_time_zone(user.timezone).to_date
        return ZERO_STATS if last_start < earliest_date
      end
      return ZERO_STATS if last_start >= last_end

      last_period_data = data_source.call(last_start, last_end, aggregate_by, products)
      calculate_total_stats_from_data(last_period_data.values)
    rescue => e
      Rails.logger.warn("Failed to calculate last period churn stats: #{e.message}")
      ZERO_STATS
    end

    def calculate_last_period_dates(start_date, end_date, aggregate_by)
      if aggregate_by == CreatorAnalytics::Churn::AGGREGATE_BY_MONTH
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

    def format_dates_for_display(start_date, end_date, aggregate_by)
      if aggregate_by == CreatorAnalytics::Churn::AGGREGATE_BY_MONTH
        date_keys = (start_date..end_date).to_a.group_by { |d| d.strftime("%Y-%m") }.keys.sort
        formatted = date_keys.map { |ym| Date.strptime("#{ym}-01", "%Y-%m-%d").strftime("%B %Y") }
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
      churned = []
      revenue = []
      churn_rate = []
      date_keys.each do |key|
        data = service_data[key]
        churned << (data ? data[:churned_users] : 0)
        revenue << (data ? data[:revenue_lost_cents] : 0)
        churn_rate << (data ? data[:churn_rate] : 0.0)
      end
      { churn_rate: churn_rate, churned_users: churned, revenue_lost_cents: revenue }
    end

    def format_first_sale_date(user)
      first_sale_created_at = user.first_sale_created_at_for_analytics
      return nil unless first_sale_created_at
      first_sale_created_at.in_time_zone(user.timezone).strftime("%B %d, %Y")
    end
end
