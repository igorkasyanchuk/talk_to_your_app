# frozen_string_literal: true

require "test_helper"
require "support/mcp_driver"

# Verifies `config.allowed_origins` is forwarded to the SDK transport, which
# owns Origin validation (DNS-rebinding protection): no-Origin and same-origin
# requests pass, a cross-origin request must be allow-listed (case-insensitive).
class AllowedOriginsIntegrationTest < TalkToYourApp::TestCase
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

  def configure_gem(allowed_origins: nil)
    TalkToYourApp.configure do |c|
      c.api_keys = { "claude-desktop" => "sk-good" }
      c.plugin :echo, connection: false
      c.allowed_origins = allowed_origins if allowed_origins
    end
  end

  def driver
    TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")
  end

  def test_cross_origin_is_rejected_without_allowlist
    configure_gem
    response = driver.initialize_session({ "HTTP_ORIGIN" => "https://attacker.example" })

    assert_equal 403, response.status
    assert_match(/Invalid Origin header/, response.body)
  end

  def test_cross_origin_is_accepted_when_allowlisted
    configure_gem(allowed_origins: ["https://app.example"])
    response = driver.initialize_session({ "HTTP_ORIGIN" => "https://app.example" })

    assert_equal 200, response.status
  end

  def test_allowlist_match_is_case_insensitive
    configure_gem(allowed_origins: ["https://App.Example"])
    response = driver.initialize_session({ "HTTP_ORIGIN" => "https://app.example" })

    assert_equal 200, response.status
  end

  def test_no_origin_header_is_accepted
    configure_gem
    response = driver.initialize_session

    assert_equal 200, response.status
  end
end
