# frozen_string_literal: true

require "test_helper"
require "support/flipper_test_setup"

class TalkToYourApp::Plugins::FlipperTest < TalkToYourApp::TestCase
  Flipper = TalkToYourApp::Plugins::Flipper

  def setup
    super
    TalkToYourApp::FlipperTestSetup.reset!
    TalkToYourApp.configure do |c|
      c.connection :flipper_writer, database: "primary", role: :writing
      c.plugin :flipper, connection: :flipper_writer
    end
  end

  def ctx_for(tool)
    TalkToYourApp::Tool::Context.new(tool_class: tool, plugin_name: :flipper)
  end

  def call(tool, args)
    JSON.parse(tool.new.call(args, ctx_for(tool)).content.first[:text])
  end

  def tool_response(tool, args)
    tool.new.call(args, ctx_for(tool))
  end

  # Net-new behavior: Flipper requires a :writing connection. Previously a
  # :reading-roled connection booted and failed only on the first write.
  def test_boot_rejects_a_reading_connection
    TalkToYourApp.reset_configuration!
    TalkToYourApp.configure do |c|
      c.connection :ro, database: "primary", role: :reading
      c.plugin :flipper, connection: :ro
    end
    error = assert_raises(TalkToYourApp::ConfigurationError) do
      TalkToYourApp::PluginRegistry.validate_enabled!
    end
    assert_match(/role: :writing/, error.message)
  end

  def test_validate_enablement_rejects_connection_false
    error = assert_raises(TalkToYourApp::ConfigurationError) do
      Flipper::Plugin.validate_enablement!({ connection: false })
    end
    assert_match(/connection: false/, error.message) # pin to the opt-out branch
    assert_match(/is not valid/, error.message)
  end

  def test_enable_then_read_globally
    call(Flipper::Tools::EnableFlag, { name: "new_ui" })
    result = call(Flipper::Tools::ReadFlag, { name: "new_ui" })
    assert_equal true, result["enabled"]
  end

  def test_list_flags_returns_configured_names
    call(Flipper::Tools::EnableFlag, { name: "alpha" })
    call(Flipper::Tools::EnableFlag, { name: "beta" })
    result = call(Flipper::Tools::ListFlags, {})
    assert_equal %w[alpha beta], result["flags"]
  end

  def test_list_flags_returns_tool_error_when_storage_fails
    failing_ctx = Object.new
    def failing_ctx.connection
      raise "offline"
    end

    response = Flipper::Tools::ListFlags.new.call({}, failing_ctx)
    assert response.error?
    assert_match(/Flipper storage unavailable/, response.content.first[:text])
  end

  def test_per_actor_enable_is_scoped
    call(Flipper::Tools::EnableFlag, { name: "feature_x", actor_class: "User", actor_id: "42" })

    for_actor = call(Flipper::Tools::ReadFlag, { name: "feature_x", actor_class: "User", actor_id: "42" })
    assert_equal true, for_actor["enabled"]
    assert_equal "User;42", for_actor["actor"]

    other_actor = call(Flipper::Tools::ReadFlag, { name: "feature_x", actor_class: "User", actor_id: "99" })
    assert_equal false, other_actor["enabled"]

    globally = call(Flipper::Tools::ReadFlag, { name: "feature_x" })
    assert_equal false, globally["enabled"]
  end

  def test_disable_flag
    call(Flipper::Tools::EnableFlag, { name: "to_disable" })
    call(Flipper::Tools::DisableFlag, { name: "to_disable" })
    result = call(Flipper::Tools::ReadFlag, { name: "to_disable" })
    assert_equal false, result["enabled"]
  end

  def test_unknown_flag_reads_as_disabled
    result = call(Flipper::Tools::ReadFlag, { name: "never_created" })
    assert_equal false, result["enabled"]
  end

  def test_actor_for_helper
    assert_nil Flipper.actor_for(nil, nil)
    assert_equal "User;7", Flipper.actor_for("User", "7").flipper_id
  end

  def test_enable_returns_gate_summary
    result = call(Flipper::Tools::EnableFlag, { name: "new_ui" })
    assert_equal "boolean", result["gate_type"]
    assert_equal true, result["enabled"]
    assert_equal true, result.dig("gates", "boolean")
  end

  def test_conflicting_gate_args_are_rejected
    response = tool_response(Flipper::Tools::EnableFlag, { name: "x", group: "admins", percentage: 50 })
    assert response.error?
    assert_match(/exactly one gate/, response.content.first[:text])
  end

  def test_partial_actor_selector_is_rejected
    response = tool_response(Flipper::Tools::EnableFlag, { name: "x", actor_class: "User" })
    assert response.error?
    assert_match(/both actor_class and actor_id/, response.content.first[:text])

    response = tool_response(Flipper::Tools::DisableFlag, { name: "x", actor_id: "42" })
    assert response.error?
    assert_match(/both actor_class and actor_id/, response.content.first[:text])

    response = tool_response(Flipper::Tools::ReadFlag, { name: "x", actor_class: "User" })
    assert response.error?
    assert_match(/both actor_class and actor_id/, response.content.first[:text])
  end

  def test_percentage_type_without_percentage_is_rejected
    response = tool_response(Flipper::Tools::EnableFlag, { name: "x", percentage_type: "time" })
    assert response.error?
    assert_match(/Specify percentage/, response.content.first[:text])
  end

  def test_disable_group_gate_round_trip
    call(Flipper::Tools::EnableFlag, { name: "beta", group: "admins" })
    result = call(Flipper::Tools::DisableFlag, { name: "beta", group: "admins" })
    refute_includes result.dig("gates", "groups"), "admins"
  end

  def test_enable_percentage_of_actors
    result = call(Flipper::Tools::EnableFlag, { name: "rollout", percentage: 25 })
    assert_equal "percentage_of_actors", result["gate_type"]
    assert_equal 25, result.dig("gates", "percentage_of_actors")
  end

  def test_enable_percentage_of_time
    result = call(Flipper::Tools::EnableFlag, { name: "rollout_t", percentage: 10, percentage_type: "time" })
    assert_equal "percentage_of_time", result["gate_type"]
    assert_equal 10, result.dig("gates", "percentage_of_time")
  end

  def test_enable_group_gate
    result = call(Flipper::Tools::EnableFlag, { name: "beta", group: "admins" })
    assert_equal "group", result["gate_type"]
    assert_includes result.dig("gates", "groups"), "admins"
  end

  def test_disable_percentage_clears_gate
    call(Flipper::Tools::EnableFlag, { name: "rollout", percentage: 40 })
    result = call(Flipper::Tools::DisableFlag, { name: "rollout", percentage: 0 })
    assert_equal 0, result.dig("gates", "percentage_of_actors")
  end

  def test_read_flag_includes_gate_values
    call(Flipper::Tools::EnableFlag, { name: "feature_x", actor_class: "User", actor_id: "42" })
    result = call(Flipper::Tools::ReadFlag, { name: "feature_x", actor_class: "User", actor_id: "42" })
    assert_equal true, result["enabled"]
    assert_includes result.dig("gates", "actors"), "User;42"
  end

  def test_enabled_flags_lists_only_active_flags_with_timestamps
    call(Flipper::Tools::EnableFlag, { name: "on_flag" })
    call(Flipper::Tools::EnableFlag, { name: "pct_flag", percentage: 30 })
    call(Flipper::Tools::EnableFlag, { name: "off_flag" })
    call(Flipper::Tools::DisableFlag, { name: "off_flag" }) # toggled back off

    result = call(Flipper::Tools::EnabledFlags, {})
    names = result["enabled_flags"].map { |f| f["name"] }
    assert_includes names, "on_flag"
    assert_includes names, "pct_flag"
    refute_includes names, "off_flag"

    on_flag = result["enabled_flags"].find { |f| f["name"] == "on_flag" }
    # ActiveRecord adapter is in use in tests, so timestamps are populated.
    refute_nil on_flag["updated_at"]
    assert_equal true, on_flag.dig("gates", "boolean")
  end

  def test_enabled_flags_empty_when_nothing_enabled
    result = call(Flipper::Tools::EnabledFlags, {})
    assert_equal [], result["enabled_flags"]
  end
end
