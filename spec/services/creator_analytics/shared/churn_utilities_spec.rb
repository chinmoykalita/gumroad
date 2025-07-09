# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::Shared::ChurnUtilities do
  describe ".calculate_total_stats_from_data" do
    it "returns zero stats for empty data" do
      result = described_class.calculate_total_stats_from_data([])
      expect(result).to eq({
                             churned_users: 0,
                             revenue_lost_cents: 0,
                             churn_rate: 0.0,
                             avg_active_base: 0
                           })
    end

    it "calculates total stats from period data" do
      periods_data = [
        {
          churned_users: 10,
          revenue_lost_cents: 5000,
          churn_rate: 5.0,
          active_subscribers: 200
        },
        {
          churned_users: 15,
          revenue_lost_cents: 7500,
          churn_rate: 10.0,
          active_subscribers: 150
        },
        {
          churned_users: 5,
          revenue_lost_cents: 2500,
          churn_rate: 2.5,
          active_subscribers: 200
        }
      ]

      result = described_class.calculate_total_stats_from_data(periods_data)

      expect(result[:churned_users]).to eq(30)
      expect(result[:revenue_lost_cents]).to eq(15000)
      expect(result[:avg_active_base]).to eq(183) # (200 + 150 + 200) / 3
      # Weighted average: (5.0 * 200 + 10.0 * 150 + 2.5 * 200) / (200 + 150 + 200) = 5.45
      expect(result[:churn_rate]).to eq(5.45)
    end

    it "handles nil values gracefully" do
      periods_data = [
        {
          churned_users: nil,
          revenue_lost_cents: 5000,
          churn_rate: nil,
          active_subscribers: 200
        },
        {
          churned_users: 15,
          revenue_lost_cents: nil,
          churn_rate: 10.0,
          active_subscribers: nil
        }
      ]

      result = described_class.calculate_total_stats_from_data(periods_data)

      expect(result[:churned_users]).to eq(15)
      expect(result[:revenue_lost_cents]).to eq(5000)
      expect(result[:avg_active_base]).to eq(100) # (200 + 0) / 2
      # Only the first period has valid active_subscribers > 0, but it has nil churn_rate
      # So no periods contribute to weighted average, result is 0.0
      expect(result[:churn_rate]).to eq(0.0)
    end

    it "calculates weighted average churn rate correctly" do
      periods_data = [
        { churned_users: 1, revenue_lost_cents: 1000, churn_rate: 1.0, active_subscribers: 100 },
        { churned_users: 2, revenue_lost_cents: 2000, churn_rate: 10.0, active_subscribers: 20 },
        { churned_users: 3, revenue_lost_cents: 3000, churn_rate: 5.0, active_subscribers: 60 }
      ]

      result = described_class.calculate_total_stats_from_data(periods_data)

      # Weighted average: (1.0 * 100 + 10.0 * 20 + 5.0 * 60) / (100 + 20 + 60) = 3.33
      expect(result[:churn_rate]).to eq(3.33)
    end

    it "clamps churn rate to maximum 100%" do
      periods_data = [
        { churned_users: 150, revenue_lost_cents: 15000, churn_rate: 150.0, active_subscribers: 100 }
      ]

      result = described_class.calculate_total_stats_from_data(periods_data)

      expect(result[:churn_rate]).to eq(100.0)
    end

    it "handles periods with zero active subscribers" do
      periods_data = [
        { churned_users: 5, revenue_lost_cents: 2500, churn_rate: 0.0, active_subscribers: 0 },
        { churned_users: 10, revenue_lost_cents: 5000, churn_rate: 5.0, active_subscribers: 200 }
      ]

      result = described_class.calculate_total_stats_from_data(periods_data)

      expect(result[:churned_users]).to eq(15)
      expect(result[:revenue_lost_cents]).to eq(7500)
      expect(result[:churn_rate]).to eq(5.0) # Only the period with active subscribers counts
      expect(result[:avg_active_base]).to eq(100) # (0 + 200) / 2
    end
  end

  describe ".calculate_last_period_dates" do
    context "with daily aggregation" do
      it "calculates last period dates for daily range" do
        start_date = Date.new(2025, 6, 15)
        end_date = Date.new(2025, 6, 20)

        last_start, last_end = described_class.calculate_last_period_dates(start_date, end_date, "daily")

        expect(last_start).to eq(Date.new(2025, 6, 9)) # 6 days back from June 14
        expect(last_end).to eq(Date.new(2025, 6, 14))   # Day before start_date
      end

      it "handles single day period" do
        start_date = Date.new(2025, 6, 15)
        end_date = Date.new(2025, 6, 15)

        last_start, last_end = described_class.calculate_last_period_dates(start_date, end_date, "daily")

        expect(last_start).to eq(Date.new(2025, 6, 14))
        expect(last_end).to eq(Date.new(2025, 6, 14))
      end
    end

    context "with monthly aggregation" do
      it "calculates last period dates for single month" do
        start_date = Date.new(2025, 6, 1)
        end_date = Date.new(2025, 6, 30)

        last_start, last_end = described_class.calculate_last_period_dates(start_date, end_date, "monthly")

        expect(last_start).to eq(Date.new(2025, 5, 1))
        expect(last_end).to eq(Date.new(2025, 5, 31))
      end

      it "calculates last period dates for multi-month range" do
        start_date = Date.new(2025, 6, 1)
        end_date = Date.new(2025, 8, 31) # 3 months

        last_start, last_end = described_class.calculate_last_period_dates(start_date, end_date, "monthly")

        expect(last_start).to eq(Date.new(2025, 3, 1)) # 3 months back
        expect(last_end).to eq(Date.new(2025, 5, 31))   # Day before June 1
      end

      it "handles partial month ranges" do
        start_date = Date.new(2025, 6, 15)
        end_date = Date.new(2025, 7, 20) # Spans 2 months

        last_start, last_end = described_class.calculate_last_period_dates(start_date, end_date, "monthly")

        expect(last_start).to eq(Date.new(2025, 4, 1)) # 2 months back from June
        expect(last_end).to eq(Date.new(2025, 5, 31))
      end
    end
  end

  describe ".format_dates_for_display" do
    context "with daily aggregation" do
      it "formats dates for daily display" do
        start_date = Date.new(2025, 6, 1)
        end_date = Date.new(2025, 6, 3)

        date_keys, formatted_dates = described_class.format_dates_for_display(start_date, end_date, "daily")

        expect(date_keys).to eq(["2025-06-01", "2025-06-02", "2025-06-03"])
        expect(formatted_dates).to eq([
                                        "Sunday, June 1st",
                                        "Monday, June 2nd",
                                        "Tuesday, June 3rd"
                                      ])
      end
    end

    context "with monthly aggregation" do
      it "formats dates for monthly display" do
        start_date = Date.new(2025, 6, 15)
        end_date = Date.new(2025, 8, 20)

        date_keys, formatted_dates = described_class.format_dates_for_display(start_date, end_date, "monthly")

        expect(date_keys).to eq(["2025-06", "2025-07", "2025-08"])
        expect(formatted_dates).to eq(["June 2025", "July 2025", "August 2025"])
      end

      it "handles single month" do
        start_date = Date.new(2025, 6, 1)
        end_date = Date.new(2025, 6, 30)

        date_keys, formatted_dates = described_class.format_dates_for_display(start_date, end_date, "monthly")

        expect(date_keys).to eq(["2025-06"])
        expect(formatted_dates).to eq(["June 2025"])
      end
    end
  end

  describe ".build_by_date_arrays" do
    it "builds arrays from service data" do
      date_keys = ["2025-06-01", "2025-06-02", "2025-06-03"]
      service_data = {
        "2025-06-01" => { churned_users: 5, revenue_lost_cents: 2500, churn_rate: 2.5 },
        "2025-06-02" => { churned_users: 0, revenue_lost_cents: 0, churn_rate: 0.0 },
        "2025-06-03" => { churned_users: 8, revenue_lost_cents: 4000, churn_rate: 4.0 }
      }

      result = described_class.build_by_date_arrays(date_keys, service_data)

      expect(result[:churned_users]).to eq([5, 0, 8])
      expect(result[:revenue_lost_cents]).to eq([2500, 0, 4000])
      expect(result[:churn_rate]).to eq([2.5, 0.0, 4.0])
    end

    it "handles missing data with zeros" do
      date_keys = ["2025-06-01", "2025-06-02", "2025-06-03"]
      service_data = {
        "2025-06-01" => { churned_users: 5, revenue_lost_cents: 2500, churn_rate: 2.5 }
        # Missing data for 2025-06-02 and 2025-06-03
      }

      result = described_class.build_by_date_arrays(date_keys, service_data)

      expect(result[:churned_users]).to eq([5, 0, 0])
      expect(result[:revenue_lost_cents]).to eq([2500, 0, 0])
      expect(result[:churn_rate]).to eq([2.5, 0.0, 0.0])
    end
  end

  describe ".format_first_sale_date" do
    it "formats first sale date when available" do
      user = double("User")
      allow(user).to receive(:first_sale_created_at_for_analytics).and_return(Time.utc(2025, 6, 15, 14, 30))
      allow(user).to receive(:timezone).and_return("UTC")

      result = described_class.format_first_sale_date(user)

      expect(result).to eq("June 15, 2025")
    end

    it "returns nil when no first sale date" do
      user = double("User")
      allow(user).to receive(:first_sale_created_at_for_analytics).and_return(nil)

      result = described_class.format_first_sale_date(user)

      expect(result).to be_nil
    end
  end

  describe ".calculate_last_period_stats" do
    let(:user) { create(:user, timezone: "UTC") }
    let(:start_date) { Date.new(2025, 6, 15) }
    let(:end_date) { Date.new(2025, 6, 20) }
    let(:products) { [create(:membership_product, user: user)] }

    context "when user has first sale date" do
      before do
        allow(user).to receive(:first_sale_created_at_for_analytics).and_return(Time.utc(2025, 1, 1))
      end

      it "calculates last period stats using data source" do
        data_source = lambda do |start_date, end_date, aggregate_by, products|
          {
            "2025-06-08" => { churned_users: 3, revenue_lost_cents: 1500, churn_rate: 1.5, active_subscribers: 200 },
            "2025-06-09" => { churned_users: 2, revenue_lost_cents: 1000, churn_rate: 1.0, active_subscribers: 200 }
          }
        end

        result = described_class.calculate_last_period_stats(
          user, start_date, end_date, "daily", products, data_source
        )

        expect(result[:churned_users]).to eq(5)
        expect(result[:revenue_lost_cents]).to eq(2500)
        expect(result[:churn_rate]).to eq(1.25)
      end

      it "returns zero stats when last period is before first sale date" do
        allow(user).to receive(:first_sale_created_at_for_analytics).and_return(Time.utc(2025, 6, 20))

        data_source = lambda { |*args| {} }

        result = described_class.calculate_last_period_stats(
          user, start_date, end_date, "daily", products, data_source
        )

        expect(result).to eq(described_class::ZERO_STATS)
      end

      it "returns zero stats when last period dates are invalid" do
        invalid_start = Date.new(2025, 6, 20)
        invalid_end = Date.new(2025, 6, 15)

        data_source = lambda { |*args| {} }

        result = described_class.calculate_last_period_stats(
          user, invalid_start, invalid_end, "daily", products, data_source
        )

        expect(result).to eq(described_class::ZERO_STATS)
      end
    end

    context "when user has no first sale date" do
      before do
        allow(user).to receive(:first_sale_created_at_for_analytics).and_return(nil)
      end

      it "calculates stats normally" do
        data_source = lambda do |start_date, end_date, aggregate_by, products|
          {
            "2025-06-08" => { churned_users: 1, revenue_lost_cents: 500, churn_rate: 0.5, active_subscribers: 200 }
          }
        end

        result = described_class.calculate_last_period_stats(
          user, start_date, end_date, "daily", products, data_source
        )

        expect(result[:churned_users]).to eq(1)
        expect(result[:revenue_lost_cents]).to eq(500)
        expect(result[:churn_rate]).to eq(0.5)
      end
    end

    it "handles data source errors gracefully" do
      data_source = lambda { |*args| raise StandardError, "Data source error" }

      expect(Rails.logger).to receive(:warn).with(/Failed to calculate last period churn stats/)

      result = described_class.calculate_last_period_stats(
        user, start_date, end_date, "daily", products, data_source
      )

      expect(result).to eq(described_class::ZERO_STATS)
    end
  end
end
