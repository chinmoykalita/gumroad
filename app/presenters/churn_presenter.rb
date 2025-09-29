# frozen_string_literal: true

class ChurnPresenter
  def initialize(seller:)
    @seller = seller
  end

  def page_props
    {
      products: subscription_products.map { |product| { id: product.external_id, alive: product.alive?, unique_permalink: product.unique_permalink, name: product.name } },
      aggregate_options: aggregate_options_props
    }
  end

  # Formats the Date-keyed churn analytics data returned by the service
  # into the structure expected by the frontend.
  #
  # Expected output shape:
  # {
  #   chart_points: [{ churn_rate, churned_users, revenue_lost_cents, title, label }, ...],
  #   totals: { churn_rate, last_period_churn_rate, revenue_lost_cents, churned_users },
  #   first_sale_date: "June 01, 2025" | nil
  # }
  def serialize_churn(data:, aggregate_by: CreatorAnalytics::Churn::AGGREGATE_BY_DAY)
    start_date = data[:start_date]
    end_date = data[:end_date]
    period_data = data[:period_data] || {}

    date_keys, formatted_dates = format_dates_for_display(start_date:, end_date:, aggregate_by:)

    chart_points = date_keys.each_with_index.map do |k, index|
      values = period_data[k] || {}
      {
        churn_rate: values[:churn_rate] || 0.0,
        churned_users: values[:churned_users] || 0,
        revenue_lost_cents: values[:revenue_lost_cents] || 0,
        title: formatted_dates[index],
        label: (index == 0 ? formatted_dates.first : (index == date_keys.size - 1 ? formatted_dates.last : ""))
      }
    end

    total = data[:total] || {}
    last = data[:last_period] || {}
    totals = {
      churn_rate: total[:churn_rate] || 0.0,
      last_period_churn_rate: last[:churn_rate] || 0.0,
      revenue_lost_cents: total[:revenue_lost_cents] || 0,
      churned_users: total[:churned_users] || 0
    }

    {
      chart_points: chart_points,
      totals: totals,
      first_sale_date: format_first_sale_date(data[:first_sale_date])
    }
  end

  private
    attr_reader :seller

    def subscription_products
      CreatorAnalytics::Churn.new(seller: seller).subscription_products
    end

    def aggregate_options_props
      CreatorAnalytics::Churn::AGGREGATE_OPTIONS.map do |value, config|
        { value: value, title: config[:title] }
      end
    end

    def format_dates_for_display(start_date:, end_date:, aggregate_by:)
      if aggregate_by == CreatorAnalytics::Churn::AGGREGATE_BY_MONTH
        date_keys = generate_monthly_dates(start_date, end_date)
        formatted = date_keys.map { it.strftime("%B %Y") }
      else
        date_keys = (start_date..end_date).to_a
        formatted = date_keys.map { it.strftime("%A, %B #{it.day.ordinalize}") }
      end

      [date_keys, formatted]
    end

    def generate_monthly_dates(start_date, end_date)
      cursor = Date.new(start_date.year, start_date.month, 1)
      last_month_start = Date.new(end_date.year, end_date.month, 1)

      [].tap do |dates|
        while cursor <= last_month_start
          dates << cursor
          cursor = cursor >> 1
        end
      end
    end

    def format_first_sale_date(date)
      return nil unless date
      date.strftime("%B %d, %Y")
    end
end
