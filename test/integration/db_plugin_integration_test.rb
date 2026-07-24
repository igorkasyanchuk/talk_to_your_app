# frozen_string_literal: true

require "test_helper"
require "support/mcp_driver"
require "support/pg_test_db"
require "support/array_logger"

class DbPluginIntegrationTest < TalkToYourApp::TestCase
  def setup
    super
    skip "Postgres not available" unless TalkToYourApp::PgTestDb.available?
    @logger = TalkToYourApp::ArrayLogger.new
    TalkToYourApp.configure do |c|
      c.api_keys = { "claude-desktop" => "sk-good" }
      c.logger = @logger
      c.connection :replica_readonly, database: "replica_pg_ro", role: :reading
      c.plugin :db, connection: :replica_readonly
    end
    @driver = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")
    @driver.initialize_session
  end

  def test_db_query_round_trip_returns_rows
    result = @driver.call_tool_result("db.query", { sql: "SELECT name, quantity FROM widgets ORDER BY id" })
    text = result.dig("result", "content", 0, "text")
    parsed = JSON.parse(text)
    assert_equal %w[name quantity], parsed["columns"]
    assert_equal [["alpha", 3], ["beta", 7]], parsed["rows"]
  end

  def test_db_query_emits_one_audit_line
    @driver.call_tool_result("db.query", { sql: "SELECT 1 AS one" })
    lines = @logger.messages_at("INFO").select { |l| l.include?("tool=db.query") }
    assert_equal 1, lines.size
    assert_match(/principal=claude-desktop/, lines.first)
  end

  def test_db_write_rejected_through_full_stack
    result = @driver.call_tool_result("db.query", { sql: "UPDATE widgets SET quantity = 0" })
    assert result.dig("result", "isError"), "expected an MCP tool error for a write"
  end
end
