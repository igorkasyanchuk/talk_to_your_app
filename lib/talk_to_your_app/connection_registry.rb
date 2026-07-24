# frozen_string_literal: true

module TalkToYourApp
  # The named-connection registry. Operators declare connections in the
  # initializer (`config.connection :name, database:, role:`); plugins reference
  # them by the gem-internal name. The registry's job is twofold:
  #
  #   1. Fail closed at boot — if a plugin requires a connection that was never
  #      declared, or a declared connection points at a database.yml key that
  #      does not exist, raise during boot rather than at the first request.
  #   2. Switch connections at call time via Rails' `connected_to`, so each tool
  #      runs against the role its plugin declared (reads on a reader, writes on
  #      a writer) without coupling plugin code to the host's database.yml.
  module ConnectionRegistry
    # One declared connection. `database` is a database.yml config key; `role`
    # is :reading or :writing. A :reading connection prevents writes at the
    # Rails layer (defense in depth on top of a genuinely read-only DB role).
    ConnectionSpec = Struct.new(:name, :database, :role, :replica, :statement_timeout, keyword_init: true) do
      def reading?
        role == :reading
      end

      def prevent_writes?
        reading?
      end
    end

    # Guards lazy pool-class construction against concurrent first-calls.
    BUILD_MUTEX = Mutex.new

    module_function

    def specs
      TalkToYourApp.configuration.connections
    end

    def registered?(name)
      specs.key?(name.to_sym)
    end

    def fetch(name)
      specs[name.to_sym] ||
        raise(ConfigurationError, "talk_to_your_app: connection #{name.inspect} is not registered. " \
          "Declare it with `config.connection #{name.inspect}, database: ..., role: ...` in your initializer.")
    end

    # Fail-closed boot check. `requirements` is an array of
    # [connection_name, requester_label] pairs gathered from enabled plugins.
    # Raises ConfigurationError naming every missing connection and who needs it.
    def validate!(requirements)
      missing = requirements.reject { |name, _requester| registered?(name) }
      unless missing.empty?
        details = missing.map { |name, requester| "#{name.inspect} (required by #{requester})" }.join(", ")
        raise ConfigurationError,
          "talk_to_your_app: missing required connection(s): #{details}. " \
          "Declare them with `config.connection ...` in config/initializers/talk_to_your_app.rb."
      end

      requirements.each do |name, requester|
        spec = fetch(name)
        next if database_config_exists?(spec.database)

        raise ConfigurationError,
          "talk_to_your_app: connection #{name.inspect} (required by #{requester}) references database " \
          "#{spec.database.inspect}, which is not configured in database.yml for the #{env_name.inspect} environment."
      end
    end

    # Runs the block against the connection declared under `name`, switched to
    # the spec's role. The connection is yielded; the role switch and checkout
    # are unwound when the block returns, so nothing leaks into the surrounding
    # request. `prevent_writes` is set explicitly from the spec (Rails also
    # forces it for the reading role) so the contract does not depend on
    # framework defaulting. `with_connection` checks the connection back into
    # the pool when the block ends.
    def with(name)
      spec = fetch(name)
      klass = connection_class_for(spec)
      klass.connected_to(role: spec.role, prevent_writes: spec.prevent_writes?) do
        klass.with_connection { |conn| yield conn }
      end
    end

    # Lazily builds (and caches) an abstract ActiveRecord class wired to the
    # spec's database under its role. Cached by (database, role) so the same
    # declared connection reuses one pool across calls. The build is guarded by a
    # mutex so concurrent first-calls under a threaded server cannot create two
    # pools for the same key.
    def connection_class_for(spec)
      cache_key = [spec.database, spec.role]
      existing = connection_classes[cache_key]
      return existing if existing

      BUILD_MUTEX.synchronize do
        connection_classes[cache_key] ||= build_connection_class(spec, connection_classes.size)
      end
    end

    # `connects_to` rejects anonymous classes, so each pool class gets a stable
    # constant name. The index suffix guarantees uniqueness even when two
    # database keys differ only in characters `\W`-normalization would collapse.
    def build_connection_class(spec, index)
      const_name = "Conn#{index}_#{spec.database}_#{spec.role}".gsub(/\W/, "_")
      remove_const(const_name) if const_defined?(const_name, false)
      klass = Class.new(ActiveRecord::Base) { self.abstract_class = true }
      const_set(const_name, klass)
      klass.connects_to(database: { spec.role => spec.database })
      klass
    end

    # Test seam: drop the cached pool classes and their constants so a
    # reconfiguration in a later test does not reuse a stale pool. Wired into
    # TalkToYourApp.reset_configuration!.
    def reset!
      BUILD_MUTEX.synchronize do
        constants(false).grep(/\AConn\d+_/).each { |const| remove_const(const) }
        @connection_classes = {}
      end
    end

    def database_config_exists?(db_key)
      ActiveRecord::Base.configurations
        .configs_for(env_name: env_name, include_hidden: true)
        .any? { |config| config.name.to_sym == db_key.to_sym }
    end

    def env_name
      (defined?(Rails) && Rails.respond_to?(:env) && Rails.env.to_s) || ENV["RAILS_ENV"] || "test"
    end

    def connection_classes
      @connection_classes ||= {}
    end
  end
end
