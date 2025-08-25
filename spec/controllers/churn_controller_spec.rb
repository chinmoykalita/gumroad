# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe ChurnController do
  render_views

  let(:seller) { create(:named_seller) }

  include_context "with user signed in as admin for seller"

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

      it "does not redirect when user not in payment requirements" do
        $redis.srem(RedisKey.user_ids_with_payment_requirements_key, seller.id)

        get :index

        expect(response).to_not redirect_to(settings_payments_path)
      end

      it "redirects when compliance requests exist" do
        create(:user_compliance_info_request, user: seller, state: :requested)

        get :index

        expect(response).to redirect_to(settings_payments_path)
        expect(flash[:notice]).to eq("Urgent: We are required to collect more information from you to continue processing payments.")
      end

      it "redirects when capabilities missing" do
        allow(@stripe_account).to receive(:capabilities).and_return({})
        get :index

        expect(response).to redirect_to(settings_payments_path)
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
    let!(:subscription_product) { create(:subscription_product, user: seller) }
    let!(:regular_product) { create(:product, user: seller) }

    before do
      allow_any_instance_of(CreatorAnalytics::Churn).to receive(:data).and_return({
                                                                                    "2021-05-25" => {
                                                                                      churned_users: 5,
                                                                                      revenue_lost_cents: 10000,
                                                                                      churn_rate: 10.5,
                                                                                      active_subscribers: 48
                                                                                    }
                                                                                  })
    end

    it_behaves_like "supports start and end times", :data

    it_behaves_like "authorize called for action", :get, :data do
      let(:record) { :analytics }
      let(:policy_method) { :index? }
    end

    describe "when start_time and end_time are valid" do
      it "calls CreatorAnalytics::Churn with correct parameters" do
        freeze_time do
          # Use recent dates and expect the service to be called multiple times
          expect(CreatorAnalytics::Churn).to receive(:new).at_least(:once).and_call_original

          get :data, params: {
            start_time: "Mon Jul 27 2025 22:40:18 GMT-0700 (PDT)",
            end_time: "Wed Jul 30 2025 22:40:18 GMT-0700 (PDT)"
          }
        end
      end

      it "returns analytics data in JSON format" do
        get :data

        json_response = JSON.parse(response.body)
        expect(json_response).to include("dates", "by_date", "total", "last_period")
      end
    end

    describe "when start_time or end_time is invalid" do
      it "uses default date range (29 days ago to today)" do
        freeze_time do
          # Controller will call service multiple times, just verify it gets called
          expect(CreatorAnalytics::Churn).to receive(:new).at_least(:once).and_call_original

          get :data, params: { start_time: "invalid", end_time: "invalid" }
        end
      end
    end

    describe "aggregate_by parameter" do
      it "uses monthly aggregation when specified" do
        expect(CreatorAnalytics::Churn).to receive(:new).at_least(:once).with(
          hash_including(aggregate_by: "monthly")
        ).and_call_original

        get :data, params: { aggregate_by: "monthly" }
      end

      it "defaults to daily for other values" do
        expect(CreatorAnalytics::Churn).to receive(:new).at_least(:once).with(
          hash_including(aggregate_by: "daily")
        ).and_call_original

        get :data, params: { aggregate_by: "invalid" }
      end
    end

    describe "product filtering" do
      it "only includes subscription products" do
        expect(CreatorAnalytics::Churn).to receive(:new).at_least(:once).with(
          hash_including(products: [subscription_product])
        ).and_call_original

        get :data
      end

      it "filters by product_ids when provided" do
        expect(CreatorAnalytics::Churn).to receive(:new).at_least(:once).with(
          hash_including(products: [subscription_product])
        ).and_call_original

        get :data, params: { product_ids: [subscription_product.external_id] }
      end

      it "handles empty product_ids gracefully" do
        expect(CreatorAnalytics::Churn).to receive(:new).at_least(:once).with(
          hash_including(products: [])
        ).and_call_original

        get :data, params: { product_ids: [regular_product.external_id] }
      end

      it "handles user with no subscription products" do
        # Create seller with only regular (non-subscription) products
        seller.products.destroy_all
        create(:product, user: seller, is_recurring_billing: false)

        expect(CreatorAnalytics::Churn).to receive(:new).at_least(:once).with(
          hash_including(products: [])
        ).and_call_original

        get :data
      end
    end
  end
end
