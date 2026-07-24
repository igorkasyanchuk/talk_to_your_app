# frozen_string_literal: true

require "test_helper"
require "support/mcp_driver"
require "support/pg_test_db"

# Proves the opt-in write path end to end: wiring a :writing connection into the
# DB plugin lets db.query execute writes, while a :reading connection still
# rejects them. Runs against the writable `primary_pg` role on the shared
# Postgres test DB (SQLite :memory: can't be shared across the gem's separate
# connection pool, so these need real Postgres).
class DbWriteOptinIntegrationTest < TalkToYourApp::TestCase
  MARKER = "optin-write-test-row"

  def setup
    super
    skip "Postgres not available" unless TalkToYourApp::PgTestDb.available?
  end

  def driver_for(role)
    TalkToYourApp.reset_configuration!
    TalkToYourApp.configure do |c|
      c.api_keys = { "claude-desktop" => "sk-good" }
      c.connection :db_conn, database: "primary_pg", role: role
      c.plugin :db, connection: :db_conn
    end
    d = TalkToYourApp::McpDriver.new(TalkToYourApp.rack_app, auth: "Bearer sk-good")
    d.initialize_session
    d
  end

  def error?(result) = result.dig("result", "isError")

  def teardown
    if TalkToYourApp::PgTestDb.available?
      driver_for(:writing).call_tool_result("db.query",
        { sql: "DELETE FROM widgets WHERE name = '#{MARKER}'" })
    end
  rescue StandardError
    nil
  ensure
    super
  end

  def test_write_executes_on_a_writing_connection
    driver = driver_for(:writing)
    insert = driver.call_tool_result("db.query",
      { sql: "INSERT INTO widgets (name, quantity) VALUES ('#{MARKER}', 1)" })
    refute error?(insert), "a write on a :writing connection must succeed"

    count = driver.call_tool_result("db.query",
      { sql: "SELECT count(*) AS n FROM widgets WHERE name = '#{MARKER}'" })
    rows = JSON.parse(count.dig("result", "content", 0, "text"))["rows"]
    assert_equal [[1]], rows, "the inserted row must be visible"
  end

  def test_write_rejected_on_a_reading_connection
    driver = driver_for(:reading)
    result = driver.call_tool_result("db.query",
      { sql: "INSERT INTO widgets (name, quantity) VALUES ('#{MARKER}', 1)" })
    assert error?(result), "a write on a :reading connection must be rejected"
  end
end
