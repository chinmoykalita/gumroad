# frozen_string_literal: true

describe ChurnPresenter do
  let(:seller) { create(:user) }
  let(:presenter) { described_class.new(seller:) }

  let!(:alive_product) { create(:membership_product, user: seller) }
  let!(:deleted_with_sales) { create(:membership_product, user: seller, deleted_at: Time.current) }

  before { create(:purchase, link: deleted_with_sales) }

  describe "#page_props" do
    it "returns products from the churn service and aggregate options" do
      churn_service = instance_double(CreatorAnalytics::Churn)
      expect(CreatorAnalytics::Churn).to receive(:new).with(seller:).and_return(churn_service)
      expect(churn_service).to receive(:subscription_products).and_return([alive_product, deleted_with_sales])

      props = presenter.page_props

      expect(props[:products]).to contain_exactly(
        {
          id: alive_product.external_id,
          alive: true,
          unique_permalink: alive_product.unique_permalink,
          name: alive_product.name
        },
        {
          id: deleted_with_sales.external_id,
          alive: false,
          unique_permalink: deleted_with_sales.unique_permalink,
          name: deleted_with_sales.name
        }
      )

      aggregate_options = props[:aggregate_options]
      expected = CreatorAnalytics::Churn::AGGREGATE_OPTIONS.map { |value, config| { value:, title: config[:title] } }
      expect(aggregate_options).to match_array(expected)
    end
  end

  describe "#serialize_churn" do
    it "builds chart_points and totals for daily aggregation" do
      start_date = Date.new(2025, 6, 14)
      end_date = Date.new(2025, 6, 15)
      period_data = {
        start_date => { churn_rate: 5.0, churned_users: 2, revenue_lost_cents: 1000 },
        end_date => { churn_rate: 7.0, churned_users: 3, revenue_lost_cents: 2000 }
      }
      data = {
        start_date: start_date,
        end_date: end_date,
        period_data: period_data,
        total: { churn_rate: 6.0, churned_users: 5, revenue_lost_cents: 3000 },
        last_period: { churn_rate: 4.0 },
        first_sale_date: Date.new(2021, 1, 1)
      }

      json = presenter.serialize_churn(data:, aggregate_by: CreatorAnalytics::Churn::AGGREGATE_BY_DAY)

      expect(json[:chart_points].length).to eq(2)
      expect(json[:chart_points].first[:churn_rate]).to eq(5.0)
      expect(json[:chart_points].last[:churned_users]).to eq(3)
      expect(json[:chart_points].first[:label]).to eq(json[:chart_points].first[:title])
      expect(json[:chart_points].last[:label]).to eq(json[:chart_points].last[:title])

      expect(json[:totals]).to include(
        churn_rate: 6.0,
        last_period_churn_rate: 4.0,
        revenue_lost_cents: 3000,
        churned_users: 5
      )
      expect(json[:first_sale_date]).to eq("January 01, 2021")
    end

    it "steps over months and formats titles for monthly aggregation" do
      start_date = Date.new(2025, 1, 10)
      end_date = Date.new(2025, 3, 20)
      period_data = {
        Date.new(2025, 1, 1) => { churn_rate: 1.0, churned_users: 1, revenue_lost_cents: 100 },
        Date.new(2025, 3, 1) => { churn_rate: 3.0, churned_users: 3, revenue_lost_cents: 300 }
      }
      data = { start_date:, end_date:, period_data:, total: {}, last_period: {} }

      json = presenter.serialize_churn(data:, aggregate_by: CreatorAnalytics::Churn::AGGREGATE_BY_MONTH)

      expect(json[:chart_points].length).to eq(3)
      expect(json[:chart_points].map { |p| p[:title] }).to eq(["January 2025", "February 2025", "March 2025"])
      feb_point = json[:chart_points][1]
      expect(feb_point[:churn_rate]).to eq(0.0)
      expect(feb_point[:churned_users]).to eq(0)
      expect(feb_point[:revenue_lost_cents]).to eq(0)
    end
  end
end
