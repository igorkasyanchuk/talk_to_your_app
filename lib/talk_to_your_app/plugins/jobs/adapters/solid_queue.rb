# frozen_string_literal: true

module TalkToYourApp
  module Plugins
    module Jobs
      module Adapters
        # Solid Queue adapter. Reads Solid Queue's ActiveRecord models, which
        # live in the host application's database. By default the queries run on
        # the primary connection (whatever Solid Queue itself is configured to
        # use); operators wanting isolation point Solid Queue at a separate
        # database in their own config. Read-only and returns the common shape.
        module SolidQueue
          REQUIRED_GEM = { const: "SolidQueue", gem_name: "solid_queue" }.freeze

          module_function

          def required_gem
            REQUIRED_GEM
          end

          def queue_sizes
            ::SolidQueue::ReadyExecution.group(:queue_name).count
          end

          def recent_jobs(limit:)
            ::SolidQueue::Job.order(created_at: :desc).limit(limit).map { |job| job_hash(job) }
          end

          def failed_jobs(limit:)
            ::SolidQueue::FailedExecution.includes(:job).order(created_at: :desc).limit(limit).map do |failure|
              job_hash(failure.job).merge(error_message: failure.message)
            end
          end

          def rate_metrics(window:)
            since = Time.now - window.to_i # plain Ruby; no ActiveSupport core-ext dependency
            {
              window_seconds: window,
              enqueued: ::SolidQueue::Job.where(created_at: since..).count,
              processed: ::SolidQueue::Job.where.not(finished_at: nil).where(finished_at: since..).count,
              failed: ::SolidQueue::FailedExecution.where(created_at: since..).count,
            }
          end

          def job_hash(job)
            # Keep every key present even for an orphaned failure (nil job), so
            # the shape matches the Sidekiq adapter.
            return { jid: nil, class: nil, queue: nil, args: nil, enqueued_at: nil, error_message: nil } unless job

            {
              jid: job.active_job_id || job.id,
              class: job.class_name,
              queue: job.queue_name,
              args: job.arguments,
              enqueued_at: job.created_at&.utc&.iso8601,
              error_message: nil, # failed_jobs overrides this; present for shape stability
            }
          end
        end
      end
    end
  end
end

TalkToYourApp::Plugins::Jobs.register_adapter(:solid_queue, TalkToYourApp::Plugins::Jobs::Adapters::SolidQueue)
