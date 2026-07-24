# frozen_string_literal: true

require "test_helper"

class TalkToYourApp::ToolTest < TalkToYourApp::TestCase
  class FooTool < TalkToYourApp::Tool
    name        "foo.bar"
    description "Does a foo."
    argument    :alpha, :string, required: true, description: "the alpha"
    argument    :mode,  :string, enum: %w[a b c], default: "a"

    def call(args, _ctx)
      text("alpha=#{args[:alpha]} mode=#{args[:mode]}")
    end
  end

  def test_to_mcp_definition_produces_json_schema_hash
    defn = FooTool.to_mcp_definition
    assert_equal "foo.bar", defn[:name]
    assert_equal "Does a foo.", defn[:description]
    schema = defn[:input_schema]
    assert_equal "string", schema[:properties][:alpha][:type]
    assert_equal %w[a b c], schema[:properties][:mode][:enum]
    assert_equal ["alpha"], schema[:required]
  end

  def test_tool_name_reader_alias
    assert_equal "foo.bar", FooTool.tool_name
  end

  # --- connection resolution -------------------------------------------------

  class WiredTool < TalkToYourApp::Tool
    name "wired.tool"
    def call(_args, _ctx) = text("ok")
  end

  class StaticTool < TalkToYourApp::Tool
    name "static.tool"
    connection :from_dsl
    def call(_args, _ctx) = text("ok")
  end

  def ctx(tool, plugin_name: nil)
    TalkToYourApp::Tool::Context.new(tool_class: tool, plugin_name: plugin_name)
  end

  def test_connection_name_resolves_plugin_wired_connection
    TalkToYourApp.configure { |c| c.plugin :demo, connection: :wired_conn }
    assert_equal :wired_conn, ctx(WiredTool, plugin_name: :demo).connection_name
  end

  def test_connection_name_reports_the_connection_a_call_ran_on
    # An explicit override goes through #connection; #connection_name then
    # echoes it (guards the footgun where they could diverge).
    TalkToYourApp.configure do |c|
      c.connection :wired, database: "primary"
      c.connection :override, database: "primary"
      c.plugin :custom_tools, connection: :wired
    end
    context = ctx(WiredTool, plugin_name: :custom_tools)
    context.connection(:override) { |_conn| :noop }
    assert_equal :override, context.connection_name
  end

  def test_connection_name_falls_back_to_static_dsl
    # No plugin-wired connection; the tool's static `connection` DSL wins.
    assert_equal :from_dsl, ctx(StaticTool, plugin_name: :custom_tools).connection_name
  end

  def test_static_dsl_beats_plugin_wired_connection
    # Most-specific-wins: a tool's own `connection` DSL takes precedence over the
    # plugin-wired default, regardless of whether the operator wired a real
    # connection or false (consistent with the connection:false case below).
    TalkToYourApp.configure { |c| c.plugin :custom_tools, connection: :plugin_default }
    assert_equal :from_dsl, ctx(StaticTool, plugin_name: :custom_tools).connection_name
  end

  def test_explicit_arg_beats_static_dsl
    # Top of the precedence chain: an explicit ctx.connection(:name) overrides
    # even a tool that declares its own static `connection` DSL.
    TalkToYourApp.configure do |c|
      c.connection :override, database: "primary"
      c.plugin :custom_tools, connection: :plugin_default
    end
    context = ctx(StaticTool, plugin_name: :custom_tools) # StaticTool declares connection :from_dsl
    context.connection(:override) { |_conn| :noop }
    assert_equal :override, context.connection_name
  end

  def test_connection_name_is_nil_safe_when_plugin_name_absent
    # plugin_name nil + no static DSL => terminal ConfigurationError, not NoMethodError.
    error = assert_raises(TalkToYourApp::ConfigurationError) { ctx(WiredTool).connection_name }
    assert_match(/could not resolve a connection/, error.message)
  end

  def test_to_mcp_tool_builds_invokable_mcp_tool
    mcp_tool = FooTool.to_mcp_tool
    assert_equal "foo.bar", mcp_tool.name_value
    response = mcp_tool.call(alpha: "x", mode: "b", server_context: nil)
    assert_equal "alpha=x mode=b", response.content.first[:text]
    refute response.error?
  end

  def test_inherited_copies_dsl_but_not_tool_name
    sub = Class.new(FooTool)
    assert_nil sub.tool_name, "tool_name must NOT be inherited — every concrete tool declares its own"
    assert_equal FooTool.arguments.keys, sub.arguments.keys, "arguments ARE inherited"
    assert_equal "Does a foo.", sub.description, "description IS inherited"
  end

  def test_inherited_arguments_are_isolated_from_the_parent
    sub = Class.new(FooTool)
    sub.argument(:extra, :string)
    assert_includes sub.arguments.keys, :extra
    refute_includes FooTool.arguments.keys, :extra, "a subclass argument must not leak into the parent"
  end

  def test_to_mcp_tool_description_override
    assert_equal "overridden", FooTool.to_mcp_tool(description: "overridden").description_value
    assert_equal "Does a foo.", FooTool.to_mcp_tool.description_value, "nil override falls back to the static description"
  end

  def test_connection_false_opt_out_gives_a_targeted_error
    TalkToYourApp.configure { |c| c.plugin :custom_tools, connection: false }
    error = assert_raises(TalkToYourApp::ConfigurationError) do
      ctx(WiredTool, plugin_name: :custom_tools).connection_name
    end
    assert_match(/connection: false/, error.message)
  end

  # Precedence: a tool's own static `connection` DSL still applies even when the
  # plugin opted out with connection: false (the DSL is the tool author's
  # explicit default; the opt-out only declines a *plugin-level* wired default).
  def test_static_dsl_wins_over_a_connection_false_opt_out
    TalkToYourApp.configure { |c| c.plugin :custom_tools, connection: false }
    assert_equal :from_dsl, ctx(StaticTool, plugin_name: :custom_tools).connection_name
  end

  def test_to_mcp_tool_requires_explicit_tool_name
    klass = Class.new(TalkToYourApp::Tool) do
      def call(_args, _ctx) = text("ok")
    end

    error = assert_raises(TalkToYourApp::ConfigurationError) { klass.to_mcp_tool }
    assert_match(/has no MCP tool name/, error.message)
  end

  def test_defaults_are_applied_when_argument_missing
    response = FooTool.to_mcp_tool.call(alpha: "x", server_context: nil)
    assert_equal "alpha=x mode=a", response.content.first[:text]
  end

  def test_context_exposes_principal_from_current
    TalkToYourApp::Current.principal = "claude-desktop"
    captured = nil
    klass = Class.new(TalkToYourApp::Tool) do
      name "ctx.probe"
      define_method(:call) do |_args, ctx|
        captured = ctx.principal
        MCP::Tool::Response.new([{ type: "text", text: "ok" }])
      end
    end
    klass.invoke({})
    assert_equal "claude-desktop", captured
  ensure
    TalkToYourApp::Current.reset
  end

  def test_context_exposes_ip_and_session_from_current
    TalkToYourApp::Current.ip = "203.0.113.7"
    TalkToYourApp::Current.session_id = "sess-1"
    captured = nil
    klass = Class.new(TalkToYourApp::Tool) do
      name "ctx.probe_ip"
      define_method(:call) do |_args, ctx|
        captured = [ctx.ip, ctx.session_id]
        MCP::Tool::Response.new([{ type: "text", text: "ok" }])
      end
    end
    klass.invoke({})
    assert_equal ["203.0.113.7", "sess-1"], captured
  ensure
    TalkToYourApp::Current.reset
  end

  def test_authorize_hook_denies_unpermitted_principal
    TalkToYourApp::Current.principal = "readonly-bot"
    TalkToYourApp.configure do |c|
      c.authorize { |principal, tool| principal == "admin" || tool.start_with?("db.") }
    end
    denied = FooTool.dispatch({ alpha: "x" }, plugin_name: :demo)
    assert denied.error?
    assert_match(/Not authorized/, denied.content.first[:text])
  ensure
    TalkToYourApp::Current.reset
  end

  def test_authorize_hook_allows_permitted_principal
    TalkToYourApp::Current.principal = "admin"
    TalkToYourApp.configure { |c| c.authorize { |principal, _tool| principal == "admin" } }
    allowed = FooTool.dispatch({ alpha: "x" }, plugin_name: :demo)
    refute allowed.error?
  ensure
    TalkToYourApp::Current.reset
  end

  def test_authorize_hook_receives_tool_args
    TalkToYourApp::Current.principal = "admin"
    seen = nil
    TalkToYourApp.configure do |c|
      c.authorize { |principal, tool, args| seen = [principal, tool, args]; true }
    end
    FooTool.dispatch({ alpha: "x" }, plugin_name: :demo)
    assert_equal ["admin", "foo.bar", { alpha: "x" }], seen
  ensure
    TalkToYourApp::Current.reset
  end

  def test_authorize_hook_can_deny_by_args
    TalkToYourApp::Current.principal = "admin"
    TalkToYourApp.configure do |c|
      c.authorize { |_p, _tool, args| args[:alpha] != "forbidden" }
    end
    refute FooTool.dispatch({ alpha: "x" }, plugin_name: :demo).error?
    assert FooTool.dispatch({ alpha: "forbidden" }, plugin_name: :demo).error?
  ensure
    TalkToYourApp::Current.reset
  end

  def test_no_authorizer_allows_all
    assert TalkToYourApp.configuration.authorized?("anyone", "any.tool")
  end

  def test_raising_authorizer_fails_closed
    TalkToYourApp.configure { |c| c.authorize { |_p, _t| raise "rbac backend down" } }
    _out, _err = capture_io do
      refute TalkToYourApp.configuration.authorized?("anyone", "any.tool")
    end
  end

  def test_string_return_is_wrapped_as_text_content
    klass = Class.new(TalkToYourApp::Tool) do
      name "str.tool"
      def call(_args, _ctx) = "hello"
    end
    response = klass.invoke({})
    assert_equal "hello", response.content.first[:text]
  end
end
