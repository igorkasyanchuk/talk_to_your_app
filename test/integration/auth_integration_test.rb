# frozen_string_literal: true

require "test_helper"
require "support/mcp_driver"

class AuthIntegrationTest < TalkToYourApp::TestCase
  class EchoTool < TalkToYourApp::Tool
    name "echo.say"
    description "Echoes its message."
    argument :message, :string, required: true
    def call(args, _ctx) = text(args[:message])
  end

  class EchoPlugin < TalkToYourApp::Plugin
    tools EchoTool
  end

  def setup
    super
    TalkToYourApp.register_plugin(:echo, EchoPlugin)
    TalkToYourApp.configure do |c|
      c.api_keys = { "claude-desktop" => "sk-good" }
      c.plugin :echo, connection: false
    end
  end

  def test_unauthenticated_request_is_rejected
    driver = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: nil)
    response = driver.initialize_session
    assert_equal 401, response.status
  end

  def test_authenticated_tools_list_returns_registered_tool
    driver = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")
    init = driver.initialize_session
    assert_equal 200, init.status
    refute_nil driver.session_id, "initialize must return an Mcp-Session-Id"

    list = JSON.parse(driver.list_tools.body)
    names = list.dig("result", "tools").map { |t| t["name"] }
    assert_includes names, "echo.say"
  end

  def test_authenticated_tools_call_round_trip
    driver = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")
    driver.initialize_session
    result = driver.call_tool_result("echo.say", { message: "hello mcp" })
    assert_equal "hello mcp", result.dig("result", "content", 0, "text")
  end

  def test_initialize_exposes_configured_server_identity
    TalkToYourApp.configure do |c|
      c.server_name = "acme-mcp"
      c.server_description = "Acme's internal data, read-only over MCP."
      c.instructions = "Use db.query for read-only SQL."
    end
    driver = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")
    body = JSON.parse(driver.initialize_session.body)
    assert_equal "acme-mcp", body.dig("result", "serverInfo", "name")
    assert_equal "Acme's internal data, read-only over MCP.", body.dig("result", "serverInfo", "description")
    assert_equal "Use db.query for read-only SQL.", body.dig("result", "instructions")
  end

  def test_default_server_identity
    driver = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")
    body = JSON.parse(driver.initialize_session.body)
    assert_equal "talk_to_your_app", body.dig("result", "serverInfo", "name")
    assert_equal TalkToYourApp::VERSION, body.dig("result", "serverInfo", "version")
  end

  def test_boot_validation_requires_auth_when_plugin_enabled
    TalkToYourApp.reset_configuration!
    TalkToYourApp.configure { |c| c.plugin :echo, connection: false } # no auth
    error = assert_raises(TalkToYourApp::ConfigurationError) do
      TalkToYourApp::Railtie.validate_boot!
    end
    assert_match(/authentication/, error.message)
  end
end
