# frozen_string_literal: true

require "test_helper"

class TalkToYourApp::ConfigurationTest < TalkToYourApp::TestCase
  def test_mount_at_defaults_to_mcp
    assert_equal "/mcp", TalkToYourApp.configuration.mount_at
  end

  def test_configure_sets_and_reads_back_mount_at
    TalkToYourApp.configure { |c| c.mount_at = "/foo" }
    assert_equal "/foo", TalkToYourApp.configuration.mount_at
  end

  def test_configure_returns_the_configuration
    result = TalkToYourApp.configure { |c| c.mount_at = "/bar" }
    assert_same TalkToYourApp.configuration, result
  end

  def test_configure_twice_merges_rather_than_overwriting
    TalkToYourApp.configure { |c| c.mount_at = "/first" }
    TalkToYourApp.configure { |_c| } # second call sets nothing
    assert_equal "/first", TalkToYourApp.configuration.mount_at,
      "second configure call must not reset earlier settings"
  end

  def test_enabled_defaults_to_true
    assert TalkToYourApp.configuration.enabled,
      "the gem must be on by default; config.enabled is an opt-out switch"
  end

  def test_configure_can_disable_the_gem
    TalkToYourApp.configure { |c| c.enabled = false }
    refute TalkToYourApp.configuration.enabled
  end

  def test_enabled_coerces_stringy_falsey_values
    { "false" => false, "0" => false, "off" => false, "no" => false, "" => false,
      "   " => false, "  FALSE  " => false, "true" => true, "1" => true }.each do |input, expected|
      TalkToYourApp.reset_configuration!
      TalkToYourApp.configure { |c| c.enabled = input }
      assert_equal expected, TalkToYourApp.configuration.enabled,
        "enabled = #{input.inspect} should coerce to #{expected}"
    end
  end

  def test_enabled_coerces_non_string_values
    { nil => false, 0 => false, 1 => true, 2 => true }.each do |input, expected|
      TalkToYourApp.reset_configuration!
      TalkToYourApp.configure { |c| c.enabled = input }
      assert_equal expected, TalkToYourApp.configuration.enabled,
        "enabled = #{input.inspect} should coerce to #{expected}"
    end
  end

  def test_plugin_rewired_to_a_different_connection_raises
    error = assert_raises(TalkToYourApp::ConfigurationError) do
      TalkToYourApp.configure do |c|
        c.plugin :db, connection: :read
        c.plugin :db, connection: :write
      end
    end
    assert_match(/re-wire/, error.message)
  end

  def test_plugin_redeclaration_merges_options
    TalkToYourApp.configure do |c|
      c.plugin :db, connection: :read
      c.plugin :db, max_rows: 50 # refine without re-stating the connection
    end
    assert_equal({ connection: :read, max_rows: 50 }, TalkToYourApp.configuration.enabled_plugins[:db])
  end

  def test_stateless_defaults_to_false
    refute TalkToYourApp.configuration.stateless,
      "stateless must default off so single-worker hosts keep SSE/notifications"
  end

  def test_configure_sets_and_reads_back_stateless
    TalkToYourApp.configure { |c| c.stateless = true }
    assert TalkToYourApp.configuration.stateless
  end
end
