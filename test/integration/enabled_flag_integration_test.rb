# frozen_string_literal: true

require "test_helper"
require "support/mcp_driver"

# Exercises the global `config.enabled` switch through the real mounted Rack
# app (not by calling RailsMount.build directly), so the per-request check is
# proven against an already-built, memoized app.
class EnabledFlagIntegrationTest < TalkToYourApp::TestCase
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
  end

  def test_disabled_gem_boots_even_with_a_plugin_and_no_auth
    TalkToYourApp.configure do |c|
      c.enabled = false
      c.plugin :echo, connection: false # would normally require auth
    end
    # No raise: a disabled gem serves nothing, so there is nothing to validate.
    assert_nil TalkToYourApp::Railtie.validate_boot!
  end

  def test_disabled_endpoint_returns_503_even_with_valid_auth
    TalkToYourApp.configure do |c|
      c.enabled = false
      c.api_keys = { "claude-desktop" => "sk-good" }
      c.plugin :echo, connection: false
    end
    driver = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")
    assert_equal 503, driver.initialize_session.status,
      "a disabled gem must serve 503 in front of auth"
  end

  def test_enabled_flag_is_read_per_request_not_captured_at_build
    TalkToYourApp.configure do |c|
      c.api_keys = { "claude-desktop" => "sk-good" }
      c.plugin :echo, connection: false
    end
    app = TalkToYourApp.rack_app # built + memoized while enabled
    driver = TalkToYourApp::McpDriver.new(app, auth: "Bearer sk-good")
    assert_equal 200, driver.initialize_session.status

    # Flip off on the same memoized app — the per-request check must honor it.
    TalkToYourApp.configuration.enabled = false
    assert_equal 503, driver.initialize_session.status,
      "toggling enabled must be honored without rebuilding rack_app"
  end
end
