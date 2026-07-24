# frozen_string_literal: true

module TalkToYourApp
  module Plugins
    module Jobs
      # The contract every jobs adapter must satisfy. Adapters duck-type it —
      # there is no abstract base class and no `include`. Each method returns a
      # plain Ruby structure with a stable shape across adapters, so a client
      # sees the same response whether the backend is Sidekiq or Solid Queue.
      #
      #   queue_sizes            -> { "queue_name" => Integer, ... }
      #   recent_jobs(limit:)    -> [ { jid:, class:, queue:, args:, enqueued_at:, error_message: }, ... ]
      #   failed_jobs(limit:)    -> [ { jid:, class:, queue:, args:, enqueued_at:, error_message: }, ... ]
      #   rate_metrics(window:)  -> { window_seconds:, processed:, failed:, enqueued:, note? }
      #
      # Job hashes carry the same keys across adapters and across recent/failed;
      # `enqueued_at` is an ISO-8601 string and `error_message` is nil for jobs
      # that have not failed. `window:` is a number of seconds; adapters that
      # cannot honor sub-day granularity include a `note` explaining the
      # resolution they returned.
      module Interface
        METHODS = %i[queue_sizes recent_jobs failed_jobs rate_metrics].freeze

        # True when the adapter responds to every interface method. Checked at
        # boot so an incomplete adapter fails fast rather than at first call.
        def self.satisfied_by?(adapter)
          METHODS.all? { |method| adapter.respond_to?(method) }
        end
      end
    end
  end
end
