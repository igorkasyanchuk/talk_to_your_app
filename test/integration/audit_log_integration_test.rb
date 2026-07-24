# frozen_string_literal: true

require "test_helper"
require "support/mcp_driver"
require "support/array_logger"

class AuditLogIntegrationTest < TalkToYourApp::TestCase
  class EchoTool < TalkToYourApp::Tool
    name "echo.say"
    argument :message, :string, required: true
    def call(args, _ctx) = text(args[:message])
  end

  class EchoPlugin < TalkToYourApp::Plugin
    tools EchoTool
  end

  def test_end_to_end_call_emits_one_audit_line_with_principal
    logger = TalkToYourApp::ArrayLogger.new
    TalkToYourApp.register_plugin(:echo_audit, EchoPlugin)
    TalkToYourApp.configure do |c|
      c.api_keys = { "claude-desktop" => "sk-good" }
      c.logger = logger
      c.plugin :echo_audit, connection: false
    end

    driver = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")
    driver.initialize_session
    driver.call_tool_result("echo.say", { message: "hi" })

    audit_lines = logger.messages_at("INFO").select { |l| l.include?("tool=echo.say") }
    assert_equal 1, audit_lines.size
    assert_match(/principal=claude-desktop/, audit_lines.first)
    assert_match(/outcome=success/, audit_lines.first)
    assert_match(/duration_ms=\d/, audit_lines.first)
  end
end
