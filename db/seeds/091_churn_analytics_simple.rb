# frozen_string_literal: true

=begin
Deterministic churn analytics seed for June–August 2025
After running this seed, login with id
email: churn-deterministic@example.com
password: StrongP@ssw0rd-Deterministic-2025

Entities:
- Seller: churn-deterministic@example.com (UTC)
- Products:
  - deterministic_alpha ($10/month)
  - deterministic_beta ($20/month)

Construction:
- All subscriptions start before June (so they are in June active base):
  - Alpha: 10 subscriptions created on 2025-05-15 10:00 UTC
  - Beta:  5 subscriptions created on 2025-05-20 10:00 UTC

- Deactivations (cancellations) schedule:
  - June 2025:
    - Alpha: 2025-06-05, 2025-06-10, 2025-06-25  (3 churns)
    - Beta:  2025-06-12, 2025-06-28               (2 churns)
    => June churned users: 5
    => June revenue lost (price_cents): 3*1000 + 2*2000 = 7000c ($70)
    => June active base (at 2025-06-01): 10 + 5 = 15
    => June churn rate: 5 / 15 * 100 = 33.33%

  - July 2025:
    - Alpha: 2025-07-10, 2025-07-20               (2 churns)
    - Beta:  2025-07-22                            (1 churn)
    => July churned users: 3
    => July revenue lost (price_cents): 2*1000 + 1*2000 = 4000c ($40)
    => July active base (at 2025-07-01): (10-3) + (5-2) = 7 + 3 = 10
    => July churn rate: 3 / 10 * 100 = 30.00%

  - August 2025 (through Aug 28):
    - Alpha: 2025-08-03                            (1 churn)
    - Beta:  2025-08-15                            (1 churn)
    => August churned users: 2
    => August revenue lost (price_cents): 1*1000 + 1*2000 = 3000c ($30)
    => August active base (at 2025-08-01): (7-2) + (3-1) = 5 + 2 = 7
    => August churn rate: 2 / 7 * 100 = 28.57%

Notes:
- The churn service aggregates revenue lost using price_cents of the original purchase.
- Active base is computed at the period start using the service's ES filters.
- The chosen dates avoid boundary cases (no deactivations on the 1st of any month).

Verification:
- Visit /dashboard/churn?from=2025-06-01&to=2025-08-28 and select both products.
- Monthly view should show:
  - June:   churned_users=5,  revenue_lost=$70, churn_rate=33.33%
  - July:   churned_users=3,  revenue_lost=$40, churn_rate=30.00%
  - August: churned_users=2,  revenue_lost=$30, churn_rate=28.57%
  - Totals over the 3 months should reflect sums and a weighted average churn rate by base.

Product-wise monthly breakdown (when filtering by a single product):

- Alpha ($10/month):
  - June 2025:   churned_users=3, revenue_lost=$30, churn_rate=30.00% (base 10)
  - July 2025:   churned_users=2, revenue_lost=$20, churn_rate=28.57% (base 7)
  - August 2025: churned_users=1, revenue_lost=$10, churn_rate=20.00% (base 5)

- Beta ($20/month):
  - June 2025:   churned_users=2, revenue_lost=$40, churn_rate=40.00% (base 5)
  - July 2025:   churned_users=1, revenue_lost=$20, churn_rate=33.33% (base 3)
  - August 2025: churned_users=1, revenue_lost=$20, churn_rate=50.00% (base 2)
=end

if Rails.env.production?
  puts "Skipping deterministic churn seeds in production"
  return
end

unless defined?(seed_log)
  def seed_log(msg)
    puts msg unless Rails.env.test?
  end
end

seed_log "Seeding deterministic churn analytics data for 2025-06 to 2025-08"

def ensure_seller(email: "churn-deterministic@example.com")
  User.find_or_create_by!(email:) do |u|
    u.password = "StrongP@ssw0rd-Deterministic-2025"
    u.name = "Deterministic Churn Seller"
    u.username = "deterministicseller"
    u.timezone = "UTC"
    u.user_risk_state = "not_reviewed"
    u.confirmed_at = Time.current
  end
end

def ensure_membership_product!(seller:, unique_permalink:, name:, price_cents:)
  product = Link.find_or_initialize_by(unique_permalink: unique_permalink)
  product.user = seller
  product.name = name
  product.description ||= "Deterministic membership product for churn analytics"
  product.filetype ||= "link"
  product.filegroup ||= "url"
  product.price_cents = price_cents
  product.price_currency_type = "usd"
  product.display_product_reviews = false
  product.is_recurring_billing = true
  product.subscription_duration = :monthly
  product.is_tiered_membership = false
  product.native_type = Link::NATIVE_TYPE_MEMBERSHIP rescue product.native_type
  product.save!

  monthly_price = product.prices.where(recurrence: "monthly", currency: "usd").first
  monthly_price ||= product.prices.create!(price_cents:, currency: "usd", recurrence: "monthly")
  monthly_price

  product
end

def ensure_buyer!(idx: 0)
  email = sprintf("determ-buyer-%03d@example.com", idx)
  user = User.find_or_create_by!(email:) do |u|
    u.password = "Determin1stic##{idx}"
    u.name = "Determin Buyer #{idx}"
    u.username = "determbuyer#{idx}"
    u.user_risk_state = "not_reviewed"
    u.confirmed_at = Time.current
  end
  if user.encrypted_password.blank?
    user.password = "Determin1stic##{idx}"
    user.save!(validate: false)
  end
  user
end

def ensure_subscription!(seller:, product:, buyer:, created_time:, deactivated_time: nil)
  sub = Subscription.find_or_initialize_by(seller:, link: product, user: buyer)
  was_new = sub.new_record?
  sub.created_at ||= created_time

  price = product.default_price || product.alive_prices.where(currency: product.price_currency_type).select(&:is_buy?).last
  sub.payment_options.build(price:) if sub.payment_options.blank? && price.present?

  sub.save!
  if was_new
    sub.update_columns(created_at: created_time)
  end
  if deactivated_time
    sub.deactivated_at = deactivated_time
    sub.cancelled_at ||= deactivated_time
    sub.save!
    sub.update_columns(deactivated_at: deactivated_time, cancelled_at: sub.cancelled_at)
  end

  if sub.payment_options.reload.blank? && price.present?
    PaymentOption.find_or_create_by!(subscription: sub, price: price)
  end

  sub
end

def ensure_original_purchase!(subscription:, product:, seller:, buyer:, price_cents:, created_time:)
  purchase = Purchase.where(subscription:, link: product, seller:, purchaser: buyer).where("flags & ? > 0", Purchase.flag_mapping["flags"][:is_original_subscription_purchase]).first
  purchase ||= Purchase.new(subscription:, link: product, seller:, purchaser: buyer)

  purchase.email = buyer.email
  purchase.price_cents = price_cents
  purchase.displayed_price_cents = price_cents
  purchase.tax_cents ||= 0
  purchase.gumroad_tax_cents ||= 0
  purchase.total_transaction_cents = (purchase.price_cents || 0)
  purchase.ip_address ||= "199.241.200.176"
  purchase.ip_country ||= "United States"
  purchase.ip_state ||= "CA"
  purchase.created_at ||= created_time
  purchase.is_original_subscription_purchase = true

  purchase.skip_preparing_for_charge = true if purchase.respond_to?(:skip_preparing_for_charge=)
  purchase.send(:calculate_fees) if purchase.respond_to?(:calculate_fees, true)
  purchase.save!(validate: false)
  purchase.update_columns(purchase_state: "successful", succeeded_at: created_time, created_at: created_time)

  purchase
end

ActiveRecord::Base.transaction do
  seller = ensure_seller

  alpha = ensure_membership_product!(seller: seller, unique_permalink: "deterministic_alpha", name: "Deterministic Alpha Membership", price_cents: 1000)
  beta  = ensure_membership_product!(seller: seller, unique_permalink: "deterministic_beta",  name: "Deterministic Beta Membership",  price_cents: 2000)

  # Creation dates (before June 1st, 2025)
  alpha_created_at = Time.utc(2025, 5, 15, 10, 0, 0)
  beta_created_at  = Time.utc(2025, 5, 20, 10, 0, 0)

  buyer_idx = 0

  # Create Alpha subscriptions: 10
  alpha_subs = 10.times.map do
    buyer_idx += 1
    buyer = ensure_buyer!(idx: buyer_idx)
    ensure_subscription!(seller: seller, product: alpha, buyer: buyer, created_time: alpha_created_at)
  end

  # Create Beta subscriptions: 5
  beta_subs = 5.times.map do
    buyer_idx += 1
    buyer = ensure_buyer!(idx: buyer_idx)
    ensure_subscription!(seller: seller, product: beta, buyer: buyer, created_time: beta_created_at)
  end

  # Deactivations
  # June (Alpha: 3, Beta: 2)
  [Time.utc(2025, 6, 5, 10, 0, 0), Time.utc(2025, 6, 10, 10, 0, 0), Time.utc(2025, 6, 25, 10, 0, 0)].each_with_index do |dt, i|
    sub = alpha_subs[i]
    ensure_subscription!(seller: seller, product: alpha, buyer: sub.user, created_time: alpha_created_at, deactivated_time: dt)
  end

  [Time.utc(2025, 6, 12, 10, 0, 0), Time.utc(2025, 6, 28, 10, 0, 0)].each_with_index do |dt, i|
    sub = beta_subs[i]
    ensure_subscription!(seller: seller, product: beta, buyer: sub.user, created_time: beta_created_at, deactivated_time: dt)
  end

  # July (Alpha: 2, Beta: 1)
  [Time.utc(2025, 7, 10, 10, 0, 0), Time.utc(2025, 7, 20, 10, 0, 0)].each_with_index do |dt, i|
    sub = alpha_subs[3 + i]
    ensure_subscription!(seller: seller, product: alpha, buyer: sub.user, created_time: alpha_created_at, deactivated_time: dt)
  end

  [Time.utc(2025, 7, 22, 10, 0, 0)].each_with_index do |dt, i|
    sub = beta_subs[2 + i]
    ensure_subscription!(seller: seller, product: beta, buyer: sub.user, created_time: beta_created_at, deactivated_time: dt)
  end

  # August (through 28th) (Alpha: 1, Beta: 1)
  [Time.utc(2025, 8, 3, 10, 0, 0)].each_with_index do |dt, i|
    sub = alpha_subs[5 + i]
    ensure_subscription!(seller: seller, product: alpha, buyer: sub.user, created_time: alpha_created_at, deactivated_time: dt)
  end

  [Time.utc(2025, 8, 15, 10, 0, 0)].each_with_index do |dt, i|
    sub = beta_subs[3 + i]
    ensure_subscription!(seller: seller, product: beta, buyer: sub.user, created_time: beta_created_at, deactivated_time: dt)
  end

  # Ensure original purchases exist for all subscriptions
  (alpha_subs + beta_subs).each do |sub|
    product = sub.link
    price_cents = product.default_price_cents || product.price_cents
    created_time = (product == alpha ? alpha_created_at : beta_created_at)
    ensure_original_purchase!(subscription: sub, product: product, seller: seller, buyer: sub.user, price_cents: price_cents, created_time: created_time)
  end
end

begin
  if defined?(Purchase) && Purchase.respond_to?(:__elasticsearch__)
    begin
      Purchase.__elasticsearch__.create_index!(force: false)
    rescue StandardError
    end
    Purchase.import(refresh: true)
    seed_log "Reindexed purchases into Elasticsearch"
  end
rescue StandardError => e
  seed_log "Elasticsearch not available or reindex failed: #{e.class}: #{e.message}"
end

seed_log "Deterministic churn analytics data seeded"
