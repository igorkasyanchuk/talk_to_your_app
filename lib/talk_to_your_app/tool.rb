# frozen_string_literal: true

require "json"
require "mcp"
require_relative "current"
require_relative "audit_logger"

module TalkToYourApp
  # Base class for MCP tools. Authors subclass it, declare arguments with the
  # class-level DSL, and implement `#call(args, ctx)`.
  #
  #   class DbQueryTool < TalkToYourApp::Tool
  #     name        "db.query"
  #     description "Run a SQL query."
  #     argument    :sql,    :string, required: true
  #     argument    :format, :string, enum: %w[json text html], default: "json"
  #
  #     def call(args, ctx)
  #       # No name: resolves the connection the operator wired into this plugin.
  #       ctx.connection { |conn| ... }
  #     end
  #   end
  #
  # A tool compiles down to an `MCP::Tool` subclass via `.to_mcp_tool`; the
  # argument DSL produces the JSON Schema the SDK validates against.
  class Tool
    NOT_SET = Object.new
    private_constant :NOT_SET

    # The context handed to `#call`. Exposes the request principal and session,
    # the audit logger, and role-switched database connections.
    class Context
      attr_reader :logger

      def initialize(tool_class:, plugin_name: nil, logger: nil)
        @tool_class = tool_class
        @plugin_name = plugin_name
        @logger = logger
      end

      def principal
        TalkToYourApp::Current.principal
      end

      def session_id
        TalkToYourApp::Current.session_id
      end

      def ip
        TalkToYourApp::Current.ip
      end

      # Runs the block against a registry connection, switched to its declared
      # role, and records the resolved name so #connection_name reports the same
      # connection the block ran on (even when an explicit override was passed).
      def connection(name = nil, &block)
        @connection_name = resolve_connection_name(name)
        TalkToYourApp::ConnectionRegistry.with(@connection_name, &block)
      end

      # The connection name this call resolves to — the one a prior #connection
      # call ran on, or the default resolution when #connection has not run yet.
      # `timeout_ms`-style code reads this so the timeout is fetched from the
      # same spec the query runs on. Pure no-arg reader: pass an override to
      # #connection, not here.
      def connection_name
        @connection_name || resolve_connection_name(nil)
      end

      private

      # Resolution precedence, most-specific first: explicit arg -> the tool's
      # own static `connection` DSL -> the plugin's operator-wired `connection:`
      # -> ConfigurationError. A tool that declares its own connection always
      # gets it (the plugin-wired value is only a default for tools that don't
      # declare one), so the outcome no longer depends on whether the operator
      # wired a real connection or `false`. `plugin_name` may be nil (a tool
      # dispatched outside a plugin), so the wired lookup is nil-safe.
      def resolve_connection_name(explicit)
        # Capture wired separately: wired_connection returns false for an
        # explicit `connection: false` opt-out and nil when nothing was wired —
        # a distinction the chain collapses but the error branch below needs.
        wired = wired_connection
        name = explicit || @tool_class.connection || wired
        return name if name

        # Distinguish "opted out" (connection: false) from "never wired" so the
        # error tells the author what to actually do.
        if wired == false
          raise TalkToYourApp::ConfigurationError,
            "tool #{@tool_class.tool_name.inspect}: plugin #{@plugin_name.inspect} was enabled with " \
            "`connection: false` (opted out of a wired connection). Pass an explicit name to " \
            "ctx.connection(:name), or enable the plugin with a real connection."
        end
        raise TalkToYourApp::ConfigurationError,
          "tool #{@tool_class.tool_name.inspect} could not resolve a connection: no explicit name, " \
          "no `connection:` wired on plugin #{@plugin_name.inspect}, and the tool declares no `connection`."
      end

      def wired_connection
        TalkToYourApp.configuration.enabled_plugins[@plugin_name]&.dig(:connection)
      end
    end

    class << self
      # --- DSL ---------------------------------------------------------------

      # The MCP tool name (e.g. "db.query"). Overrides Class#name as a setter
      # while preserving it as a reader before one is assigned.
      def name(value = NOT_SET)
        if value == NOT_SET
          defined?(@tool_name) && @tool_name ? @tool_name : super()
        else
          @tool_name = value
        end
      end

      def tool_name
        @tool_name
      end

      def description(value = NOT_SET)
        value == NOT_SET ? @description : (@description = value)
      end

      def connection(value = NOT_SET)
        value == NOT_SET ? @connection : (@connection = value)
      end

      def argument(arg_name, type, required: false, enum: nil, default: nil, description: nil, redact: false, minimum: nil, maximum: nil)
        arguments[arg_name.to_sym] = {
          type: type.to_s,
          required: required,
          enum: enum,
          default: default,
          description: description,
          redact: redact,
          minimum: minimum,
          maximum: maximum,
        }.compact
      end

      def arguments
        @arguments ||= {}
      end

      # --- Custom-tool collection -------------------------------------------

      # While true, every newly defined Tool subclass adds itself to
      # custom_registry. The :custom_tools plugin flips this on only while it
      # loads the host app's app/talk_to_your_app/custom_tools/ directory, so the
      # bundled tools (defined when the gem loads) are never collected.
      attr_accessor :collecting_custom_tools

      # Tools collected while loading the custom_tools directory, in definition
      # order. Held on the base class; subclasses share the one list.
      def custom_registry
        TalkToYourApp::Tool.instance_variable_get(:@custom_registry) ||
          TalkToYourApp::Tool.instance_variable_set(:@custom_registry, [])
      end

      # Test seam: forget all collected custom tools.
      def clear_custom_registry!
        custom_registry.clear
      end

      # Records app-defined tools while collection is active (see above). Fires
      # at any subclass depth. Also copies the class-level DSL state (arguments,
      # description, connection) down to the subclass so a subclass can reuse a
      # base tool's shape and only override what differs (the Jobs plugins build
      # per-adapter tools this way). `name`/`tool_name` is deliberately NOT
      # copied — every concrete tool must declare its own MCP name.
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@arguments, arguments.dup)
        subclass.instance_variable_set(:@description, description) unless description.nil?
        subclass.instance_variable_set(:@connection, connection) unless connection.nil?
        TalkToYourApp::Tool.custom_registry << subclass if TalkToYourApp::Tool.collecting_custom_tools
      end

      # --- Compilation -------------------------------------------------------

      # JSON Schema (object) for the declared arguments.
      def input_schema_hash
        properties = arguments.each_with_object({}) do |(arg_name, opts), acc|
          prop = { type: opts[:type] }
          prop[:enum] = opts[:enum] if opts[:enum]
          prop[:description] = opts[:description] if opts[:description]
          prop[:minimum] = opts[:minimum] if opts[:minimum]
          prop[:maximum] = opts[:maximum] if opts[:maximum]
          acc[arg_name] = prop
        end
        required = arguments.select { |_, o| o[:required] }.keys.map(&:to_s)
        schema = { properties: properties }
        # Draft-04 (the SDK's metaschema) rejects an empty `required` array.
        schema[:required] = required unless required.empty?
        schema
      end

      # The shape used by tests and documentation.
      def to_mcp_definition
        { name: tool_name, description: description, input_schema: input_schema_hash }
      end

      # Builds the MCP::Tool subclass the server registers. Its class-level
      # `call(**args, server_context:)` bridges to this tool's `#call(args, ctx)`.
      # plugin_name and log_level are threaded through for the audit logger.
      def to_mcp_tool(plugin_name: nil, log_level: nil, description: nil)
        if tool_name.nil? || tool_name.to_s.empty?
          raise TalkToYourApp::ConfigurationError,
            "#{inspect} has no MCP tool name — call `name \"your.tool\"` in the tool class."
        end

        ttya_tool = self
        resolved_description = description || ttya_tool.description
        MCP::Tool.define(
          name: ttya_tool.tool_name,
          description: resolved_description,
          input_schema: ttya_tool.input_schema_hash,
        ) do |server_context: nil, **args|
          ttya_tool.dispatch(args, plugin_name: plugin_name, log_level: log_level)
        end
      end

      # Invocation entry point, wrapped by the audit logger: one log line per
      # call. Applies argument defaults, runs the tool, and normalizes the return
      # into an MCP::Tool::Response.
      def dispatch(args, plugin_name: nil, log_level: nil)
        AuditLogger.around(tool_class: self, plugin_name: plugin_name, log_level: log_level, params: args) do
          if TalkToYourApp.configuration.authorized?(TalkToYourApp::Current.principal, tool_name, args)
            invoke(args, plugin_name: plugin_name)
          else
            MCP::Tool::Response.new(
              [{ type: "text", text: "Not authorized: principal may not call #{tool_name}." }],
              error: true,
            )
          end
        end
      end

      def invoke(args, plugin_name: nil)
        merged = default_arguments.merge(args)
        ctx = Context.new(tool_class: self, plugin_name: plugin_name, logger: TalkToYourApp.configuration.logger)
        normalize_response(new.call(merged, ctx))
      end

      # Static metadata, computed once per tool class.
      def default_arguments
        @default_arguments ||= arguments.each_with_object({}) do |(arg_name, opts), acc|
          acc[arg_name] = opts[:default] unless opts[:default].nil?
        end
      end

      def normalize_response(result)
        case result
        when MCP::Tool::Response
          result
        when String
          MCP::Tool::Response.new([{ type: "text", text: result }])
        else
          MCP::Tool::Response.new([{ type: "text", text: result.to_json }])
        end
      end
    end

    # Tool authors override this.
    def call(_args, _ctx)
      raise NotImplementedError, "#{self.class}#call must be implemented"
    end

    # --- Response helpers available to subclasses ---------------------------

    private

    def text(string)
      MCP::Tool::Response.new([{ type: "text", text: string.to_s }])
    end

    def json(object)
      MCP::Tool::Response.new([{ type: "text", text: JSON.pretty_generate(object) }])
    end

    def error(message)
      MCP::Tool::Response.new([{ type: "text", text: message.to_s }], error: true)
    end
  end
end
