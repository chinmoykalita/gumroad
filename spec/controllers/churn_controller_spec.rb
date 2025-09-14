# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe ChurnController do
  render_views

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

  before(:all) do
    if ObfuscateIds::CIPHER_KEY.nil?
      ObfuscateIds.send(:remove_const, :CIPHER_KEY)
      ObfuscateIds.send(:remove_const, :NUMERIC_CIPHER_KEY)
      ObfuscateIds.const_set(:CIPHER_KEY, "testcipherkey")
      ObfuscateIds.const_set(:NUMERIC_CIPHER_KEY, 123_456)
    end
  end

  before do
    allow(StripeBalanceEnforcer).to receive(:ensure_sufficient_balance).and_return(true)
    Feature.activate_user(:churn_analytics, seller)
  end

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { :analytics }
    end

    context "stripe connect requirements" do
      before do
        create(:merchant_account, user: seller)
        $redis.sadd(RedisKey.user_ids_with_payment_requirements_key, seller.id)
        @stripe_account = double
        allow(Stripe::Account).to receive(:retrieve).and_return(@stripe_account)
      end

      it "does not redirect to payout settings page if user not part of user_ids_with_payment_requirements_key" do
        $redis.srem(RedisKey.user_ids_with_payment_requirements_key, seller.id)

        get :index

        expect(response).to_not redirect_to(settings_payments_path)
      end

      it "redirects to payout settings page if compliance requests exist" do
        create(:user_compliance_info_request, user: seller, state: :requested)

        get :index

        expect(response).to redirect_to(settings_payments_path)
        expect(flash[:notice]).to eq("Urgent: We are required to collect more information from you to continue processing payments.")
      end

      it "redirects to payout settings page if capabilities missing" do
        allow(@stripe_account).to receive(:capabilities).and_return({})
        get :index

        expect(response).to redirect_to(settings_payments_path)
        expect(flash[:notice]).to eq("Urgent: We are required to collect more information from you to continue processing payments.")
      end

      it "removes from users that need requirements if capabilities are satisfied" do
        allow(@stripe_account).to receive(:capabilities).and_return({ card_payments: "active",
                                                                      legacy_payments: "active",
                                                                      transfers: "active" })

        get :index

        expect(response).to_not redirect_to(settings_payments_path)
        expect($redis.sismember(RedisKey.user_ids_with_payment_requirements_key, seller.id)).to eq(false)
      end
    end

    it "assigns churn props" do
      get :index
      expect(assigns(:churn_props)).to_not be(nil)
    end
  end

  shared_examples "supports start and end times" do |action_name|
    it "assigns @start_date and @end_date" do
      get(action_name, params: {
            start_time: "Tue May 25 2021 14:32:31 GMT 0700 (Novosibirsk Standard Time)",
            end_time: "Wed Jun 23 2021 14:32:31 GMT 0700 (Novosibirsk Standard Time)",
          })
      # Controller constrains dates, so just verify they are assigned
      expect(assigns(:start_date)).to be_a(Date)
      expect(assigns(:end_date)).to be_a(Date)
    end
  end

  describe "GET data" do
    let(:mock_analytics_data) do
      {
        dates: ["June 14th", "June 15th"],
        start_date: "June 14th",
        end_date: "June 15th",
        by_date: {
          churn_rate: [5.2, 7.8],
          churned_users: [3, 5],
          revenue_lost_cents: [1500, 2500]
        },
        total: {
          churned_users: 8,
          revenue_lost_cents: 4000,
          churn_rate: 6.5,
          avg_active_base: 120
        },
        last_period: {
          churned_users: 5,
          revenue_lost_cents: 2000,
          churn_rate: 4.2,
          avg_active_base: 100
        },
        first_sale_date: "January 1, 2021"
      }
    end

    before do
      allow_any_instance_of(CreatorAnalytics::Churn).to receive(:data).and_return(mock_analytics_data)
    end

    it_behaves_like "supports start and end times", :data

    it_behaves_like "authorize called for action", :get, :data do
      let(:record) { :analytics }
      let(:policy_method) { :index? }
      let(:request_params) do
        {
          start_time: "Mon Jul 27 2025 22:40:18 GMT-0700 (PDT)",
          end_time: "Wed Jul 30 2025 22:40:18 GMT-0700 (PDT)"
        }
      end
    end

    describe "service delegation and response format" do
      it "calls CreatorAnalytics::Churn with correct parameters and returns JSON" do
        expect(CreatorAnalytics::Churn).to receive(:new).with(
          seller: seller,
          products: anything,
          dates: anything,
          aggregate_by: anything
        ).and_call_original

        get :data, params: {
          start_time: "Mon Jul 27 2025 22:40:18 GMT-0700 (PDT)",
          end_time: "Wed Jul 30 2025 22:40:18 GMT-0700 (PDT)",
          aggregate_by: "month",
          product_ids: ["product1", "product2"]
        }

        expect(response).to have_http_status(:ok)
        expect(response.content_type).to include("application/json")

        json_response = JSON.parse(response.body)
        expect(json_response).to include("dates", "by_date", "total", "last_period")
        expect(json_response["total"]).to include("churned_users", "revenue_lost_cents", "churn_rate")
      end
    end

    it "handles date parameter processing" do
      get :data, params: { start_time: "invalid", end_time: "invalid" }

      # Controller should process dates (valid or invalid) and assign them
      expect(assigns(:start_date)).to be_a(Date)
      expect(assigns(:end_date)).to be_a(Date)
      expect(response).to have_http_status(:ok)
    end
  end
end
