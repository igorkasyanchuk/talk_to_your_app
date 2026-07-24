# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"

require "active_record"
ActiveRecord::Migration.verbose = false
load File.expand_path("dummy/db/schema.rb", __dir__)

require "minitest/autorun"

module TalkToYourApp
  # Base class for gem unit tests. Resets the configuration singleton around
  # each test so configuration set in one test never leaks into the next.
  class TestCase < Minitest::Test
    def setup
      TalkToYourApp.reset_configuration!
      super
    end

    def teardown
      super
      TalkToYourApp.reset_configuration!
    end
  end
end
