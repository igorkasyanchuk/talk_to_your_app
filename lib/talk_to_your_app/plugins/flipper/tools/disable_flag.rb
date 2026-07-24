# frozen_string_literal: true

require_relative "../../../tool"

module TalkToYourApp
  module Plugins
    module Flipper
      module Tools
        # Disables a flag. With no gate arguments it disables globally; supply
        # actor_class+actor_id, group, or percentage (+ optional percentage_type)
        # to clear that specific gate.
        class DisableFlag < TalkToYourApp::Tool
          name        "flipper.disable_flag"
          description "Disable a feature flag globally, for an actor, a group, or a percentage."
          argument    :name, :string, required: true, description: "Flag name."
          argument    :actor_class, :string, description: "Actor class name, e.g. \"User\"."
          argument    :actor_id, :string, description: "Actor id, e.g. \"42\"."
          argument    :group, :string, description: "A registered Flipper group name."
          argument    :percentage, :integer, minimum: 0, maximum: 100,
            description: "Percentage gate to clear (0-100); the value is ignored on disable."
          argument    :percentage_type, :string, enum: %w[actors time],
            description: "Whether percentage applies to actors or time."

          def call(args, ctx)
            if (message = Flipper.invalid_gate_selector_message(args))
              return error(message)
            end

            gate = Flipper.gate_from(args)
            result = ctx.connection do
              Flipper.apply(:disable, args[:name], gate)
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
