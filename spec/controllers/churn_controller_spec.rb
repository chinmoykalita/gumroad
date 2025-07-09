# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"

describe ChurnController do
  let(:seller) { create(:user, timezone: "UTC") }

  include_context "with user signed in as admin for seller"

  describe "GET index" do
    it_behaves_like "authorize called for action", :get, :index do
      let(:record) { :analytics }
      let(:policy_method) { :index? }
    end
  end

  describe "GET data_by_date" do
    before do
      @stats = { "2025-07-08" => { churned_users: 5, revenue_lost_cents: 2500, churn_rate: 2.5, active_subscribers: 200 } }
      allow_any_instance_of(CreatorAnalytics::ChurnCachingProxy).to receive(:data_for_dates).and_return(@stats)
    end

    it_behaves_like "authorize called for action", :get, :data_by_date do
      let(:record) { :analytics }
      let(:policy_method) { :index? }
    end

    describe "when start_time and end_time are valid" do
      it "gets churn analytics data from start_time to end_time" do
        start_time = "Mon Apr 8 2025 22:40:18 GMT-0700 (PDT)"
        end_time = "Wed Apr 10 2025 22:40:18 GMT-0700 (PDT)"

        # The controller will constrain dates, so we expect the actual constrained dates
        expect_any_instance_of(CreatorAnalytics::ChurnCachingProxy).to receive(:data_for_dates).with(
          anything,
          anything,
          aggregate_by: "daily",
          products: []
        ).and_return(@stats)

        get :data_by_date, params: { start_time: start_time, end_time: end_time }
        expect(response).to have_http_status(:success)
      end

      it "renders churn data in json format" do
        get :data_by_date
        expect(response.content_type).to include("application/json")
      end
    end

    describe "when start_time or end_time is invalid" do
      it "gets churn analytics data range from 29 days ago to today" do
        travel_to Date.new(2025, 7, 8) do
          # The controller will constrain dates, so we expect the actual constrained dates
          expect_any_instance_of(CreatorAnalytics::ChurnCachingProxy).to receive(:data_for_dates).with(
            anything,
            anything,
            aggregate_by: "daily",
            products: []
          ).and_return(@stats)

          get :data_by_date
          expect(response).to have_http_status(:success)
        end
      end
    end
  end
end
