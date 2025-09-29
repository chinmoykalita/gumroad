# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::Churn do
  let(:user_timezone) { "UTC" }

  before do
    @user = create(:user, timezone: user_timezone, created_at: Date.new(2020, 1, 1))
    @product = create(:membership_product, user: @user)
    Feature.activate_user(:churn_analytics_enabled, @user)
  end

  describe "#subscription_products" do
    it "returns only recurring billing and tiered membership products" do
      service = described_class.new(seller: @user)

      recurring = instance_double(Link, is_recurring_billing?: true, is_tiered_membership?: false)
      membership = instance_double(Link, is_recurring_billing?: false, is_tiered_membership?: true)
      onetime = instance_double(Link, is_recurring_billing?: false, is_tiered_membership?: false)

      allow(@user).to receive(:products_for_creator_analytics).and_return([recurring, membership, onetime])

      expect(service.subscription_products).to match_array([recurring, membership])
    end
  end

  describe "business logic and calculations" do
    let!(:subscription_product) { create(:subscription_product, user: @user) }
    let!(:membership_product) { create(:membership_product, user: @user) }

    context "with real churn scenarios" do
      before do
        create_subscription!(
          product: subscription_product,
          price_cents: 1000,
          created_time: Time.utc(2021, 1, 1, 10, 0, 0),
          deactivated_time: Time.utc(2021, 1, 5, 12, 0, 0)
        )
        create_subscription!(
          product: subscription_product,
          price_cents: 2000,
          created_time: Time.utc(2021, 1, 2, 10, 0, 0),
          deactivated_time: Time.utc(2021, 1, 5, 14, 0, 0)
        )
        create_subscription!(
          product: membership_product,
          price_cents: 1500,
          created_time: Time.utc(2021, 1, 3, 10, 0, 0),
          deactivated_time: Time.utc(2021, 1, 6, 12, 0, 0)
        )

        create_active_subscriptions(subscription_product, count: 10, price_cents: 1000)
        create_active_subscriptions(membership_product, count: 5, price_cents: 1500)

        index_model_records(Purchase)
      end

      it "calculates churn metrics correctly across multiple products" do
        service = described_class.new(seller: @user)
        result = service.generate_data(
          product_ids: [subscription_product.external_id, membership_product.external_id],
          dates: (Date.new(2021, 1, 1)..Date.new(2021, 1, 10)),
          aggregate_by: "day"
        )

        expect(result[:period_data].values.map { it[:churned_users] }.sum).to be > 0
        expect(result[:total][:churned_users]).to eq(3)
        expect(result[:total][:revenue_lost_cents]).to eq(4500) # 1000 + 2000 + 1500
        expect(result[:total][:churn_rate]).to be > 0
      end

      it "handles empty products gracefully" do
        service = described_class.new(seller: @user)
        result = service.generate_data(
          product_ids: [],
          dates: (Date.new(2021, 1, 1)..Date.new(2021, 1, 3))
        )
        expect(result[:total]).to include(
          churned_users: 0,
          revenue_lost_cents: 0,
          churn_rate: 0.0,
          avg_active_base: 0
        )
      end
    end

    context "aggregation options" do
      before do
        create_subscription!(
          product: subscription_product,
          price_cents: 1000,
          created_time: Time.utc(2025, 1, 15, 10, 0, 0),
          deactivated_time: Time.utc(2025, 1, 25, 12, 0, 0)
        )
        create_subscription!(
          product: subscription_product,
          price_cents: 2000,
          created_time: Time.utc(2025, 2, 5, 10, 0, 0),
          deactivated_time: Time.utc(2025, 2, 15, 12, 0, 0)
        )
        index_model_records(Purchase)
      end

      it "groups data by month correctly" do
        service = described_class.new(seller: @user)
        result = service.generate_data(
          product_ids: [subscription_product.external_id],
          dates: (Date.new(2025, 1, 1)..Date.new(2025, 2, 28)),
          aggregate_by: "month"
        )

        # Should have 2 months of data
        expect(result[:period_data].keys.length).to eq(2)
        expect(result[:period_data].values.sum { it[:churned_users] }).to eq(2)
        expect(result[:period_data].values.sum { it[:revenue_lost_cents] }).to eq(3000)
      end

      it "handles daily vs monthly aggregation differences" do
        # Use a range that will be within the seller's created date constraints
        dates = (Date.new(2021, 1, 1)..Date.new(2021, 1, 10))

        service = described_class.new(seller: @user)
        daily_result = service.generate_data(
          product_ids: [subscription_product.external_id],
          dates: dates,
          aggregate_by: "day"
        )
        monthly_result = service.generate_data(
          product_ids: [subscription_product.external_id],
          dates: dates,
          aggregate_by: "month"
        )

        # Both should have same data structure
        expected_keys = [:period_data, :start_date, :end_date, :total, :last_period, :first_sale_date]
        expect(daily_result.keys).to match_array(expected_keys)
        expect(monthly_result.keys).to match_array(expected_keys)

        # Total metrics should be similar (same period, different aggregation)
        expect(daily_result[:total][:churned_users]).to eq(monthly_result[:total][:churned_users])
      end
    end

    context "date constraints and edge cases" do
      it "constrains future dates to today" do
        future_dates = (Date.new(2030, 1, 1)..Date.new(2030, 1, 3))
        service = described_class.new(seller: @user)
        constrained_dates = service.send(:constrain_dates, future_dates)
        expect(constrained_dates.last).to be <= Date.current
      end

      it "constrains early dates to seller creation date" do
        early_dates = (Date.new(2010, 1, 1)..Date.new(2010, 1, 3))
        service = described_class.new(seller: @user)
        constrained_dates = service.send(:constrain_dates, early_dates)
        expect(constrained_dates.first).to be >= @user.created_at.to_date
      end
    end
  end

  describe "#data" do
    context "daily aggregation" do
      it "ingests churn data and computes churn rate" do
        create_subscription!(
          product: @product,
          price_cents: 1500,
          created_time: Time.utc(2021, 1, 1, 10, 0, 0),
          deactivated_time: Time.utc(2021, 1, 2, 12, 0, 0)
        )

        index_model_records(Purchase)

        service = described_class.new(seller: @user)
        result = service.generate_data(
          product_ids: [@product.external_id],
          dates: (Date.new(2021, 1, 1) .. Date.new(2021, 1, 3)),
          aggregate_by: "day"
        )

        # Check the structured data format
        expect(result).to include(:period_data, :start_date, :end_date, :total, :last_period, :first_sale_date)

        # Check that we have data for the expected date range
        expect(result[:period_data].keys.length).to eq(3) # 3 days
        expect(result[:total][:churned_users]).to eq(1)
        expect(result[:total][:revenue_lost_cents]).to eq(1500)
      end

      it "returns expected data with one query" do
        create_subscription!(
          product: @product,
          price_cents: 1000,
          created_time: Time.utc(2021, 1, 1, 12, 0, 0),
          deactivated_time: Time.utc(2021, 1, 2, 12, 0, 0)
        )

        index_model_records(Purchase)

        allow_any_instance_of(described_class).to receive(:bulk_active_subscribers).and_return({})
        expect(Purchase).to receive(:search).once.and_call_original

        service = described_class.new(seller: @user)
        result = service.generate_data(
          product_ids: [@product.external_id],
          dates: (Date.new(2021, 1, 1) .. Date.new(2021, 1, 3)),
          aggregate_by: "day"
        )
        expect(result[:total][:churned_users]).to eq(1)
        expect(result[:total][:revenue_lost_cents]).to eq(1000)
      end
    end

    context "monthly aggregation" do
      it "groups by month" do
        create_subscription!(product: @product, price_cents: 1000, created_time: Time.utc(2025, 5, 1, 10, 0, 0), deactivated_time: Time.utc(2025, 5, 10, 8, 0, 0))
        create_subscription!(product: @product, price_cents: 2000, created_time: Time.utc(2025, 6, 1, 10, 0, 0), deactivated_time: Time.utc(2025, 6, 15, 8, 0, 0))

        index_model_records(Purchase)

        service = described_class.new(seller: @user)
        result = service.generate_data(
          product_ids: [@product.external_id],
          dates: (Date.new(2025, 5, 1) .. Date.new(2025, 6, 30)),
          aggregate_by: "month"
        )
        expect(result[:total][:churned_users]).to eq(2)
        expect(result[:total][:revenue_lost_cents]).to eq(3000) # 1000 + 2000
      end
    end

    context "when paginating" do
      it "fetches all buckets across pages" do
        stub_const("#{described_class}::ES_MAX_BUCKET_SIZE", 2)
        create_subscription!(product: @product, price_cents: 1000, created_time: Time.utc(2025, 6, 1, 10, 0, 0), deactivated_time: Time.utc(2025, 6, 14, 10, 0, 0))
        create_subscription!(product: @product, price_cents: 2000, created_time: Time.utc(2025, 6, 1, 10, 0, 0), deactivated_time: Time.utc(2025, 6, 15, 10, 0, 0))
        create_subscription!(product: @product, price_cents: 3000, created_time: Time.utc(2025, 6, 1, 10, 0, 0), deactivated_time: Time.utc(2025, 6, 16, 10, 0, 0))

        index_model_records(Purchase)

        allow_any_instance_of(described_class).to receive(:bulk_active_subscribers).and_return({})
        allow(Purchase).to receive(:search).and_call_original

        service = described_class.new(seller: @user)
        result = service.generate_data(
          product_ids: [@product.external_id],
          dates: (Date.new(2025, 6, 14) .. Date.new(2025, 6, 16)),
          aggregate_by: "day"
        )
        expect(result[:total][:churned_users]).to eq(3)
        expect(result[:total][:revenue_lost_cents]).to eq(6000) # 1000 + 2000 + 3000
        expect(Purchase).to have_received(:search).at_least(2).times
      end
    end

    context "when user time zone is Pacific Time" do
      let(:user_timezone) { "Pacific Time (US & Canada)" }

      it "buckets churn by the user's time zone" do
        create_subscription!(
          product: @product,
          price_cents: 1000,
          created_time: Time.utc(2020, 12, 15, 12, 0, 0),
          deactivated_time: Time.utc(2021, 1, 1, 1, 0, 0) # previous day in PT
        )

        index_model_records(Purchase)

        allow_any_instance_of(described_class).to receive(:bulk_active_subscribers).and_return({})

        service = described_class.new(seller: @user)
        result = service.generate_data(
          product_ids: [@product.external_id],
          dates: (Date.new(2020, 12, 31) .. Date.new(2021, 1, 1)),
          aggregate_by: "day"
        )
        expect(result[:total][:churned_users]).to eq(1)
        expect(result[:total][:revenue_lost_cents]).to eq(1000)
      end
    end
  end

  private
    def create_active_subscriptions(product, count:, price_cents:)
      count.times do |i|
        user = create(:user)
        subscription = create(:subscription, link: product, user: user)

        purchase = build(:purchase,
                         link: product,
                         subscription: subscription,
                         is_original_subscription_purchase: true,
                         price_cents: price_cents,
                         created_at: Time.utc(2020, 12, 1) + i.days,
                         purchaser: user,
                         stripe_transaction_id: "active_#{i}_#{SecureRandom.hex(4)}",
                         stripe_fingerprint: "fp_#{i}_#{SecureRandom.hex(4)}"
        )
        purchase.skip_preparing_for_charge = true if purchase.respond_to?(:skip_preparing_for_charge=)
        purchase.save!(validate: false)
        purchase.update_columns(purchase_state: "successful", succeeded_at: Time.utc(2020, 12, 1) + i.days + 1.hour, created_at: Time.utc(2020, 12, 1) + i.days)
      end
    end

    def create_subscription!(product:, price_cents:, created_time:, deactivated_time: nil)
      user = create(:user)
      subscription = create(:subscription, link: product, user: user)

      original = build(
        :purchase,
        link: product,
        subscription: subscription,
        is_original_subscription_purchase: true,
        price_cents: price_cents,
        created_at: created_time,
        purchaser: user,
        stripe_transaction_id: "orig_#{SecureRandom.hex(4)}",
        stripe_fingerprint: "fp_#{SecureRandom.hex(4)}"
      )
      original.skip_preparing_for_charge = true if original.respond_to?(:skip_preparing_for_charge=)
      original.save!(validate: false)
      original.update_columns(purchase_state: "successful", succeeded_at: created_time + 1.hour, created_at: created_time)

      if deactivated_time
        subscription.update!(deactivated_at: deactivated_time, cancelled_at: deactivated_time)
      end
    end
end
