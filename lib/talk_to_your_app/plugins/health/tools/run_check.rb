# frozen_string_literal: true

require "timeout"
require_relative "../../../tool"

module TalkToYourApp
  module Plugins
    module Health
      module Tools
        # Runs one registered health check by name and reports pass/fail plus
        # whatever value the check produced.
        #
        # Two failure modes, handled differently:
        #
        # 1. The check raises, or times out. Treated as a failed check (not a
        #    500) — surfaced as `passed: false` with an error, never propagated,
        #    the same posture the DB/Flipper plugins take toward backend errors.
        #    Also logged server-side (warn level) so it shows up in ops
        #    monitoring even though the MCP response stays a graceful failure —
        #    a raising check is exactly the kind of thing an operator watching
        #    logs wants to know about, and the audit logger's `outcome` field
        #    alone wouldn't flag it (this tool never returns an `error()`
        #    response for a raising check, by design, so `AuditLogger` sees a
        #    normal `success`).
        # 2. The check returns something other than the documented
        #    `bool | [bool, value]` contract. Rejected outright as a tool error
        #    rather than guessed at — coercing e.g. `0` or `nil` into a pass/fail
        #    via Ruby truthiness would silently misreport the very thing this
        #    tool exists to report accurately (see #normalize).
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
            # The rescued code is arbitrary operator Ruby (the README's own
            # examples touch third-party HTTP clients), so e.message can easily
            # embed a URL with a token, an internal hostname, connection
            # details, etc. Log the full exception server-side; return only the
            # class name to the MCP client, which is authenticated but not
            # necessarily trusted with backend internals.
            log_failure(args[:name], "#{e.class}: #{e.message}")
            json(name: args[:name], passed: false, value: nil, error: e.class.name)
          end

          private

          # Distinct from StandardError so the outer rescue can tell "the check
          # took too long" apart from "the check raised" without inspecting
          # Timeout::Error's message (which #call's timeout: keyword would
          # otherwise collide with, since Timeout.timeout raises the class
          # passed as its second argument, not the built-in Timeout::Error, to
          # keep an operator's own `rescue Timeout::Error` inside a check from
          # swallowing ours).
          class HealthCheckTimeout < StandardError; end

          def log_failure(name, message)
            TalkToYourApp.configuration.logger&.warn("talk_to_your_app: health check #{name.inspect} failed: #{message}")
          rescue StandardError
            # A logging failure must never replace the tool's result — same
            # defensive posture AuditLogger takes around its own emit.
            nil
          end

          # A check must return a bare boolean or a [passed, value] pair — no
          # other shape is guessed at. Ruby's truthiness (only nil/false are
          # falsy) makes silent coercion dangerous here: a check that
          # accidentally returns `0` (e.g. a bare `recent.count`, a very
          # plausible slip given the README's own `[cond, recent.count]`
          # pattern) would coerce to `passed: true` even though zero recent
          # items plausibly means "nothing ran". A check whose last expression
          # accidentally evaluates to `nil` would coerce to `passed: false`,
          # masking an authoring bug as a real outage. Returns `[passed, value]`
          # on a valid shape, or a String error message on an invalid one —
          # the caller branches on the return type.
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
