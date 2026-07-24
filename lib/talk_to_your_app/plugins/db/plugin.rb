# frozen_string_literal: true

require_relative "../../plugin"
require_relative "tools/query"
require_relative "tools/tables"
require_relative "tools/schema"

module TalkToYourApp
  module Plugins
    module Db
      # Default cap on rows returned by db.query. Override per app with
      # `config.plugin :db, max_rows: 5000`, or disable the cap entirely with
      # `max_rows: nil` (also accepts false or :unlimited).
      DEFAULT_MAX_ROWS = 2000
      UNLIMITED = [nil, false, :unlimited].freeze

      module_function

      # Returns the row cap as an Integer, or nil for "no cap".
      def max_rows
        options = TalkToYourApp.configuration.enabled_plugins[:db] || {}
        return DEFAULT_MAX_ROWS unless options.key?(:max_rows)

        value = options[:max_rows]
        return nil if UNLIMITED.include?(value)

        Integer(value)
      end

      # The DB plugin: SQL plus schema introspection against an operator-wired
      # connection (`config.plugin :db, connection: :read`). Wired to a :reading
      # connection (the default role) it is read-only — Rails' write prevention
      # plus the DB role reject writes. Wired to a :writing connection it can
      # execute writes; that is a deliberate, documented opt-in (see README).
      class Plugin < TalkToYourApp::Plugin
        tools Tools::Query, Tools::Tables, Tools::Schema

        # The DB plugin needs a real connection — `connection: false` is invalid.
        # Branch on the wired role: a :reading connection keeps the read-only
        # guarantee (boot silently); a :writing connection enables writes through
        # db.query — permitted, but warned loudly. The warning is detection/audit
        # only; the real safeguard is that the operator had to both declare a
        # role: :writing connection and wire it here.
        def self.validate_enablement!(options)
          unless options[:connection]
            raise TalkToYourApp::ConfigurationError,
              "talk_to_your_app: the DB plugin requires a real connection — " \
              "`config.plugin :db, connection: :your_connection`. `connection: false` is not valid."
          end

          spec = wired_spec(options) # nil for an unregistered name (ConnectionRegistry.validate! owns that)
          warn_writable(spec.name) if spec && !spec.reading?
        end

        # When wired to a writable connection, advertise that on the db.query
        # tool so an MCP client can tell a write-capable deployment apart from a
        # read-only one. Returns nil (use the tool's own description) otherwise.
        def self.describe_tool(tool_class)
          return unless tool_class == Tools::Query

          conn = TalkToYourApp.configuration.enabled_plugins.dig(:db, :connection)
          return unless conn && TalkToYourApp::ConnectionRegistry.registered?(conn)
          return if TalkToYourApp::ConnectionRegistry.fetch(conn).reading?

          "Run a SQL query and return the rows. This connection is WRITABLE — " \
            "UPDATE/INSERT/DELETE/DDL statements will execute."
        end

        def self.warn_writable(conn)
          message = "talk_to_your_app: the DB plugin is wired to connection #{conn.inspect} with " \
            "role: :writing — db.query can execute writes (UPDATE/INSERT/DELETE/DDL). Ensure this is " \
            "intended and that the database user's privileges are scoped accordingly."
          # Boot-time warning goes to $stderr (Kernel#warn), never the configured
          # logger, which may write to $stdout (captured by scripts at boot).
          warn(message)
        end
        private_class_method :warn_writable
      end
    end
  end
end

TalkToYourApp.register_plugin(:db, TalkToYourApp::Plugins::Db::Plugin)
