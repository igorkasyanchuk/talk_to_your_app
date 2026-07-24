# frozen_string_literal: true

require_relative "../../plugin"

module TalkToYourApp
  module Plugins
    module CustomTools
      # Exposes the host app's own tools over MCP. Tools live in
      # app/talk_to_your_app/custom_tools/ (one TalkToYourApp::Tool subclass per
      # file, scaffolded by `rails g talk_to_your_app:custom_tool`). Unlike the
      # bundled plugins, the tool list is dynamic: it's whatever this plugin
      # collects while loading that directory — bundled tools, defined when the
      # gem loads, are never collected.
      class Plugin < TalkToYourApp::Plugin
        def self.tools
          TalkToYourApp::Tool.collecting_custom_tools = true
          TalkToYourApp.require_app_dir("custom_tools") do |_file, load_file|
            before = TalkToYourApp::Tool.custom_registry.length
            load_file.call
          rescue StandardError, ScriptError
            TalkToYourApp::Tool.custom_registry.slice!(before..)
            raise
          end
          # Dedup by MCP name (last wins) in case two files declare the same
          # tool_name, or a class is collected more than once in a process.
          TalkToYourApp::Tool.custom_registry.each_with_object({}) { |t, acc| acc[t.tool_name] = t }.values
        ensure
          TalkToYourApp::Tool.collecting_custom_tools = false
        end
      end
    end
  end
end

TalkToYourApp.register_plugin(:custom_tools, TalkToYourApp::Plugins::CustomTools::Plugin)
