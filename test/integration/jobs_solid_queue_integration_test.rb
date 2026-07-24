# frozen_string_literal: true

require "test_helper"
require "support/mcp_driver"
require "support/solid_queue_test_setup"

class JobsSolidQueueIntegrationTest < TalkToYourApp::TestCase
  def setup
    super
    TalkToYourApp::SolidQueueTestSetup.reset!
    TalkToYourApp.configure do |c|
      c.api_keys = { "claude-desktop" => "sk-good" }
      c.plugin :solid_queue, connection: false
    end
    @driver = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")
    @driver.initialize_session
  end

  def test_queue_sizes_round_trip
    2.times { TalkToYourApp::SolidQueueProbeJob.perform_later }
    result = @driver.call_tool_result("solid_queue.queue_sizes")
    parsed = JSON.parse(result.dig("result", "content", 0, "text"))
    assert_equal({ "default" => 2 }, parsed)
  end

  def test_exposes_four_solid_queue_tools
    names = JSON.parse(@driver.list_tools.body).dig("result", "tools").map { |t| t["name"] }
    %w[solid_queue.queue_sizes solid_queue.recent_jobs solid_queue.failed_jobs solid_queue.rate_metrics].each do |n|
      assert_includes names, n
    end
  end
end
