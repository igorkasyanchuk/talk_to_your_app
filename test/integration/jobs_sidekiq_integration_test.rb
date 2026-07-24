# frozen_string_literal: true

require "test_helper"
require "support/mcp_driver"
require "support/sidekiq_test_setup"

class JobsSidekiqIntegrationTest < TalkToYourApp::TestCase
  def setup
    super
    skip "Redis not available" unless TalkToYourApp::SidekiqTestSetup.available?
    TalkToYourApp::SidekiqTestSetup.reset!
    TalkToYourApp.configure do |c|
      c.api_keys = { "claude-desktop" => "sk-good" }
      c.plugin :sidekiq, connection: false
    end
    @driver = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")
    @driver.initialize_session
  end

  def test_tools_list_shows_four_sidekiq_tools
    names = JSON.parse(@driver.list_tools.body).dig("result", "tools").map { |t| t["name"] }
    %w[sidekiq.queue_sizes sidekiq.recent_jobs sidekiq.failed_jobs sidekiq.rate_metrics].each do |n|
      assert_includes names, n
    end
  end

  def test_queue_sizes_round_trip
    2.times { TalkToYourApp::SidekiqProbeWorker.perform_async }
    result = @driver.call_tool_result("sidekiq.queue_sizes")
    parsed = JSON.parse(result.dig("result", "content", 0, "text"))
    assert_equal({ "default" => 2 }, parsed)
  end
end
