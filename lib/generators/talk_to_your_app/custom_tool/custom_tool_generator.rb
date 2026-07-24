# frozen_string_literal: true

require "rails/generators/named_base"
require "talk_to_your_app"

module TalkToYourApp
  module Generators
    # `rails g talk_to_your_app:custom_tool MakeAdmin` — scaffolds a custom MCP
    # tool in app/talk_to_your_app/custom_tools/. Enable
    # `config.plugin :custom_tools, connection: false` and the tool is exposed
    # automatically as `custom.<path.name>` (for example, Admin/MakeAdmin ->
    # custom.admin.make_admin).
    class CustomToolGenerator < ::Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      desc "Creates a TalkToYourApp::Tool subclass in app/talk_to_your_app/custom_tools/."

      TOOLS_DIR = File.join(TalkToYourApp::APP_DIR, "custom_tools")

      def create_tool
        template "tool.rb.tt", File.join(TOOLS_DIR, class_path, "#{file_name}.rb")
      end

      def show_next_steps
        say ""
        say "Created #{File.join(TOOLS_DIR, class_path, "#{file_name}.rb")} — exposed as MCP tool #{tool_name.inspect}.", :green
        say "Make sure config/initializers/talk_to_your_app.rb enables it:"
        say "  config.plugin :custom_tools, connection: false   # or connection: :your_connection"
        say "Files here are loaded with require (not Zeitwerk-reloaded) — restart the server to pick up new or edited tools."
      end

      private

      # MCP tool name: "custom.<underscored.path_name>".
      def tool_name
        "custom.#{[*class_path, file_name].join('.')}"
      end
    end
  end
end
