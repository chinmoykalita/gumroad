# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::Churn do
  let(:user_timezone) { "UTC" }

  before do
    @user = create(:user, timezone: user_timezone, created_at: Date.new(2020, 1, 1))
    @product = create(:membership_product, user: @user)
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

        service = described_class.new(
          user: @user,
          products: [@product],
          dates: (Date.new(2021, 1, 1) .. Date.new(2021, 1, 3)).to_a,
          aggregate_by: "daily"
        )

        result = service.data
        expect(result["2021-01-02"]).to include(churned_users: 1, revenue_lost_cents: 1500, active_subscribers: 1)
        expect(result["2021-01-02"][:churn_rate]).to eq(100.0)
        expect(result["2021-01-01"]).to include(churned_users: 0, revenue_lost_cents: 0, active_subscribers: 0)
        expect(result["2021-01-01"][:churn_rate]).to eq(0.0)
        expect(result["2021-01-03"]).to include(churned_users: 0, revenue_lost_cents: 0, active_subscribers: 0)
        expect(result["2021-01-03"][:churn_rate]).to eq(0.0)
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

        service = described_class.new(
          user: @user,
          products: [@product],
          dates: (Date.new(2021, 1, 1) .. Date.new(2021, 1, 3)).to_a,
          aggregate_by: "daily"
        )

        result = service.data
        expect(result["2021-01-02"]).to include(churned_users: 1, revenue_lost_cents: 1000)
      end
    end

    context "monthly aggregation" do
      it "groups by month" do
        create_subscription!(product: @product, price_cents: 1000, created_time: Time.utc(2025, 5, 1, 10, 0, 0), deactivated_time: Time.utc(2025, 5, 10, 8, 0, 0))
        create_subscription!(product: @product, price_cents: 2000, created_time: Time.utc(2025, 6, 1, 10, 0, 0), deactivated_time: Time.utc(2025, 6, 15, 8, 0, 0))

        index_model_records(Purchase)

        service = described_class.new(
          user: @user,
          products: [@product],
          dates: (Date.new(2025, 5, 1) .. Date.new(2025, 6, 30)).to_a,
          aggregate_by: "monthly"
        )

        result = service.data
        expect(result["2025-05"]).to include(churned_users: 1, revenue_lost_cents: 1000)
        expect(result["2025-06"]).to include(churned_users: 1, revenue_lost_cents: 2000)
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

        service = described_class.new(
          user: @user,
          products: [@product],
          dates: (Date.new(2025, 6, 14) .. Date.new(2025, 6, 16)).to_a,
          aggregate_by: "daily"
        )

        result = service.data
        expect(result["2025-06-14"]).to include(churned_users: 1, revenue_lost_cents: 1000)
        expect(result["2025-06-15"]).to include(churned_users: 1, revenue_lost_cents: 2000)
        expect(result["2025-06-16"]).to include(churned_users: 1, revenue_lost_cents: 3000)
        expect(Purchase).to have_received(:search).exactly(2).times
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

        service = described_class.new(
          user: @user,
          products: [@product],
          dates: (Date.new(2020, 12, 31) .. Date.new(2021, 1, 1)).to_a,
          aggregate_by: "daily"
        )

        result = service.data
        expect(result.key?("2020-12-31")).to be(true)
        expect(result["2020-12-31"]).to include(churned_users: 1, revenue_lost_cents: 1000)
      end
    end
  end

  private
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
