# frozen_string_literal: true

module TalkToYourApp
  # Module-level registry of known plugins, keyed by name. Registration is
  # explicit (`TalkToYourApp.register_plugin(:db, Plugins::Db)`) rather than
  # autoloaded by convention, so the contract is visible. Iteration follows
  # registration (Hash insertion) order.
  module PluginRegistry
    module_function

    def registry
      @registry ||= {}
    end

    def register(name, plugin_class)
      plugin_class.plugin_name = name.to_sym
      registry[name.to_sym] = plugin_class
    end

    def [](name)
      registry[name.to_sym]
    end

    def registered?(name)
      registry.key?(name.to_sym)
    end

    # Boot validation for the set of plugins the operator enabled: each must be
    # registered, and any soft-dependency gem it declares must be loadable.
    # Connection requirements are validated separately by ConnectionRegistry.
    def validate_enabled!
      TalkToYourApp.enabled_plugins.each do |name, plugin_class, opts|
        unless plugin_class
          raise ConfigurationError,
            "talk_to_your_app: plugin #{name.inspect} is enabled but no plugin is registered under that name."
        end

        if (req = plugin_class.required_gem) && !Object.const_defined?(req[:const])
          raise ConfigurationError,
            "talk_to_your_app: Plugin #{name.inspect} requires the `#{req[:gem_name]}` gem in your Gemfile " \
            "(constant #{req[:const]} is not defined)."
        end

        # Every plugin must declare connection: explicitly — a connection name,
        # or `false` to opt out (e.g. the Sidekiq adapter reads Redis, not SQL).
        # This is enforced before validate_enablement! so a plugin's own role
        # check can't pre-empt the more actionable message. The value itself
        # (real name vs false) is validated by ConnectionRegistry and the
        # plugin's own validate_enablement!.
        unless opts.key?(:connection)
          raise ConfigurationError,
            "talk_to_your_app: plugin #{name.inspect} must declare a connection. " \
            "Wire one with `config.plugin #{name.inspect}, connection: :your_connection`, " \
            "or `connection: false` to opt out (no database access)."
        end

        plugin_class.validate_enablement!(opts)
      end
    end
  end
end
