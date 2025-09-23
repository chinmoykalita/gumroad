# frozen_string_literal: true

class ChurnController < Sellers::BaseController
  before_action :set_body_id_as_app
  before_action :check_payment_details, only: :index
  before_action :parse_and_validate_dates, only: :data

  def index
    authorize :churn_analytics, :index?

    @churn_props = ChurnPresenter.new(seller: current_seller).page_props
  end

  def data
    authorize :churn_analytics, :index?

    aggregate_by = CreatorAnalytics::Churn::AGGREGATE_OPTIONS.key?(params[:aggregate_by]) ? params[:aggregate_by] : CreatorAnalytics::Churn::AGGREGATE_BY_DAY

    churn_service = CreatorAnalytics::Churn.new(seller: current_seller)
    analytics_data = churn_service.generate_data(
      product_ids: params[:product_ids],
      dates: @start_date..@end_date,
      aggregate_by:
    )

    render json: analytics_data
  end

  protected
    def set_title
      @title = "Churn analytics"
    end

    def parse_and_validate_dates
      begin
        end_date = Date.parse(strip_timestamp_location(params[:end_time]))
        start_date = Date.parse(strip_timestamp_location(params[:start_time]))
      rescue Date::Error
        end_date = Date.current
        start_date = end_date.ago(29.days).to_date
      end

      earliest_date = \
        current_seller.first_sale_created_at_for_analytics&.in_time_zone(current_seller.timezone)&.to_date ||
        current_seller.created_at.in_time_zone(current_seller.timezone).to_date

      today = Date.current
      earliest_date = [earliest_date, today].min
      @start_date = start_date.clamp(earliest_date, today)
      @end_date = end_date.clamp(@start_date, today)
    end
end
