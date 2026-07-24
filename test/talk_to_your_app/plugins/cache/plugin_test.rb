# frozen_string_literal: true

require "test_helper"

class TalkToYourApp::Plugins::CacheTest < TalkToYourApp::TestCase
  def test_registered_under_cache
    assert_equal TalkToYourApp::Plugins::Cache::Plugin, TalkToYourApp::PluginRegistry[:cache]
  end

  def test_clear_wipes_the_rails_cache
    Rails.cache.write("ttya-probe", "warm")
    assert_equal "warm", Rails.cache.read("ttya-probe")

    response = TalkToYourApp::Plugins::Cache::ClearTool.dispatch({}, plugin_name: :cache)

    refute response.error?
    assert_nil Rails.cache.read("ttya-probe")
    payload = JSON.parse(response.content.first[:text])
    assert_equal true, payload["cleared"]
    assert_equal Rails.cache.class.name, payload["store"]
  end
end
