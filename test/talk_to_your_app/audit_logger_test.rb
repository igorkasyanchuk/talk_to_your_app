# frozen_string_literal: true

require "test_helper"
require "support/array_logger"

class TalkToYourApp::AuditLoggerTest < TalkToYourApp::TestCase
  class OkTool < TalkToYourApp::Tool
    name "db.query"
    argument :sql, :string, required: true
    argument :token, :string, redact: true
    def call(args, _ctx) = text("ran #{args[:sql]}")
  end

  class BoomTool < TalkToYourApp::Tool
    name "db.boom"
    def call(_args, _ctx) = raise(ActiveRecord::StatementInvalid, "nope")
  end

  def setup
    super
    @logger = TalkToYourApp::ArrayLogger.new
    TalkToYourApp.configure { |c| c.logger = @logger }
  end

  def info_lines
    @logger.messages_at("INFO")
  end

  # Covers AE6: a successful invocation emits one INFO line with the fields.
  def test_success_emits_single_info_line_with_fields
    TalkToYourApp::Current.principal = "claude-desktop"
    OkTool.dispatch({ sql: "SELECT 1" }, plugin_name: :db)
    assert_equal 1, info_lines.size
    line = info_lines.first
    assert_match(/principal=claude-desktop/, line)
    assert_match(/plugin=db/, line)
    assert_match(/tool=db\.query/, line)
    assert_match(/outcome=success/, line)
    assert_match(/duration_ms=\d/, line)
    assert_match(/params=.*SELECT 1/, line)
  ensure
    TalkToYourApp::Current.reset
  end

  def test_redacted_argument_is_masked
    OkTool.dispatch({ sql: "SELECT 1", token: "s3cr3t" }, plugin_name: :db)
    line = info_lines.first
    assert_match(/REDACTED/, line)
    refute_match(/s3cr3t/, line)
    assert_match(/SELECT 1/, line, "non-redacted args remain visible")
  end

  def test_exception_logs_error_outcome_and_reraises
    assert_raises(ActiveRecord::StatementInvalid) do
      BoomTool.dispatch({}, plugin_name: :db)
    end
    line = info_lines.first
    assert_match(/outcome=error/, line)
    assert_match(/error_class=ActiveRecord::StatementInvalid/, line)
  end

  def test_swappable_logger_is_used
    other = TalkToYourApp::ArrayLogger.new
    TalkToYourApp.configure { |c| c.logger = other }
    OkTool.dispatch({ sql: "SELECT 1" }, plugin_name: :db)
    assert_equal 1, other.messages_at("INFO").size
    assert_empty @logger.lines
  end

  def test_per_plugin_log_level_override
    @logger.level = ::Logger::DEBUG
    OkTool.dispatch({ sql: "SELECT 1" }, plugin_name: :db, log_level: :debug)
    assert_equal 1, @logger.messages_at("DEBUG").size
    assert_empty @logger.messages_at("INFO")
  end

  def test_tool_returning_error_response_logs_error_outcome
    klass = Class.new(TalkToYourApp::Tool) do
      name "db.reject"
      define_method(:call) { |_args, _ctx| MCP::Tool::Response.new([{ type: "text", text: "no" }], error: true) }
    end
    klass.dispatch({}, plugin_name: :db)
    assert_match(/outcome=error/, info_lines.first)
  end

  def test_logger_failure_does_not_replace_tool_result
    boom_logger = Object.new
    def boom_logger.info(*) = raise("logger down")
    def boom_logger.public_send(*) = raise("logger down")
    TalkToYourApp.configure { |c| c.logger = boom_logger }
    # The tool result must survive even though logging blows up.
    result = nil
    _out, _err = capture_io { result = OkTool.dispatch({ sql: "SELECT 1" }, plugin_name: :db) }
    assert_equal "ran SELECT 1", result.content.first[:text]
  end

  def test_authorization_denial_logs_error_outcome
    TalkToYourApp::Current.principal = "restricted"
    TalkToYourApp.configure do |c|
      c.logger = @logger
      c.authorize { |principal, _tool| principal == "admin" }
    end
    OkTool.dispatch({ sql: "SELECT 1" }, plugin_name: :db)
    assert_match(/outcome=error/, info_lines.first)
  ensure
    TalkToYourApp::Current.reset
  end

  def test_log_line_includes_ip_and_principal
    TalkToYourApp::Current.principal = "claude-desktop"
    TalkToYourApp::Current.ip = "203.0.113.7"
    OkTool.dispatch({ sql: "SELECT 1" }, plugin_name: :db)
    assert_match(/principal=claude-desktop/, info_lines.first)
    assert_match(%r{ip=203\.0\.113\.7}, info_lines.first)
  ensure
    TalkToYourApp::Current.reset
  end

  def test_emits_structured_notification_payload
    TalkToYourApp::Current.principal = "alice"
    TalkToYourApp::Current.ip = "198.51.100.4"
    events = []
    subscription = ActiveSupport::Notifications.subscribe("talk_to_your_app.tool_call") do |*args|
      events << ActiveSupport::Notifications::Event.new(*args).payload
    end
    OkTool.dispatch({ sql: "SELECT 1", token: "s3cr3t" }, plugin_name: :db)
    payload = events.first
    assert_equal "alice", payload[:principal]
    assert_equal "198.51.100.4", payload[:ip]
    assert_equal "db.query", payload[:tool]
    assert_equal :db, payload[:plugin]
    assert_equal "success", payload[:outcome]
    assert_equal "[REDACTED]", payload[:params][:token]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
    TalkToYourApp::Current.reset
  end

  def test_two_invocations_emit_two_lines
    OkTool.dispatch({ sql: "SELECT 1" }, plugin_name: :db)
    OkTool.dispatch({ sql: "SELECT 2" }, plugin_name: :db)
    assert_equal 2, info_lines.size
  end
end
