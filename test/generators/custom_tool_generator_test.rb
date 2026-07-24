# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/talk_to_your_app/custom_tool/custom_tool_generator"

class CustomToolGeneratorTest < Rails::Generators::TestCase
  tests TalkToYourApp::Generators::CustomToolGenerator
  destination File.expand_path("../tmp/generator", __dir__)
  setup :prepare_destination

  def test_creates_a_custom_tool_in_app_talk_to_your_app
    run_generator ["MakeAdmin"]
    assert_file "app/talk_to_your_app/custom_tools/make_admin.rb" do |content|
      assert_match(/class MakeAdmin < TalkToYourApp::Tool/, content)
      assert_match(/name\s+"custom\.make_admin"/, content)
      assert_match(/def call\(args, ctx\)/, content)
    end
  end

  def test_underscores_multiword_names
    run_generator ["ToggleActive"]
    assert_file "app/talk_to_your_app/custom_tools/toggle_active.rb" do |content|
      assert_match(/name\s+"custom\.toggle_active"/, content)
    end
  end

  def test_namespaced_tool_is_module_wrapped_and_path_named
    run_generator ["Admin/MakeAdmin"]
    assert_file "app/talk_to_your_app/custom_tools/admin/make_admin.rb" do |content|
      assert_match(/module Admin/, content)
      assert_match(/class MakeAdmin < TalkToYourApp::Tool/, content)
      assert_match(/name\s+"custom\.admin\.make_admin"/, content)
    end
  end
end
