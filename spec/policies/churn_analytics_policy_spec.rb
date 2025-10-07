# frozen_string_literal: true

require "spec_helper"

describe ChurnAnalyticsPolicy do
  subject { described_class }

  let(:accountant_for_seller) { create(:user) }
  let(:admin_for_seller) { create(:user) }
  let(:marketing_for_seller) { create(:user) }
  let(:support_for_seller) { create(:user) }
  let(:seller) { create(:named_seller) }

  before do
    create(:team_membership, user: accountant_for_seller, seller:, role: TeamMembership::ROLE_ACCOUNTANT)
    create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
    create(:team_membership, user: marketing_for_seller, seller:, role: TeamMembership::ROLE_MARKETING)
    create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
  end

  permissions :index? do
    context "when feature flag is active and seller has subscription products" do
      before do
        Feature.activate_user(:churn_analytics_enabled, seller)
        create(:membership_product, user: seller)
      end

      it "grants access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).to permit(seller_context, :churn_analytics)
      end

      it "grants access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).to permit(seller_context, :churn_analytics)
      end

      it "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, :churn_analytics)
      end

      it "grants access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).to permit(seller_context, :churn_analytics)
      end

      it "grants access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).to permit(seller_context, :churn_analytics)
      end
    end

    context "when feature flag is inactive" do
      before do
        Feature.deactivate_user(:churn_analytics_enabled, seller)
        create(:membership_product, user: seller)
      end

      it "denies access" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).not_to permit(seller_context, :churn_analytics)
      end
    end

    context "when seller has no subscription products" do
      before do
        Feature.activate_user(:churn_analytics_enabled, seller)
      end

      it "denies access" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).not_to permit(seller_context, :churn_analytics)
      end
    end
  end
end
