# frozen_string_literal: true

require "test_helper"

# DB plugin boot/config behavior that does not need a live Postgres connection
# (describe_tool only inspects the wired ConnectionSpec, never opens it).
class TalkToYourApp::Plugins::Db::PluginTest < TalkToYourApp::TestCase
  Plugin = TalkToYourApp::Plugins::Db::Plugin
  Query = TalkToYourApp::Plugins::Db::Tools::Query
  Tables = TalkToYourApp::Plugins::Db::Tools::Tables

  def test_describe_tool_flags_a_writable_connection
    TalkToYourApp.configure do |c|
      c.connection :writer, database: "primary", role: :writing
      c.plugin :db, connection: :writer
    end
    assert_match(/WRITABLE/, Plugin.describe_tool(Query))
  end

  def test_describe_tool_returns_nil_for_a_reading_connection
    TalkToYourApp.configure do |c|
      c.connection :reader, database: "primary", role: :reading
      c.plugin :db, connection: :reader
    end
    assert_nil Plugin.describe_tool(Query), "a read-only connection uses the default description"
  end

  def test_validate_enablement_rejects_connection_false
    error = assert_raises(TalkToYourApp::ConfigurationError) { Plugin.validate_enablement!({ connection: false }) }
    assert_match(/is not valid/, error.message)
    assert_match(/requires a real connection/, error.message)
  end

  def test_describe_tool_returns_nil_for_non_query_tools
    TalkToYourApp.configure do |c|
      c.connection :writer, database: "primary", role: :writing
      c.plugin :db, connection: :writer
    end
    assert_nil Plugin.describe_tool(Tables)
  end
end
