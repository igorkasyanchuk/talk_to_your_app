# frozen_string_literal: true

require "sidekiq"
require "sidekiq/api"

module TalkToYourApp
  # Points Sidekiq at a dedicated Redis database for tests and reports whether
  # Redis is reachable so tests can skip cleanly when it is not.
  module SidekiqTestSetup
    REDIS_URL = ENV.fetch("TTYA_TEST_REDIS_URL", "redis://localhost:6379/15")

    module_function

    def available?
      configure
      ::Sidekiq.redis { |conn| conn.ping == "PONG" }
    rescue StandardError
      false
    end

    def configure
      return if @configured

      ::Sidekiq.configure_client { |config| config.redis = { url: REDIS_URL } }
      @configured = true
    end

    def reset!
      ::Sidekiq.redis { |conn| conn.flushdb }
    end
  end

  # A trivial Sidekiq worker used to enqueue real jobs into Redis under test.
  class SidekiqProbeWorker
    include ::Sidekiq::Job
    def perform(*); end
  end
end
