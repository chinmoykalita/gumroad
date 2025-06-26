# frozen_string_literal: true

class ChurnPresenter
  def initialize(seller:)
    @seller = seller
  end

  def page_props
    {
      products: subscription_products.map { product_props(_1) }
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
end
