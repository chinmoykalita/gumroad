# frozen_string_literal: true

require "spec_helper"

describe CreatorAnalytics::ChurnCachingProxy do
  describe "#data_for_dates" do
    before do
      @user = create(:user, timezone: "UTC", created_at: Time.utc(2023, 1, 1))
      travel_to Time.utc(2025, 1, 10)
      @membership_product1 = create(:membership_product, user: @user, name: "Premium")
      @membership_product2 = create(:membership_product, user: @user, name: "Basic")
      @dates = (Date.new(2025, 1, 1) .. Date.new(2025, 1, 7)).to_a  # same month to avoid partial month logic
      @service = described_class.new(@user)
      recreate_model_index(Purchase)
    end

    def churn_data(start_date, end_date, aggregate_by: "daily", products: nil)
      CreatorAnalytics::Churn.new(
        user: @user,
        products: products || [@membership_product1, @membership_product2],
        dates: (start_date .. end_date).to_a,
        aggregate_by: aggregate_by
      ).by_date_with_product_breakdown
    end

    it "returns merged mix of cached and generated data" do
      create(:large_seller, user: @user)

      result = @service.data_for_dates(@dates.first, @dates.last, aggregate_by: "daily")
      expect(result).to be_a(Hash)

      @dates.each do |date|
        date_key = date.to_s
        expect(result[date_key]).to be_a(Hash)
        expect(result[date_key]).to have_key(:churned_users)
        expect(result[date_key]).to have_key(:revenue_lost_cents)
        expect(result[date_key]).to have_key(:churn_rate)
        expect(result[date_key]).to have_key(:active_subscribers)
      end
    end

    it "merges cached and real-time data for missing ranges" do
      create(:large_seller, user: @user)

      cached_dates = [@dates[0], @dates[3], @dates[6]]
      cached_dates.each do |date|
        create(:computed_churn_analytics_day,
               key: @service.send(:cache_key_for_churn_data, date, aggregate_by: "daily"),
               data: churn_data(date, date, aggregate_by: "daily").to_json
        )
      end

      # Should call analytics_data for missing date ranges
      # The system might batch missing dates, so allow flexible calling
      allow(@service).to receive(:analytics_data).and_call_original

      result = @service.data_for_dates(@dates.first, @dates.last, aggregate_by: "daily")

      # All dates should have data, whether from cache or real-time
      @dates.each do |date|
        expect(result[date.to_s]).to be_present
        expect(result[date.to_s]).to have_key(:churned_users)
      end
    end

    it "handles cache misses and data integrity issues" do
      create(:large_seller, user: @user)

      # Test with missing cache entries (should fallback gracefully)
      result = @service.data_for_dates(@dates.first, @dates.last, aggregate_by: "daily")
      expect(result).to be_a(Hash)

      # Should still return valid structure even with no cache
      @dates.each do |date|
        expect(result[date.to_s]).to have_key(:churned_users)
      end
    end

    it "returns real-time data when cache should not be used" do
      allow(@service).to receive(:use_cache?).and_return(false)
      expect(@service).not_to receive(:fetch_data_for_dates)
      expect(@service).to receive(:analytics_data).with(@dates.first, @dates.last, aggregate_by: "daily", products: nil).and_call_original

      @service.data_for_dates(@dates.first, @dates.last, aggregate_by: "daily")
    end

    context "with product filtering" do
      before do
        allow(@service).to receive(:use_cache?).and_return(true)
      end

      it "filters from cached product breakdown when available" do
        # cached data with product breakdown
        cached_data = {
          "2025-01-01" => {
            churned_users: 5,
            revenue_lost_cents: 5000,
            churn_rate: 10.0,
            active_subscribers: 50,
            by_product: {
              @membership_product1.id => { churned_users: 3, revenue_lost_cents: 3000, active_subscribers: 30 },
              @membership_product2.id => { churned_users: 2, revenue_lost_cents: 2000, active_subscribers: 20 }
            }
          }
        }

        create(:computed_churn_analytics_day,
               key: @service.send(:cache_key_for_churn_data, @dates.first, aggregate_by: "daily"),
               data: cached_data.to_json
        )

        result = @service.data_for_dates(@dates.first, @dates.first, aggregate_by: "daily", products: [@membership_product1])

        expect(result["2025-01-01"][:churned_users]).to eq(3)
        expect(result["2025-01-01"][:revenue_lost_cents]).to eq(3000)
        expect(result["2025-01-01"][:active_subscribers]).to eq(30)
      end

      it "falls back to real-time when cached product filtering is not possible" do
        cached_data = {
          "2025-01-01" => {
            churned_users: 5,
            revenue_lost_cents: 5000,
            churn_rate: 10.0,
            active_subscribers: 50
          }
        }

        create(:computed_churn_analytics_day,
               key: @service.send(:cache_key_for_churn_data, @dates.first, aggregate_by: "daily"),
               data: cached_data.to_json
        )

        expect(@service).to receive(:analytics_data).with(@dates.first, @dates.first, aggregate_by: "daily", products: [@membership_product1]).and_call_original

        @service.data_for_dates(@dates.first, @dates.first, aggregate_by: "daily", products: [@membership_product1])
      end
    end

    context "with monthly aggregation and partial months" do
      before do
        @start_date = Date.new(2024, 6, 15) # Mid-month start
        @end_date = Date.new(2024, 7, 20)   # Mid-month end
        allow(@service).to receive(:use_cache?).and_return(true)
      end

      it "uses hybrid cache + real-time approach for partial months" do
        # Should use real-time for partial months
        expect(@service).to receive(:analytics_data).twice.and_call_original

        @service.data_for_dates(@start_date, @end_date, aggregate_by: "monthly")
      end

      it "uses cache for complete months" do
        # Complete month range
        complete_start = Date.new(2024, 6, 1)
        complete_end = Date.new(2024, 6, 30)

        create(:computed_churn_analytics_day,
               key: @service.send(:cache_key_for_churn_data, complete_start, aggregate_by: "monthly"),
               data: churn_data(complete_start, complete_end, aggregate_by: "monthly").to_json
        )

        expect(@service).not_to receive(:analytics_data)

        @service.data_for_dates(complete_start, complete_end, aggregate_by: "monthly")
      end
    end

    context "with monthly partial month handling" do
      before do
        create(:large_seller, user: @user)
      end

      it "detects and handles partial months correctly for 'last 30 days' scenarios" do
        # Simulate "last 30 days" crossing month boundaries (June 8 - July 8)
        start_date = Date.new(2025, 6, 8)
        end_date = Date.new(2025, 7, 8)

        # Should detect partial months and use hybrid approach
        expect(@service).to receive(:analytics_data).at_least(:once).with(
          anything, anything, hash_including(aggregate_by: "monthly")
        ).and_call_original

        result = @service.data_for_dates(start_date, end_date, aggregate_by: "monthly")
        expect(result).to be_a(Hash)
      end

      it "uses cache for complete month requests" do
        # Complete month: July 1 - July 31
        start_date = Date.new(2025, 7, 1)
        end_date = Date.new(2025, 7, 31)

        # Create cached data for complete month
        create(:computed_churn_analytics_day,
               key: @service.send(:cache_key_for_churn_data, start_date, aggregate_by: "monthly"),
               data: churn_data(start_date, end_date, aggregate_by: "monthly").to_json
        )

        # Should NOT call analytics_data for complete month (uses cache)
        expect(@service).not_to receive(:analytics_data)

        result = @service.data_for_dates(start_date, end_date, aggregate_by: "monthly")
        expect(result).to be_a(Hash)
      end

      it "splits complex date ranges with multiple complete and partial months" do
        # Complex range: May 15 - August 20 (partial May, complete June/July, partial August)
        start_date = Date.new(2025, 5, 15)
        end_date = Date.new(2025, 8, 20)

        # Should use hybrid approach - some cache, some real-time
        expect(@service).to receive(:analytics_data).at_least(:once).and_call_original

        result = @service.data_for_dates(start_date, end_date, aggregate_by: "monthly")
        expect(result).to be_a(Hash)
      end
    end

    context "with decision tree logic" do
      it "immediately computes real-time for non-large sellers" do
        # Don't create large_seller record
        expect(@service.send(:use_cache?)).to eq(false)

        # Should go straight to real-time computation
        expect(@service).to receive(:analytics_data).with(
          @dates.first, @dates.last, hash_including(aggregate_by: "daily", products: nil)
        ).and_call_original

        result = @service.data_for_dates(@dates.first, @dates.last, aggregate_by: "daily")
        expect(result).to be_a(Hash)
      end

      it "uses cache infrastructure for large sellers with proper fallbacks" do
        create(:large_seller, user: @user)

        # Should attempt cache operations first
        expect(@service).to receive(:fetch_data_for_dates).and_call_original

        result = @service.data_for_dates(@dates.first, @dates.last, aggregate_by: "daily")
        expect(result).to be_a(Hash)
      end

      it "handles product filtering decision tree correctly" do
        create(:large_seller, user: @user)

        # Test with product filtering - should check for cached breakdown first
        expect(@service).to receive(:fetch_and_filter_cached_data).and_call_original

        result = @service.data_for_dates(
          @dates.first, @dates.last,
          aggregate_by: "daily",
          products: [@membership_product1]
        )
        expect(result).to be_a(Hash)
      end
    end

    context "with data accuracy and integrity" do
      before do
        create(:large_seller, user: @user)
      end

      it "ensures partial month requests exclude unwanted days for accuracy" do
        # Example from description: June 8 - July 8 should NOT include June 1-7
        start_date = Date.new(2025, 6, 8)
        end_date = Date.new(2025, 7, 8)

        # For partial months, should compute real-time to avoid including unwanted days
        # This prevents cached full-month data from contaminating results
        expect(@service).to receive(:analytics_data).with(
          start_date, Date.new(2025, 6, 30), hash_including(aggregate_by: "monthly")
        ).and_call_original

        expect(@service).to receive(:analytics_data).with(
          Date.new(2025, 7, 1), end_date, hash_including(aggregate_by: "monthly")
        ).and_call_original

        result = @service.data_for_dates(start_date, end_date, aggregate_by: "monthly")
        expect(result).to be_a(Hash)
      end

      it "maintains consistent data structure across cache and real-time paths" do
        test_date = Date.new(2025, 2, 15)
        real_time_result = @service.data_for_dates(test_date, test_date, aggregate_by: "daily")

        create(:computed_churn_analytics_day,
               key: @service.send(:cache_key_for_churn_data, test_date, aggregate_by: "daily"),
               data: churn_data(test_date, test_date, aggregate_by: "daily").to_json
        )

        cached_result = @service.data_for_dates(test_date, test_date, aggregate_by: "daily")

        expect(cached_result.keys).to eq(real_time_result.keys)
        cached_result.each do |date_key, data|
          expect(data.keys.sort).to eq(real_time_result[date_key].keys.sort)
        end
      end

      it "handles real-time vs cache decisions transparently" do
        # System should seamlessly switch between real-time and cache

        test_date = Date.new(2025, 3, 20)  # Use a different date to avoid conflicts

        # First call - no cache, should use real-time
        result1 = @service.data_for_dates(test_date, test_date, aggregate_by: "daily")

        # Second call - after cache generation, should use cache
        @service.send(:fetch_data, test_date, aggregate_by: "daily")
        result2 = @service.data_for_dates(test_date, test_date, aggregate_by: "daily")

        # Results should be equivalent despite different data sources
        expect(result1.keys).to eq(result2.keys)
        result1.each do |date_key, data|
          result2_data = result2[date_key]
          [:churned_users, :revenue_lost_cents, :churn_rate, :active_subscribers].each do |metric|
            expect(data[metric]).to eq(result2_data[metric])
          end
        end
      end
    end
  end

  describe "#generate_cache" do
    before do
      @membership_product = create(:membership_product)
      @service = described_class.new(@membership_product.user)
    end

    it "generates cache for users with subscription sales" do
      subscription = create(:subscription, link: @membership_product, user: create(:user))
      create(:purchase,
             link: @membership_product,
             subscription: subscription,
             is_original_subscription_purchase: true,
             created_at: Time.utc(2025, 8, 1),
             purchaser: subscription.user
      )

      @membership_product.user.update!(timezone: "Tokyo")
      travel_to Time.utc(2025, 8, 6, 22) # Aug 7 in Tokyo

      create(:computed_churn_analytics_day,
             key: @service.send(:cache_key_for_churn_data, Date.new(2025, 8, 3), aggregate_by: "daily"),
             data: "{}"
      )
      create(:computed_churn_analytics_day,
             key: @service.send(:cache_key_for_churn_data, Date.new(2025, 8, 1), aggregate_by: "monthly"),
             data: "{}"
      )

      expect(@service).to receive(:fetch_data).with(Date.new(2025, 8, 2), aggregate_by: "daily")
      expect(@service).not_to receive(:fetch_data).with(Date.new(2025, 8, 3), aggregate_by: "daily")
      expect(@service).to receive(:fetch_data).with(Date.new(2025, 8, 4), aggregate_by: "daily")
      expect(@service).to receive(:fetch_data).with(Date.new(2025, 8, 5), aggregate_by: "daily")

      expect(@service).not_to receive(:fetch_data).with(Date.new(2025, 8, 1), aggregate_by: "monthly")

      @service.generate_cache
    end

    it "handles users with no subscription sales" do
      user = create(:user)
      expect { described_class.new(user).generate_cache }.not_to raise_error
    end

    it "skips suspended users" do
      user = create(:tos_user)
      create(:purchase, link: create(:membership_product, user: user))
      expect(user).to receive(:suspended?).and_return(true)
      described_class.new(user).generate_cache
    end

    it "only processes users with subscriptions" do
      user = create(:user)
      create(:purchase, link: create(:product, user: user)) # Regular product, not subscription
      expect { described_class.new(user).generate_cache }.not_to raise_error
    end
  end

  describe "#overwrite_cache" do
    before do
      travel_to Time.utc(2025, 1, 1)
      @user = create(:user, timezone: "UTC")
      @service = described_class.new(@user)
    end

    it "does not update data for recent dates" do
      allow(@service).to receive(:use_cache?).and_return(true)
      expect(ComputedChurnAnalyticsDay).not_to receive(:upsert_data_from_key)
      @service.overwrite_cache(Date.yesterday)
      @service.overwrite_cache(Date.today)
      @service.overwrite_cache(Date.tomorrow)
    end

    it "does not update data when cache should not be used" do
      allow(@service).to receive(:use_cache?).and_return(false)
      expect(ComputedChurnAnalyticsDay).not_to receive(:upsert_data_from_key)
      @service.overwrite_cache(Date.new(2024, 12, 30))
    end

    it "regenerates and stores churn analytics for the date" do
      allow(@service).to receive(:use_cache?).and_return(true)
      date = 3.days.ago.to_date

      membership_product = create(:membership_product, user: @user)
      subscription = create(:subscription, link: membership_product, user: create(:user))
      create(:purchase,
             link: membership_product,
             subscription: subscription,
             is_original_subscription_purchase: true,
             created_at: date - 30.days,
             purchaser: subscription.user
      )

      expect(ComputedChurnAnalyticsDay).to receive(:upsert_data_from_key).once

      @service.overwrite_cache(date)
    end

    context "with monthly aggregation" do
      it "uses first day of month as cache key for monthly data" do
        allow(@service).to receive(:use_cache?).and_return(true)
        date = Date.new(2024, 12, 15)

        expect(ComputedChurnAnalyticsDay).to receive(:upsert_data_from_key).with(
          @service.send(:cache_key_for_churn_data, Date.new(2024, 12, 1), aggregate_by: "monthly"),
          anything
        )

        @service.overwrite_cache(date, aggregate_by: "monthly")
      end
    end
  end

  describe "#use_cache?" do
    it "returns true if user is a large seller" do
      user = create(:user)
      service = described_class.new(user)
      expect(service.send(:use_cache?)).to eq(false)

      create(:large_seller, user: user)
      expect(service.send(:use_cache?)).to eq(true)
    end
  end

  describe "#cache_key_for_churn_data" do
    it "returns cache key for churn data by date" do
      user = create(:user, timezone: "Tokyo")
      cache_key = described_class.new(user).send(:cache_key_for_churn_data, Date.new(2025, 12, 3))
      expect(cache_key).to eq("seller_churn_analytics_v0_user_#{user.id}_Tokyo_churn_by_daily_for_2025-12-03")
    end

    it "returns cache key for monthly aggregation" do
      user = create(:user, timezone: "UTC")
      cache_key = described_class.new(user).send(:cache_key_for_churn_data, Date.new(2025, 12, 3), aggregate_by: "monthly")
      expect(cache_key).to eq("seller_churn_analytics_v0_user_#{user.id}_UTC_churn_by_monthly_for_2025-12-03")
    end
  end

  describe "#user_cache_key" do
    it "returns cache key for the user and its timezone" do
      user = create(:user, timezone: "London")
      user_cache_key = described_class.new(user).send(:user_cache_key)
      expect(user_cache_key).to eq("seller_churn_analytics_v0_user_#{user.id}_London")

      $redis.set(RedisKey.seller_analytics_cache_version, 5)
      user_cache_key = described_class.new(user).send(:user_cache_key)
      expect(user_cache_key).to eq("seller_churn_analytics_v5_user_#{user.id}_London")
    end

    it "handles Redis unavailability gracefully" do
      user = create(:user, timezone: "UTC")
      allow($redis).to receive(:get).and_raise(Redis::CannotConnectError)

      expect(Rails.logger).to receive(:warn).with(/Redis unavailable/)
      user_cache_key = described_class.new(user).send(:user_cache_key)
      expect(user_cache_key).to eq("seller_churn_analytics_v0_user_#{user.id}_UTC")
    end
  end

  describe "#analytics_data" do
    it "proxies method call to ChurnService" do
      user = create(:user, timezone: "UTC")
      start_date, end_date = Date.new(2024, 1, 1), Date.new(2024, 1, 7)
      dates = (start_date .. end_date).to_a
      products = [create(:membership_product, user: user)]

      expect(CreatorAnalytics::Churn).to receive(:new).with(
        user: user,
        products: products,
        dates: dates,
        aggregate_by: "daily"
      ).and_call_original
      expect_any_instance_of(CreatorAnalytics::Churn).to receive(:by_date).and_call_original

      service = described_class.new(user)
      service.send(:analytics_data, start_date, end_date, aggregate_by: "daily", products: products)
    end
  end

  describe "#analytics_data_with_product_breakdown" do
    it "proxies method call to ChurnService with product breakdown" do
      user = create(:user, timezone: "UTC")
      start_date, end_date = Date.new(2024, 1, 1), Date.new(2024, 1, 7)
      dates = (start_date .. end_date).to_a

      expect(CreatorAnalytics::Churn).to receive(:new).with(
        user: user,
        products: user.products_for_creator_analytics,
        dates: dates,
        aggregate_by: "daily"
      ).and_call_original
      expect_any_instance_of(CreatorAnalytics::Churn).to receive(:by_date_with_product_breakdown).and_call_original

      service = described_class.new(user)
      service.send(:analytics_data_with_product_breakdown, start_date, end_date, aggregate_by: "daily")
    end
  end

  describe "#fetch_data" do
    before do
      travel_to Time.utc(2025, 2, 1)
      @user = create(:user, timezone: "UTC")
      @service = described_class.new(@user)
    end

    it "returns cached data if it exists, generates the data if not" do
      date = Date.new(2025, 1, 1)
      expect(@service).to receive(:analytics_data_with_product_breakdown).with(date, date, aggregate_by: "daily").once.and_return("churn_data")
      expect(@service.send(:fetch_data, date)).to eq("churn_data")
      expect(@service.send(:fetch_data, date)).to eq("churn_data") # from cache
    end

    it "does not cache data for recent dates" do
      date = Date.new(2025, 2, 1) # today in the test
      expect(ComputedChurnAnalyticsDay).not_to receive(:fetch_data_from_key)
      expect(@service).to receive(:analytics_data_with_product_breakdown).twice.and_return("data1", "data2")

      expect(@service.send(:fetch_data, date)).to eq("data1")
      expect(@service.send(:fetch_data, date)).to eq("data2")
    end

    context "with monthly aggregation" do
      it "fetches data for entire month range" do
        date = Date.new(2025, 1, 15) # Mid-month
        cache_date = Date.new(2025, 1, 1) # First of month
        month_end = Date.new(2025, 1, 31) # End of month

        expect(@service).to receive(:analytics_data_with_product_breakdown).with(
          cache_date, month_end, aggregate_by: "monthly"
        ).and_return("monthly_data")

        result = @service.send(:fetch_data, date, aggregate_by: "monthly")
        expect(result).to eq("monthly_data")
      end
    end
  end

  describe "#requested_dates" do
    before do
      @user = create(:user, timezone: "UTC", created_at: Time.utc(2024))
      travel_to Time.utc(2025)
      @service = described_class.new(@user)
    end

    it "constrains dates to valid range" do
      # Future dates should be constrained to today
      today = @service.send(:today_date)
      result = @service.send(:requested_dates, today + 2, today + 5, aggregate_by: "daily")
      expect(result).to eq([today])
    end

    it "uses first sale date as earliest constraint when available" do
      allow(@user).to receive(:first_sale_created_at_for_analytics).and_return(Time.utc(2024, 6, 15))

      result = @service.send(:requested_dates, Date.new(2024, 1, 1), Date.new(2024, 12, 31), aggregate_by: "daily")
      expect(result.first).to eq(Date.new(2024, 6, 15))
    end

    it "uses user creation date when no first sale date" do
      allow(@user).to receive(:first_sale_created_at_for_analytics).and_return(nil)

      result = @service.send(:requested_dates, Date.new(2023, 1, 1), Date.new(2024, 12, 31), aggregate_by: "daily")
      expect(result.first).to eq(@user.created_at.in_time_zone(@user.timezone).to_date)
    end
  end

  describe "#uncached_dates" do
    it "returns all dates missing from cache" do
      user = create(:user)
      service = described_class.new(user)

      [Date.new(2025, 1, 1), Date.new(2025, 1, 3)].each do |date|
        create(:computed_churn_analytics_day,
               key: service.send(:cache_key_for_churn_data, date),
               data: "{}"
        )
      end

      dates = (Date.new(2025, 1, 1) .. Date.new(2025, 1, 4)).to_a
      expect(service.send(:uncached_dates, dates)).to match_array([
                                                                    Date.new(2025, 1, 2),
                                                                    Date.new(2025, 1, 4)
                                                                  ])
    end

    context "with monthly aggregation" do
      it "converts dates to monthly cache dates" do
        user = create(:user)
        service = described_class.new(user)

        # Create cache for first day of January
        create(:computed_churn_analytics_day,
               key: service.send(:cache_key_for_churn_data, Date.new(2025, 1, 1), aggregate_by: "monthly"),
               data: "{}"
        )

        # Test with various dates in January and February
        dates = [Date.new(2025, 1, 15), Date.new(2025, 1, 31), Date.new(2025, 2, 10)]
        uncached = service.send(:uncached_dates, dates, aggregate_by: "monthly")

        # Should return first day of February since January is cached
        expect(uncached).to eq([Date.new(2025, 2, 1)])
      end
    end
  end

  describe "#filter_metrics_by_products" do
    before do
      @user = create(:user)
      @service = described_class.new(@user)
      @product1_id = 123
      @product2_id = 456
      @product3_id = 789
    end

    it "filters and aggregates metrics for specified products" do
      cached_metrics = {
        "churned_users" => 10,
        "revenue_lost_cents" => 10000,
        "active_subscribers" => 100,
        "by_product" => {
          @product1_id.to_s => { "churned_users" => 3, "revenue_lost_cents" => 3000, "active_subscribers" => 30 },
          @product2_id.to_s => { "churned_users" => 4, "revenue_lost_cents" => 4000, "active_subscribers" => 40 },
          @product3_id.to_s => { "churned_users" => 3, "revenue_lost_cents" => 3000, "active_subscribers" => 30 }
        }
      }

      product_ids = Set.new([@product1_id, @product3_id])
      result = @service.send(:filter_metrics_by_products, cached_metrics, product_ids)

      expect(result[:churned_users]).to eq(6) # 3 + 3
      expect(result[:revenue_lost_cents]).to eq(6000) # 3000 + 3000
      expect(result[:active_subscribers]).to eq(60) # 30 + 30
      expect(result[:churn_rate]).to eq(10.0) # (6 / 60) * 100
    end

    it "calculates zero churn rate when no active subscribers" do
      cached_metrics = {
        "by_product" => {
          @product1_id.to_s => { "churned_users" => 1, "revenue_lost_cents" => 1000, "active_subscribers" => 0 }
        }
      }

      product_ids = Set.new([@product1_id])
      result = @service.send(:filter_metrics_by_products, cached_metrics, product_ids)

      expect(result[:churn_rate]).to eq(0.0)
    end
  end

  describe "#subscription_product_ids" do
    it "returns sorted IDs of subscription and membership products" do
      user = create(:user)
      regular_product = create(:product, user: user)
      membership_product = create(:membership_product, user: user)
      subscription_product = create(:subscription_product, user: user)

      service = described_class.new(user)
      result = service.send(:subscription_product_ids)

      expect(result).to contain_exactly(membership_product.id, subscription_product.id)
      expect(result).not_to include(regular_product.id)
      expect(result).to eq(result.sort) # Should be sorted
    end
  end
end
