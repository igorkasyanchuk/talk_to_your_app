# frozen_string_literal: true

require_relative "base"

module TalkToYourApp
  module Plugins
    module Jobs
      module Tools
        # Processed/failed/enqueued counts over a trailing window. The window is
        # expressed in seconds (default 30 minutes); adapters that cannot honor
        # sub-day granularity say so in the response `note`.
        class RateMetrics < Base
          DEFAULT_WINDOW_SECONDS = 1800

          description "Processed/failed/enqueued counts over a trailing window (seconds)."
          argument    :window, :integer, default: DEFAULT_WINDOW_SECONDS, minimum: 1,
            description: "Trailing window in seconds (default 1800 = 30 minutes)."

          def call(args, _ctx)
            window = args[:window] || DEFAULT_WINDOW_SECONDS
            json(adapter.rate_metrics(window: window))
          rescue StandardError => e
            error("Jobs backend unavailable: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
