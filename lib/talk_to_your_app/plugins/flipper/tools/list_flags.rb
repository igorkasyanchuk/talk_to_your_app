# frozen_string_literal: true

require_relative "../../../tool"

module TalkToYourApp
  module Plugins
    module Flipper
      module Tools
        # Lists the keys of all configured feature flags.
        class ListFlags < TalkToYourApp::Tool
          name        "flipper.list_flags"
          description "List all configured feature flag names."

          def call(_args, ctx)
            names = ctx.connection { ::Flipper.features.map(&:key) }
            json(flags: names.sort)
          rescue StandardError => e
            error("Flipper storage unavailable: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
