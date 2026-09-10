# frozen_string_literal: true

module TalkToYourApp
  # Raised at boot when required configuration is missing or contradictory.
  # The gem is fail-closed: configuration errors surface during Rails boot,
  # never at the first request.
  class ConfigurationError < StandardError; end

  # The single mutable configuration object. Held as a memoized singleton on
  # the TalkToYourApp module, so calling `TalkToYourApp.configure` more than
  # once merges into the same instance rather than replacing it.
  class Configuration
    # Path the MCP endpoint is mounted at in the host app's router. Default "/mcp".
    attr_accessor :mount_at

    # MCP server identity, surfaced to clients in the `initialize` handshake
    # (serverInfo + instructions). All optional except name/version, which
    # default sensibly.
    attr_accessor :server_name, :server_title, :server_version, :server_description, :instructions

    # Audit logger. Defaults to Rails.logger at boot; swappable to any object
    # implementing the Logger interface.
    attr_accessor :logger

    # Global audit log level (default :info). Overridable per plugin via the
    # plugin DSL's `log_level`.
    attr_accessor :log_level

    # Named API keys, { "principal-name" => "secret-key" }. The name is logged
    # as the principal. Supports multiple keys for rotation.
    attr_accessor :api_keys

    # Origins permitted for browser-originated cross-origin requests
    # (DNS-rebinding protection). Forwarded to the SDK transport, which owns the
    # check: no-Origin (non-browser) and same-origin requests are always
    # allowed; a cross-origin request must match this list (case-insensitive).
    attr_accessor :allowed_origins

    # Extra `Host` header values accepted by the transport's DNS-rebinding
    # protection, beyond the always-allowed loopback defaults (127.0.0.1, ::1,
    # localhost). A non-loopback deployment (the endpoint served from a real
    # domain) MUST list its host here, or every request is rejected with
    # "Forbidden: Invalid Host header". Each entry matches a bare host name (any
    # port) or a full host:port. Empty by default (loopback only).
    attr_accessor :allowed_hosts

    # Global on/off switch for the whole gem. When false, the mounted endpoint
    # serves nothing (503) and boot validation is skipped, so an operator can
    # ship the initializer and disable it per-environment without the gem
    # refusing to boot on otherwise-incomplete configuration. Default true.
    attr_reader :enabled

    # Stringy env values are common here (`config.enabled = ENV["MCP_ENABLED"]`),
    # and every non-empty string is truthy in Ruby — so "false"/"0"/"" would
    # otherwise serve. Coerce the common falsey forms to a real boolean; the
    # disabled side is the safe one to bias toward.
    FALSEY_STRINGS = %w[false 0 no off].freeze

    def enabled=(value)
      @enabled = case value
                 when String then !(value.strip.empty? || FALSEY_STRINGS.include?(value.strip.downcase))
                 when Numeric then !value.zero? # 0 disables, like the string "0" (Ruby treats 0 as truthy)
                 else !!value
                 end
    end

    # When true, the Streamable HTTP transport runs stateless: every request is
    # self-contained, with no per-session state held in the transport. Required
    # when the host app runs more than one Puma/Unicorn worker or replica, where
    # a follow-up request can land on a process that never saw the `initialize`
    # handshake and would otherwise fail with "Session not found". Trades away
    # SSE streaming and server-initiated notifications, neither of which the
    # bundled read-only tools use. Default false.
    attr_accessor :stateless

    def initialize
      @enabled = true
      @mount_at = "/mcp"
      @server_name = "talk_to_your_app"
      @server_version = TalkToYourApp::VERSION
      @server_title = nil
      @server_description = nil
      @instructions = nil
      @connections = {}
      @enabled_plugins = {}
      @health_checks = {}
      @logger = nil
      @api_keys = {}
      @allowed_origins = []
      @allowed_hosts = []
      @stateless = false
      @basic_auth = nil
      @log_level = :info
      @authorizer = nil
    end

    # Sets or reads the HTTP Basic auth callable. The block receives
    # (username, password) and returns truthy to authenticate.
    #
    #   config.basic_auth { |user, pass| User.authenticate(user, pass) }
    def basic_auth(&block)
      @basic_auth = block if block
      @basic_auth
    end

    # True when at least one authentication mechanism is configured.
    def auth_configured?
      api_keys.any? || !@basic_auth.nil?
    end

    # Optional per-principal tool authorization. The block receives
    # (principal, tool_name, args) and returns truthy to allow the call. `args`
    # is the tool's argument hash (symbol keys, as received — defaults not yet
    # applied), enabling per-flag/per-task/per-table decisions. A two-parameter
    # block keeps working (Ruby blocks ignore extra arguments); an explicit
    # lambda must accept all three. With no authorizer configured, every
    # authenticated principal may call every tool.
    #
    #   config.authorize { |principal, tool| principal == "admin" || tool.start_with?("db.") }
    #   config.authorize { |_p, tool, args| tool != "flipper.enable_flag" || args[:name] != "require_2fa" }
    def authorize(&block)
      @authorizer = block if block
      @authorizer
    end

    def authorized?(principal, tool_name, args = {})
      return true if @authorizer.nil?

      @authorizer.call(principal, tool_name, args)
    rescue StandardError => e
      # A raising authorizer denies (fail-closed), mirroring basic_auth handling.
      warn("talk_to_your_app: authorizer raised: #{e.class}: #{e.message}")
      false
    end

    # Registers a named health check. `block` is called with no arguments and
    # must return either a boolean (pass/fail, no extra value) or a
    # [passed, value] pair, where `value` is any JSON-serializable payload the
    # check wants to surface (a count, a timestamp, a status string). Re-registering
    # an existing name overwrites it — the last declaration in the initializer wins,
    # matching how `connection`/`plugin` behave elsewhere in this class.
    #
    #   config.health_check(:video_pipeline) do
    #     recent = VideoJob.where("created_at > ?", 15.minutes.ago)
    #     [recent.any? && recent.all?(&:succeeded?), recent.count]
    #   end
    def health_check(name, &block)
      raise ArgumentError, "health_check #{name.inspect}: a block is required" unless block

      @health_checks[name.to_sym] = block
    end

    # Declared health checks, keyed by name => callable.
    attr_reader :health_checks

    # Declared named connections, keyed by gem-internal symbol name.
    attr_reader :connections

    # Enabled plugins, keyed by name => options hash. Plugins are off by default.
    attr_reader :enabled_plugins

    # Enables a registered plugin, with optional per-plugin options.
    #
    #   config.plugin :db, connection: :read
    #   config.plugin :sidekiq, connection: false
    #
    # Re-declaring a plugin merges options, so a later call can refine an earlier
    # one. But re-wiring it to a *different* connection is rejected — a silent
    # last-wins overwrite could point :db at a writable connection unnoticed.
    def plugin(name, **options)
      key = name.to_sym
      existing = @enabled_plugins[key]
      if existing && options.key?(:connection) && existing.key?(:connection) &&
         existing[:connection] != options[:connection]
        raise ConfigurationError,
          "plugin #{key.inspect} is already wired to connection #{existing[:connection].inspect}; " \
          "refusing to silently re-wire it to #{options[:connection].inspect}."
      end
      @enabled_plugins[key] = (existing || {}).merge(options)
    end

    # Declares a named connection plugins can reference.
    #
    #   config.connection :read,  database: "primary"                 # role: :reading (default)
    #   config.connection :write, database: "primary", role: :writing
    #
    # +database+ is a database.yml config key. +role+ defaults to :reading (the
    # safe default; a :reading connection prevents writes at the Rails layer) —
    # pass role: :writing explicitly for a writer. +replica: true+ marks the
    # connection as pointing at a replica (informational; combining it with
    # role: :writing is rejected as nonsensical).
    def connection(name, database:, role: :reading, replica: false, statement_timeout: nil)
      role = role.to_sym
      unless %i[reading writing].include?(role)
        raise ConfigurationError, "connection #{name.inspect}: role must be :reading or :writing, got #{role.inspect}."
      end
      if replica && role == :writing
        raise ConfigurationError,
          "connection #{name.inspect}: `replica: true` with `role: :writing` is nonsensical — a replica cannot accept writes."
      end

      @connections[name.to_sym] = ConnectionRegistry::ConnectionSpec.new(
        name: name.to_sym,
        database: database.to_sym,
        role: role,
        replica: replica,
        statement_timeout: statement_timeout,
      )
    end
  end
end
