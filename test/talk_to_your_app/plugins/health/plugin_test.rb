# frozen_string_literal: true

require "test_helper"

class TalkToYourApp::Plugins::HealthTest < TalkToYourApp::TestCase
  def teardown
    super
    TalkToYourApp.configuration.health_checks.clear
  end

  def test_registered_under_health
    assert_equal TalkToYourApp::Plugins::Health::Plugin, TalkToYourApp::PluginRegistry[:health]
  end

  def test_health_check_requires_a_block
    error = assert_raises(ArgumentError) { TalkToYourApp.configuration.health_check(:no_block) }
    assert_match(/block is required/, error.message)
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
    assert_match(/boom/, payload["error"])
  end

  def test_run_truthy_non_boolean_result_is_coerced
    TalkToYourApp.configuration.health_check(:truthy) { "anything" }
    response = TalkToYourApp::Plugins::Health::Tools::RunCheck.dispatch({ name: "truthy" }, plugin_name: :health)
    payload = JSON.parse(response.content.first[:text])
    assert_equal true, payload["passed"]
    assert_nil payload["value"]
  end
end
