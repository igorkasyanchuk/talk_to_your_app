# frozen_string_literal: true

source "https://rubygems.org"

# Specify gem dependencies in talk_to_your_app.gemspec
gemspec

# Rails is a hard dependency at the integration level; pin a concrete version
# locally. Appraisal overrides this for the 7.2 / 8.0 / 8.1 matrix.
gem "rails", ">= 7.2"

group :development, :test do
  gem "rake", "~> 13.0"
  gem "minitest", "~> 5.0"
  gem "rack-test", "~> 2.0"
  gem "appraisal", "~> 2.5"
  gem "debug", ">= 1.0", require: false # interactive debugger (binding.break)
  gem "puma", ">= 6.0"                   # serve the dummy app for local Claude testing

  # Default dummy-app database.
  gem "sqlite3", ">= 1.4"

  # Real backends for integration tests (soft deps in the gemspec).
  gem "pg", "~> 1.5"               # DB plugin read-only role tests
  gem "sidekiq", ">= 7.0"          # Jobs plugin Sidekiq adapter
  gem "solid_queue", ">= 1.0"      # Jobs plugin Solid Queue adapter
  gem "flipper", "~> 1.3"          # Flipper plugin
  gem "flipper-active_record", "~> 1.3"
end
