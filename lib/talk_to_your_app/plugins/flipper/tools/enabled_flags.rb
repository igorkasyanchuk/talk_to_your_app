# frozen_string_literal: true

require_relative "../../../tool"

module TalkToYourApp
  module Plugins
    module Flipper
      module Tools
        # Lists the currently-enabled feature flags (any active gate) with their
        # per-gate configuration and last-change timestamps, for inspection.
        # Flipper does not record full enable/disable history; `updated_at` is
        # the last time the feature changed (ActiveRecord adapter only).
        class EnabledFlags < TalkToYourApp::Tool
          name        "flipper.enabled_flags"
          description "List currently-enabled feature flags with their gates and last-change timestamps."

          def call(_args, ctx)
            flags = ctx.connection do
              features = ::Flipper.features.to_a
              timestamps = Flipper.preload_timestamps(features.map(&:key))
              no_timestamps = { created_at: nil, updated_at: nil }
              features.filter_map do |feature|
                gates = Flipper.gate_values(feature.key)
                next unless Flipper.active?(gates)

                { name: feature.key, enabled: true, gates: gates }.merge(timestamps.fetch(feature.key, no_timestamps))
              end
            end
            json(
              enabled_flags: flags.sort_by { |f| f[:name] },
              note: "Flipper does not store enable/disable history; updated_at is the last feature change (ActiveRecord adapter only).",
            )
          rescue StandardError => e
            error("Flipper storage unavailable: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
