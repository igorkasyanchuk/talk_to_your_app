# frozen_string_literal: true

require_relative "../../../tool"

module TalkToYourApp
  module Plugins
    module Flipper
      module Tools
        # Reads a flag's effective state plus its full per-gate configuration.
        # With an actor, `enabled` reflects that actor; otherwise it reflects the
        # global state. Unknown flags read as disabled.
        class ReadFlag < TalkToYourApp::Tool
          name        "flipper.read_flag"
          description "Read a feature flag's state and per-gate configuration."
          argument    :name, :string, required: true, description: "Flag name."
          argument    :actor_class, :string, description: "Actor class name, e.g. \"User\"."
          argument    :actor_id, :string, description: "Actor id, e.g. \"42\"."

          def call(args, ctx)
            if (message = Flipper.invalid_gate_selector_message(args))
              return error(message)
            end

            actor = Flipper.actor_for(args[:actor_class], args[:actor_id])
            enabled, gates = ctx.connection do
              [Flipper.state(args[:name], actor), Flipper.gate_values(args[:name])]
            end
            json(name: args[:name], enabled: enabled, actor: actor&.flipper_id, gates: gates)
          rescue StandardError => e
            error("Flipper storage unavailable: #{e.class}: #{e.message}")
          end
        end
      end
    end
  end
end
