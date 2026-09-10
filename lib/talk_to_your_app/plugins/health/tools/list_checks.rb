# frozen_string_literal: true

require_relative "../../../tool"

module TalkToYourApp
  module Plugins
    module Health
      module Tools
        # Lists the names of every health check the operator registered via
        # `config.health_check(:name) { ... }`.
        class ListChecks < TalkToYourApp::Tool
          name        "health.list"
          description "List the names of registered health checks."

          def call(_args, _ctx)
            json(checks: TalkToYourApp.configuration.health_checks.keys.map(&:to_s).sort)
          end
        end
      end
    end
  end
end
