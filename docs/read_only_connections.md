# Setting up a read-only database connection

The DB plugin runs operator-submitted SQL, so it must only ever touch a
**read-only** connection. `talk_to_your_app` has two layers here, and only one
of them is a security boundary:

1. **Database layer (REQUIRED — this is the security boundary).** You point the
   connection at a genuinely read-only target: a physical replica, or a DB
   role/user granted only `SELECT`. The database server then rejects writes no
   matter how the SQL is shaped.
2. **Rails layer (best-effort convenience, bypassable).** You declare the
   connection with `role: :reading`, and the gem refuses to boot otherwise.
   Rails' `connected_to(role: :reading)` sets `prevent_writes`, which raises
   `ActiveRecord::ReadOnlyError` on statements it detects as writes — but Rails
   detects writes with a **leading-keyword check**, so statements that start
   with a read keyword and still modify data slip through it:

   ```sql
   -- classified as reads by Rails, but they write:
   WITH gone AS (DELETE FROM users RETURNING *) SELECT count(*) FROM gone;
   SELECT 1; UPDATE accounts SET balance = 0;   -- stacked statement (PostgreSQL)
   ```

   Treat this layer as a guard rail against accidents, never as the thing that
   stops a hostile or confused agent.

Never "fake" the read-only connection by pointing it at your primary writable
user. The Rails layer blocks only the writes it can recognize; against the
statements above your data is protected by nothing at all. A SELECT-only DB
user or a replica is **required**, not a recommendation.

## The two pieces you configure

**1. A `database.yml` entry** for the read-only target (a named connection).

**2. An initializer declaration** mapping a gem-internal name to that entry:

```ruby
# config/initializers/talk_to_your_app.rb
TalkToYourApp.configure do |config|
  config.connection :replica_readonly, database: "primary_replica", role: :reading
  config.plugin :db, connection: :replica_readonly
end
```

You declare the connection, then **wire it into the DB plugin by name**
(`connection: :replica_readonly`). `database:` is a key under your environment in
`database.yml`. `role:` defaults to `:reading`, so you can omit it for a read-only
connection — it is shown explicitly here for clarity. Optionally set a
per-connection statement timeout:

```ruby
config.connection :replica_readonly, database: "primary_replica", role: :reading,
                  statement_timeout: 10_000 # ms; default 30_000
```

The statement timeout is enforced on PostgreSQL and MySQL. SQLite has no
per-statement timeout (see below).

---

## PostgreSQL

### Option A — a read-only role on the same database (no replica needed)

Create a login role granted only `SELECT`:

```sql
CREATE ROLE app_readonly LOGIN PASSWORD 'change-me';
GRANT CONNECT ON DATABASE myapp_production TO app_readonly;
GRANT USAGE  ON SCHEMA public TO app_readonly;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_readonly;
-- New tables created later are also readable:
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO app_readonly;
-- Make sure the role cannot create objects:
REVOKE CREATE ON SCHEMA public FROM app_readonly;
```

`database.yml`:

```yaml
production:
  primary:
    <<: *default
    database: myapp_production
    username: myapp
    password: <%= ENV["DATABASE_PASSWORD"] %>
  primary_replica:
    <<: *default
    database: myapp_production       # same database…
    username: app_readonly           # …but the SELECT-only role
    password: <%= ENV["READONLY_DB_PASSWORD"] %>
    replica: true
```

### Option B — a physical read replica

Point `primary_replica` at your replica's host. A streaming replica is
physically read-only, so any write is rejected by the server:

```yaml
production:
  primary:
    <<: *default
    host: primary.db.internal
  primary_replica:
    <<: *default
    host: replica.db.internal
    replica: true
```

PostgreSQL honors the gem's per-query timeout via transaction-local
`SET LOCAL statement_timeout`.

---

## MySQL / MariaDB

### Read-only user on the same database

```sql
CREATE USER 'app_readonly'@'%' IDENTIFIED BY 'change-me';
GRANT SELECT ON myapp_production.* TO 'app_readonly'@'%';
FLUSH PRIVILEGES;
```

`database.yml`:

```yaml
production:
  primary:
    <<: *default
    database: myapp_production
    username: myapp
    password: <%= ENV["DATABASE_PASSWORD"] %>
  primary_replica:
    <<: *default
    database: myapp_production
    username: app_readonly
    password: <%= ENV["READONLY_DB_PASSWORD"] %>
    replica: true
```

A read replica works the same way — point `host:` at the replica.

MySQL enforces the timeout via `SET SESSION max_execution_time` (milliseconds),
which bounds read-only `SELECT`s on that connection until reset; the gem re-sets
it on every call. The DB plugin uses its own dedicated connection pool, so this
does not affect your application's other connections. **MariaDB** does not
implement `max_execution_time` — there the timeout is silently skipped (the
read-only role still applies), like SQLite.

---

## SQLite

SQLite has no separate users or replicas, so it has **no database-level
read-only account** — the layer that is the real security boundary on
PostgreSQL/MySQL does not exist here. That makes an OS-level backstop
**required, not optional**: run the MCP-serving process with the SQLite file
read-only (a dedicated read-only bind mount, or file permissions that deny
write to that process's user). Without it, the bypassable Rails-layer check is
the only thing between an agent and your data.

Declare the connection with `role: :reading` as usual:

```yaml
production:
  primary:
    adapter: sqlite3
    database: storage/production.sqlite3
  primary_replica:
    adapter: sqlite3
    database: storage/production.sqlite3   # same file; read-only via role: :reading
```

```ruby
config.connection :replica_readonly, database: "primary_replica", role: :reading
```

`role: :reading` makes Rails raise `ActiveRecord::ReadOnlyError` on writes it
detects — remember this check is bypassable (see the top of this document), which
is why the OS-level file protection above is required.

> **Avoid the `query_only` pragma with the Rails SQLite adapter.** It looks
> tempting, but the adapter writes to the database at connect time (WAL/journal
> setup), so `PRAGMA query_only = ON` makes even `SELECT`s fail with
> "attempt to write a readonly database". Use `role: :reading` plus the
> required OS-level file protection instead.

> **SQLite has no per-statement timeout.** The `statement_timeout` option is a
> no-op there; a long-running query is not cancelled by the gem. Prefer
> PostgreSQL or MySQL for the DB plugin if untrusted clients can submit
> arbitrary SQL.

---

## Verifying it works

After configuring, boot the app. If you enable `:db` without wiring a
`connection:`, or wire a name you never declared, boot fails immediately with a
clear error — that is the fail-closed contract. (Wiring a `role: :writing`
connection does **not** fail boot — it enables writes through `db.query` and
logs a loud warning; see the README's "Running `:db` against a writable
connection".)

Then call `db.query` over MCP:

- `SELECT count(*) FROM users` → returns rows.
- `UPDATE users SET admin = true` → rejected. On PostgreSQL/MySQL the read-only
  role denies it at the database; on every adapter Rails' `prevent_writes`
  raises `ActiveRecord::ReadOnlyError`. Either way the tool returns an error and
  the audit log records `outcome=error`.

See the [README](../README.md) for the full configuration reference.
