# frozen_string_literal: true

require "rails/railtie"

module TalkToYourApp
  # Wires the gem into the Rails boot sequence. The headline behavior is the
  # fail-closed validation initializer: every required piece of configuration is
  # checked once, at the end of boot, so misconfiguration surfaces at deploy
  # time rather than on the first MCP request.
  class Railtie < ::Rails::Railtie
    # The gem owns the custom_tools/ subdir of app/talk_to_your_app/ and requires
    # its files itself. Tell every autoloader to ignore that subdir before it is
    # set up, so eager loading (production, zeitwerk:check) doesn't expect
    # constants that aren't there. Anything else a host places under
    # app/talk_to_your_app/ is left to Zeitwerk to autoload normally.
    initializer "talk_to_your_app.ignore_app_dir", before: :set_autoload_paths do |app|
      next unless ::Rails.respond_to?(:autoloaders)

      dir = app.root.join(TalkToYourApp::APP_DIR, "custom_tools")
      ::Rails.autoloaders.each { |loader| loader.ignore(dir) }
    end

    # Runs after the host app's config/initializers (where the operator calls
    # TalkToYourApp.configure) have loaded.
    initializer "talk_to_your_app.validate", after: :load_config_initializers do
      config.after_initialize do
        TalkToYourApp.configuration.logger ||= Rails.logger
        TalkToYourApp::Railtie.validate_boot!
      end
    end

    # Aggregated fail-closed validation. With nothing enabled (the default),
    # validation is a no-op and the gem boots silently. With `config.enabled`
    # false the gem serves nothing, so there is nothing to validate — boot
    # silently. (Re-enabling means a reboot, where this runs again and fails
    # closed on missing auth or connections.)
    def self.validate_boot!
      return unless TalkToYourApp.configuration.enabled

      TalkToYourApp::PluginRegistry.validate_enabled!
      TalkToYourApp::ConnectionRegistry.validate!(TalkToYourApp.required_connections)
      validate_auth!
    end

    # At least one auth mechanism must be configured once the endpoint serves
    # tools. With no plugins enabled (the default) there is nothing to protect,
    # so the gem still boots cleanly with no configuration at all.
    def self.validate_auth!
      return if TalkToYourApp.configuration.enabled_plugins.empty?

      validate_api_key_values!
      return if TalkToYourApp.configuration.auth_configured?

      raise ConfigurationError,
        "talk_to_your_app: no authentication configured. Set `config.api_keys` or `config.basic_auth` " \
        "in config/initializers/talk_to_your_app.rb (the MCP endpoint must not be exposed unauthenticated)."
    end

    # A blank API key can never authenticate anything (an empty Bearer token is
    # rejected before comparison), so an entry with one is a dead credential —
    # yet it counts toward `auth_configured?` and the app would boot serving 401
    # to every request. This is the `config.api_keys = { "x" => ENV["TTYA_KEY"] }`
    # footgun with the variable unset: fail at deploy, like every other missing
    # piece of configuration, rather than shipping an endpoint nobody can reach.
    def self.validate_api_key_values!
      blank = TalkToYourApp.configuration.api_keys.select { |_name, key| key.to_s.strip.empty? }.keys
      return if blank.empty?

      raise ConfigurationError,
        "talk_to_your_app: API key(s) #{blank.map(&:to_s).inspect} have a blank value — a blank key can " \
        "never authenticate, so the endpoint would reject every request. Check that the ENV var or " \
        "credential backing each key in `config.api_keys` is actually set."
    end
  end
end
