# frozen_string_literal: true

describe ChurnPresenter do
  let(:seller) { create(:user) }
  let(:presenter) { described_class.new(seller: seller) }

  let!(:alive_membership) { create(:membership_product, user: seller) }
  let!(:alive_subscription) { create(:subscription_product, user: seller) }
  let!(:deleted_membership_with_sales) { create(:membership_product, user: seller, deleted_at: Time.current) }
  let!(:deleted_subscription_without_sales) { create(:subscription_product, user: seller, deleted_at: Time.current) }
  let!(:regular_product) { create(:product, user: seller) }

  before do
    allow_any_instance_of(Link).to receive(:external_id).and_return("test-external-id")
    create(:purchase, link: deleted_membership_with_sales)
  end

  describe "#page_props" do
    it "returns the correct props" do
      expect(presenter.page_props[:products]).to contain_exactly(
        {
          id: alive_membership.external_id,
          alive: true,
          unique_permalink: alive_membership.unique_permalink,
          name: alive_membership.name
        }, {
          id: alive_subscription.external_id,
          alive: true,
          unique_permalink: alive_subscription.unique_permalink,
          name: alive_subscription.name
        }, {
          id: deleted_membership_with_sales.external_id,
          alive: false,
          unique_permalink: deleted_membership_with_sales.unique_permalink,
          name: deleted_membership_with_sales.name
        }
      )
    end
  end
end
