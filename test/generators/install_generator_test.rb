# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/talk_to_your_app/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests TalkToYourApp::Generators::InstallGenerator
  destination File.expand_path("../tmp/generator", __dir__)
  setup :prepare_destination

  def test_creates_initializer_from_template
    run_generator
    assert_file "config/initializers/talk_to_your_app.rb" do |content|
      assert_match(/TalkToYourApp\.configure do \|config\|/, content)
      assert_match(/config\.mount_at/, content)
      assert_match(/config\.api_keys/, content)
      assert_match(/config\.enabled/, content)
      assert_match(/config\.plugin :db, connection:/, content)
      assert_match(/config\.stateless = true if Rails\.env\.production\?/, content)
      assert_match(/Strongly recommended in production/, content)
      assert_match(/SECURITY\.md/, content)
    end
  end
end
