# frozen_string_literal: true

# A trivial fake job. Scheduled to run every minute via config/recurring.yml so
# the Jobs (Solid Queue) plugin has something to report. Does no real work.
class HeartbeatJob < ApplicationJob
  queue_as :default

  def perform(*)
    Rails.logger.info("[HeartbeatJob] tick at #{Time.now.utc.iso8601}")
  end
end
