# Changelog

All notable changes to this project are documented here. This project follows
[Semantic Versioning](https://semver.org). Pre-1.0 minor releases may include
breaking changes.

## [Unreleased]

## [0.1.0.pre.7] - 2026-07-24

### Removed
- The boot-time `no config.authorize configured` warning, and
  `Configuration#authorize_configured?` along with it. It fired on every boot of
  a deployment that deliberately grants every principal every tool, and could
  not tell that choice apart from an oversight. The behavior it warned about is
  unchanged and still documented in the README security model, the `SECURITY.md`
  operator checklist, and the generated initializer. The writable-DB-connection
  boot warning is unaffected.

### Fixed
- Docs: `rails g talk_to_your_app:custom_tool`'s next-steps output and the
  README "Writing your own plugin" example both told operators to enable a
  plugin without `connection:`, which boot rejects. Both now show
  `connection: false`.
- README's demo poster and video use absolute URLs, so they resolve wherever the
  README is rendered (the files ship in the repo, not in the gem).

## [0.1.0.pre.6] - 2026-07-20

### Fixed
- Boot-time warnings (`no config.authorize configured`, writable DB connection)
  now go to `$stderr` (`Kernel#warn`) instead of the configured logger. The
  configured logger may write to `$stdout`, and boot output on `$stdout` can be
  captured by scripts (e.g. building `DATABASE_URL` from `rails runner`), which
  corrupted the captured value. Warnings never touch `$stdout` at boot now.

## [0.1.0.pre.5] - 2026-07-18

Requires Ruby >= 3.3 and Rails >= 7.2 (the tested CI matrix: Ruby 3.3/4.0 ×
Rails 7.2/8.0/8.1); the `mcp` SDK is pinned `~> 0.25.0`.

### Added
- Cache plugin: `config.plugin :cache, connection: false` exposes `cache.clear`
  (`Rails.cache.clear`). Destructive (drops every cached entry) — scope it to
  trusted principals with `config.authorize`.
- `config.authorize` now receives the tool's arguments as a third parameter:
  `{ |principal, tool_name, args| ... }` (symbol keys, before defaults are
  applied). Enables per-flag/per-task/per-table authorization. Two-parameter
  blocks keep working (Ruby blocks ignore extra arguments); an explicit lambda
  passed via `authorize(&my_lambda)` must accept all three.
- Boot warns (does not fail) when plugins are enabled without `config.authorize`
  — every authenticated principal can otherwise call every enabled tool.
- `SECURITY.md` with private reporting instructions and an operator misconfiguration
  checklist. Packaged in the gem; linked from the README security model.
- `config.allowed_hosts` (default `[]`). Extra `Host` header values accepted by
  the transport's DNS-rebinding protection, beyond the loopback defaults
  (`127.0.0.1`, `::1`, `localhost`). Required for any non-loopback deployment
  (endpoint served from a real domain) — without it the transport rejects every
  request with "Forbidden: Invalid Host header". Forwarded to the mcp SDK's
  `StreamableHTTPTransport(allowed_hosts:)`. The generated initializer defaults
  it to `TalkToYourApp.rails_hosts` — the host app's own `config.hosts` (literal
  host strings only; regexp/IPAddr/dotted-wildcard entries are skipped).
- `config.enabled` (default true). A global on/off switch: when false the
  mounted endpoint serves `503` and boot validation is skipped, so an operator
  can ship the initializer and disable it per-environment without the gem
  refusing to boot on otherwise-incomplete configuration.
- Opt-in DB writes: wiring a `role: :writing` connection into the DB plugin
  (`config.plugin :db, connection: :writer`) lets `db.query` execute writes. It
  is read-only on a `:reading` connection (the default) and logs a loud warning
  at boot on a writable one. `config.authorize` cannot distinguish reads from
  writes, and full SQL is written to the audit log — scope the DB user and log
  sinks accordingly (see the README).
- `config.stateless` (default false). When true the Streamable HTTP transport
  runs stateless — every request is self-contained with no per-session state in
  the transport — so any worker or replica can serve any request. Set it when
  the host app runs more than one Puma/Unicorn worker, where a follow-up request
  can otherwise land on a process that never saw `initialize` and fail with
  "Session not found". Stateless mode does not support SSE streaming or
  server-initiated notifications.
- `app/talk_to_your_app/` convention directory: custom tools live in
  `custom_tools/` (one `TalkToYourApp::Tool` subclass per file, loaded by
  `:custom_tools`). The gem ignores the tree in Zeitwerk and requires the files
  itself. The custom-tool generator writes here.
- `rails g talk_to_your_app:custom_tool NAME` generator — scaffolds a
  `TalkToYourApp::Tool` subclass in `app/talk_to_your_app/custom_tools/`,
  exposed as `custom.<name>`.
- Rake plugin per-task timeout: `config.plugin :rake, allowed: [...], timeout: 60`
  (seconds, default 20). A task exceeding it is hard-killed (process group) and
  returned as a tool error, so a hung task can't pin the web thread.
- `Tool::Context#ip` exposes the request IP (from `Current.ip`), completing
  parity with `#principal` and `#session_id` for custom tools.
- Per-principal tool authorization: `config.authorize { |principal, tool_name| ... }`.
- DB plugin statement timeout on MySQL (`max_execution_time`) in addition to
  PostgreSQL. SQLite and MariaDB have no per-statement timeout (the read-only
  role still applies).
- Flipper plugin: enable/disable across actor, group, and percentage
  (`percentage_of_actors` / `percentage_of_time`) gates, plus a
  `flipper.enabled_flags` tool that lists active flags with their gates and
  last-change timestamps.

### Changed
- **BREAKING — minimum `mcp` SDK raised to `~> 0.25.0`.** 0.23 added `Host`-header
  DNS-rebinding protection (`allowed_hosts:`); 0.24/0.25 add transport fixes
  (SSE write synchronization, header normalization) with no further breaking
  changes to this gem's SDK touch points. Earlier SDK versions reject
  `allowed_hosts:` at boot.
- `config.allowed_origins` now works: it is forwarded to the mcp SDK transport,
  which owns Origin validation (same-origin allowed, case-insensitive matching,
  no-Origin non-browser clients allowed). Previously the gem's own middleware
  rejected every cross-origin request regardless of the setting — the gem-side
  check is removed in favor of the SDK's.
- Connections use `with_connection` inside `connected_to` (with explicit
  `prevent_writes:` from the connection spec) so checkouts return to the pool
  when the tool block ends.
- `401` `WWW-Authenticate` lists only the configured schemes (`Bearer`, `Basic`,
  or both) instead of always advertising Bearer.
- Install generator: sets `config.stateless = true` in production; stronger
  production comments for `enabled`, `authorize`, and the security checklist.
- Gem package includes `CHANGELOG.md` and `SECURITY.md`; ships only operator
  docs (`docs/read_only_connections.md`, `docs/plugin_authoring.md`) rather than
  internal plans/brainstorms.
- README security model updated for opt-in writable DB and the authorize warning.
- **BREAKING — the `:jobs` plugin is split into `:sidekiq` and `:solid_queue`.**
  Enable the backend you run (or both, e.g. mid-migration):
  `config.plugin :sidekiq, connection: false`. The `adapter:` option is gone.
  Tools are now adapter-namespaced — `sidekiq.queue_sizes` / `solid_queue.queue_sizes`
  (etc.) instead of `jobs.queue_sizes` — so both backends can be exposed at once.
- **BREAKING — every plugin must declare `connection:`.** Pass a declared
  connection name, or `connection: false` to opt out (`:sidekiq`, `:solid_queue`,
  `:rake`, and connection-less `:custom_tools` use `false`). Enabling any plugin
  without the option fails at boot. `:db` and `:flipper` require a real
  connection (`connection: false` is rejected).
- **BREAKING — connections are wired into plugins by name.** Plugins no longer
  hardcode a connection name; you declare connections and wire one into each
  plugin that needs a database: `config.plugin :db, connection: :readonly` and
  `config.plugin :flipper, connection: :writer`. Enabling `:db` or `:flipper`
  without `connection:` now fails at boot with an actionable error. The per-tool
  hardcoded connection names were removed. `config.connection`'s `role:` now
  defaults to `:reading`. **Existing initializers must add `connection:` to
  `config.plugin :db`/`:flipper`.** **Plugin authors:** the `requires_connection`
  DSL and the `Plugin.required_connections` alias are removed entirely — the
  framework now enforces `connection:` universally (see above), so plugins no
  longer mark themselves. `Tool::Context#connection_name` is now a no-arg reader
  (it reports the connection the call ran on); pass an explicit override to
  `ctx.connection(:name)`, not to `connection_name`. Connection resolution is
  most-specific-first: an explicit `ctx.connection(:name)` arg, then the tool's
  own static `connection` DSL, then the plugin-wired `connection:` default. A
  tool that declares its own connection is no longer overridden by the
  plugin-wired one (custom tools), and a tool's declared connection is now
  validated at boot, not at first call.
- **BREAKING — Flipper enforces `role: :writing` at boot.** A Flipper connection
  declared `role: :reading` previously booted and failed only on the first write;
  it now fails closed at boot.
- **Jobs adapter contract:** the `required_gem` hash key was renamed from
  `name:` to `gem_name:` (e.g. `{ const: "Sidekiq", gem_name: "sidekiq" }`),
  matching the Plugin DSL's `requires_gem` option. **Third-party jobs adapters
  must update their `REQUIRED_GEM`/`required_gem` to use `gem_name:`** — with the
  old `name:` key the boot-time gem check still runs but its error message shows
  a blank gem name.
- **Jobs adapter response shape:** `enqueued_at` is now an ISO-8601 string
  across all adapters, and every job hash carries the same keys (`jid`, `class`,
  `queue`, `args`, `enqueued_at`, `error_message`), with `error_message` nil for
  jobs that have not failed.
- **Flipper enable/disable response shape:** now `{ name, enabled, gate_type,
  gates }` (previously `{ name, enabled, actor }`), consistent with `read_flag`.
