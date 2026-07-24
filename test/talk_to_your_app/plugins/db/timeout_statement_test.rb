# frozen_string_literal: true

require "test_helper"

# Pure unit test for the adapter-detected timeout SQL — no database required,
# so the MySQL branch is covered even though mysql2 is not in the bundle.
class TalkToYourApp::Plugins::Db::TimeoutStatementTest < TalkToYourApp::TestCase
  Query = TalkToYourApp::Plugins::Db::Tools::Query

  def test_postgres_uses_transaction_local_statement_timeout
    assert_equal "SET LOCAL statement_timeout = 5000", Query.timeout_statement("PostgreSQL", 5000)
  end

  def test_mysql_uses_session_max_execution_time
    assert_equal "SET SESSION max_execution_time = 5000", Query.timeout_statement("Mysql2", 5000)
    assert_equal "SET SESSION max_execution_time = 5000", Query.timeout_statement("Trilogy", 5000)
  end

  def test_sqlite_and_unknown_adapters_have_no_timeout
    assert_nil Query.timeout_statement("SQLite", 5000)
    assert_nil Query.timeout_statement("OracleEnhanced", 5000)
  end

  def test_ms_is_coerced_to_integer
    assert_equal "SET LOCAL statement_timeout = 30000", Query.timeout_statement("PostgreSQL", "30000")
  end
end
