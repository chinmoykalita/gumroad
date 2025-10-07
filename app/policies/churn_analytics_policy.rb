# frozen_string_literal: true

class ChurnAnalyticsPolicy < ApplicationPolicy
  def index?
    Feature.active?(:churn_analytics_enabled, seller) &&
    (
      user.role_admin_for?(seller) ||
      user.role_marketing_for?(seller) ||
      user.role_support_for?(seller) ||
      user.role_accountant_for?(seller)
    ) &&
      seller_has_subscription_products?
  end

  private
    def seller_has_subscription_products?
      CreatorAnalytics::Churn.new(seller: seller).subscription_products.any?
    end
end
