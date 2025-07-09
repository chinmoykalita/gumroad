# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::Churn do
  before do
    @user = create(:user, timezone: "UTC", created_at: Time.utc(2024, 1, 1))
    @membership_product1 = create(:membership_product, user: @user, name: "Premium Membership")
    @membership_product2 = create(:membership_product, user: @user, name: "Basic Membership")
    @subscription_product = create(:subscription_product, user: @user, name: "Monthly Newsletter")
    @dates = (Date.new(2024, 12, 20) .. Date.new(2024, 12, 22)).to_a

    recreate_model_index(Purchase)

    @service = described_class.new(
      user: @user,
      products: [@membership_product1, @membership_product2, @subscription_product],
      dates: @dates,
      aggregate_by: "daily"
    )
  end

  describe "#by_date" do
    context "with churned subscriptions" do
      before do
        travel_to Time.utc(2024, 12, 20, 12, 0, 0) do
          @subscription1 = create(:subscription, link: @membership_product1, user: @user)
          @original_purchase1 = create(:purchase,
                                       link: @membership_product1,
                                       subscription: @subscription1,
                                       is_original_subscription_purchase: true,
                                       price_cents: 1000,
                                       created_at: Time.utc(2020, 12, 1),
                                       purchaser: @user
          )
        end

        travel_to Time.utc(2021, 1, 2, 12, 0, 0) do
          @subscription2 = create(:subscription, link: @membership_product2, user: create(:user))
          @original_purchase2 = create(:purchase,
                                       link: @membership_product2,
                                       subscription: @subscription2,
                                       is_original_subscription_purchase: true,
                                       price_cents: 2000,
                                       created_at: Time.utc(2020, 11, 15),
                                       purchaser: @subscription2.user
          )
        end

        travel_to Time.utc(2021, 1, 3, 12, 0, 0) do
          @subscription3 = create(:subscription, link: @subscription_product, user: create(:user))
          @original_purchase3 = create(:purchase,
                                       link: @subscription_product,
                                       subscription: @subscription3,
                                       is_original_subscription_purchase: true,
                                       price_cents: 500,
                                       created_at: Time.utc(2020, 10, 1),
                                       purchaser: @subscription3.user
          )
        end

        @subscription1.update!(deactivated_at: Time.utc(2024, 12, 20, 15, 0, 0))
        @subscription2.update!(deactivated_at: Time.utc(2024, 12, 21, 10, 0, 0))
        @subscription3.update!(deactivated_at: Time.utc(2024, 12, 22, 18, 0, 0))

        index_model_records(Purchase)
      end

      it "returns churn data by date" do
        result = @service.by_date

        expect(result.keys).to match_array(["2024-12-20", "2024-12-21", "2024-12-22"])

        expect(result["2024-12-20"][:churned_users]).to eq(1)
        expect(result["2024-12-20"][:revenue_lost_cents]).to eq(1000)
        expect(result["2024-12-20"][:churn_rate]).to be > 0
        expect(result["2024-12-20"][:active_subscribers]).to be >= 0

        expect(result["2024-12-21"][:churned_users]).to eq(1)
        expect(result["2024-12-21"][:revenue_lost_cents]).to eq(2000)
        expect(result["2024-12-21"][:churn_rate]).to be > 0
        expect(result["2024-12-21"][:active_subscribers]).to be >= 0

        expect(result["2024-12-22"][:churned_users]).to eq(1)
        expect(result["2024-12-22"][:revenue_lost_cents]).to eq(500)
        expect(result["2024-12-22"][:churn_rate]).to be > 0
        expect(result["2024-12-22"][:active_subscribers]).to be >= 0
      end
    end

    context "with no churned subscriptions" do
      before do
        travel_to Time.utc(2021, 1, 1, 12, 0, 0) do
          @subscription1 = create(:subscription, link: @membership_product1, user: @user)
          @original_purchase1 = create(:purchase,
                                       link: @membership_product1,
                                       subscription: @subscription1,
                                       is_original_subscription_purchase: true,
                                       price_cents: 1000,
                                       created_at: Time.utc(2020, 12, 1),
                                       purchaser: @user
          )
        end

        index_model_records(Purchase)
      end

      it "returns zero churn data" do
        result = @service.by_date

        expect(result.keys).to match_array(["2024-12-20", "2024-12-21", "2024-12-22"])

        result.each do |date_key, data|
          expect(data[:churned_users]).to eq(0)
          expect(data[:revenue_lost_cents]).to eq(0)
          expect(data[:churn_rate]).to eq(0.0)
          expect(data[:active_subscribers]).to be >= 0
        end
      end
    end

    context "with monthly aggregation" do
      before do
        @monthly_service = described_class.new(
          user: @user,
          products: [@membership_product1],
          dates: (Date.new(2024, 12, 1) .. Date.new(2025, 1, 31)).to_a,
          aggregate_by: "monthly"
        )

        travel_to Time.utc(2021, 1, 15, 12, 0, 0) do
          @subscription1 = create(:subscription, link: @membership_product1, user: create(:user))
          @original_purchase1 = create(:purchase,
                                       link: @membership_product1,
                                       subscription: @subscription1,
                                       is_original_subscription_purchase: true,
                                       price_cents: 1000,
                                       created_at: Time.utc(2020, 12, 1),
                                       purchaser: @subscription1.user
          )
          @subscription1.update!(deactivated_at: Time.utc(2024, 12, 15, 15, 0, 0))
        end

        travel_to Time.utc(2021, 2, 10, 12, 0, 0) do
          @subscription2 = create(:subscription, link: @membership_product1, user: create(:user))
          @original_purchase2 = create(:purchase,
                                       link: @membership_product1,
                                       subscription: @subscription2,
                                       is_original_subscription_purchase: true,
                                       price_cents: 1500,
                                       created_at: Time.utc(2020, 11, 1),
                                       purchaser: @subscription2.user
          )
          @subscription2.update!(deactivated_at: Time.utc(2025, 1, 10, 10, 0, 0))
        end

        index_model_records(Purchase)
      end

      it "aggregates churn data by month" do
        result = @monthly_service.by_date

        expect(result.keys).to match_array(["2024-12", "2025-01"])

        expect(result["2024-12"][:churned_users]).to eq(1)
        expect(result["2024-12"][:revenue_lost_cents]).to eq(1000)
        expect(result["2024-12"][:churn_rate]).to be > 0

        expect(result["2025-01"][:churned_users]).to eq(1)
        expect(result["2025-01"][:revenue_lost_cents]).to eq(1500)
        expect(result["2025-01"][:churn_rate]).to be > 0
      end
    end

    context "with timezone considerations" do
      before do
        @user.update!(timezone: "Pacific Time (US & Canada)")
        @pst_service = described_class.new(
          user: @user,
          products: [@membership_product1],
          dates: @dates,
          aggregate_by: "daily"
        )

        travel_to Time.utc(2021, 1, 2, 3, 0, 0) do # This is Jan 1 7pm PST
          @subscription = create(:subscription, link: @membership_product1, user: create(:user))
          @original_purchase = create(:purchase,
                                      link: @membership_product1,
                                      subscription: @subscription,
                                      is_original_subscription_purchase: true,
                                      price_cents: 1000,
                                      created_at: Time.utc(2020, 12, 1),
                                      purchaser: @subscription.user
          )
          @subscription.update!(deactivated_at: Time.utc(2024, 12, 21, 3, 0, 0))
        end

        index_model_records(Purchase)
      end
    end
  end

  describe "#by_date_with_product_breakdown" do
    before do
      travel_to Time.utc(2021, 1, 1, 12, 0, 0) do
        @subscription1 = create(:subscription, link: @membership_product1, user: create(:user))
        @original_purchase1 = create(:purchase,
                                     link: @membership_product1,
                                     subscription: @subscription1,
                                     is_original_subscription_purchase: true,
                                     price_cents: 1000,
                                     created_at: Time.utc(2020, 12, 1),
                                     purchaser: @subscription1.user
        )
        @subscription1.update!(deactivated_at: Time.utc(2024, 12, 20, 15, 0, 0))

        @subscription2 = create(:subscription, link: @membership_product2, user: create(:user))
        @original_purchase2 = create(:purchase,
                                     link: @membership_product2,
                                     subscription: @subscription2,
                                     is_original_subscription_purchase: true,
                                     price_cents: 2000,
                                     created_at: Time.utc(2024, 11, 1),
                                     purchaser: @subscription2.user
        )
        @subscription2.update!(deactivated_at: Time.utc(2024, 12, 20, 16, 0, 0))
      end

      index_model_records(Purchase)
    end

    it "returns churn data with product breakdown" do
      result = @service.by_date_with_product_breakdown

      expect(result["2024-12-20"][:by_product]).to have_key(@membership_product1.id)
      expect(result["2024-12-20"][:by_product]).to have_key(@membership_product2.id)

      product1_data = result["2024-12-20"][:by_product][@membership_product1.id]
      expect(product1_data[:churned_users]).to eq(1)
      expect(product1_data[:revenue_lost_cents]).to eq(1000)

      product2_data = result["2024-12-20"][:by_product][@membership_product2.id]
      expect(product2_data[:churned_users]).to eq(1)
      expect(product2_data[:revenue_lost_cents]).to eq(2000)

      expect(result["2024-12-20"][:churned_users]).to eq(2)
      expect(result["2024-12-20"][:revenue_lost_cents]).to eq(3000)
      expect(result["2024-12-20"][:churn_rate]).to be > 0
    end
  end

  describe "date constraining" do
    context "when dates are outside valid range" do
      before do
        @user.update!(created_at: Time.utc(2024, 1, 15))
      end

      it "constrains dates to valid range" do
        allow(Time).to receive(:now).and_return(Time.utc(2024, 12, 31))

        @future_service = described_class.new(
          user: @user,
          products: [@membership_product1],
          dates: (Date.new(2023, 1, 1) .. Date.new(2025, 12, 31)).to_a,
          aggregate_by: "daily"
        )

        expect(@future_service.instance_variable_get(:@dates).first).to be >= @user.created_at.to_date
        expect(@future_service.instance_variable_get(:@dates).last).to be <= Date.new(2024, 12, 31)
      end
    end

    context "when user has first sale date" do
      before do
        allow(@user).to receive(:first_sale_created_at_for_analytics).and_return(Time.utc(2024, 12, 10))
        @constrained_service = described_class.new(
          user: @user,
          products: [@membership_product1],
          dates: (Date.new(2024, 1, 1) .. Date.new(2024, 12, 15)).to_a,
          aggregate_by: "daily"
        )
      end

      it "uses first sale date as earliest constraint" do
        expect(@constrained_service.instance_variable_get(:@dates).first).to eq(Date.new(2024, 12, 10))
      end
    end
  end

  describe "active subscriber calculations" do
    before do
      travel_to Time.utc(2021, 1, 1, 12, 0, 0) do
        @active_subscription = create(:subscription, link: @membership_product1, user: create(:user))
        @active_purchase = create(:purchase,
                                  link: @membership_product1,
                                  subscription: @active_subscription,
                                  is_original_subscription_purchase: true,
                                  price_cents: 1000,
                                  created_at: Time.utc(2020, 12, 1),
                                  purchaser: @active_subscription.user
        )

        @churned_subscription = create(:subscription, link: @membership_product1, user: create(:user))
        @churned_purchase = create(:purchase,
                                   link: @membership_product1,
                                   subscription: @churned_subscription,
                                   is_original_subscription_purchase: true,
                                   price_cents: 1000,
                                   created_at: Time.utc(2020, 11, 1),
                                   purchaser: @churned_subscription.user
        )
        @churned_subscription.update!(deactivated_at: Time.utc(2024, 12, 20, 15, 0, 0))
      end

      index_model_records(Purchase)
    end

    it "correctly calculates active subscribers and churn rate" do
      result = @service.by_date

      dec_20_data = result["2024-12-20"]
      expect(dec_20_data[:churned_users]).to eq(1)
      expect(dec_20_data[:active_subscribers]).to be > 0

      expected_churn_rate = (dec_20_data[:churned_users].to_f / dec_20_data[:active_subscribers] * 100).round(2)
      expect(dec_20_data[:churn_rate]).to eq(expected_churn_rate)
    end
  end

  describe "pagination handling" do
    before do
      stub_const("#{described_class}::ES_MAX_BUCKET_SIZE", 2)

      travel_to Time.utc(2021, 1, 1, 12, 0, 0) do
        5.times do |i|
          subscription = create(:subscription, link: @membership_product1, user: create(:user))
          create(:purchase,
                 link: @membership_product1,
                 subscription: subscription,
                 is_original_subscription_purchase: true,
                 price_cents: 1000,
                 created_at: Time.utc(2020, 12, 1),
                 purchaser: subscription.user
          )
          subscription.update!(deactivated_at: Time.utc(2024, 12, 20, 15, 0, 0))
        end
      end

      index_model_records(Purchase)
    end

    it "handles pagination correctly" do
      expect(Purchase).to receive(:search).at_least(2).times.and_call_original

      result = @service.by_date
      expect(result["2024-12-20"][:churned_users]).to eq(5)
    end
  end
end
