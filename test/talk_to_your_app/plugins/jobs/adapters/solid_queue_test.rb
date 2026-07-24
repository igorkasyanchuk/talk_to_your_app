# frozen_string_literal: true

require "test_helper"
require "support/solid_queue_test_setup"

class TalkToYourApp::Plugins::Jobs::Adapters::SolidQueueTest < TalkToYourApp::TestCase
  Adapter = TalkToYourApp::Plugins::Jobs::Adapters::SolidQueue

  def setup
    super
    TalkToYourApp::SolidQueueTestSetup.reset!
  end

  def test_required_gem_metadata
    assert_equal "SolidQueue", Adapter.required_gem[:const]
    assert_equal "solid_queue", Adapter.required_gem[:gem_name]
  end

  def test_queue_sizes_counts_ready_executions
    3.times { TalkToYourApp::SolidQueueProbeJob.perform_later }
    assert_equal({ "default" => 3 }, Adapter.queue_sizes)
  end

  def test_recent_jobs_returns_jobs_with_stable_shape
    TalkToYourApp::SolidQueueProbeJob.perform_later(1, 2)
    jobs = Adapter.recent_jobs(limit: 50)
    assert_equal 1, jobs.size
    job = jobs.first
    assert_equal "TalkToYourApp::SolidQueueProbeJob", job[:class]
    assert_equal "default", job[:queue]
    assert job[:jid]
  end

  def test_failed_jobs_includes_error_message_with_same_shape
    job = ::SolidQueue::Job.create!(
      queue_name: "default", class_name: "FailJob", arguments: [1].to_json, active_job_id: "aj-1"
    )
    ::SolidQueue::FailedExecution.create!(job: job, error: { exception_class: "RuntimeError", message: "boom" })

    failed = Adapter.failed_jobs(limit: 50)
    assert_equal 1, failed.size
    assert_equal "FailJob", failed.first[:class]
    assert_equal "boom", failed.first[:error_message]
  end

  def test_job_hash_for_orphaned_failure_keeps_full_shape
    # An orphaned FailedExecution (nil job) must still carry every key so the
    # shape matches the Sidekiq adapter.
    shape = Adapter.job_hash(nil)
    assert_equal %i[jid class queue args enqueued_at error_message].sort, shape.keys.sort
    assert shape.values.all?(&:nil?)
  end

  def test_empty_tables_return_empty_collections
    assert_equal({}, Adapter.queue_sizes)
    assert_equal [], Adapter.recent_jobs(limit: 10)
    assert_equal [], Adapter.failed_jobs(limit: 10)
  end

  def test_rate_metrics_shape
    TalkToYourApp::SolidQueueProbeJob.perform_later
    metrics = Adapter.rate_metrics(window: 3600)
    assert_equal 3600, metrics[:window_seconds]
    assert_equal 1, metrics[:enqueued]
    assert_includes metrics.keys, :processed
    assert_includes metrics.keys, :failed
  end
end
