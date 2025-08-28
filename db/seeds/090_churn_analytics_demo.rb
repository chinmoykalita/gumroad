# frozen_string_literal: true

# Creates a new seller, 3 products, and a set of buyers and subscriptions across 2024 -> Aug 19, 2025
# Data generated to resemble a real-world churn pattern with complex seasonal and product-specific churn

# After running this seed, login with id
# email: creator009@example.com
# password: OIh0923*h3h64$@

if Rails.env.production?
  puts "Skipping churn demo seeds in production"
  return
end

unless defined?(seed_log)
  def seed_log(msg)
    puts msg unless Rails.env.test?
  end
end

seed_log "Seeding churn analytics demo data"

def ensure_seller(email: "creator009@example.com")
  User.find_or_create_by!(email:) do |u|
    u.password = "OIh0923*h3h64$@"
    u.name = "Churn Demo Creator"
    u.username = "chrundemocreator009"
    u.timezone = "UTC"
    u.user_risk_state = "not_reviewed"
    u.confirmed_at = Time.current
  end
end

def ensure_membership_product!(seller:, unique_permalink:, name:, price_cents:)
  product = Link.find_or_initialize_by(unique_permalink: unique_permalink)
  product.user = seller
  product.name = name
  product.description ||= "Demo membership product for churn analytics"
  product.filetype ||= "link"
  product.filegroup ||= "url"
  product.price_cents = price_cents
  product.price_currency_type = "usd"
  product.display_product_reviews = true
  product.is_recurring_billing = true
  product.subscription_duration = :monthly
  product.is_tiered_membership = false
  # use membership native type for clarity, though not strictly required
  product.native_type = Link::NATIVE_TYPE_MEMBERSHIP rescue product.native_type
  product.save!

  monthly_price = product.prices.where(recurrence: "monthly", currency: "usd").first
  monthly_price ||= product.prices.create!(price_cents:, currency: "usd", recurrence: "monthly")
  monthly_price

  product
end

def ensure_buyer!(idx: 0)
  email = sprintf("churn-buyer-%03d@example.com", idx)
  user = User.find_or_create_by!(email:) do |u|
    u.password = "JLJop23#24#{idx}"
    u.name = "Churn Buyer #{idx}"
    u.username = "churnbuyer#{idx}"
    u.user_risk_state = "not_reviewed"
    u.confirmed_at = Time.current
  end
  if user.encrypted_password.blank?
    user.password = "JLJop23#24#{idx}"
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

  products = [
    ensure_membership_product!(seller:, unique_permalink: "churn_alpha", name: "Monthly Membership Alpha", price_cents: 1000),
    ensure_membership_product!(seller:, unique_permalink: "churn_beta", name: "Monthly Membership Beta", price_cents: 2000),
    ensure_membership_product!(seller:, unique_permalink: "churn_gamma", name: "Monthly Membership Gamma", price_cents: 500),
  ]

  start_date = Date.new(2024, 1, 1)
  end_date = Date.new(2025, 8, 19)
  months = (start_date..end_date).map { |d| Date.new(d.year, d.month, 1) }.uniq

  buyer_index = 0

  months.each do |month_start|
    month_end = [month_start.end_of_month.to_date, end_date].min

    products.each_with_index do |product, p_idx|
      [5, 10, 15, 20].each_with_index do |day, i|
        next if Date.new(month_start.year, month_start.month, 1) > end_date
        next unless day <= month_end.day

        buyer_index += 1
        buyer = ensure_buyer!(idx: buyer_index)

        created_time = Time.utc(month_start.year, month_start.month, day, 10, 0, 0)

        should_churn = if month_start.year == 2024
          i.even? # 2 out of 4 per month per product
        else
          (i == 0) || (i == 3) # ~2 out of 4 for some months in 2025
        end

        deactivated_time = nil
        if should_churn
          # Deactivate within the same month when possible; otherwise first week of the next month
          churn_day = [day + 10, month_end.day].min
          deactivated_time = Time.utc(month_start.year, month_start.month, churn_day, 10, 0, 0)
          # cap by global end_date
          deactivated_time = [deactivated_time, end_date.to_time(:utc).end_of_day].min
        end

        subscription = ensure_subscription!(seller:, product:, buyer:, created_time:, deactivated_time:)
        ensure_original_purchase!(subscription:, product:, seller:, buyer:, price_cents: product.default_price_cents || product.price_cents, created_time:)
      end
    end
  end
end

# ===== Additional variation to create non-linear, product-specific churn =====
# This section adds more subscribers and churn with seasonal and product-specific patterns
def next_buyer_index_start
  existing = User.where("email LIKE ?", "churn-buyer-%@example.com").pluck(:email)
  max = existing.map { |e| (e[/churn-buyer-(\d+)/, 1] || 0).to_i }.max || 0
  max + 1
end

def seasonal_multiplier_for(month_number)
  # Make certain months spikier
  case month_number
  when 1 then 0.9  # Jan
  when 2 then 0.8
  when 3 then 1.4  # March spike
  when 4 then 1.0
  when 5 then 1.1
  when 6 then 1.2  # early summer
  when 7 then 1.15
  when 8 then 1.0
  when 9 then 1.5  # September spike
  when 10 then 1.0
  when 11 then 1.2
  when 12 then 1.3  # holiday cancellations
  else 1.0
  end
end

def churn_profile_for(product)
  # Different base churn probabilities per product
  case product.unique_permalink
  when "churn_alpha"
    { base_new: 5, churn_prob: 0.55 } # high churn
  when "churn_beta"
    { base_new: 3, churn_prob: 0.15 } # low churn
  else # gamma or others
    { base_new: 4, churn_prob: 0.35 } # mixed
  end
end

rng = Random.new(20250819)

ActiveRecord::Base.transaction do
  seller = User.find_by!(email: "creator@example.com")
  products = Link.where(unique_permalink: ["churn_alpha", "churn_beta", "churn_gamma"]).order(:unique_permalink).to_a
  start_date = Date.new(2024, 1, 1)
  end_date = Date.new(2025, 8, 19)
  months = (start_date..end_date).map { |d| Date.new(d.year, d.month, 1) }.uniq

  seed_log "Seeding additional churn variation data"

  buyer_index = next_buyer_index_start

  months.each do |month_start|
    month_end = [month_start.end_of_month.to_date, end_date].min

    products.each do |product|
      profile = churn_profile_for(product)
      seasonal_multiplier = seasonal_multiplier_for(month_start.month)
      new_subscriptions = (profile[:base_new] * seasonal_multiplier).round + rng.rand(0..2)

      new_subscriptions.times do
        buyer_index += 1
        buyer = ensure_buyer!(idx: buyer_index)

        start_day = rng.rand(2..[26, month_end.day].min)
        created_time = Time.utc(month_start.year, month_start.month, start_day, rng.rand(8..18), rng.rand(0..59), 0)

        churn_probability = (profile[:churn_prob] * seasonal_multiplier).clamp(0.05, 0.9)
        will_churn = rng.rand < churn_probability

        deactivated_time = nil
        if will_churn
          # 70% churn in same month after 3-15 days, 30% early next month
          if rng.rand < 0.7 || month_start == end_date.beginning_of_month.to_date
            churn_day = [[start_day + rng.rand(3..15), month_end.day].min, start_day].max
            deactivated_time = Time.utc(month_start.year, month_start.month, churn_day, rng.rand(7..20), rng.rand(0..59), 0)
          else
            next_month = (month_start + 1.month)
            nm_end = [next_month.end_of_month.to_date, end_date].min
            churn_day = [rng.rand(1..8), nm_end.day].min
            deactivated_time = Time.utc(next_month.year, next_month.month, churn_day, rng.rand(7..20), rng.rand(0..59), 0)
          end
        end

        subscription = ensure_subscription!(seller:, product:, buyer:, created_time:, deactivated_time:)
        ensure_original_purchase!(subscription:, product:, seller:, buyer:, price_cents: product.default_price_cents || product.price_cents, created_time:)
      end
    end
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

seed_log "Churn analytics demo data seeded"
