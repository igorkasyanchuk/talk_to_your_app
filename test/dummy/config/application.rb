# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)
require "talk_to_your_app"

module Dummy
  class Application < Rails::Application
    config.root = File.expand_path("..", __dir__)
    config.load_defaults "#{Rails::VERSION::MAJOR}.#{Rails::VERSION::MINOR}"

    config.eager_load = false
    config.consider_all_requests_local = true
    config.secret_key_base = "dummy-secret-key-base-for-tests"
    # Silence logs in tests; stream to stdout when run as a local server so the
    # audit log lines are visible. INFO level keeps SQL debug noise out of
    # captured rake output.
    config.logger = Rails.env.test? ? Logger.new(File::NULL) : Logger.new($stdout)
    config.log_level = :info

    # Keep the dummy app quiet and dependency-light.
    config.api_only = true

    # Run background jobs through Solid Queue when serving the local demo.
    config.active_job.queue_adapter = :solid_queue if Rails.env.development?
  end
end
