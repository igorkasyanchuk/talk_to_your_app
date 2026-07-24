# frozen_string_literal: true

require_relative "base"

module TalkToYourApp
  module Plugins
    module Jobs
      module Tools
        # Returns the most recently enqueued jobs, newest first, capped at 500.
        class RecentJobs < Base
          MAX_LIMIT = 500

          description "Most recently enqueued jobs (newest first)."
          argument    :limit, :integer, default: 50, minimum: 1, maximum: MAX_LIMIT,
            description: "How many jobs to return (1-500)."

          def call(args, _ctx)
            limit = args[:limit].to_i.clamp(1, MAX_LIMIT)
            json(adapter.recent_jobs(limit: limit))
          rescue StandardError => e
            error("Jobs backend unavailable: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
