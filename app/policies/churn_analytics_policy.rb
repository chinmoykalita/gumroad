# frozen_string_literal: true

class ChurnAnalyticsPolicy < ApplicationPolicy
  def index?
    Feature.active?(:churn_analytics_enabled, seller) &&
      seller_has_subscription_products? &&
      (
        user.role_admin_for?(seller) ||
        user.role_marketing_for?(seller) ||
        user.role_support_for?(seller) ||
        user.role_accountant_for?(seller)
      )
  end

  private
    def seller_has_subscription_products?
      seller.products_for_creator_analytics.any? { it.is_recurring_billing? || it.is_tiered_membership? }
    end
end
