# talk_to_your_app

**Let an AI agent talk to your running Rails app — safely.** `talk_to_your_app` mounts a [Model Context Protocol](https://modelcontextprotocol.io) endpoint on your app, so a tool like Claude can query your database, inspect background jobs, flip feature flags, and call tools you write yourself — all behind your auth, all audit-logged, and read-only unless you opt into a write-capable plugin.

[![20-second demo](docs/demo.gif)](docs/demo.mp4)

> ▶️ Click for the full-quality video — setup, live `db.query`, and read-only enforcement.

![Asking Claude Code a question about production data](docs/quick.png)

> A plain-English question, answered from the live database: the agent writes the read-only `SELECT` itself, calls `db.query`, and reports the number. The approval prompt in the middle is the **MCP client's** (here Claude Code) — independent of the gem's own `config.authorize` and read-only DB role, which apply whether or not a client asks.

It's a thin, Rails-native layer over the official [MCP Ruby SDK](https://github.com/modelcontextprotocol/ruby-sdk): the SDK handles the wire protocol; this gem adds everything Rails — your replicas, your jobs backend, your feature flags — plus the guardrails that make pointing an agent at your app something you can actually ship.

**What you get**

- 🔌 **A Streamable HTTP MCP endpoint in two lines** — `mount TalkToYourApp.rack_app`, and you're live.
- 🔒 **Fail-closed by design** — API-key or HTTP Basic auth required, optional per-tool authorization, and an explicitly wired database connection the app *refuses to boot without* (read-only `:reading` role by default). Misconfiguration fails at deploy, never on the first request.
- 🧰 **Batteries-included plugins** — `db` (read-only SQL + schema introspection), `sidekiq` and `solid_queue` (background-job metrics), `flipper` (feature flags), `rake` (allow-listed tasks), `cache` (clear the Rails cache), and `custom_tools` (your own tools, with a generator).
- 📝 **Every call audit-logged** — principal, IP, params, outcome, duration, plus a line for every *rejected* request. Subscribe to persist your own trail.
- ✍️ **A Ruby DSL + generators** for writing first-class tools of your own in a few lines.

Everything is **off by default and opt-in per plugin** — an agent can only touch what you explicitly turn on.

## Installation

```ruby
# Gemfile
gem "talk_to_your_app"
```

```sh
bundle install
bin/rails generate talk_to_your_app:install
```

The generator writes a commented `config/initializers/talk_to_your_app.rb`. Then mount the endpoint in `config/routes.rb`:

```ruby
mount TalkToYourApp.rack_app, at: TalkToYourApp.configuration.mount_at
```

## Your first query

1. **Declare a read-only connection and enable the DB plugin** in `config/initializers/talk_to_your_app.rb`:

   ```ruby
   TalkToYourApp.configure do |config|
     config.api_keys = { "my-agent" => ENV.fetch("TTYA_KEY") }
     config.connection :readonly, database: "primary"   # role: defaults to :reading
     config.plugin :db, connection: :readonly
   end
   ```

   `"my-agent"` is the **principal** — the name this token authenticates as, recorded on every audit line. The endpoint is **secure by default**: no tool responds until auth is configured, and the app refuses to boot with a plugin enabled and no auth.

   You declare connections by name and **wire one into each plugin** that needs a database (`connection: :readonly`). `role:` defaults to `:reading`. In production, point `database:` at a genuinely read-only replica (or a Postgres role with `GRANT SELECT` only). The gem enforces read-only at the Rails layer too, but the database role is the real backstop. See [docs/read_only_connections.md](docs/read_only_connections.md) for step-by-step setup on PostgreSQL, MySQL, and SQLite.

2. **Mount it** (see above) and boot the app. If you enable `:db` without wiring a `connection:`, or name one you never declared, boot fails with a clear error.

3. **Point your MCP client** (e.g. Claude Code) at `http://localhost:3000/mcp` with the bearer token `TTYA_KEY`.

4. **Ask in plain English.** The agent translates your question into SQL, calls `db.query`, and answers:

   ```
   You:    How many users registered this week?
   Claude: 1,284 — up 12% from last week.
           (db.query → SELECT count(*) FROM users WHERE created_at >= '2026-05-25')
   ```

   Rows come back as JSON, plain text, or an HTML table — the agent picks what it needs.

## Try it locally

Want to see it end to end before wiring it into your own app? The bundled
`test/dummy` app runs as a real MCP server with HTTP Basic auth, the bundled
plugins, and seeded data. From a clone of this repo (needs a local PostgreSQL —
see [LOCAL_DEVELOPMENT.md](LOCAL_DEVELOPMENT.md)):

```sh
cd test/dummy
RAILS_ENV=development bundle exec ruby bin/rails db:prepare      # creates the DB + a read-only role, seeds data
RAILS_ENV=development bundle exec ruby bin/rails server -p 3000  # MCP endpoint at http://localhost:3000/mcp
```

Then connect Claude Code with one command (Basic auth `dev` / `secret`, where
`ZGV2OnNlY3JldA==` is `base64("dev:secret")` — see
[LOCAL_DEVELOPMENT.md](LOCAL_DEVELOPMENT.md#computing-the-base64-value) if
you're not sure where to run that):

```sh
claude mcp add --transport http talk-to-your-app http://localhost:3000/mcp \
  --header "Authorization: Basic ZGV2OnNlY3JldA=="
```

Run `/mcp` in a Claude Code session to list the tools — e.g. *"use
talk-to-your-app's db.query to count comments per user."* The full walkthrough
(per-user tokens, background jobs, curl examples) is in
**[LOCAL_DEVELOPMENT.md](LOCAL_DEVELOPMENT.md)**.

## Configuration reference

Every option lives inside `TalkToYourApp.configure`:

| Option | Description |
| --- | --- |
| `config.enabled` | Global on/off switch. When `false`, the endpoint serves `503` and boot validation is skipped, so you can ship the initializer and disable per-environment. Default `true`. |
| `config.mount_at` | Path the endpoint serves from. Default `"/mcp"`. |
| `config.server_name` | Server name in the `initialize` handshake. Default `"talk_to_your_app"`. |
| `config.server_title` | Human-friendly server title shown to clients (optional). |
| `config.server_version` | Reported server version. Defaults to the gem version. |
| `config.server_description` | One-line description of this MCP server, shown to clients (optional). |
| `config.instructions` | Guidance shown to the LLM on how to use this server's tools (optional). |
| `config.api_keys` | `{ "principal-name" => "secret" }`. The name is logged as the principal. Multiple keys supported for rotation. |
| `config.basic_auth { \|user, pass\| ... }` | HTTP Basic callable returning truthy to authenticate. Wire it to your own user model. |
| `config.authorize { \|principal, tool, args\| ... }` | Optional per-principal tool authorization. Returns truthy to allow. `args` is the tool's argument hash (symbol keys), so you can authorize per flag/task/argument, not just per tool — two-parameter blocks keep working. Without it, any authenticated principal may call any enabled tool. |
| `config.allowed_origins` | Cross-origin browser `Origin` values to allow (DNS-rebinding protection, enforced by the MCP SDK transport). Requests without an `Origin` header (non-browser clients) and same-origin requests always pass; matching is case-insensitive. |
| `config.allowed_hosts` | Extra `Host` header values accepted by the transport (DNS-rebinding protection), beyond the always-allowed loopback defaults (`127.0.0.1`, `::1`, `localhost`). A non-loopback deployment **must** list its host here or every request is rejected with "Forbidden: Invalid Host header". Each entry matches a bare host (any port) or full `host:port`. The generated initializer defaults this to `TalkToYourApp.rails_hosts` (your app's own `config.hosts`, literal strings only — add wildcard/regexp hosts explicitly). |
| `config.stateless` | Run the Streamable HTTP transport stateless — every request is self-contained, so any worker or replica can serve it. **Set to `true` whenever the app runs more than one Puma/Unicorn worker or replica** (i.e. most production deployments): with the default stateful mode, a follow-up request can land on a process that never saw `initialize` and fail with **"Session not found"**. Stateless mode does not support SSE streaming or server-initiated notifications. Default `false`. |
| `config.connection :name, database:, role:, replica:, statement_timeout:` | Declares a named connection. `role:` defaults to `:reading`; pass `:writing` for a writer. |
| `config.plugin :name, connection: :conn, **opts` | Enables a plugin (off by default). **Every plugin must declare `connection:`** — a declared connection name, or `connection: false` to opt out (e.g. `:sidekiq`, `:rake`, `:custom_tools` that don't read a wired SQL connection). |
| `config.logger` | Audit logger. Defaults to `Rails.logger`. Swappable to any Logger-compatible object. |
| `config.log_level` | Global audit level (default `:info`); overridable per plugin. |

At least one of `api_keys` / `basic_auth` must be configured once any plugin is enabled, or the app refuses to boot.

## Authentication & per-user tokens

> **What's a principal?** The *identity* behind a request — the name of the API key that authenticated (or the HTTP Basic username). It's what gets written to every audit line and what `config.authorize` receives, so giving each user or client its own named token gives you per-user attribution, scoping, and revocation.

`config.api_keys` is a map of **principal name → secret token**. The *name* is what gets logged as the principal and what `config.authorize` receives — so give **each user or client its own named token** rather than sharing one. That buys you per-user attribution in the audit log, per-user revocation, and per-user scoping:

```ruby
TalkToYourApp.configure do |config|
  # One named token per client/user — the key NAME is the principal.
  config.api_keys = {
    "claude-desktop"  => ENV.fetch("TTYA_KEY_CLAUDE"),
    "alice@acme.com"  => ENV.fetch("TTYA_KEY_ALICE"),
    "ci-readonly-bot" => ENV.fetch("TTYA_KEY_CI"),
  }

  # Optionally scope what each principal may call.
  config.authorize { |principal, tool| principal == "ci-readonly-bot" ? tool.start_with?("db.") : true }

  # The block also receives the tool's arguments (third parameter), so you can
  # authorize per flag/task/argument, not just per tool:
  # config.authorize { |_p, tool, args| tool != "flipper.enable_flag" || args[:name] != "require_2fa" }
end
```

Clients send `Authorization: Bearer <token>`. (HTTP Basic via `config.basic_auth` is the alternative; the username becomes the principal.)

Generating per-user tokens from your own `User` model is straightforward — give each user a high-entropy token (Rails' `has_secure_token` works well) and build the map:

```ruby
config.api_keys = User.where.not(api_token: nil).pluck(:email, :api_token).to_h
```

(The map is read at configure time; rebuild and redeploy — or rebuild in a `to_prepare` block — when the set of users changes. See `test/dummy` for a worked example.)

**Keeping tokens secure**

- **Never commit tokens.** Pull them from `ENV` or Rails credentials, not source.
- **Use HTTPS in production** so Bearer tokens aren't sent in clear text. Restrict `config.allowed_origins` for any browser-originated traffic.
- **Use high-entropy tokens** (e.g. `SecureRandom.hex(32)` or `has_secure_token`), one per principal — never a shared secret.
- **Rotate by adding the new named token and removing the old**; multiple keys can be valid at once, so rotation needs no downtime.
- **Revoke** a user by dropping their key (or nulling their `api_token`) and redeploying.
- Comparison is constant-time, and tokens are never written to the audit log. Mark any sensitive *tool argument* `redact: true` so it is masked too.
- Scope blast radius with `config.authorize` (per-principal tool allow-lists) and read-only DB roles, so a leaked token is bounded.

## Plugins

All plugins are **off by default** — enable them explicitly, and an agent can only reach the ones you turn on.

| Plugin | What an agent can do | Enable with |
| --- | --- | --- |
| [DB](#db) | Run SQL (read-only by default); introspect tables, columns, indexes, FKs | `config.plugin :db, connection: :readonly` |
| [Sidekiq](#jobs-read-only) | Read Sidekiq queue sizes, recent/failed jobs, rates | `config.plugin :sidekiq, connection: false` |
| [Solid Queue](#jobs-read-only) | Read Solid Queue queue sizes, recent/failed jobs, rates | `config.plugin :solid_queue, connection: false` |
| [Flipper](#flipper) | Read and toggle feature flags (global, actor, group, %) | `config.plugin :flipper, connection: :writer` |
| [Rake](#rake-allow-listed-task-runner) | Run allow-listed rake tasks and read their output | `config.plugin :rake, connection: false, allowed: [...]` |
| [Cache](#cache) | Clear the Rails cache | `config.plugin :cache, connection: false` |
| [Custom Tools](#custom-tools) | Call tools you write yourself (writes allowed) | `config.plugin :custom_tools, connection: false` |

### DB

A single SQL tool — read-only by default.

```ruby
# `database:` must map to a SELECT-only DB user or a replica — not your
# writable primary. That read-only role is the security boundary.
config.connection :readonly, database: "readonly"   # role: defaults to :reading
config.plugin :db, connection: :readonly
```

- **`db.query`** — `sql` (required), `format` (`json` | `text` | `html`, default `json`). Runs inside a transaction with a per-query statement timeout (default 30s, override with `statement_timeout:` on the connection). The timeout is enforced on PostgreSQL (`statement_timeout`) and MySQL (`max_execution_time`); SQLite has no per-statement timeout. **On a `:reading` connection (the default) writes are rejected by the read-only DB role** — the gem does not parse SQL (see [Read-only is enforced by the database](#read-only-is-enforced-by-the-database)). Results are capped at **2000 rows by default** — raise or lower it with `config.plugin :db, connection: :readonly, max_rows: 5000`, or remove the cap with `max_rows: nil` (also accepts `false` or `:unlimited`); when a query exceeds the cap the response is truncated and flagged (`"truncated": true, "max_rows": N`). **Invalid SQL** comes back as a tool error (`isError`) carrying the database's message — it never crashes the request or leaks a stack trace.

> ⚠️ **`max_rows` bounds the response, not memory.** The full result set is fetched before truncation, so `SELECT * FROM a_very_large_table` can exhaust the web process well inside the statement timeout. Keep an explicit `LIMIT` in the queries you expect, lower `statement_timeout:` on the connection, and constrain the connection at the database (PostgreSQL: a low `work_mem` and a per-role `statement_timeout`).
- **`db.tables`** — lists the table names in the database.
- **`db.schema`** — `table` (required): the table's columns, primary key, indexes, and foreign keys.

> **Discovering the schema.** Point the model at your `db/schema.rb` or `db/structure.sql` so it knows the tables and columns before querying — or let it call `db.tables` / `db.schema` to introspect the live database directly.

Setting up the read-only connection for each database engine is covered in **[docs/read_only_connections.md](docs/read_only_connections.md)**.

#### Read-only is enforced by the database

`db.query` does **not** parse or sanitize SQL, and you should not treat Rails' own write-protection as a security boundary. Rails decides "is this a write?" with a leading-keyword check, so statements that *start* with a read keyword but modify data slip through it:

```sql
-- starts with WITH/SELECT, so Rails classifies it as a read — but it writes:
WITH gone AS (DELETE FROM users RETURNING *) SELECT count(*) FROM gone;
SELECT 1; UPDATE accounts SET balance = 0;   -- stacked statement (PostgreSQL)
```

The **only** thing that reliably stops these is the database itself. Point the `:reading` connection at a **genuinely read-only DB account** — then a write fails at the server no matter how the SQL is shaped:

- **PostgreSQL** — create a role with no write grants and use it for the reader:
  ```sql
  CREATE ROLE app_readonly LOGIN PASSWORD '…';
  GRANT CONNECT ON DATABASE app_production TO app_readonly;
  GRANT USAGE ON SCHEMA public TO app_readonly;
  GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_readonly;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO app_readonly;
  -- optional belt-and-suspenders: ALTER ROLE app_readonly SET default_transaction_read_only = on;
  ```
  …or simply point `:reading` at a **physical read replica**, which is read-only by construction.
- **MySQL** — `GRANT SELECT ON app_production.* TO 'app_readonly'@'%';` (grant `SELECT` only), or use a replica.

Then declare that account as the reader and add the `db` plugin:

```ruby
# database.yml has a `readonly` entry using the SELECT-only credentials above
config.connection :readonly, database: "readonly"   # role: defaults to :reading
config.plugin :db, connection: :readonly
```

> ⚠️ Do **not** point a `:reading` connection at your writable primary. If the account can write, a crafted CTE or stacked statement will write — the gem cannot prevent it. The read-only role is the boundary; everything else is convenience.

#### Running `:db` against a writable connection

`db.query` runs read-only as shipped. If you deliberately wire a **`:writing`** connection, `db.query` can execute arbitrary writes — `UPDATE`, `INSERT`, `DELETE`, even DDL:

```ruby
config.connection :writer, database: "primary", role: :writing
config.plugin :db, connection: :writer   # db.query can now write — logs a loud boot warning
```

This is a deliberate, two-step opt-in (declare a `role: :writing` connection **and** wire it in); the gem logs a warning at boot but does not stop you. Before enabling it, understand what it does **not** give you:

- **`config.authorize` cannot distinguish reads from writes.** The tool is always `"db.query"`, so an authorizer like `tool.start_with?("db.")` permits `SELECT` and `DELETE` identically. The real access control is the **database user's privileges** — grant only what the writes you intend require.
- **Full SQL, including literal values, is written to the audit log.** Write statements with sensitive literals (`UPDATE users SET token = '…'`) appear in every audit destination. Scope or filter your log sinks accordingly.
- The gem still does **not** parse SQL. Nothing inspects or restricts the statement beyond the connection's role.

Prefer a read-only connection unless you specifically need writes.

### Jobs (read-only)

Background-job metrics, as one plugin per backend — `:sidekiq` and
`:solid_queue`. Enable whichever you run (or both, e.g. mid-migration). The
backends read Redis / their own tables, not a wired SQL connection, so enable
them with `connection: false`:

```ruby
config.plugin :sidekiq, connection: false
config.plugin :solid_queue, connection: false   # both may run at once
```

Each plugin exposes four adapter-namespaced tools:

- **Sidekiq** — `sidekiq.queue_sizes`, `sidekiq.recent_jobs` (`limit`, ≤500), `sidekiq.failed_jobs` (`limit`, ≤500), `sidekiq.rate_metrics` (`window` seconds, default 1800).
- **Solid Queue** — `solid_queue.queue_sizes`, `solid_queue.recent_jobs`, `solid_queue.failed_jobs`, `solid_queue.rate_metrics` (same arguments).

Both backends return the same response shape. Boot fails if the backend's gem is missing.

### Flipper

Read and toggle feature flags, globally or per actor.

```ruby
config.connection :flipper_writer, database: "primary", role: :writing
config.plugin :flipper, connection: :flipper_writer
```

Flipper writes flag state, so it requires a connection declared `role: :writing` — boot fails on a `:reading` connection.

- **`flipper.list_flags`** — names of all configured flags.
- **`flipper.read_flag`** — a flag's effective state plus its full per-gate configuration. Optional `actor_class` + `actor_id` reads the state for that actor.
- **`flipper.enable_flag`** / **`flipper.disable_flag`** — toggle a flag across a gate: global (default), an actor (`actor_class` + `actor_id`), a registered `group`, or a `percentage` rollout (`percentage_type`: `actors` or `time`). Each returns `{ name, enabled, gate_type, gates }` — `gate_type` is the targeted gate (`boolean`, `actor`, `group`, `percentage_of_actors`, `percentage_of_time`) and `gates` is the flag's full per-gate configuration.
- **`flipper.enabled_flags`** — the currently-enabled flags with their gates and last-change timestamps, for inspection. (Flipper stores no enable/disable history; `updated_at` is the last feature change, available with the ActiveRecord adapter.)

Declaring `:flipper_writer` is required (the gem refuses to boot without it) and documents that flag writes need a writable connection, kept separate from the DB plugin's read-only role. Flipper itself reads and writes through whatever adapter you configure for it (e.g. `flipper-active_record`); point that adapter at the same writable database.

> ⚠️ Enabling the Flipper write tools lets any permitted principal toggle **every** flag. To restrict security-sensitive flags, use the authorizer's `args` parameter — e.g. `config.authorize { |_p, tool, args| !tool.start_with?("flipper.enable", "flipper.disable") || %w[new_dashboard beta_search].include?(args[:name]) }`.

### Rake (allow-listed task runner)

Runs operator-approved rake tasks and returns their status and output.

```ruby
config.plugin :rake, connection: false, allowed: ["stats", "report:generate"]
config.plugin :rake, connection: false, allowed: [...], timeout: 60   # per-task seconds, default 20
```

- **`rake.run`** — `task` (required, must be on the `allowed:` list), `args` (optional array of positional arguments → `task[arg1,arg2]`). Returns JSON `{ task, status, exit_code, output, error }`. The task runs in a subprocess (`bundle exec rake`), so arguments cannot inject shell commands. A task that runs longer than `timeout:` (default 20s) is hard-killed and returned as a tool error, so a hung task can't pin the web thread.

> ⚠️ **Security.** Rake tasks can do anything, so this plugin is **fail-closed and allow-list-only**: it refuses to boot without a non-empty `allowed:` list, and refuses any task not on it. The allow-list is the security boundary — keep it tight and prefer read-only/reporting tasks. Combine with `config.authorize` to scope it to specific principals.

### Cache

One destructive-but-recoverable tool: wipe the Rails cache.

```ruby
config.plugin :cache, connection: false
```

- **`cache.clear`** — calls `Rails.cache.clear` and returns `{ cleared, store }`. Every cached entry is dropped and the app re-warms from cold, so scope it to trusted principals: `config.authorize { |principal, tool, _args| tool != "cache.clear" || principal == "admin" }`.

### Custom Tools

Write your own tools by subclassing `TalkToYourApp::Tool` — the same base class the bundled tools use, with typed arguments and **writes allowed** (unlike the read-only DB plugin). Drop one per file in `app/talk_to_your_app/custom_tools/` and it's exposed automatically; no explicit registration.

```ruby
config.plugin :custom_tools, connection: false          # tools call ctx.connection(:name) explicitly
config.plugin :custom_tools, connection: :read          # ...or wire a default; ctx.connection (no arg) uses it
```

Scaffold one with the generator (creates `app/talk_to_your_app/custom_tools/<name>.rb`, exposed as `custom.<name>`):

```sh
bin/rails generate talk_to_your_app:custom_tool MakeAdmin
```

```ruby
# app/talk_to_your_app/custom_tools/make_admin.rb
class MakeAdmin < TalkToYourApp::Tool
  name        "custom.make_admin"
  description "Grant admin to a user by id."
  argument    :user_id, :integer, required: true

  def call(args, _ctx)
    user = User.find(args[:user_id])
    user.update!(admin: true)
    json(id: user.id, admin: user.admin)
  end
end
```

Namespaced generator paths are reflected in the tool name. For example,
`bin/rails generate talk_to_your_app:custom_tool Admin/MakeAdmin` creates
`app/talk_to_your_app/custom_tools/admin/make_admin.rb` and exposes
`custom.admin.make_admin`.

- The tool list is dynamic — one `Tool` subclass per file in `app/talk_to_your_app/custom_tools/`, loaded automatically (restart to pick up new or edited tools). Only tools in that directory are exposed by this plugin; `Tool` subclasses defined elsewhere are not.
- Because custom tools can do anything the host app allows, including writes, enable them only when you trust the authenticated principals and scope with `config.authorize`. Every call is still audit-logged.

## Writing your own plugin

See [docs/plugin_authoring.md](docs/plugin_authoring.md) for a full walkthrough. The short version:

```ruby
class CacheStatsTool < TalkToYourApp::Tool
  name        "cache.stats"
  description "Rails cache statistics."

  def call(_args, _ctx)
    json(Rails.cache.stats)
  end
end

class CachePlugin < TalkToYourApp::Plugin
  tools CacheStatsTool
end

TalkToYourApp.register_plugin(:cache, CachePlugin)
```

Then `config.plugin :cache, connection: false` (every plugin must declare `connection:`). Third-party plugins use the exact same DSL and lifecycle as the bundled ones.

## Custom audit logging

Every tool invocation produces one audit record, and every **rejected** request produces one too. There are two ways to consume them:

**1. Swap the logger.** `config.logger` accepts any object with a `Logger` interface; the gem writes one line per call to it at `config.log_level`.

**2. Subscribe to the structured event** (recommended for a durable, queryable trail). The gem emits an `ActiveSupport::Notifications` event — `talk_to_your_app.tool_call` — for every invocation, with a structured payload: `ts`, `principal`, `ip`, `session_id`, `plugin`, `tool`, `params` (redacted), `outcome`, `duration_ms`, and `error_class` (on failure). Subscribe and persist it to your own table:

```ruby
# An Activity model: t.string :principal, :ip, :plugin, :tool, :outcome;
#                    t.text :params; t.float :duration_ms; t.timestamps
ActiveSupport::Notifications.subscribe("talk_to_your_app.tool_call") do |*args|
  e = ActiveSupport::Notifications::Event.new(*args).payload
  Activity.create!(
    principal:   e[:principal],   # the authenticated key name / Basic username
    ip:          e[:ip],          # client IP (from the request)
    plugin:      e[:plugin].to_s,
    tool:        e[:tool],        # e.g. "db.query"
    params:      e[:params].to_json,
    outcome:     e[:outcome],     # "success" | "error"
    duration_ms: e[:duration_ms],
  )
rescue => err
  Rails.logger.warn("activity log failed: #{err.message}")  # never break the tool call
end
```

The client IP comes from the request; the principal is the authenticated identity (so per-user tokens give you per-user attribution). Sensitive arguments marked `redact: true` are already masked in the payload. Put the subscriber in an initializer. See `test/dummy` for a working `Activity`-table example surfaced on its home page.

> ⚠️ **The IP is only as trustworthy as your proxy.** It comes from `Rack::Request#ip`, which honours `X-Forwarded-For`. Behind a proxy you control, it's the real client. Directly exposed, a caller can forge it — treat the principal, not the IP, as the identity.

### Failed authentication

Rejected requests are logged too — an unlogged `401` makes credential guessing and endpoint scanning invisible. Each rejection emits **one `WARN` line** (the level is fixed, not `config.log_level`) and a `talk_to_your_app.auth_failure` event:

```
talk_to_your_app ts=2026-07-24T21:30:00.561Z event=auth_failure reason=invalid_credentials scheme=bearer ip=203.0.113.4
```

| Field | Values |
| --- | --- |
| `reason` | `missing_credentials` (no `Authorization` header) · `unsupported_scheme` · `invalid_credentials` (wrong token, or your `basic_auth` callable returned false) · `validator_error` (your callable raised — `error_class` is included) |
| `scheme` | `bearer`, `basic`, `other`, or absent. Never the client's raw value: an unknown scheme is reported as `other` so a crafted header can't forge log fields. |
| `ip` | Client IP, same caveat as above. |

**No credential material is ever logged** — not the presented token, not the configured key, not the Basic password. Alert on a burst of `event=auth_failure` from one IP:

```ruby
ActiveSupport::Notifications.subscribe("talk_to_your_app.auth_failure") do |*args|
  e = ActiveSupport::Notifications::Event.new(*args).payload
  SecurityAlert.record(reason: e[:reason], ip: e[:ip], scheme: e[:scheme])
end
```

The gem does **not** rate-limit or lock out repeated failures — put a throttle (e.g. [Rack::Attack](https://github.com/rack/rack-attack)) in front of `config.mount_at`.

## Connecting an MCP client

The endpoint is Streamable HTTP at `config.mount_at` (default `/mcp`). Point any MCP client at `https://your-app.example.com/mcp` with an `Authorization` header (a per-user Bearer token or HTTP Basic). The snippets below cover Claude, Gemini CLI, and Codex CLI; config keys for the CLIs evolve, so check your version's docs if a key differs.

**Claude Code** — add the server with a header (`--scope user` makes it available across projects):

```sh
# Per-user API key (Bearer) — recommended
claude mcp add --transport http my-app https://your-app.example.com/mcp \
  --header "Authorization: Bearer $TTYA_TOKEN"

# HTTP Basic instead
claude mcp add --transport http my-app https://your-app.example.com/mcp \
  --header "Authorization: Basic $(printf 'user:pass' | base64)"
```

List with `claude mcp list`, inspect in a session with `/mcp`, and **remove** with `claude mcp remove my-app`.

**Claude Desktop** — add to `claude_desktop_config.json` (Settings → Developer → Edit Config) and restart:

```json
{
  "mcpServers": {
    "my-app": {
      "url": "https://your-app.example.com/mcp",
      "headers": { "Authorization": "Bearer YOUR_TOKEN" }
    }
  }
}
```

(You can also add it through Settings → Connectors with the same URL and `Authorization` header.) Remove the server by deleting its entry and restarting.

**Gemini CLI** — add the server to `~/.gemini/settings.json` (or a project `.gemini/settings.json`). Use `httpUrl` for the Streamable HTTP transport, with `headers`:

```json
{
  "mcpServers": {
    "my-app": {
      "httpUrl": "https://your-app.example.com/mcp",
      "headers": { "Authorization": "Bearer YOUR_TOKEN" }
    }
  }
}
```

Recent Gemini CLI versions can also add it from the command line: `gemini mcp add --transport http my-app https://your-app.example.com/mcp --header "Authorization: Bearer YOUR_TOKEN"`. Manage with `gemini mcp list` / `gemini mcp remove my-app`, and `/mcp` inside a session.

**Codex CLI** — add the server to `~/.codex/config.toml` under `[mcp_servers.<name>]`. Recent Codex versions support Streamable HTTP servers directly:

```toml
[mcp_servers.my-app]
url = "https://your-app.example.com/mcp"
http_headers = { Authorization = "Bearer YOUR_TOKEN" }
```

You can also add it with `codex mcp add`. (If your Codex version only supports stdio MCP servers, point it at a stdio→HTTP bridge instead.)

For a local end-to-end walkthrough (run the bundled dummy app, connect a client, curl examples), see **[LOCAL_DEVELOPMENT.md](LOCAL_DEVELOPMENT.md)**.

## Security model

- **Fail-closed.** Missing required config (auth, a required connection, a missing adapter gem) raises at boot, not at the first request. Without `config.authorize`, every authenticated principal can call every enabled tool.
- **Per-plugin database roles.** Tools run on the connection their plugin wires, switched via Rails' `connected_to`. The DB plugin defaults to a `:reading` connection (Rails `prevent_writes` + your DB grants). Wiring a `:writing` connection is an explicit opt-in that lets `db.query` execute writes — the **database role / replica is the real write boundary**, not SQL parsing in the gem. See [Read-only is enforced by the database](#read-only-is-enforced-by-the-database).
- **One audit line per invocation** through `Rails.logger`: timestamp, principal, plugin, tool, params, outcome, duration. Mark sensitive arguments `redact: true`. Full SQL is logged as submitted.
- **One `WARN` line per rejected request**, with the reason, scheme, and IP — never any credential material. See [Failed authentication](#failed-authentication).
- **What the gem does NOT do:** no "execute arbitrary Ruby" tool; no OAuth/JWT (static API keys and HTTP Basic only); no stdio transport; no web admin UI; **no rate limiting or lockout** — put a throttle in front of the endpoint. Network exposure, TLS, and DB grants are operator-owned — see [SECURITY.md](SECURITY.md).

## Troubleshooting

**"Forbidden: Invalid Host header" on every request.** The transport's DNS-rebinding protection only accepts loopback hosts (`127.0.0.1`, `::1`, `localhost`) by default. Any deployment served from a real domain must list it:

```ruby
config.allowed_hosts = TalkToYourApp.rails_hosts        # your app's own config.hosts…
config.allowed_hosts += ["app.example.com"]             # …or add it explicitly
```

Entries match a bare host (any port) or a full `host:port`. Wildcard and regexp hosts from Rails' `config.hosts` are deliberately not forwarded — add those as literal strings.

**"Session not found" after the first request.** The default transport is stateful: the session created by `initialize` lives in one process's memory. With more than one Puma/Unicorn worker (or multiple replicas), the next request can land on a process that never saw it. Turn on stateless mode:

```ruby
config.stateless = true   # required for multi-worker/multi-replica deployments
```

**Boot fails with a `ConfigurationError`.** That's the fail-closed contract working: the message names exactly what's missing (auth not configured, a plugin without `connection:`, a connection naming a missing `database.yml` key). Fix the named thing; nothing fails silently at request time.

**A write "slipped through" `db.query`.** The Rails `role: :reading` layer is best-effort and bypassable (data-modifying CTEs, stacked statements). The database account is the real boundary — see [docs/read_only_connections.md](docs/read_only_connections.md).

## Compatibility

| | Supported |
| --- | --- |
| Ruby | 3.3+ |
| Rails | 7.2+ |
| MCP spec | 2026-07-28 (Streamable HTTP) |
| MCP SDK (`mcp` gem) | `~> 1.4` |

Tested against Rails 7.2, 8.0, and 8.1 on Ruby 3.3 and 4.0 in CI.

## Upgrade discipline

This gem pins the `mcp` SDK to `~> 1.4` and isolates all SDK touch points to the transport mount and tool compilation. Watch the SDK's releases before bumping, and pin it in your own `Gemfile.lock`.

This gem is also pre-1.0 — releases may include breaking changes, each documented with migration steps in the **[CHANGELOG](CHANGELOG.md)**.

## Development

Working on the gem itself? See **[LOCAL_DEVELOPMENT.md](LOCAL_DEVELOPMENT.md)** for setup, how to run the test suite (and what PostgreSQL/Redis it optionally uses), and how to test against the Rails version matrix.

## Security

See **[SECURITY.md](SECURITY.md)** for how to report vulnerabilities and the
production misconfiguration checklist.

## License

MIT. See [LICENSE](LICENSE).
