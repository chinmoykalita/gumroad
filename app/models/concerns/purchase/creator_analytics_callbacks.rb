# frozen_string_literal: true

module Purchase::CreatorAnalyticsCallbacks
  extend ActiveSupport::Concern

    included do
    after_commit :update_creator_analytics_cache, on: :update
    after_commit :update_churn_analytics_cache, on: :update

    def update_creator_analytics_cache(force: false)
      return if !force && !%w[chargeback_date flags purchase_state stripe_refunded].intersect?(previous_changes.keys)

      # Do not attempt to update the cache if the purchase exists for the seller's Today,
      # as we're not caching data for that day.
      purchase_cache_date = created_at.in_time_zone(seller.timezone).to_date
      today_date = Time.now.in_time_zone(seller.timezone).to_date
      return if purchase_cache_date == today_date

      RegenerateCreatorAnalyticsCacheWorker.perform_in(2.seconds, seller_id, purchase_cache_date.to_s)
    end

    def update_churn_analytics_cache(force: false)
      # Only trigger for subscription purchases
      return unless subscription_id.present?

      subscription_fields = %w[subscription_deactivated_at chargeback_date flags purchase_state stripe_refunded]
      return if !force && !subscription_fields.intersect?(previous_changes.keys)

      cache_date = if previous_changes.key?('subscription_deactivated_at') && subscription_deactivated_at.present?
        subscription_deactivated_at.in_time_zone(seller.timezone).to_date
      else
        created_at.in_time_zone(seller.timezone).to_date
      end

      # Don't cache today's data
      today_date = Time.now.in_time_zone(seller.timezone).to_date
      return if cache_date == today_date

      RegenerateChurnAnalyticsCacheWorker.perform_in(2.seconds, seller_id, cache_date.to_s)
    end
  end
end
