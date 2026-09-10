# frozen_string_literal: true

require_relative "../../plugin"
require_relative "tools/list_checks"
require_relative "tools/run_check"

module TalkToYourApp
  module Plugins
    module Health
      # Exposes operator-registered health checks (`config.health_check(:name) { ... }`)
      # as MCP tools: `health.list` to discover names, `health.run` to execute one
      # and get pass/fail plus its value. v1 is deliberately minimal — no
      # scheduling, no aggregation across runs, no alerting, no historical
      # storage (see docs/brainstorms/talk-to-your-app-gem-v1-requirements.md,
      # R20-R22). A check is arbitrary operator Ruby, so it does not use the
      # plugin's `connection:` wiring the way DB/Flipper do — checks reach
      # whatever the app already has (a model, a service object, a DB call)
      # directly, same as custom_tools.
      class Plugin < TalkToYourApp::Plugin
        tools Tools::ListChecks, Tools::RunCheck
      end
    end
  end
end

TalkToYourApp.register_plugin(:health, TalkToYourApp::Plugins::Health::Plugin)
