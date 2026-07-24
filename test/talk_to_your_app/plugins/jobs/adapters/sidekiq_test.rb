# frozen_string_literal: true

require "test_helper"
require "support/sidekiq_test_setup"

class TalkToYourApp::Plugins::Jobs::Adapters::SidekiqTest < TalkToYourApp::TestCase
  Adapter = TalkToYourApp::Plugins::Jobs::Adapters::Sidekiq

  def setup
    super
    skip "Redis not available" unless TalkToYourApp::SidekiqTestSetup.available?
    TalkToYourApp::SidekiqTestSetup.reset!
  end

  def test_required_gem_metadata
    assert_equal "Sidekiq", Adapter.required_gem[:const]
    assert_equal "sidekiq", Adapter.required_gem[:gem_name]
  end

  def test_queue_sizes_counts_enqueued_jobs
    3.times { TalkToYourApp::SidekiqProbeWorker.perform_async }
    assert_equal({ "default" => 3 }, Adapter.queue_sizes)
  end

  def test_recent_jobs_returns_enqueued_jobs_with_stable_shape
    TalkToYourApp::SidekiqProbeWorker.perform_async(1, 2)
    jobs = Adapter.recent_jobs(limit: 50)
    assert_equal 1, jobs.size
    job = jobs.first
    assert_equal "TalkToYourApp::SidekiqProbeWorker", job[:class]
    assert_equal "default", job[:queue]
    assert_equal [1, 2], job[:args]
    assert job[:jid]
  end

  def test_failed_jobs_includes_error_message
    payload = ::Sidekiq.dump_json(
      "class" => "FailWorker", "jid" => "deadjid", "queue" => "default",
      "args" => [1], "error_message" => "boom", "failed_at" => 1_700_000_000.0
    )
    ::Sidekiq::DeadSet.new.kill(payload, notify_failure: false)

    failed = Adapter.failed_jobs(limit: 50)
    assert_equal 1, failed.size
    assert_equal "boom", failed.first[:error_message]
    assert_equal "FailWorker", failed.first[:class]
  end

  def test_empty_backend_returns_empty_collections
    assert_equal({}, Adapter.queue_sizes)
    assert_equal [], Adapter.recent_jobs(limit: 10)
    assert_equal [], Adapter.failed_jobs(limit: 10)
  end

  def test_rate_metrics_returns_shape_with_note
    metrics = Adapter.rate_metrics(window: 600)
    assert_equal 600, metrics[:window_seconds]
    assert_includes metrics.keys, :processed
    assert_includes metrics.keys, :failed
    assert_match(/cumulative/i, metrics[:note])
  end
end
