# frozen_string_literal: true

require_relative "base"

module TalkToYourApp
  module Plugins
    module Jobs
      module Tools
        # Returns the current size of each queue as { queue_name => count }.
        # The concrete MCP name is set per adapter (e.g. "sidekiq.queue_sizes").
        class QueueSizes < Base
          description "Current size of each background-job queue."

          def call(_args, _ctx)
            json(adapter.queue_sizes)
          rescue StandardError => e
            error("Jobs backend unavailable: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
