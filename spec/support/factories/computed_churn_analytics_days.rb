# frozen_string_literal: true

FactoryBot.define do
  factory :computed_churn_analytics_day do
    sequence(:key) { |n| "churn_key#{n}" }
    data { "{}" }
  end
end
