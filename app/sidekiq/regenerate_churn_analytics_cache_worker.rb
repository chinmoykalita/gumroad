# frozen_string_literal: true

class RegenerateChurnAnalyticsCacheWorker
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low, lock: :until_executed

  def perform(user_id, date_string)
    user = User.find(user_id)
    date = Date.parse(date_string)
    service = CreatorAnalytics::ChurnCachingProxy.new(user)

    WithMaxExecutionTime.timeout_queries(seconds: 20.minutes) do
      ["daily", "monthly"].each do |aggregate_by|
        service.overwrite_cache(date, aggregate_by: aggregate_by)
      end
    end
  end
end
