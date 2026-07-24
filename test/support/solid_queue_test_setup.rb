# frozen_string_literal: true

require "solid_queue"

module TalkToYourApp
  # Loads Solid Queue's schema into the dummy app's database and provides reset
  # plus a job class for enqueuing real jobs through ActiveJob's Solid Queue
  # adapter.
  module SolidQueueTestSetup
    SCHEMA = Gem::Specification.find_by_name("solid_queue").gem_dir +
      "/lib/generators/solid_queue/install/templates/db/queue_schema.rb"

    module_function

    def install!
      return if @installed

      ActiveRecord::Migration.suppress_messages { load SCHEMA }
      ActiveJob::Base.queue_adapter = :solid_queue
      ActiveJob::Base.logger = Logger.new(File::NULL)
      @installed = true
    end

    def reset!
      install!
      %w[solid_queue_failed_executions solid_queue_ready_executions solid_queue_jobs].each do |table|
        ActiveRecord::Base.connection.execute("DELETE FROM #{table}")
      end
    end
  end

  class SolidQueueProbeJob < ActiveJob::Base
    queue_as :default
    def perform(*); end
  end
end
