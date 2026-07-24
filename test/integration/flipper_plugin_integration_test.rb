# frozen_string_literal: true

require "test_helper"
require "support/mcp_driver"
require "support/flipper_test_setup"

class FlipperPluginIntegrationTest < TalkToYourApp::TestCase
  def setup
    super
    TalkToYourApp::FlipperTestSetup.reset!
    TalkToYourApp.configure do |c|
      c.api_keys = { "claude-desktop" => "sk-good" }
      c.connection :flipper_writer, database: "primary", role: :writing
      c.plugin :flipper, connection: :flipper_writer
    end
    @driver = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")
    @driver.initialize_session
  end

  def body_of(result)
    JSON.parse(result.dig("result", "content", 0, "text"))
  end

  def test_enable_read_disable_round_trip
    @driver.call_tool_result("flipper.enable_flag", { name: "new_ui" })
    read = body_of(@driver.call_tool_result("flipper.read_flag", { name: "new_ui" }))
    assert_equal true, read["enabled"]

    @driver.call_tool_result("flipper.disable_flag", { name: "new_ui" })
    read_again = body_of(@driver.call_tool_result("flipper.read_flag", { name: "new_ui" }))
    assert_equal false, read_again["enabled"]
  end

  def test_per_actor_enable_round_trip
    @driver.call_tool_result("flipper.enable_flag", { name: "beta", actor_class: "User", actor_id: "42" })
    read = body_of(@driver.call_tool_result("flipper.read_flag", { name: "beta", actor_class: "User", actor_id: "42" }))
    assert_equal true, read["enabled"]
  end
end
