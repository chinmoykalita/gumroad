# frozen_string_literal: true

require "spec_helper"
require "shared_examples/authorize_called"
require "shared_examples/creator_dashboard_page"

describe "Churn analytics", :js, :sidekiq_inline, :elasticsearch_wait_for_refresh, type: :feature do
  let(:seller) { create(:user, created_at: Date.new(2025, 1, 1)) }

  include_context "with switching account to user as admin for seller"

  before do
    stub_const("ObfuscateIds::CIPHER_KEY", "testcipherkey")
    stub_const("ObfuscateIds::NUMERIC_CIPHER_KEY", 123_456)
    ignore_js_error(/AbortError: Request aborted/)
    allow_any_instance_of(ApplicationController).to receive(:check_payment_details).and_return(true)
  end

  it_behaves_like "creator dashboard page", "Analytics" do
    let(:path) { churn_dashboard_path }
  end

  it "loads the empty state page successfully" do
    visit churn_dashboard_path
    expect(page).to have_text("No products selected")
  end

  context "with subscription products" do
    let(:membership_product1) { create(:membership_product, user: seller, name: "Premium Membership") }
    let(:membership_product2) { create(:membership_product, user: seller, name: "Basic Membership") }

    before do
      membership_product1
      membership_product2
    end

    it "shows products available for selection" do
      visit churn_dashboard_path

      select_disclosure "Select products..." do
        expect(page).to have_text("Premium Membership")
        expect(page).to have_text("Basic Membership")
      end
    end

    context "with churn data" do
      before do
        create_churned_subscription(membership_product1, 2000, churn_date: Time.utc(2025, 6, 14, 15, 0, 0))
        create_churned_subscription(membership_product2, 1000, churn_date: Time.utc(2025, 6, 16, 10, 0, 0))
        create_active_subscriptions(membership_product1, count: 10, price_cents: 2000)
        create_active_subscriptions(membership_product2, count: 5, price_cents: 1000)

        index_model_records(Purchase)
      end

      context "UI functionality" do
        it "calculates total churn stats" do
          visit churn_dashboard_path(from: "2025-06-01", to: "2025-06-30")

          within_section("Churned users") { expect(page).to have_text("2") }
          within_section("Revenue lost") { expect(page).to have_text("$30") }
          within_section("Churn rate") { expect(page).to have_text(/\d+\.\d%/) }
        end

        it "filters by product selection" do
          visit churn_dashboard_path(from: "2025-06-01", to: "2025-06-30")

          within_section("Churned users") { expect(page).to have_text("2") }
          within_section("Revenue lost") { expect(page).to have_text("$30") }

          select_disclosure "Select products..." do
            expect(page).to have_text("All products")
            expect(page).to have_text("Premium Membership")
            expect(page).to have_text("Basic Membership")

            uncheck "Premium Membership"
          end

          within_section("Churned users") { expect(page).to have_text("1") }
          within_section("Revenue lost") { expect(page).to have_text("$10") }

          select_disclosure "Select products..." do
            check "Premium Membership"
          end

          within_section("Churned users") { expect(page).to have_text("2") }
          within_section("Revenue lost") { expect(page).to have_text("$30") }
        end

        it "shows the churn chart" do
          visit churn_dashboard_path(from: "2025-06-01", to: "2025-06-30")

          expect(page).to have_css(".chart")
          expect(page).to have_css(".point", count: 30)
          expect(page).to have_css("path", minimum: 2)

          chart = find(".chart")
          chart.hover
          expect(chart).to have_tooltip(text: /\d+\.\d%.*churn/)
        end

        it "supports different date ranges" do
          visit churn_dashboard_path(from: "2025-06-16", to: "2025-06-20")

          expect(page).to have_current_path(churn_dashboard_path(from: "2025-06-16", to: "2025-06-20"))
          within_section("Churned users") { expect(page).to have_text("1") }
          within_section("Revenue lost") { expect(page).to have_text("$10") }
          expect(page).to have_css(".point", count: 5)

          expect(page).to have_css("[aria-label='Date range selector']")
          date_range_text = find("[aria-label='Date range selector']").text
          select_disclosure date_range_text do
            expect(page).to have_text("Custom range...")
          end
        end

        it "supports monthly aggregation" do
          visit churn_dashboard_path(from: "2025-05-01", to: "2025-06-30")

          expect(page).to have_select("Aggregate by", selected: "Daily")
          expect(page).to have_css(".point", count: 61)

          select "Monthly", from: "Aggregate by"
          expect(page).to have_css(".point", count: 2)
          expect(page).to have_select("Aggregate by", selected: "Monthly")

          select "Daily", from: "Aggregate by"
          expect(page).to have_select("Aggregate by", selected: "Daily")
          expect(page).to have_css(".point", count: 61)
        end
      end
    end

    context "with no churn data" do
      before do
        subscription = create(:subscription, link: membership_product1, user: create(:user))
        create(:purchase,
               link: membership_product1,
               subscription: subscription,
               is_original_subscription_purchase: true,
               price_cents: 1000,
               created_at: Time.utc(2025, 5, 1),
               purchaser: subscription.user,
               purchase_state: "successful",
               succeeded_at: Time.utc(2025, 5, 1, 12, 0, 0)
        )
        recreate_model_index(Purchase)
      end

      it "shows zero churn data" do
        visit churn_dashboard_path(from: "2025-06-01", to: "2025-06-30")
        within_section("Churned users") { expect(page).to have_text("0") }
        within_section("Churn rate") { expect(page).to have_text("0.0%") }
      end
    end
  end

  context "authorization" do
    context "when user is not authorized for analytics" do
      before do
        allow_any_instance_of(AnalyticsPolicy).to receive(:index?).and_return(false)
      end

      it "redirects or shows unauthorized message" do
        visit churn_dashboard_path
        expect(page.current_path).not_to eq(churn_dashboard_path)
      end
    end
  end

  private
    def create_churned_subscription(product, price_cents, churn_date:)
      travel_to churn_date - 3.months do
        user = create(:user)
        subscription = create(:subscription, link: product, user: user)

        create(:purchase,
               link: product,
               subscription: subscription,
               is_original_subscription_purchase: true,
               price_cents: price_cents,
               created_at: Time.current,
               purchaser: user,
               purchase_state: "successful",
               succeeded_at: Time.current + 1.hour,
               stripe_transaction_id: "test_original_#{SecureRandom.hex(8)}",
               stripe_fingerprint: "test_fp_original_#{SecureRandom.hex(8)}"
        )

        2.times do |i|
          create(:purchase,
                 link: product,
                 subscription: subscription,
                 is_original_subscription_purchase: false,
                 price_cents: price_cents,
                 created_at: Time.current + (i + 1).month,
                 purchaser: user,
                 purchase_state: "successful",
                 succeeded_at: Time.current + (i + 1).month + 1.hour,
                 stripe_transaction_id: "test_recurring_#{SecureRandom.hex(8)}",
                 stripe_fingerprint: "test_fp_#{SecureRandom.hex(8)}"
          )
        end

        subscription.update!(
          deactivated_at: churn_date,
          cancelled_at: churn_date
        )
      end
    end

    def create_active_subscriptions(product, count:, price_cents:)
      travel_to Time.utc(2025, 1, 1) do
        count.times do |i|
          user = create(:user)
          subscription = create(:subscription, link: product, user: user)

          create(:purchase,
                 link: product,
                 subscription: subscription,
                 is_original_subscription_purchase: true,
                 price_cents: price_cents,
                 created_at: Time.current + i.days,
                 purchaser: user,
                 purchase_state: "successful",
                 succeeded_at: Time.current + i.days + 1.hour,
                 stripe_transaction_id: "test_active_#{i}_#{SecureRandom.hex(8)}",
                 stripe_fingerprint: "test_active_fp_#{i}_#{SecureRandom.hex(8)}"
          )

          3.times do |payment_idx|
            create(:purchase,
                   link: product,
                   subscription: subscription,
                   is_original_subscription_purchase: false,
                   price_cents: price_cents,
                   created_at: Time.current + (payment_idx + 1).month + i.days,
                   purchaser: user,
                   purchase_state: "successful",
                   succeeded_at: Time.current + (payment_idx + 1).month + i.days + 1.hour,
                   stripe_transaction_id: "test_active_#{i}_#{payment_idx}_#{SecureRandom.hex(8)}",
                   stripe_fingerprint: "test_active_fp_#{i}_#{payment_idx}_#{SecureRandom.hex(8)}"
            )
          end
        end
      end
    end
end
