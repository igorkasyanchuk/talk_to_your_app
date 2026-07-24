# frozen_string_literal: true

require "test_helper"
require "support/pg_test_db"
require "support/array_logger"

# DB-plugin query tool, exercised against a genuinely read-only Postgres role.
class TalkToYourApp::Plugins::Db::QueryTest < TalkToYourApp::TestCase
  Query = TalkToYourApp::Plugins::Db::Tools::Query
  Tables = TalkToYourApp::Plugins::Db::Tools::Tables
  Schema = TalkToYourApp::Plugins::Db::Tools::Schema

  def setup
    super
    skip "Postgres not available" unless TalkToYourApp::PgTestDb.available?
    TalkToYourApp.configure do |c|
      c.connection :replica_readonly, database: "replica_pg_ro", role: :reading
      c.plugin :db, connection: :replica_readonly
    end
  end

  # Tools resolve their connection from the wired plugin option, so the Context
  # must carry the plugin name the way dispatch threads it.
  def db_ctx(tool)
    TalkToYourApp::Tool::Context.new(tool_class: tool, plugin_name: :db)
  end

  def run_query(sql, format: "json")
    Query.new.call({ sql: sql, format: format }, db_ctx(Query))
  end

  def text_of(response)
    response.content.first[:text]
  end

  def test_json_format_returns_columns_and_rows
    response = run_query("SELECT 1 AS one")
    assert_equal({ "columns" => ["one"], "rows" => [[1]] }, JSON.parse(text_of(response)))
    refute response.error?
  end

  # Invalid SQL must come back as a tool error (isError) with the database's
  # message — not crash the request or leak a stack trace.
  def test_invalid_sql_returns_tool_error
    response = run_query("SELECT * FROM table_that_does_not_exist")
    assert response.error?
    assert_match(/Query failed/i, text_of(response))
  end

  def test_rows_are_capped_at_max_rows
    TalkToYourApp.configure { |c| c.plugin :db, connection: :replica_readonly, max_rows: 2 }
    parsed = JSON.parse(text_of(run_query("SELECT * FROM generate_series(1, 5) AS n")))
    assert_equal 2, parsed["rows"].length
    assert_equal true, parsed["truncated"]
    assert_equal 2, parsed["max_rows"]
  end

  def test_default_max_rows_is_2000
    assert_equal 2000, TalkToYourApp::Plugins::Db.max_rows
  end

  def test_max_rows_can_be_disabled
    [nil, false, :unlimited].each do |value|
      TalkToYourApp.reset_configuration!
      TalkToYourApp.configure { |c| c.connection :replica_readonly, database: "replica_pg_ro", role: :reading; c.plugin :db, connection: :replica_readonly, max_rows: value }
      assert_nil TalkToYourApp::Plugins::Db.max_rows, "max_rows: #{value.inspect} should disable the cap"
    end
    parsed = JSON.parse(text_of(run_query("SELECT * FROM generate_series(1, 5) AS n")))
    assert_equal 5, parsed["rows"].length
    refute parsed.key?("truncated")
  end

  def test_db_tables_lists_tables
    response = Tables.new.call({}, db_ctx(Tables))
    assert_includes JSON.parse(text_of(response))["tables"], "widgets"
  end

  def test_db_schema_describes_a_table
    response = Schema.new.call({ table: "widgets" }, db_ctx(Schema))
    schema = JSON.parse(text_of(response))
    assert_equal "id", schema["primary_key"]
    assert_includes schema["columns"].map { |c| c["name"] }, "quantity"
    assert schema.key?("indexes")
    assert schema.key?("foreign_keys")
  end

  def test_db_schema_unknown_table_is_a_tool_error
    response = Schema.new.call({ table: "nope" }, db_ctx(Schema))
    assert response.error?
    assert_match(/Unknown table/, text_of(response))
  end

  # Covers AE4: HTML and text rendering.
  def test_html_format_returns_table
    response = run_query("SELECT 1 AS one", format: "html")
    html = text_of(response)
    assert_includes html, "<thead><tr><th>one</th></tr></thead>"
    assert_includes html, "<tbody><tr><td>1</td></tr></tbody>"
  end

  def test_text_format_returns_aligned_table
    response = run_query("SELECT name, quantity FROM widgets ORDER BY id", format: "text")
    body = text_of(response)
    assert_match(/name/, body)
    assert_match(/alpha/, body)
    assert_match(/beta/, body)
  end

  # Covers AE3: a write against the read-only role is rejected by the database.
  def test_write_is_rejected_by_readonly_role
    response = run_query("UPDATE widgets SET quantity = 0")
    assert response.error?, "expected a write to be rejected"
    assert_match(/permission denied|read.?only|Query failed/i, text_of(response))
  end

  # The database-level backstop: even if Rails' prevent_writes were bypassed
  # (here by declaring the read-only user under a :writing role), the read-only
  # Postgres role itself rejects the write with "permission denied".
  def test_write_rejected_at_database_layer_independent_of_rails
    TalkToYourApp.reset_configuration!
    TalkToYourApp.configure do |c|
      c.connection :replica_readonly, database: "replica_pg_ro", role: :writing
      c.plugin :db, connection: :replica_readonly
    end
    response = run_query("UPDATE widgets SET quantity = 0")
    assert response.error?
    assert_match(/permission denied/i, text_of(response))
  end

  # A data-modifying CTE (WITH ... DELETE ... RETURNING) starts with WITH, which
  # Rails' leading-keyword write-check classifies as a read — so the read-only
  # DB role is what must reject it. Documents that the role, not SQL parsing, is
  # the boundary (see README "Read-only is enforced by the database").
  def test_data_modifying_cte_is_rejected_by_readonly_role
    response = run_query("WITH gone AS (DELETE FROM widgets RETURNING *) SELECT count(*) FROM gone")
    assert response.error?, "a data-modifying CTE must be rejected by the read-only role"
    assert_match(/permission denied|read.?only|Query failed/i, text_of(response))
  end

  # Covers AE3: a query exceeding the statement timeout is cancelled cleanly.
  def test_statement_timeout_cancels_long_query
    TalkToYourApp.reset_configuration!
    TalkToYourApp.configure do |c|
      c.connection :replica_readonly, database: "replica_pg_ro", role: :reading, statement_timeout: 500
      c.plugin :db, connection: :replica_readonly
    end
    response = run_query("SELECT pg_sleep(2)")
    assert response.error?
    assert_match(/timeout/i, text_of(response))
  end

  def test_null_renders_per_format
    assert_equal [[nil]], JSON.parse(text_of(run_query("SELECT NULL AS n")))["rows"]
    assert_includes text_of(run_query("SELECT NULL AS n", format: "html")), "<td></td>"
    assert_match(/NULL/, text_of(run_query("SELECT NULL AS n", format: "text")))
  end

  def test_html_escapes_cell_contents
    response = run_query("SELECT '<script>' AS x", format: "html")
    assert_includes text_of(response), "&lt;script&gt;"
  end

  # A :writing connection is now an opt-in, not a boot failure: the gem boots
  # (writes enabled) and logs a loud warning. The warning is detection/audit
  # only — the real safeguard is the deliberate role: :writing wiring.
  def test_boot_warns_and_passes_on_writable_connection
    TalkToYourApp.reset_configuration!
    TalkToYourApp.configure do |c|
      c.api_keys = { "k" => "secret" }
      c.authorize { |_p, _t, _a| true }
      c.connection :writer, database: "primary", role: :writing
      c.plugin :db, connection: :writer
    end
    # Boot warning goes to $stderr, never a (possibly stdout) logger.
    _out, err = capture_io { TalkToYourApp::Railtie.validate_boot! } # does not raise
    assert_match(/db\.query can execute writes/i, err,
      "wiring a :writing connection into :db must log a loud warning")
  end

  def test_boot_is_silent_on_reading_connection
    TalkToYourApp.reset_configuration!
    TalkToYourApp.configure do |c|
      c.api_keys = { "k" => "secret" }
      c.authorize { |_p, _t, _a| true }
      c.connection :replica_readonly, database: "primary", role: :reading
      c.plugin :db, connection: :replica_readonly
    end
    _out, err = capture_io { TalkToYourApp::Railtie.validate_boot! } # does not raise
    refute_match(/db\.query can execute writes/i, err,
      "a read-only DB connection must not warn")
  end

  # The missing-connection case fails closed at boot with an actionable message.
  def test_boot_rejects_db_without_a_wired_connection
    TalkToYourApp.reset_configuration!
    TalkToYourApp.configure do |c|
      c.api_keys = { "k" => "secret" }
      c.plugin :db # no connection: wired
    end
    error = assert_raises(TalkToYourApp::ConfigurationError) { TalkToYourApp::Railtie.validate_boot! }
    assert_match(/connection:/, error.message)
  end
end
