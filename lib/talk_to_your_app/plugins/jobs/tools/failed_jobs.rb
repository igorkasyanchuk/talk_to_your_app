# frozen_string_literal: true

require_relative "base"

module TalkToYourApp
  module Plugins
    module Jobs
      module Tools
        # Returns recently failed jobs with their error messages, capped at 500.
        class FailedJobs < Base
          MAX_LIMIT = 500

          description "Recently failed jobs and their error messages."
          argument    :limit, :integer, default: 50, minimum: 1, maximum: MAX_LIMIT,
            description: "How many failed jobs to return (1-500)."

          def call(args, _ctx)
            limit = args[:limit].to_i.clamp(1, MAX_LIMIT)
            json(adapter.failed_jobs(limit: limit))
          rescue StandardError => e
            error("Jobs backend unavailable: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
