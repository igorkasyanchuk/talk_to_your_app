# frozen_string_literal: true

require "mcp"
require_relative "../auth/middleware"

module TalkToYourApp
  module Transport
    # Builds the Rack application the host app mounts. It assembles an
    # MCP::Server from the enabled plugins' tools, wraps it in the SDK's
    # Streamable HTTP transport, and fronts the whole thing with the auth
    # middleware. `config.stateless` selects the transport's stateless mode,
    # which holds no per-session state — required when the host app runs more
    # than one worker or replica.
    module RailsMount
      module_function

      def build
        config = TalkToYourApp.configuration
        server = MCP::Server.new(
          name: config.server_name,
          title: config.server_title,
          version: config.server_version,
          description: config.server_description,
          instructions: config.instructions,
          tools: collect_tools,
        )
        transport = MCP::Server::Transports::StreamableHTTPTransport.new(
          server,
          stateless: config.stateless,
          enable_json_response: true,
          allowed_hosts: config.allowed_hosts,
          allowed_origins: config.allowed_origins,
        )
        app = Auth::Middleware.new(transport)

        # `config.enabled` is checked per request rather than captured here:
        # `rack_app` is memoized and the host mounts it in routes.rb, which can
        # be evaluated before the operator's initializer sets `enabled`. Reading
        # it live means toggling the flag is honored without a stale-app
        # surprise. The 503 sits in front of auth — nothing to protect when the
        # gem is disabled.
        lambda do |env|
          return disabled_response unless TalkToYourApp.configuration.enabled

          app.call(env)
        end
      end

      # 503 (not 404) so monitoring and host catch-all routes can tell "gem
      # disabled" apart from "route missing".
      def disabled_response
        [503, { "content-type" => "text/plain" }, ["talk_to_your_app: disabled"]]
      end

      # Compiles every enabled plugin's tools into MCP::Tool subclasses, each
      # audit-wrapped with its plugin name and (optional) per-plugin log level.
      def collect_tools
        TalkToYourApp.enabled_plugins.flat_map do |name, plugin_class, _opts|
          next [] unless plugin_class

          plugin_class.tools.map do |tool_class|
            # A plugin may tailor a tool's description to the operator's config
            # (e.g. the DB plugin flags a writable connection). nil -> the tool's
            # own static description is used.
            description = plugin_class.describe_tool(tool_class)
            tool_class.to_mcp_tool(plugin_name: name, log_level: plugin_class.log_level, description: description)
          end
        end
      end
    end
  end
end
