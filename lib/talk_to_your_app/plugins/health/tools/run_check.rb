# frozen_string_literal: true

require_relative "../../../tool"

module TalkToYourApp
  module Plugins
    module Health
      module Tools
        # Runs one registered health check by name and reports pass/fail plus
        # whatever value the check produced. A check is operator Ruby code, so a
        # raising check is treated as a failed check (not a 500) — the tool
        # reports it the same way the DB/Flipper plugins turn a backend error
        # into an MCP tool error: caught, surfaced as `passed: false` with the
        # exception message, never propagated.
        class RunCheck < TalkToYourApp::Tool
          name        "health.run"
          description "Run a named health check and return pass/fail plus its value."
          argument    :name, :string, required: true, description: "Health check name, from health.list."

          def call(args, _ctx)
            check = TalkToYourApp.configuration.health_checks[args[:name].to_sym]
            return error("Unknown health check: #{args[:name].inspect}. Call health.list for the registered names.") unless check

            passed, value = normalize(check.call)
            json(name: args[:name], passed: passed, value: value)
          rescue StandardError => e
            json(name: args[:name], passed: false, value: nil, error: "#{e.class}: #{e.message}")
          end

          private

          # A check returns either a bare boolean or a [passed, value] pair.
          # Anything else is coerced to its truthiness with a nil value, so an
          # operator's check can return e.g. an ActiveRecord relation (truthy
          # when non-empty is NOT what #present? does — checks should return
          # an explicit boolean or pair; this is a last-resort coercion, not
          # the documented contract).
          def normalize(result)
            case result
            when Array
              passed, value = result
              [!!passed, value]
            when true, false
              [result, nil]
            else
              [!!result, nil]
            end
          end
        end
      end
    end
  end
end
