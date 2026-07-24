# frozen_string_literal: true

require "test_helper"
require "support/mcp_driver"

# Stateless mode must let a request stand on its own — no `initialize`
# handshake, no Mcp-Session-Id header — because with more than one Puma worker
# a follow-up request can land on a process that never saw the handshake. A
# driver that skips initialize_session mirrors exactly that cross-worker case.
class StatelessTransportTest < TalkToYourApp::TestCase
  # A trivial always-available tool so the test doesn't depend on any particular
  # plugin — it only exercises the transport's session handling.
  class PingTool < TalkToYourApp::Tool
    name "ping.say"
    def call(_args, _ctx) = json(status: "pass")
  end

  class PingPlugin < TalkToYourApp::Plugin
    tools PingTool
  end

  def test_tool_call_without_session_succeeds_when_stateless
    configure_gem(stateless: true)
    driver = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")

    # No initialize_session: the request carries no session id, just as it
    # would on a worker that never handled the handshake.
    result = driver.call_tool_result("ping.say", {})
    payload = JSON.parse(result.dig("result", "content", 0, "text"))

    assert_equal "pass", payload["status"]
  end

  def test_tool_call_without_session_is_rejected_when_stateful
    configure_gem(stateless: false)
    driver = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")

    response = driver.call_tool("ping.say", {})

    refute_equal 200, response.status,
      "stateful mode must reject a tool call that carries no session id — this is the multi-worker failure stateless mode fixes"
  end

  private

  def configure_gem(stateless:)
    TalkToYourApp.register_plugin(:ping, PingPlugin)
    TalkToYourApp.configure do |c|
      c.api_keys = { "claude-desktop" => "sk-good" }
      c.stateless = stateless
      c.plugin :ping, connection: false
    end
  end
end
