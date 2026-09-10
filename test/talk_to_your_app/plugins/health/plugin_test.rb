# frozen_string_literal: true

require "test_helper"

class TalkToYourApp::Plugins::HealthTest < TalkToYourApp::TestCase
  def setup
    super
    reset_health_checks!
  end

  def teardown
    reset_health_checks!
    super
  end

  # #health_checks returns a defensive copy (thread-safety — see
  # Configuration#health_checks), so clearing it doesn't clear the
  # configuration; reach the ivar directly instead.
  def reset_health_checks!
    TalkToYourApp.configuration.instance_variable_get(:@health_checks).clear
  end

  def test_registered_under_health
    assert_equal TalkToYourApp::Plugins::Health::Plugin, TalkToYourApp::PluginRegistry[:health]
  end

  def test_health_check_requires_a_block
    error = assert_raises(ArgumentError) { TalkToYourApp.configuration.health_check(:no_block) }
    assert_match(/block is required/, error.message)
  end

  def test_health_check_rejects_a_non_positive_timeout
    error = assert_raises(ArgumentError) { TalkToYourApp.configuration.health_check(:bad_timeout, timeout: 0) { true } }
    assert_match(/timeout must be a positive number/, error.message)

    error = assert_raises(ArgumentError) { TalkToYourApp.configuration.health_check(:bad_timeout, timeout: -1) { true } }
    assert_match(/timeout must be a positive number/, error.message)
  end

  def test_health_check_reregistration_overwrites
    TalkToYourApp.configuration.health_check(:flag) { [true, "first"] }
    TalkToYourApp.configuration.health_check(:flag) { [true, "second"] }

    response = TalkToYourApp::Plugins::Health::Tools::RunCheck.dispatch({ name: "flag" }, plugin_name: :health)
    payload = JSON.parse(response.content.first[:text])
    assert_equal "second", payload["value"]

    response = TalkToYourApp::Plugins::Health::Tools::ListChecks.dispatch({}, plugin_name: :health)
    payload = JSON.parse(response.content.first[:text])
    assert_equal ["flag"], payload["checks"] # not duplicated
  end

  def test_list_returns_registered_names_sorted
    TalkToYourApp.configuration.health_check(:zebra) { true }
    TalkToYourApp.configuration.health_check(:alpha) { true }

    response = TalkToYourApp::Plugins::Health::Tools::ListChecks.dispatch({}, plugin_name: :health)
    payload = JSON.parse(response.content.first[:text])
    assert_equal %w[alpha zebra], payload["checks"]
  end

  def test_list_is_empty_when_nothing_registered
    response = TalkToYourApp::Plugins::Health::Tools::ListChecks.dispatch({}, plugin_name: :health)
    payload = JSON.parse(response.content.first[:text])
    assert_equal [], payload["checks"]
  end

  def test_run_bare_boolean_true
    TalkToYourApp.configuration.health_check(:ok) { true }
    response = TalkToYourApp::Plugins::Health::Tools::RunCheck.dispatch({ name: "ok" }, plugin_name: :health)
    payload = JSON.parse(response.content.first[:text])
    assert_equal true, payload["passed"]
    assert_nil payload["value"]
  end

  def test_run_bare_boolean_false
    TalkToYourApp.configuration.health_check(:broken) { false }
    response = TalkToYourApp::Plugins::Health::Tools::RunCheck.dispatch({ name: "broken" }, plugin_name: :health)
    payload = JSON.parse(response.content.first[:text])
    assert_equal false, payload["passed"]
  end

  def test_run_pair_with_value
    TalkToYourApp.configuration.health_check(:video_pipeline) { [true, 42] }
    response = TalkToYourApp::Plugins::Health::Tools::RunCheck.dispatch({ name: "video_pipeline" }, plugin_name: :health)
    payload = JSON.parse(response.content.first[:text])
    assert_equal true, payload["passed"]
    assert_equal 42, payload["value"]
  end

  def test_run_failing_pair_with_value
    TalkToYourApp.configuration.health_check(:queue_depth) { [false, 9001] }
    response = TalkToYourApp::Plugins::Health::Tools::RunCheck.dispatch({ name: "queue_depth" }, plugin_name: :health)
    payload = JSON.parse(response.content.first[:text])
    assert_equal false, payload["passed"]
    assert_equal 9001, payload["value"]
  end

  def test_run_unknown_check_is_a_tool_error
    response = TalkToYourApp::Plugins::Health::Tools::RunCheck.dispatch({ name: "does_not_exist" }, plugin_name: :health)
    assert response.error?
    assert_match(/Unknown health check/, response.content.first[:text])
  end

  def test_run_raising_check_is_reported_as_failed_not_a_500
    TalkToYourApp.configuration.health_check(:flaky) { raise "boom" }
    response = TalkToYourApp::Plugins::Health::Tools::RunCheck.dispatch({ name: "flaky" }, plugin_name: :health)
    refute response.error? # not a tool-dispatch error — a reported failed check
    payload = JSON.parse(response.content.first[:text])
    assert_equal false, payload["passed"]
    # Only the exception class reaches the client — the message might carry a
    # URL, token, or hostname. The full message goes to the server log instead
    # (see test_run_raising_check_logs_the_full_message_server_side).
    assert_equal "RuntimeError", payload["error"]
    refute_match(/boom/, payload["error"])
  end

  def test_run_raising_check_logs_the_full_message_server_side
    logger = Minitest::Mock.new
    logger.expect(:warn, nil) { |msg| msg.include?("flaky") && msg.include?("boom") }
    # AuditLogger also logs its own success/error line through the same
    # configured logger, at whatever level the plugin defaults to (info) —
    # mock it as a no-op so this test only asserts on the health-check-specific
    # warn line, not the framework's own audit line.
    logger.expect(:info, nil) { true }
    TalkToYourApp.configuration.logger = logger

    TalkToYourApp.configuration.health_check(:flaky) { raise "boom" }
    TalkToYourApp::Plugins::Health::Tools::RunCheck.dispatch({ name: "flaky" }, plugin_name: :health)

    logger.verify
  ensure
    TalkToYourApp.configuration.logger = nil
  end

  def test_run_slow_check_times_out
    TalkToYourApp.configuration.health_check(:slow, timeout: 0.05) { sleep 1 }
    response = TalkToYourApp::Plugins::Health::Tools::RunCheck.dispatch({ name: "slow" }, plugin_name: :health)
    refute response.error?
    payload = JSON.parse(response.content.first[:text])
    assert_equal false, payload["passed"]
    assert_match(/timed out after 0\.05s/, payload["error"])
  end

  def test_run_fast_check_under_timeout_is_unaffected
    TalkToYourApp.configuration.health_check(:fast, timeout: 5) { true }
    response = TalkToYourApp::Plugins::Health::Tools::RunCheck.dispatch({ name: "fast" }, plugin_name: :health)
    payload = JSON.parse(response.content.first[:text])
    assert_equal true, payload["passed"]
  end

  def test_run_bare_integer_is_rejected_not_coerced
    TalkToYourApp.configuration.health_check(:count_only) { 0 }
    response = TalkToYourApp::Plugins::Health::Tools::RunCheck.dispatch({ name: "count_only" }, plugin_name: :health)
    assert response.error?
    assert_match(/expected a boolean or \[passed, value\]/, response.content.first[:text])
  end

  def test_run_nil_is_rejected_not_coerced
    TalkToYourApp.configuration.health_check(:oops) {} # rubocop:disable Lint/EmptyBlock
    response = TalkToYourApp::Plugins::Health::Tools::RunCheck.dispatch({ name: "oops" }, plugin_name: :health)
    assert response.error?
    assert_match(/expected a boolean or \[passed, value\]/, response.content.first[:text])
  end

  def test_run_empty_string_is_rejected_not_coerced
    TalkToYourApp.configuration.health_check(:blank) { "" }
    response = TalkToYourApp::Plugins::Health::Tools::RunCheck.dispatch({ name: "blank" }, plugin_name: :health)
    assert response.error?
    assert_match(/expected a boolean or \[passed, value\]/, response.content.first[:text])
  end

  def test_run_wrong_size_array_is_rejected
    TalkToYourApp.configuration.health_check(:bad_shape) { [true, "value", "extra"] }
    response = TalkToYourApp::Plugins::Health::Tools::RunCheck.dispatch({ name: "bad_shape" }, plugin_name: :health)
    assert response.error?
    assert_match(/expected exactly \[passed, value\]/, response.content.first[:text])
  end

  def test_run_array_with_non_boolean_first_element_is_rejected
    TalkToYourApp.configuration.health_check(:bad_first) { ["yes", "value"] }
    response = TalkToYourApp::Plugins::Health::Tools::RunCheck.dispatch({ name: "bad_first" }, plugin_name: :health)
    assert response.error?
    assert_match(/expected exactly \[passed, value\]/, response.content.first[:text])
  end
end
