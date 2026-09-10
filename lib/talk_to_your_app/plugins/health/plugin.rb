# frozen_string_literal: true

require_relative "../../plugin"
require_relative "tools/list_checks"
require_relative "tools/run_check"

module TalkToYourApp
  module Plugins
    module Health
      class Plugin < TalkToYourApp::Plugin
        tools Tools::ListChecks, Tools::RunCheck
      end
    end
  end
end

TalkToYourApp.register_plugin(:health, TalkToYourApp::Plugins::Health::Plugin)
