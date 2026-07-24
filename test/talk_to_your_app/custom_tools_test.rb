# frozen_string_literal: true

require "test_helper"
require "fileutils"

# Covers the :custom_tools collection mechanism: a Tool subclass is exposed as a
# custom tool only when it's defined while the plugin is loading the host app's
# custom_tools/ directory (collecting_custom_tools on). Bundled tools, defined
# when the gem loads, are never collected.
class TalkToYourApp::CustomToolsTest < TalkToYourApp::TestCase
  FIXTURE_DIR = Rails.root.join(TalkToYourApp::APP_DIR, "custom_tools", "rollback_fixture")
  FIXTURE_CONSTANTS = %i[RollbackBrokenTool RollbackOkTool].freeze

  def setup
    super
    TalkToYourApp::Tool.clear_custom_registry!
  end

  def teardown
    FileUtils.rm_rf(FIXTURE_DIR)
    FIXTURE_CONSTANTS.each { |name| Object.send(:remove_const, name) if Object.const_defined?(name, false) }
    TalkToYourApp::Tool.collecting_custom_tools = false
    TalkToYourApp::Tool.clear_custom_registry!
    super
  end

  # Mirrors what Plugins::CustomTools::Plugin.tools does while loading the app
  # dir: collection is on, so tools defined in this window register themselves.
  def while_collecting
    TalkToYourApp::Tool.collecting_custom_tools = true
    yield
  ensure
    TalkToYourApp::Tool.collecting_custom_tools = false
  end

  def test_tools_defined_while_collecting_register_in_definition_order
    a = b = nil
    while_collecting do
      a = Class.new(TalkToYourApp::Tool) { name "custom.a"; def call(_args, _ctx) = text("a") }
      b = Class.new(TalkToYourApp::Tool) { name "custom.b"; def call(_args, _ctx) = text("b") }
    end
    assert_equal [a, b], TalkToYourApp::Tool.custom_registry
  end

  def test_tools_defined_outside_collection_are_not_registered
    Class.new(TalkToYourApp::Tool) { name "bundled.x"; def call(_a, _c) = text("x") }
    assert_empty TalkToYourApp::Tool.custom_registry
  end

  def test_enabled_plugin_exposes_collected_tools
    while_collecting do
      Class.new(TalkToYourApp::Tool) { name "custom.echo"; def call(_a, _c) = text("hi") }
    end
    TalkToYourApp.configure do |c|
      c.api_keys = { "k" => "secret" }
      c.plugin :custom_tools, connection: false
    end
    names = TalkToYourApp::Plugins::CustomTools::Plugin.tools.map(&:tool_name)
    assert_includes names, "custom.echo"
  end

  def test_custom_tool_dispatches_like_any_tool
    klass = Class.new(TalkToYourApp::Tool) do
      name "custom.shout"
      argument :word, :string, required: true
      def call(args, _ctx) = text(args[:word].upcase)
    end
    response = klass.to_mcp_tool.call(word: "hi", server_context: nil)
    assert_equal "HI", response.content.first[:text]
  end

  def test_failed_custom_tool_file_rolls_back_collected_classes
    FileUtils.mkdir_p(FIXTURE_DIR)
    File.write(FIXTURE_DIR.join("a_broken.rb"), <<~RUBY)
      class RollbackBrokenTool < TalkToYourApp::Tool
        name "custom.rollback_broken"
        def call(_args, _ctx) = text("bad")
      end

      raise "boom"
    RUBY
    File.write(FIXTURE_DIR.join("b_ok.rb"), <<~RUBY)
      class RollbackOkTool < TalkToYourApp::Tool
        name "custom.rollback_ok"
        def call(_args, _ctx) = text("ok")
      end
    RUBY

    quiet_logger = Object.new
    def quiet_logger.error(_message); end
    TalkToYourApp.configure { |c| c.logger = quiet_logger }

    names = TalkToYourApp::Plugins::CustomTools::Plugin.tools.map(&:tool_name)

    refute_includes names, "custom.rollback_broken"
    assert_includes names, "custom.rollback_ok"
  end
end
