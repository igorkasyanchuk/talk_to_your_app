# frozen_string_literal: true

require_relative "../../../tool"

module TalkToYourApp
  module Plugins
    module Flipper
      module Tools
        # Enables a flag. With no gate arguments it enables globally (boolean
        # gate); supply actor_class+actor_id for a single actor, group for a
        # registered group, or percentage (+ optional percentage_type) for a
        # percentage rollout.
        class EnableFlag < TalkToYourApp::Tool
          name        "flipper.enable_flag"
          description "Enable a feature flag globally, for an actor, a group, or a percentage."
          argument    :name, :string, required: true, description: "Flag name."
          argument    :actor_class, :string, description: "Actor class name, e.g. \"User\"."
          argument    :actor_id, :string, description: "Actor id, e.g. \"42\"."
          argument    :group, :string, description: "A registered Flipper group name."
          argument    :percentage, :integer, minimum: 0, maximum: 100,
            description: "Percentage rollout (0-100)."
          argument    :percentage_type, :string, enum: %w[actors time],
            description: "Whether percentage applies to actors or time."

          def call(args, ctx)
            if (message = Flipper.invalid_gate_selector_message(args))
              return error(message)
            end

            gate = Flipper.gate_from(args)
            result = ctx.connection do
              Flipper.apply(:enable, args[:name], gate)
              Flipper.gate_values(args[:name])
            end
            json(name: args[:name], enabled: Flipper.active?(result), gate_type: gate[:type], gates: result)
          rescue StandardError => e
            error("Flipper storage unavailable: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
