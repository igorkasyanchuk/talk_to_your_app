# Local development

How to work on the `talk_to_your_app` gem and run its test suite.

## Prerequisites

- **Ruby** >= 3.3 (CI runs 3.3 and 4.0).
- **Bundler** (`gem install bundler`).
- **SQLite** — the default test database; the `sqlite3` gem is bundled, no server needed.
- **PostgreSQL** — _optional_ for the test suite (DB-plugin read-only-role and timeout tests skip without it) but **required to run the dummy app as a local MCP server** (see below). A running server on `localhost:5432` reachable as the `postgres` superuser (DBngin, Postgres.app, Homebrew, or Docker all work).
- **Redis** _(optional)_ — exercises the Sidekiq plugin. A running server on `localhost:6379`.

Tests that need PostgreSQL or Redis **skip cleanly** when the service is not reachable, so `bundle exec rake test` always runs; you just get fewer assertions without the services.

## Setup

```sh
git clone https://github.com/igorkasyanchuk/talk_to_your_app.git
cd talk_to_your_app
bundle install
```

## Running tests

The suite is Minitest, driven by Rake.

```sh
# Everything
bundle exec rake test

# A single file (Rake)
bundle exec rake test TEST=test/talk_to_your_app/configuration_test.rb

# A single file (plain Ruby — fastest feedback)
bundle exec ruby -Itest -Ilib test/talk_to_your_app/configuration_test.rb

# Filter by test name within a file
bundle exec rake test TEST=test/talk_to_your_app/configuration_test.rb TESTOPTS="--name=/mount_at/"
```

### What the suite touches

- **SQLite** — the dummy app's primary database, in-memory, set up automatically by `test/test_helper.rb`.
- **PostgreSQL** — `test/support/pg_test_db.rb` connects as the `postgres` superuser and (re)creates a `ttya_test` database plus a genuinely read-only role (`ttya_ro`, `GRANT SELECT` only) on each run. Nothing to set up by hand; if Postgres is unreachable, the DB-plugin tests skip.
- **Redis** — the Sidekiq adapter tests use database **15** at `redis://localhost:6379/15` and flush it between tests. Override with `TTYA_TEST_REDIS_URL` if your Redis lives elsewhere:

  ```sh
  TTYA_TEST_REDIS_URL=redis://localhost:6380/15 bundle exec rake test
  ```

- **MySQL/MariaDB** — the DB plugin has a MySQL statement-timeout path, but it is not exercised locally (no `mysql2` in the bundle). Its SQL is unit-tested without a server in `test/talk_to_your_app/plugins/db/timeout_statement_test.rb`.

## Testing against multiple Rails versions

The gem supports Rails 7.2, 8.0, and 8.1 via [Appraisal](https://github.com/thoughtbot/appraisal). The version matrix lives in `Appraisals`.

```sh
# Generate/install the per-version gemfiles under gemfiles/ (needs network)
bundle exec appraisal install

# Run the suite against one Rails version
bundle exec appraisal rails-8.0 bundle exec rake test

# …or all of them
bundle exec appraisal rake test
```

CI runs the full Rails × Ruby matrix (see `.github/workflows/ci.yml`).

## Running the dummy app as a local MCP server (and connecting Claude)

The bundled `test/dummy` app can run as a real MCP server so you can point an MCP
client such as **Claude Code** or **Claude Desktop** at it and exercise the gem
end to end. In `development` it auto-configures **HTTP Basic auth** and enables
the bundled plugins (see `test/dummy/config/initializers/talk_to_your_app.rb`).

It runs on **PostgreSQL** so the DB plugin can connect through a genuine
read-only database user — the same pattern you'd use in production. You need a
local Postgres reachable as the `postgres` superuser (see Prerequisites).

It ships `User`, `Post`, and `Comment` models (with associations) so there's real
relational data to query.

### 1. One-time database setup

```sh
cd test/dummy
RAILS_ENV=development bundle exec ruby bin/rails db:prepare
```

`db:prepare` creates `ttya_dummy_development`, loads the schema, seeds sample data
(users Alice/Bob, their posts and comments, plus a `widgets` table), **and
provisions a read-only Postgres role** `ttya_dummy_ro` (`GRANT SELECT` only).
The DB plugin's `:replica_readonly` connection authenticates as that role against
the **same database**, so writes are rejected by Postgres itself — not just by
Rails. Override any of the names with `TTYA_DEV_DB_*` / `TTYA_DEV_RO_*` env vars.

Re-run `RAILS_ENV=development bundle exec ruby bin/rails db:seed` any time to
re-grant or top up data; explore the models with
`RAILS_ENV=development bundle exec ruby bin/rails console`.

### 2. Start the server

```sh
# from test/dummy
RAILS_ENV=development bundle exec ruby bin/rails server -p 3000
```

The MCP endpoint is now at **`http://localhost:3000/mcp`**.

- **Auth (two options):**
  - **HTTP Basic** — username `dev` / password `secret` (override with
    `TTYA_DEV_USER` / `TTYA_DEV_PASSWORD`); the username is the logged principal.
  - **Per-user Bearer token** — each seeded user has an `api_token`. Open
    <http://localhost:3000/> to see the users and their tokens, and send
    `Authorization: Bearer <token>` — the audit log then attributes calls to
    that user's name. (Restart the server after seeding new users so their
    tokens are picked up.)
- **Root page:** `http://localhost:3000/` shows DB stats and the per-user tokens.
- **Plugins enabled:** DB, **Solid Queue**, **Flipper**, and **Rake** (allow-listed tasks `demo:stats`, `demo:echo`).
- **Tools available:** `db.query` (read-only SQL over `users` / `posts` /
  `comments` / `widgets`), `db.tables`, `db.schema` (columns/indexes/FKs);
  `solid_queue.queue_sizes` / `solid_queue.recent_jobs` /
  `solid_queue.failed_jobs` / `solid_queue.rate_metrics`; `flipper.list_flags` /
  `read_flag` / `enable_flag` / `disable_flag` / `enabled_flags`; `rake.run`
  (allow-listed `demo:stats` and `demo:echo[message]`); and custom tools
  `custom.make_admin` / `custom.toggle_active` (which write user state).
- **Seed data also includes** 3 feature flags (`new_dashboard` on,
  `beta_search` 25% of actors, `dark_mode` 10% of the time) and a few queued
  `HeartbeatJob`s, so the Flipper and Jobs tools have something to show
  immediately.
- Audit log lines stream to the server's stdout, one per tool call.

### Background jobs (Solid Queue)

`db:prepare` loads Solid Queue's tables and enqueues a few jobs. To actually
process them — and run the **`HeartbeatJob` every minute** (`config/recurring.yml`)
— start the Solid Queue worker in a second terminal:

```sh
cd test/dummy
RAILS_ENV=development bundle exec ruby bin/jobs
```

Watch the queue with the `solid_queue.*` MCP tools (or `bin/rails console`).

### 3. Connect Claude Code

Add the server with an `Authorization` header — either the Basic credential
(`base64("dev:secret")` = `ZGV2OnNlY3JldA==`) or a per-user Bearer token copied
from <http://localhost:3000/>:

```sh
# Basic
claude mcp add --transport http talk-to-your-app http://localhost:3000/mcp \
  --header "Authorization: Basic ZGV2OnNlY3JldA=="

# or a per-user token (audit log attributes calls to that user)
claude mcp add --transport http talk-to-your-app http://localhost:3000/mcp \
  --header "Authorization: Bearer <token-from-the-home-page>"
```

#### Computing the base64 value

If you're rolling your own header instead of copy-pasting `ZGV2OnNlY3JldA==`
(e.g. because you changed `TTYA_DEV_USER` / `TTYA_DEV_PASSWORD`, or you're
wiring up a different `user:pass` pair entirely), you need `base64("user:pass")`.
Where that's confusing: Ruby doesn't have a `base64` binary, and `Base64` isn't
autoloaded in `irb` / `rails console` — you'd need `require "base64"` first, and
even then it's an extra hop for a one-liner. The shortest path is your shell:

```sh
# macOS / Linux, any shell with coreutils
echo -n "user:pass" | base64
```

The `-n` matters — without it `echo` adds a trailing newline that gets encoded
too, producing a value that looks right but fails auth. If you'd rather stay
in Ruby (e.g. scripting the header generation):

```sh
ruby -rbase64 -e 'print Base64.strict_encode64("user:pass")'
```

`strict_encode64` (not `encode64`) avoids a trailing newline in the output for
the same reason as `echo -n` above.

Then in a Claude Code session: `/mcp` lists the server, and you can ask it to
run a tool — e.g. *"use talk-to-your-app's db.query to count comments per user"*.

### 4. Connect Claude Desktop

Add an entry to your `claude_desktop_config.json` (Settings → Developer → Edit
Config) and restart the app:

```json
{
  "mcpServers": {
    "talk-to-your-app": {
      "url": "http://localhost:3000/mcp",
      "headers": { "Authorization": "Basic ZGV2OnNlY3JldA==" }
    }
  }
}
```

(Or add it through Settings → Connectors with the same URL and `Authorization`
header.)

### Removing the server

- **Claude Code:** `claude mcp remove talk-to-your-app` (confirm with `claude mcp list`).
- **Claude Desktop:** delete the `talk-to-your-app` entry from
  `claude_desktop_config.json` and restart the app.
- **Stop the dummy server:** Ctrl-C the `rails server` process. To wipe the demo
  database, drop it (this also drops the `ttya_test` DB used by the suite, which
  the tests recreate automatically):
  `RAILS_ENV=development bundle exec ruby bin/rails db:drop`.

### 5. Verify without a client (curl)

MCP is stateful: `initialize` first to get an `Mcp-Session-Id`, then send it plus
the protocol version on each call.

```sh
AUTH="Authorization: Basic ZGV2OnNlY3JldA=="

# initialize → read the Mcp-Session-Id response header
curl -i -sS -X POST http://localhost:3000/mcp -H "$AUTH" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"curl","version":"1"}}}'

# then call a tool (substitute the session id)
curl -sS -X POST http://localhost:3000/mcp -H "$AUTH" \
  -H "Content-Type: application/json" -H "Accept: application/json" \
  -H "Mcp-Session-Id: <id-from-above>" -H "MCP-Protocol-Version: 2025-11-25" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"db.query","arguments":{"sql":"SELECT u.name, p.title, COUNT(c.id) AS comments FROM users u JOIN posts p ON p.user_id = u.id LEFT JOIN comments c ON c.post_id = p.id GROUP BY u.name, p.title ORDER BY u.name","format":"text"}}}'
```

An unauthenticated request returns `401`; a write (`INSERT`/`UPDATE`/`DELETE`)
returns a tool error — Postgres rejects it because `db.query` connects as the
`ttya_dummy_ro` SELECT-only role.

### Generating the initializer in your own app

In a host application, `bundle add talk_to_your_app` then run the install
generator to drop a commented initializer at
`config/initializers/talk_to_your_app.rb`:

```sh
bin/rails generate talk_to_your_app:install
```

The dummy app's initializer is a worked example of the same configuration.

## Debugging

The [`debug`](https://github.com/ruby/debug) gem is a dev/test dependency. Drop a
breakpoint anywhere and run the test:

```ruby
require "debug"
# ...
binding.break   # or: debugger
```

```sh
bundle exec ruby -Itest -Ilib test/talk_to_your_app/configuration_test.rb
```

Execution stops at the breakpoint with an interactive console (`c` to continue,
`n` next, `s` step, `info` for locals).

## Project layout

```
lib/talk_to_your_app/        # the gem
  configuration.rb           # TalkToYourApp.configure surface
  connection_registry.rb     # fail-closed named connections + role switching
  tool.rb / plugin.rb        # the Tool & Plugin DSLs
  plugin_registry.rb         # module-level plugin registry
  auth/                      # Bearer/Basic middleware + validators
  transport/rails_mount.rb   # builds the MCP::Server + Rack app
  audit_logger.rb            # one log line per tool call
  plugins/                   # db, jobs (sidekiq + solid_queue), flipper, rake, custom_tools
lib/generators/talk_to_your_app/  # install, custom_tool generators
test/
  dummy/                     # minimal Rails app for integration tests
  support/                   # test helpers (mcp_driver, pg_test_db, …)
  integration/               # full MCP HTTP round-trip tests
  talk_to_your_app/          # unit tests mirroring lib/
```

## Working on a plugin or tool

Writing a plugin uses the same public DSL as the bundled ones — see
[docs/plugin_authoring.md](docs/plugin_authoring.md). The bundled plugins under
`lib/talk_to_your_app/plugins/` are good references; each has unit tests under
`test/talk_to_your_app/plugins/` and an end-to-end test under `test/integration/`.

## Conventions

- Every Ruby file starts with `# frozen_string_literal: true`.
- No linter is configured; match the surrounding style.
- New behavior ships with tests. Integration tests drive the real MCP stack via
  `test/support/mcp_driver.rb` (the `initialize` handshake → `tools/list` →
  `tools/call`).
- Keep SDK touch points isolated to `transport/rails_mount.rb` and tool
  compilation; the `mcp` gem is pinned `~> 1.4` (see the README upgrade note).
