# frozen_string_literal: true

require_relative "talk_to_your_app/version"
require_relative "talk_to_your_app/configuration"
require_relative "talk_to_your_app/connection_registry"
require_relative "talk_to_your_app/current"
require_relative "talk_to_your_app/audit_logger"
require_relative "talk_to_your_app/tool"
require_relative "talk_to_your_app/plugin"
require_relative "talk_to_your_app/plugin_registry"
require_relative "talk_to_your_app/transport/rails_mount"

# Rails-native MCP server. See README for the configuration reference.
module TalkToYourApp
  # Convention directory for host-app extensions: custom_tools/ holds Tool
  # subclasses. The railtie tells Zeitwerk to ignore this tree (the gem requires
  # the files itself via require_app_dir), so eager loading doesn't expect
  # constants the loader would otherwise infer from the path.
  APP_DIR = "app/talk_to_your_app"

  class << self
    # Yields the configuration singleton for the host app's initializer.
    #
    #   TalkToYourApp.configure do |config|
    #     config.mount_at = "/mcp"
    #   end
    #
    # Calling this more than once merges into the same object rather than
    # replacing it.
    def configure
      yield(configuration) if block_given?
      configuration
    end

    def configuration
      @configuration ||= Configuration.new
    end

    # Test seam: drop all configuration back to defaults.
    def reset_configuration!
      @configuration = Configuration.new
      @rack_app = nil
      ConnectionRegistry.reset!
    end

    # The Rack application to mount in the host app's routes:
    #
    #   mount TalkToYourApp.rack_app, at: TalkToYourApp.configuration.mount_at
    #
    # Built once from the enabled plugins. reset_configuration! clears it.
    def rack_app
      @rack_app ||= Transport::RailsMount.build
    end

    # Registers a plugin class under a name so it can be enabled in the
    # initializer. Bundled plugins register themselves on load; plugin authors
    # call this from their own code.
    def register_plugin(name, plugin_class)
      PluginRegistry.register(name, plugin_class)
    end

    # The enabled plugins as [name, plugin_class, options] triples, in the order
    # they were enabled. plugin_class is nil if the name was never registered
    # (validation surfaces that at boot).
    def enabled_plugins
      configuration.enabled_plugins.map do |name, opts|
        [name, PluginRegistry[name], opts]
      end
    end

    # Connections required by the enabled plugins and their tools, as
    # [connection_name, requester_label] pairs, for ConnectionRegistry.validate!.
    # Two sources: the operator's `connection:` option on each enabled plugin,
    # and any tool that declares a static `connection` DSL (custom tools). Both
    # must be registered, so both fail closed at boot rather than at first call.
    # `connection: false` (opted out) and a missing option are skipped — the
    # missing-option error is owned by PluginRegistry.validate_enabled! — so only
    # a real name reaches ConnectionRegistry.registered?.
    def required_connections
      requirements = []
      enabled_plugins.each do |name, plugin_class, opts|
        next unless plugin_class

        conn_name = opts[:connection]
        requirements << [conn_name, "Plugin #{name.inspect}"] if conn_name # skips false/nil

        plugin_class.tools.each do |tool_class|
          tool_conn = tool_class.connection
          requirements << [tool_conn, "Tool #{tool_class.tool_name.inspect}"] if tool_conn
        end
      end
      requirements
    end

    # A literal Host allowlist derived from the host app's own
    # `Rails.application.config.hosts` — a sensible default for `allowed_hosts`
    # so the MCP endpoint accepts exactly the hosts the app already serves. The
    # transport matches hosts literally (bare name or `host:port`), so Rails'
    # regexp, IPAddr, and dotted-subdomain (".example.com") entries can't be
    # forwarded — only plain host strings are kept. Returns [] when Rails is
    # absent or defines no string hosts (the transport's loopback defaults still
    # apply). Wildcard/regexp hosts must be added to `allowed_hosts` explicitly.
    def rails_hosts
      return [] unless defined?(::Rails) && ::Rails.respond_to?(:application) && ::Rails.application

      Array(::Rails.application.config.hosts).grep(String).reject { |h| h.start_with?(".") }
    end

    # Requires every .rb under app/talk_to_your_app/<subdir> so the files'
    # side effects run (each defines a Tool subclass the :custom_tools plugin
    # collects). require is idempotent, so calling this repeatedly loads
    # each file once per process (edits need a restart). No-op when the directory
    # or Rails is absent. Each file is loaded in isolation: one file that fails
    # to load is logged and skipped so it can't suppress the others. ScriptError
    # is rescued alongside StandardError so a syntax/load error is reported the
    # same way as a runtime error rather than escaping uncaught.
    def require_app_dir(subdir)
      return unless defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root

      dir = ::Rails.root.join(APP_DIR, subdir)
      return unless File.directory?(dir)

      Dir[File.join(dir, "**/*.rb")].sort.each do |file|
        if block_given?
          yield(file, -> { require file })
        else
          require file
        end
      rescue StandardError, ScriptError => e
        message = "talk_to_your_app: failed to load #{file}: #{e.class}: #{e.message}"
        logger = configuration.logger
        logger ? logger.error(message) : $stderr.puts(message)
      end
    end
  end
end

require_relative "talk_to_your_app/railtie" if defined?(Rails::Railtie)

# Bundled plugins self-register on load (after register_plugin is defined). They
# are off by default; the operator enables them in the initializer. Soft-dep
# constants are referenced only inside tool calls, so loading these files never
# requires the backing gem.
require_relative "talk_to_your_app/plugins/db/plugin"
require_relative "talk_to_your_app/plugins/jobs/plugin"
require_relative "talk_to_your_app/plugins/flipper/plugin"
require_relative "talk_to_your_app/plugins/rake/plugin"
require_relative "talk_to_your_app/plugins/cache/plugin"
require_relative "talk_to_your_app/plugins/health/plugin"
require_relative "talk_to_your_app/plugins/custom_tools/plugin"
