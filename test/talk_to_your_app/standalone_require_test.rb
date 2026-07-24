# frozen_string_literal: true

require "test_helper"
require "open3"

# The rest of the suite loads the dummy app first, so every ActiveSupport file is
# already in memory and a missing `require` in the gem's own load path is
# invisible. These tests load the gem in a fresh process instead — the only way
# to catch a load-order bug that a Rails boot papers over.
class TalkToYourApp::StandaloneRequireTest < TalkToYourApp::TestCase
  LIB = File.expand_path("../../lib", __dir__)

  def load_in_subprocess(script)
    Open3.capture2e(RbConfig.ruby, "-I", LIB, "-e", script)
  end

  def test_gem_loads_without_rails_booted
    output, status = load_in_subprocess('require "talk_to_your_app"; print TalkToYourApp::VERSION')
    assert status.success?, "`require \"talk_to_your_app\"` failed outside a Rails boot:\n#{output}"
    assert_equal TalkToYourApp::VERSION, output
  end

  # The railtie is conditional on Rails::Railtie being defined, so requiring the
  # gem after `rails` must also work — that is the real-world path.
  def test_gem_loads_after_rails
    output, status = load_in_subprocess('require "rails"; require "talk_to_your_app"; print TalkToYourApp::Railtie.name')
    assert status.success?, "`require \"talk_to_your_app\"` failed after requiring rails:\n#{output}"
    assert_equal "TalkToYourApp::Railtie", output
  end
end
