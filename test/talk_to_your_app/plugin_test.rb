# frozen_string_literal: true

require "test_helper"

class TalkToYourApp::PluginTest < TalkToYourApp::TestCase
  class ToolA < TalkToYourApp::Tool
    name "x.a"
    def call(_args, _ctx) = text("a")
  end

  class ToolB < TalkToYourApp::Tool
    name "x.b"
    def call(_args, _ctx) = text("b")
  end

  class SamplePlugin < TalkToYourApp::Plugin
    requires_gem "Sidekiq", gem_name: "sidekiq"
    tools ToolA, ToolB
    log_level :debug
  end

  def test_requires_gem_records_const_and_humanized_name
    assert_equal "Sidekiq", SamplePlugin.required_gem[:const]
    assert_equal "sidekiq", SamplePlugin.required_gem[:gem_name]
  end

  def test_tools_are_iterable
    assert_equal [ToolA, ToolB], SamplePlugin.tools
  end

  def test_log_level_override
    assert_equal :debug, SamplePlugin.log_level
  end

  def test_plugin_without_declarations_has_empty_defaults
    bare = Class.new(TalkToYourApp::Plugin)
    assert_nil bare.required_gem
    assert_empty bare.tools
    assert_nil bare.log_level
  end
end
