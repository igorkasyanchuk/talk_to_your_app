# frozen_string_literal: true

require "test_helper"

class TalkToYourApp::PluginRegistryTest < TalkToYourApp::TestCase
  class QueryTool < TalkToYourApp::Tool
    name "reg.query"
    def call(_args, _ctx) = text("ok")
  end

  class RegDbPlugin < TalkToYourApp::Plugin
    tools QueryTool
  end

  # A tool that declares its own static connection (the custom-tool pattern).
  class StaticConnTool < TalkToYourApp::Tool
    name "reg.static_conn"
    connection :tool_only_conn
    def call(_args, _ctx) = text("ok")
  end

  class StaticConnPlugin < TalkToYourApp::Plugin
    tools StaticConnTool
  end

  class RegJobsPlugin < TalkToYourApp::Plugin
    # A constant that is genuinely not loaded, so the gem check fails locally
    # (the real Sidekiq adapter is exercised against an absent bundle in U8).
    requires_gem "PhantomQueueLib", gem_name: "phantom_queue"
  end

  def test_register_and_lookup
    TalkToYourApp.register_plugin(:reg_db, RegDbPlugin)
    assert TalkToYourApp::PluginRegistry.registered?(:reg_db)
    assert_equal RegDbPlugin, TalkToYourApp::PluginRegistry[:reg_db]
    assert_equal :reg_db, RegDbPlugin.plugin_name
  end

  def test_enabled_plugins_resolves_registered_classes
    TalkToYourApp.register_plugin(:reg_db, RegDbPlugin)
    TalkToYourApp.configure { |c| c.plugin :reg_db }
    name, klass, opts = TalkToYourApp.enabled_plugins.first
    assert_equal :reg_db, name
    assert_equal RegDbPlugin, klass
    assert_equal({}, opts)
  end

  # Covers AE2: enabling a plugin whose soft-dep gem is absent.
  def test_validate_enabled_raises_for_missing_gem
    TalkToYourApp.register_plugin(:reg_jobs, RegJobsPlugin)
    TalkToYourApp.configure { |c| c.plugin :reg_jobs }
    error = assert_raises(TalkToYourApp::ConfigurationError) do
      TalkToYourApp::PluginRegistry.validate_enabled!
    end
    assert_match(/phantom_queue/, error.message)
    assert_match(/reg_jobs/, error.message)
  end

  def test_validate_enabled_raises_for_unregistered_plugin
    TalkToYourApp.configure { |c| c.plugin :never_registered }
    error = assert_raises(TalkToYourApp::ConfigurationError) do
      TalkToYourApp::PluginRegistry.validate_enabled!
    end
    assert_match(/never_registered/, error.message)
  end

  # A plugin that requires a connection but is enabled without `connection:`
  # fails at boot with an actionable message — owned by PluginRegistry, not a
  # downstream fetch error.
  def test_boot_validation_raises_when_no_connection_wired
    TalkToYourApp.register_plugin(:reg_db, RegDbPlugin)
    TalkToYourApp.configure { |c| c.plugin :reg_db } # no connection: wired
    error = assert_raises(TalkToYourApp::ConfigurationError) do
      TalkToYourApp::PluginRegistry.validate_enabled!
    end
    assert_match(/reg_db/, error.message)
    assert_match(/connection:/, error.message)
  end

  # A wired-but-undeclared name is owned by ConnectionRegistry.validate!, which
  # names the requester — not pre-empted by the plugin's own validate_enablement!.
  def test_boot_validation_raises_for_unregistered_wired_connection
    TalkToYourApp.register_plugin(:reg_db, RegDbPlugin)
    TalkToYourApp.configure { |c| c.plugin :reg_db, connection: :typo }
    error = assert_raises(TalkToYourApp::ConfigurationError) do
      TalkToYourApp::ConnectionRegistry.validate!(TalkToYourApp.required_connections)
    end
    assert_match(/typo/, error.message)
    assert_match(/reg_db/, error.message)
  end

  # A tool's static `connection` DSL is boot-validated even when its plugin opts
  # out with connection: false — so an undeclared connection fails closed at boot,
  # not at first call.
  def test_boot_validates_a_tools_static_connection
    TalkToYourApp.register_plugin(:reg_static, StaticConnPlugin)
    TalkToYourApp.configure { |c| c.plugin :reg_static, connection: false }
    error = assert_raises(TalkToYourApp::ConfigurationError) do
      TalkToYourApp::ConnectionRegistry.validate!(TalkToYourApp.required_connections)
    end
    assert_match(/tool_only_conn/, error.message)
    assert_match(/reg\.static_conn/, error.message)
  end

  # required_connections collects from both sources: the plugin's wired
  # connection AND each tool's static `connection` DSL.
  def test_required_connections_collects_plugin_and_tool_connections
    TalkToYourApp.register_plugin(:reg_static, StaticConnPlugin)
    TalkToYourApp.configure { |c| c.plugin :reg_static, connection: :conn_a }
    names = TalkToYourApp.required_connections.map(&:first)
    assert_includes names, :conn_a, "the plugin-wired connection must be required"
    assert_includes names, :tool_only_conn, "the tool's static connection must also be required"
  end

  def test_boot_validation_passes_when_connection_wired
    TalkToYourApp.register_plugin(:reg_db, RegDbPlugin)
    TalkToYourApp.configure do |c|
      c.plugin :reg_db, connection: :replica_readonly
      c.connection :replica_readonly, database: "primary", role: :reading
      c.api_keys = { "k" => "secret" }
    end
    TalkToYourApp::Railtie.validate_boot! # does not raise
  end
end
