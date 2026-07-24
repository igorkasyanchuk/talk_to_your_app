# frozen_string_literal: true

require "time"

module TalkToYourApp
  module Plugins
    module Jobs
      module Adapters
        # Sidekiq adapter. Reads queue, retry, and dead-set data through
        # Sidekiq's public API. Read-only: it never enqueues, retries, or kills.
        # All four methods return the common shape defined by Jobs::Interface.
        module Sidekiq
          REQUIRED_GEM = { const: "Sidekiq", gem_name: "sidekiq" }.freeze

          module_function

          def required_gem
            REQUIRED_GEM
          end

          def queue_sizes
            load_api
            ::Sidekiq::Stats.new.queues
          end

          # Sidekiq has no first-class "recent jobs" API; we scan the queues and
          # the retry set, sort newest-first by enqueued time, and cap at limit.
          # Per-queue fetch is bounded so a many-queue install does not materialize
          # limit*queue_count records to return `limit`; this can miss the very
          # newest jobs when they cluster in one queue, which is acceptable for an
          # inspection tool.
          def recent_jobs(limit:)
            load_api
            queues = ::Sidekiq::Queue.all
            per_queue = [(limit / [queues.size, 1].max) + 1, limit].min
            queued = queues.flat_map { |queue| queue.first(per_queue) }
            retries = ::Sidekiq::RetrySet.new.first(limit)
            (queued + retries)
              .sort_by { |entry| -raw_enqueued_at(entry) }
              .first(limit)
              .map { |entry| job_hash(entry) }
          end

          def failed_jobs(limit:)
            load_api
            ::Sidekiq::DeadSet.new.first(limit).map { |entry| job_hash(entry) }
          end

          # Sidekiq exposes cumulative and day-resolution counts, not arbitrary
          # trailing windows; the response says so via `note`.
          def rate_metrics(window:)
            load_api
            stats = ::Sidekiq::Stats.new
            {
              window_seconds: window,
              processed: stats.processed,
              failed: stats.failed,
              enqueued: stats.enqueued,
              note: "Sidekiq reports cumulative processed/failed counts; the window is not applied at sub-day resolution.",
            }
          end

          # Both Sidekiq::JobRecord and Sidekiq::SortedEntry expose the raw job
          # hash via #item. Keys are always present (nil where absent) so the
          # shape is stable across adapters and across recent/failed.
          def job_hash(entry)
            item = entry.respond_to?(:item) ? entry.item : entry
            {
              jid: item["jid"],
              class: item["class"] || item["wrapped"],
              queue: item["queue"],
              args: item["args"],
              enqueued_at: iso8601(item["enqueued_at"] || item["created_at"]),
              error_message: item["error_message"],
            }
          end

          # Sidekiq stores timestamps as Unix floats; surface ISO-8601 so the
          # field type matches the Solid Queue adapter.
          def iso8601(unix_timestamp)
            return nil unless unix_timestamp

            Time.at(unix_timestamp.to_f).utc.iso8601
          end

          def raw_enqueued_at(entry)
            item = entry.respond_to?(:item) ? entry.item : entry
            (item["enqueued_at"] || item["created_at"] || 0).to_f
          end

          # Sidekiq's metrics API (Stats/Queue/RetrySet/DeadSet) is not loaded by
          # `require "sidekiq"`. Load it lazily at call time — never at gem load —
          # so an app without Sidekiq can still load this adapter file. `require`
          # is idempotent, so repeated calls are cheap.
          def load_api
            require "sidekiq/api"
          end
        end
      end
    end
  end
end

TalkToYourApp::Plugins::Jobs.register_adapter(:sidekiq, TalkToYourApp::Plugins::Jobs::Adapters::Sidekiq)
