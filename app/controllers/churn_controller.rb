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
                                        .select { it.is_recurring_billing? || it.is_tiered_membership? }

    products = if params[:product_ids].present?
      subscription_products.select { params[:product_ids].include?(it.external_id) }
    else
      subscription_products
    end

    analytics_data = CreatorAnalytics::Churn.new(
      seller: current_seller,
      products:,
      dates: (@start_date..@end_date),
      aggregate_by:
    ).data

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
      rescue Date::Error
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
