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

    if params[:product_ids].blank?
      if aggregate_by == "monthly"
        date_keys = (@start_date .. @end_date).to_a.group_by { |date| date.strftime("%Y-%m") }.keys.sort
        dates = date_keys.map { |ym| Date.strptime("#{ym}-01", "%Y-%m-%d").strftime("%B %Y") }
      else
        date_keys = (@start_date .. @end_date).to_a.map(&:to_s)
        dates = date_keys.map do |d|
          date = Date.parse(d)
          date.strftime("%A, %B #{date.day.ordinalize}")
        end
      end

      render json: {
        dates:,
        start_date: dates.first,
        end_date: dates.last,
        by_date: {
          churn_rate: Array.new(dates.length, 0.0),
          churned_users: Array.new(dates.length, 0),
          revenue_lost_cents: Array.new(dates.length, 0),
        },
        total: {
          churn_rate: 0.0,
          churned_users: 0,
          revenue_lost_cents: 0,
          avg_active_base: 0,
        },
        last_period: {
          churn_rate: 0.0,
          churned_users: 0,
          revenue_lost_cents: 0,
        },
      }
      return
    end

    products = current_seller.products_for_creator_analytics.by_external_ids(params[:product_ids])

    caching_proxy = CreatorAnalytics::ChurnCachingProxy.new(current_seller)
    service_data = caching_proxy.data_for_dates(@start_date, @end_date, aggregate_by: aggregate_by, products: products)

    churn_service = CreatorAnalytics::Churn.new(
      user: current_seller,
      products: products,
      dates: (@start_date .. @end_date).to_a,
      aggregate_by: aggregate_by
    )
    total_stats = churn_service.total_stats
    last_period_stats = churn_service.last_period_stats

    if aggregate_by == "monthly"
      date_keys = (@start_date .. @end_date).to_a.group_by { |date| date.strftime("%Y-%m") }.keys.sort
      dates = date_keys.map { |ym| Date.strptime("#{ym}-01", "%Y-%m-%d").strftime("%B %Y") }
    else
      date_keys = (@start_date .. @end_date).to_a.map(&:to_s)
      dates = date_keys.map do |d|
        date = Date.parse(d)
        date.strftime("%A, %B #{date.day.ordinalize}")
      end
    end

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

    first_sale_created_at = current_seller.first_sale_created_at_for_analytics

    payload = {
      dates: dates,
      start_date: dates.first,
      end_date: dates.last,
      by_date: {
        churn_rate: churn_rate_arr,
        churned_users: churned_users_arr,
        revenue_lost_cents: revenue_lost_arr,
      },
      total: {
        churn_rate: total_stats[:churn_rate],
        churned_users: total_stats[:churned_users],
        revenue_lost_cents: total_stats[:revenue_lost_cents],
        avg_active_base: total_stats[:avg_active_base],
      },
      last_period: {
        churn_rate: last_period_stats[:churn_rate],
        churned_users: last_period_stats[:churned_users],
        revenue_lost_cents: last_period_stats[:revenue_lost_cents],
      },
    }

    if first_sale_created_at
      payload[:first_sale_date] = first_sale_created_at.in_time_zone(current_seller.timezone).strftime("%B %d, %Y")
    end

    render json: payload
  end

  protected
    def set_title
      @title = "Analytics"
    end

    def set_time_range
      begin
        end_time = Date.parse(params[:end_time])
        start_date = Date.parse(params[:start_time])
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
      @start_date = start_date.clamp(earliest_date, today)
      @end_date = end_time.clamp(@start_date, today)
    end
end
