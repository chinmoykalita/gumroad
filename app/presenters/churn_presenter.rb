# frozen_string_literal: true

class ChurnPresenter
  def initialize(seller:)
    @seller = seller
  end

  def page_props
    {
      products: subscription_products.map { product_props(_1) },
      aggregate_options: aggregate_options_props
    }
  end

  private
    attr_reader :seller

    def subscription_products
      seller.products_for_creator_analytics.select { |p| p.is_recurring_billing? || p.is_tiered_membership? }
    end

    def product_props(product)
      { id: product.external_id, alive: product.alive?, unique_permalink: product.unique_permalink, name: product.name }
    end

    def aggregate_options_props
      CreatorAnalytics::Churn::AGGREGATE_OPTIONS.map do |value, config|
        { value: value, title: config[:title] }
      end
    end
end
