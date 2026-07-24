# frozen_string_literal: true

# Demo configuration for running the dummy app as a local MCP server you can
# connect Claude to. Development only — the test suite configures the gem
# per-test, so this block is skipped under RAILS_ENV=test.
#
# See ../../../LOCAL_DEVELOPMENT.md for how to start the server and point Claude
# at it.
if Rails.env.development?
  TalkToYourApp.configure do |config|
    # Server identity advertised to MCP clients in the initialize handshake.
    config.server_title = "talk_to_your_app — dummy app"
    config.server_description = "Read-only data, background-job metrics, and feature flags over MCP."
    config.instructions = "db.query for read-only SQL; solid_queue.* for job metrics; flipper.* for feature flags."

    # HTTP Basic auth. Username "dev" / password "secret" by default; override
    # with TTYA_DEV_USER / TTYA_DEV_PASSWORD. The username is the logged principal.
    dev_user = ENV.fetch("TTYA_DEV_USER", "dev")
    dev_pass = ENV.fetch("TTYA_DEV_PASSWORD", "secret")
    config.basic_auth { |username, password| username == dev_user && password == dev_pass }

    # Accept the hosts the app itself serves (Rails' config.hosts) in addition
    # to the loopback defaults. Empty in local dev, so this is a no-op here —
    # it documents the pattern for a real-domain deployment.
    config.allowed_hosts = TalkToYourApp.rails_hosts

    # Read-only connection (separate SELECT-only Postgres user) for the DB plugin.
    # role: defaults to :reading.
    config.connection :replica_readonly, database: "replica_readonly"
    # Writer connection for the Flipper plugin (flag writes go to primary).
    config.connection :flipper_writer, database: "primary", role: :writing

    config.plugin :db, connection: :replica_readonly
    # Solid Queue reads its own tables via the app connection, not a wired one.
    config.plugin :solid_queue, connection: false
    config.plugin :flipper, connection: :flipper_writer
    # Allow-listed rake tasks only (see test/dummy/lib/tasks/demo.rake).
    config.plugin :rake, connection: false, allowed: ["demo:stats", "demo:echo"]
    # Exposes the tools defined in app/talk_to_your_app/custom_tools/. The demo
    # tools (make_admin.rb, toggle_active.rb) load automatically. They write via
    # the app's default connection, so they opt out of a wired one.
    config.plugin :custom_tools, connection: false
  end

  # Custom audit logging: persist every tool call to the Activity table (with
  # IP, principal, params, outcome, duration). The gem emits this event for each
  # invocation; subscribing keeps a durable, queryable audit trail. The write is
  # best-effort so it never breaks a tool call.
  ActiveSupport::Notifications.subscribe("talk_to_your_app.tool_call") do |*args|
    payload = ActiveSupport::Notifications::Event.new(*args).payload
    Activity.create!(
      principal: payload[:principal],
      ip: payload[:ip],
      plugin: payload[:plugin]&.to_s,
      tool: payload[:tool],
      params: payload[:params].to_json,
      outcome: payload[:outcome],
      duration_ms: payload[:duration_ms],
    )
  rescue StandardError => e
    Rails.logger.warn("[activity] failed to record tool call: #{e.class}: #{e.message}")
  end

  # Per-user API tokens: each seeded user's token becomes a Bearer key whose
  # principal is the user's name, so audit logs attribute calls to the user.
  # Done in to_prepare (not the initializer body) so the User model is
  # autoloadable, and re-run on reload. basic_auth above already satisfies the
  # gem's boot-time auth check, so this only adds the token keys. Restart after
  # seeding new users to pick up their tokens.
  Rails.application.config.to_prepare do
    TalkToYourApp.configuration.api_keys =
      begin
        if ActiveRecord::Base.connection.table_exists?("users")
          User.where.not(api_token: nil).pluck(:name, :api_token).to_h
        else
          {}
        end
      rescue StandardError
        {}
      end
  end
end
