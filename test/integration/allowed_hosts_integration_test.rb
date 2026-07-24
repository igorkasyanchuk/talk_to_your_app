# frozen_string_literal: true

require "test_helper"
require "support/mcp_driver"

# Verifies `config.allowed_hosts` is forwarded to the transport's DNS-rebinding
# protection. Without it, a non-loopback Host is rejected; listing the host lets
# it through. Regression guard for non-localhost deployments (endpoint served
# from a real domain), which 403 with "Invalid Host header" otherwise.
class AllowedHostsIntegrationTest < TalkToYourApp::TestCase
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

  def configure_gem(allowed_hosts: nil)
    TalkToYourApp.configure do |c|
      c.api_keys = { "claude-desktop" => "sk-good" }
      c.plugin :echo, connection: false
      c.allowed_hosts = allowed_hosts if allowed_hosts
    end
  end

  def test_non_loopback_host_is_rejected_without_allowlist
    configure_gem
    driver = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")
    response = driver.initialize_session({ "HTTP_HOST" => "app.example.com" })

    assert_equal 403, response.status
    assert_match(/Invalid Host header/, response.body)
  end

  def test_non_loopback_host_is_accepted_when_allowlisted
    configure_gem(allowed_hosts: ["app.example.com"])
    driver = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")
    response = driver.initialize_session({ "HTTP_HOST" => "app.example.com" })

    assert_equal 200, response.status
    assert_equal "talk_to_your_app", JSON.parse(response.body).dig("result", "serverInfo", "name")
  end

  def test_loopback_host_is_always_accepted
    configure_gem
    driver = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")
    response = driver.initialize_session({ "HTTP_HOST" => "localhost:3000" })

    assert_equal 200, response.status
  end
end
