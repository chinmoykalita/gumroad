# frozen_string_literal: true

class ChurnController < Sellers::BaseController
  before_action :set_body_id_as_app
  before_action :check_payment_details, only: :index
  before_action :set_time_range, only: :data_by_date

  def index
    authorize :analytics, :index?

    @churn_props = ChurnPresenter.new(seller: current_seller).page_props

    LargeSeller.create_if_warranted(current_seller)
  end

  def data_by_date
    authorize :analytics, :index?

    aggregate_by = params[:aggregate_by] == "monthly" ? "monthly" : "daily"

    subscription_products = current_seller.products_for_creator_analytics.select { |p| p.is_recurring_billing? || p.is_tiered_membership? }

    if params[:product_ids].blank?
      products = []
    else
      products = subscription_products.select { |p| params[:product_ids].include?(p.external_id) }
    end

    caching_proxy = CreatorAnalytics::ChurnCachingProxy.new(current_seller)
    service_data = caching_proxy.data_for_dates(
      @start_date,
      @end_date,
      aggregate_by: aggregate_by,
      products: products
    )

    total_stats = CreatorAnalytics::Shared::ChurnUtilities.calculate_total_stats_from_data(service_data.values)

    data_source = lambda do |start_date, end_date, aggregate_by, products|
      caching_proxy.data_for_dates(start_date, end_date, aggregate_by: aggregate_by, products: products)
    end

    last_period_stats = CreatorAnalytics::Shared::ChurnUtilities.calculate_last_period_stats(
      current_seller, @start_date, @end_date, aggregate_by, products, data_source
    )

    date_keys, formatted_dates = CreatorAnalytics::Shared::ChurnUtilities.format_dates_for_display(@start_date, @end_date, aggregate_by)
    by_date_arrays = CreatorAnalytics::Shared::ChurnUtilities.build_by_date_arrays(date_keys, service_data)

    analytics_data = {
      dates: formatted_dates,
      start_date: formatted_dates.first,
      end_date: formatted_dates.last,
      by_date: by_date_arrays,
      total: total_stats,
      last_period: last_period_stats,
      first_sale_date: CreatorAnalytics::Shared::ChurnUtilities.format_first_sale_date(current_seller)
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
end
