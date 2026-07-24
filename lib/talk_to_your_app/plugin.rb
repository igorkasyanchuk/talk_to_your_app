# frozen_string_literal: true

module TalkToYourApp
  # Base class for plugins. A plugin bundles a set of tools and declares the
  # connections and soft-dependency gems it needs. Subclasses use the class-level
  # DSL; instances are not created — everything is declarative metadata read at
  # boot and registration time.
  #
  #   class TalkToYourApp::Plugins::Db < TalkToYourApp::Plugin
  #     tools DbQueryTool
  #   end
  #
  # Every plugin is wired a connection by the operator at enable time
  # (`config.plugin :db, connection: :read`, or `connection: false` to opt out);
  # the framework enforces that the option is present. A plugin that needs a
  # specific role overrides validate_enablement! and checks wired_spec.
  class Plugin
    NOT_SET = Object.new
    private_constant :NOT_SET

    class << self
      # Declares a soft-dependency gem. `const` is the constant the gem defines
      # (checked at boot); `gem_name` is the human gem name for the error message.
      def requires_gem(const = NOT_SET, gem_name: nil)
        if const == NOT_SET
          @required_gem
        else
          @required_gem = { const: const.to_s, gem_name: gem_name || const.to_s.downcase }
        end
      end
      alias_method :required_gem, :requires_gem

      # Tool classes this plugin exposes.
      def tools(*tool_classes)
        @tools ||= []
        @tools.concat(tool_classes) unless tool_classes.empty?
        @tools
      end

      # Per-plugin audit log level override (defaults to the global level).
      def log_level(level = NOT_SET)
        level == NOT_SET ? @log_level : (@log_level = level)
      end

      # The registry name this plugin was registered under. Set by the registry.
      attr_accessor :plugin_name

      # Per-plugin boot validation hook, called with the operator's enablement
      # options (e.g. { connection: :read }). Override to enforce plugin-specific
      # requirements; the default is a no-op.
      def validate_enablement!(_options)
      end

      # Optional hook to tailor a tool's MCP description to the operator's config
      # (the DB plugin flags a writable connection). Return nil to use the tool's
      # own static description. Called once per tool at server-build time.
      def describe_tool(_tool_class)
        nil
      end

      # Resolves the ConnectionSpec the operator wired into this plugin, or nil
      # when validation should defer. Returns nil when connection is false/nil
      # (the operator opted out) or names an unregistered connection — the latter
      # is owned by ConnectionRegistry.validate! (which names the requester), so
      # guard with registered? before fetch to avoid pre-empting that message.
      # Plugins that need a real connection or a specific role call this from
      # validate_enablement! and act on the nil/role themselves.
      def wired_spec(options)
        conn = options[:connection]
        return unless conn && TalkToYourApp::ConnectionRegistry.registered?(conn)

        TalkToYourApp::ConnectionRegistry.fetch(conn)
      end
    end
  end
end
