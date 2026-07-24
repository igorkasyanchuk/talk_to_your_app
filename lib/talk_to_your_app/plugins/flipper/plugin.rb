# frozen_string_literal: true

require_relative "../../plugin"
require_relative "tools/list_flags"
require_relative "tools/read_flag"
require_relative "tools/enable_flag"
require_relative "tools/disable_flag"
require_relative "tools/enabled_flags"

module TalkToYourApp
  module Plugins
    # The Flipper plugin: list flags, read a flag's state (globally or for an
    # actor), and enable/disable flags globally or per actor. All operations run
    # through the connection the operator wires in (config.plugin :flipper,
    # connection: :your_writer); boot fails unless that connection is declared
    # role: :writing, since Flipper writes flag state.
    module Flipper
      # A minimal actor: Flipper only needs an object responding to #flipper_id.
      # We reconstitute one from a class name + id rather than loading the host's
      # real record, which avoids coupling to the host's user model and any
      # privilege leak from instantiating it.
      Actor = Struct.new(:flipper_id)

      module_function

      # Builds an actor from a class name + id, or nil when none was supplied.
      def actor_for(actor_class, actor_id)
        return nil if actor_class.nil? || actor_id.nil?

        Actor.new("#{actor_class};#{actor_id}")
      end

      # True when a call names more than one gate dimension (actor, group,
      # percentage). gate_from would silently pick one by precedence and drop the
      # rest, so the tools reject the call instead.
      def gate_conflict?(args)
        selectors = []
        selectors << :actor if args[:actor_class] && args[:actor_id]
        selectors << :group if args[:group]
        selectors << :percentage unless args[:percentage].nil?
        selectors.size > 1
      end

      def invalid_gate_selector_message(args)
        if args.key?(:actor_class) != args.key?(:actor_id)
          "Specify both actor_class and actor_id when targeting an actor."
        elsif args.key?(:percentage_type) && args[:percentage].nil?
          "Specify percentage when using percentage_type."
        elsif gate_conflict?(args)
          "Specify exactly one gate: an actor, a group, or a percentage."
        end
      end

      # Resolves which Flipper gate a tool call targets from its arguments. In
      # precedence order: a specific actor, a named group, a percentage, else the
      # global boolean gate.
      def gate_from(args)
        if (actor = actor_for(args[:actor_class], args[:actor_id]))
          { type: :actor, actor: actor }
        elsif args[:group]
          { type: :group, group: args[:group].to_sym }
        elsif !args[:percentage].nil?
          type = args[:percentage_type] == "time" ? :percentage_of_time : :percentage_of_actors
          { type: type, percentage: args[:percentage].to_i }
        else
          { type: :boolean }
        end
      end

      # Applies :enable or :disable across the resolved gate. Every branch is an
      # explicit named call so the dispatch is statically obvious and an unknown
      # gate type fails fast rather than silently toggling the boolean gate.
      def apply(operation, name, gate)
        enabling = operation == :enable
        case gate[:type]
        when :boolean
          enabling ? ::Flipper.enable(name) : ::Flipper.disable(name)
        when :actor
          enabling ? ::Flipper.enable(name, gate[:actor]) : ::Flipper.disable(name, gate[:actor])
        when :group
          enabling ? ::Flipper.enable_group(name, gate[:group]) : ::Flipper.disable_group(name, gate[:group])
        when :percentage_of_actors
          enabling ? ::Flipper.enable_percentage_of_actors(name, gate[:percentage]) : ::Flipper.disable_percentage_of_actors(name)
        when :percentage_of_time
          enabling ? ::Flipper.enable_percentage_of_time(name, gate[:percentage]) : ::Flipper.disable_percentage_of_time(name)
        else
          raise ArgumentError, "unknown Flipper gate type: #{gate[:type].inspect}"
        end
      end

      # Reads a flag's effective state, globally or for an actor. Unknown flags
      # read false.
      def state(name, actor)
        actor ? ::Flipper.enabled?(name, actor) : ::Flipper.enabled?(name)
      end

      # The full per-gate configuration of a flag, for read_flag.
      def gate_values(name)
        values = ::Flipper[name].gate_values
        {
          boolean: values.boolean,
          actors: values.actors.to_a,
          groups: values.groups.to_a,
          percentage_of_actors: values.percentage_of_actors,
          percentage_of_time: values.percentage_of_time,
        }
      end

      # A flag is "enabled" if any gate is active.
      def active?(gates)
        gates[:boolean] ||
          gates[:actors].any? ||
          gates[:groups].any? ||
          gates[:percentage_of_actors].to_i.positive? ||
          gates[:percentage_of_time].to_i.positive?
      end

      # Last-change timestamps for many flags in a single query, keyed by flag
      # name, read from the flipper_features table when the ActiveRecord adapter
      # is in use. Flipper records no enable/disable history, so updated_at is
      # the last time the feature row changed. Returns an empty hash (callers
      # fall back to nil timestamps) for non-ActiveRecord adapters. Batched to
      # avoid an N+1 across all flags.
      def preload_timestamps(names)
        return {} unless defined?(::Flipper::Adapters::ActiveRecord::Feature)

        ::Flipper::Adapters::ActiveRecord::Feature.where(key: names.map(&:to_s)).each_with_object({}) do |row, acc|
          acc[row.key] = { created_at: row.created_at&.utc&.iso8601, updated_at: row.updated_at&.utc&.iso8601 }
        end
      rescue StandardError
        {}
      end

      class Plugin < TalkToYourApp::Plugin
        requires_gem "Flipper", gem_name: "flipper"
        tools Tools::ListFlags, Tools::ReadFlag, Tools::EnableFlag, Tools::DisableFlag, Tools::EnabledFlags

        # Flipper toggles flags, so it needs a writer — `connection: false` is
        # invalid, and a :reading connection fails at boot (previously a misrole'd
        # connection booted and failed only on the first write).
        def self.validate_enablement!(options)
          unless options[:connection]
            raise TalkToYourApp::ConfigurationError,
              "talk_to_your_app: the Flipper plugin requires a connection declared role: :writing — " \
              "`config.plugin :flipper, connection: :your_writer`. `connection: false` is not valid."
          end

          spec = wired_spec(options) # nil for an unregistered name (ConnectionRegistry.validate! owns that)
          return unless spec&.reading?

          raise TalkToYourApp::ConfigurationError,
            "talk_to_your_app: the Flipper plugin's connection #{spec.name.inspect} must be declared with " \
            "role: :writing (got role: #{spec.role.inspect}). Flipper writes flag state."
        end
      end
    end
  end
end

TalkToYourApp.register_plugin(:flipper, TalkToYourApp::Plugins::Flipper::Plugin)
