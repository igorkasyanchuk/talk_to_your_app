# frozen_string_literal: true

require "test_helper"
require "support/mcp_driver"

class HealthPluginIntegrationTest < TalkToYourApp::TestCase
  def setup
    super
    TalkToYourApp.configure do |c|
      c.api_keys = { "claude-desktop" => "sk-good" }
      c.plugin :health, connection: false
      c.health_check(:always_ok) { true }
      c.health_check(:with_value) { [true, "42 rows"] }
    end
    @driver = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")
    @driver.initialize_session
  end

  def body_of(result)
    JSON.parse(result.dig("result", "content", 0, "text"))
  end

  def test_list_then_run_round_trip
    listed = body_of(@driver.call_tool_result("health.list", {}))
    assert_equal %w[always_ok with_value], listed["checks"]

    ran = body_of(@driver.call_tool_result("health.run", { name: "with_value" }))
    assert_equal true, ran["passed"]
    assert_equal "42 rows", ran["value"]
  end
end
