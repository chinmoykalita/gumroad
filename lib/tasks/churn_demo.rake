# frozen_string_literal: true

namespace :churn do
  desc "Seed churn analytics test data"
  task demo_seed: :environment do
    seed_file = Rails.root.join("db", "seeds", "091_churn_analytics_simple.rb")
    # seed_file = Rails.root.join("db", "seeds", "090_churn_analytics_demo.rb")
    puts "Loading #{seed_file}"
    load(seed_file)
  end
end
