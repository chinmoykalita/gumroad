# frozen_string_literal: true

require "spec_helper"

describe RegenerateChurnAnalyticsCacheWorker do
  describe "#perform" do
    it "runs CreatorAnalytics::ChurnCachingProxy#overwrite_cache for both aggregation types" do
      user = create(:user)

      service_object = double("CreatorAnalytics::ChurnCachingProxy object")
      expect(CreatorAnalytics::ChurnCachingProxy).to receive(:new).with(user).and_return(service_object)
      expect(service_object).to receive(:overwrite_cache).with(Date.new(2025, 6, 15), aggregate_by: "daily")
      expect(service_object).to receive(:overwrite_cache).with(Date.new(2025, 6, 15), aggregate_by: "monthly")

      described_class.new.perform(user.id, "2025-06-15")
    end
  end
end
