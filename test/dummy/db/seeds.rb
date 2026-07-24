# frozen_string_literal: true

# Relational sample data (idempotent — only seeds an empty database). Each user
# gets an api_token automatically (has_secure_token).
if User.count.zero?
  alice = User.create!(name: "Alice", email: "alice@example.com")
  bob   = User.create!(name: "Bob",   email: "bob@example.com")
  carol = User.create!(name: "Carol", email: "carol@example.com")
  dave  = User.create!(name: "Dave",  email: "dave@example.com")
  erin  = User.create!(name: "Erin",  email: "erin@example.com")

  posts = {
    alice => [["Hello world", "First post from Alice."],
              ["Read-only by default", "Why the DB plugin only ever reads."]],
    bob   => [["MCP is neat", "Talking to my app over MCP."]],
    carol => [["Feature flags", "Rolling out the new dashboard with Flipper."],
              ["On-call notes", "What to watch for during a deploy."]],
    dave  => [["Background jobs", "Keeping an eye on the queue depths."]],
    erin  => [["Postgres tips", "Read replicas and SELECT-only roles."]],
  }.flat_map do |user, list|
    list.map { |title, body| user.posts.create!(title: title, body: body) }
  end

  commenters = [alice, bob, carol, dave, erin]
  bodies = [
    "Great post!", "Agreed — read-only SQL is handy.", "And the audit log is nice.",
    "Bookmarking this.", "How does this scale?", "Tried it locally, works well.",
    "The per-user tokens are a nice touch.", "Thanks for writing this up.",
  ]
  posts.each_with_index do |post, i|
    2.times do |j|
      author = commenters[(i + j + 1) % commenters.size]
      post.comments.create!(user: author, body: bodies[(i * 2 + j) % bodies.size])
    end
  end
end

# A non-model table for the simplest DB-plugin demo.
conn = ActiveRecord::Base.connection
if conn.table_exists?(:widgets) && conn.select_value("SELECT COUNT(*) FROM widgets").to_i.zero?
  conn.execute(<<~SQL)
    INSERT INTO widgets (name, quantity, created_at, updated_at) VALUES
      ('alpha', 3, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
      ('beta', 7, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
  SQL
end

# Flipper: create its tables (if missing) and enable 3 demo features with
# different gate types, for the Flipper plugin to list and toggle.
if Rails.env.development?
  unless conn.table_exists?(:flipper_features)
    ActiveRecord::Schema.define do
      create_table :flipper_features do |t|
        t.string :key, null: false
        t.timestamps null: false
      end
      add_index :flipper_features, :key, unique: true
      create_table :flipper_gates do |t|
        t.string :feature_key, null: false
        t.string :key, null: false
        t.text :value
        t.timestamps null: false
      end
      add_index :flipper_gates, %i[feature_key key value], unique: true
    end
  end

  require "flipper"
  Flipper.enable(:new_dashboard)                      # boolean gate, on for everyone
  Flipper.enable_percentage_of_actors(:beta_search, 25) # 25% of actors
  Flipper.enable_percentage_of_time(:dark_mode, 10)     # 10% of the time
end

# Solid Queue: load its schema (if missing) and enqueue a few heartbeat jobs so
# the Jobs plugin has data even before the worker (bin/jobs) runs.
if Rails.env.development?
  unless conn.table_exists?(:solid_queue_jobs)
    sq_dir = Gem::Specification.find_by_name("solid_queue").gem_dir
    ActiveRecord::Migration.suppress_messages do
      load "#{sq_dir}/lib/generators/solid_queue/install/templates/db/queue_schema.rb"
    end
  end
  if defined?(HeartbeatJob) && SolidQueue::Job.where(class_name: "HeartbeatJob").none?
    3.times { HeartbeatJob.perform_later }
  end
end

# Provision the read-only Postgres user the DB plugin connects through. Same
# database as primary, but a role with SELECT only — so writes are rejected at
# the database, not just by Rails. Runs LAST so the grant covers the flipper and
# solid_queue tables too. Idempotent; runs as the (superuser) primary.
if Rails.env.development? && conn.adapter_name.match?(/postgres/i)
  ro_user = ENV.fetch("TTYA_DEV_RO_USER", "ttya_dummy_ro")
  ro_pass = ENV.fetch("TTYA_DEV_RO_PASSWORD", "ro_pass")
  db_name = conn.current_database

  conn.execute(<<~SQL)
    DO $$ BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '#{ro_user}') THEN
        CREATE ROLE #{ro_user} LOGIN PASSWORD '#{ro_pass}';
      END IF;
    END $$;
    GRANT CONNECT ON DATABASE #{db_name} TO #{ro_user};
    GRANT USAGE ON SCHEMA public TO #{ro_user};
    GRANT SELECT ON ALL TABLES IN SCHEMA public TO #{ro_user};
    ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO #{ro_user};
    REVOKE CREATE ON SCHEMA public FROM #{ro_user};
  SQL
  puts "Seeded primary and granted SELECT to read-only role #{ro_user}"
end
