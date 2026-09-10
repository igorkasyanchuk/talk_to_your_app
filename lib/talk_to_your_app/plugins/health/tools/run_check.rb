# frozen_string_literal: true

require "timeout"
require_relative "../../../tool"

module TalkToYourApp
  module Plugins
    module Health
      module Tools
        class RunCheck < TalkToYourApp::Tool
          name        "health.run"
          description "Run a named health check and return pass/fail plus its value."
          argument    :name, :string, required: true, description: "Health check name, from health.list."

          def call(args, _ctx)
            check = TalkToYourApp.configuration.health_checks[args[:name].to_sym]
            return error("Unknown health check: #{args[:name].inspect}. Call health.list for the registered names.") unless check

            result = Timeout.timeout(check[:timeout], HealthCheckTimeout) { check[:block].call }
            normalized = normalize(args[:name], result)
            return error(normalized) if normalized.is_a?(String)

            passed, value = normalized
            json(name: args[:name], passed: passed, value: value)
          rescue HealthCheckTimeout
            log_failure(args[:name], "timed out after #{check[:timeout]}s")
            json(name: args[:name], passed: false, value: nil, error: "timed out after #{check[:timeout]}s")
          rescue StandardError => e
            log_failure(args[:name], "#{e.class}: #{e.message}")
            json(name: args[:name], passed: false, value: nil, error: e.class.name)
          end

          private

          class HealthCheckTimeout < StandardError; end

          def log_failure(name, message)
            TalkToYourApp.configuration.logger&.warn("talk_to_your_app: health check #{name.inspect} failed: #{message}")
          rescue StandardError
            nil
          end

          def normalize(check_name, result)
            case result
            when Array
              unless result.size == 2 && [true, false].include?(result[0])
                return "health check #{check_name.inspect} returned an array of shape #{result.inspect} — " \
                       "expected exactly [passed, value] with passed a true/false."
              end
              result
            when true, false
              [result, nil]
            else
              "health check #{check_name.inspect} returned #{result.class}, expected a boolean or [passed, value]."
            end
          end
        end
      end
    end
  end
end
