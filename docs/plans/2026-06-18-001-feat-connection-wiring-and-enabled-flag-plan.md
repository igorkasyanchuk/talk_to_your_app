---
title: "feat: Pluggable connection wiring, global enabled flag, opt-in DB writes"
type: feat
status: completed
date: 2026-06-18
deepened: 2026-06-18
---

# feat: Pluggable connection wiring, global enabled flag, opt-in DB writes

## Summary

Three changes to the operator-facing configuration of `talk_to_your_app`: (1) a global `config.enabled = false` switch that makes the whole gem inert without removing the initializer; (2) replacing each plugin's hardcoded connection name with an explicit `config.plugin :db, connection: :read` wiring so operators define connections once and route them to plugins by name (with `role:` now defaulting to `:reading`); and (3) letting the DB plugin run against a `:writing` connection — opt-in, loudly warned — so `db.query` can execute writes when an operator deliberately wires one in. The connection-wiring change is a deliberate breaking change, accepted pre-1.0.

---

## Problem Frame

The connection model couples plugins to magic connection names: the DB plugin hardcodes `:replica_readonly`, the Flipper plugin hardcodes `:flipper_writer`, in both the plugin's `requires_connection` declaration and every tool's `CONNECTION` constant (`lib/talk_to_your_app/plugins/db/tools/query.rb:18`). An operator cannot name their own connections, cannot point the DB plugin at a writable database even deliberately (boot hard-fails on a `:writing` role — `lib/talk_to_your_app/plugins/db/plugin.rb:42`), and cannot disable the gem in one environment without deleting configuration. The connection DSL also forces three keyword arguments (`name`, `database:`, `role:`) where `role:` is almost always `:reading`.

---

## Requirements

- R1. `config.enabled = true/false` (default `true`) toggles the whole gem. When `false`, the mounted endpoint serves nothing and boot validation is skipped, so a partially-configured-but-disabled gem still boots.
- R2. `config.connection` defaults `role:` to `:reading`; `database:` stays required. Existing explicit-`role:` calls keep working.
- R3. Plugins that need a database connection receive it explicitly via `config.plugin <name>, connection: <conn_name>`. Hardcoded connection names are removed.
- R4. A plugin that requires a connection but is enabled without `connection:` fails at boot with a clear, actionable error (breaking change — existing `config.plugin :db` / `config.plugin :flipper` now require the arg).
- R5. The DB plugin wired to a `:reading` connection stays read-only (write prevention on, as today). Wired to a `:writing` connection, `db.query` may execute writes — a loud warning is logged at boot and the risk is documented.
- R6. The Flipper plugin requires a `:writing` connection (it toggles flags); wiring a `:reading` connection fails at boot.
- R7. Documentation (README, `docs/read_only_connections.md`), the dummy app initializer, and the install generator reflect the new wiring, including a worked "run `:db` with a write DB" example.

---

## Scope Boundaries

- Not adding `enabled:` per-plugin or per-connection — global only (per the decision: `config.enabled`). Plugins remain individually off-by-default by not being listed.
- Not adding SQL parsing or statement-type filtering to the writable DB path — writes are gated solely by the wired connection's role plus operator intent. The read-only guarantee for `:reading` connections is unchanged.
- Not changing the auth, audit-logging, transport, or rake/jobs/custom_tools plugins beyond what the connection-resolution threading requires.
- Not adding a deprecation/back-compat shim for the old hardcoded names — explicit `connection:` is required (breaking change accepted pre-1.0).

---

## Context & Research

### Relevant Code and Patterns

- `lib/talk_to_your_app/configuration.rb:108` — `#plugin(name, **options)` stores per-plugin options in `@enabled_plugins`; `#connection(name, database:, role:, ...)` at `:120` builds the `ConnectionSpec`.
- `lib/talk_to_your_app/plugin.rb:19` — `requires_connection(*names)` class DSL (currently stores names); role policy enforced in subclass `validate_enablement!`.
- `lib/talk_to_your_app.rb:73` — `TalkToYourApp.required_connections` gathers `[name, requester]` pairs from `plugin_class.required_connections` **and** each `tool_class.connection`, feeding `ConnectionRegistry.validate!`.
- `lib/talk_to_your_app/tool.rb:54` — `Context#connection(name=nil)` falls back to the tool's static `connection` DSL; `:160`/`:179` already thread `plugin_name` into `to_mcp_tool` → `dispatch` (but not yet into `invoke`/`Context`).
- `lib/talk_to_your_app/plugins/db/plugin.rb:33-52` — `requires_connection :replica_readonly`, `validate_enablement!` hard-rejects non-`:reading`. `Db.max_rows` (`:20`) is the established pattern for a plugin reading its own enabled options.
- `lib/talk_to_your_app/plugins/db/tools/query.rb:18,53` — `CONNECTION = :replica_readonly`; `timeout_ms` does `ConnectionRegistry.fetch(CONNECTION)`. Same `CONNECTION` constant in `tables.rb:12` and `schema.rb:13`.
- `lib/talk_to_your_app/plugins/flipper/plugin.rb:134` — `requires_connection :flipper_writer`; tools declare `connection :flipper_writer`.
- `lib/talk_to_your_app/transport/rails_mount.rb:17` — `RailsMount.build` assembles the Rack app; `lib/talk_to_your_app/railtie.rb:35` — `validate_boot!` runs all fail-closed checks.
- `lib/talk_to_your_app/connection_registry.rb:72` — `with(name)` switches role via `connected_to`; a `:writing` role does not set `prevent_writes`, so writes already flow once a writer is wired and validation permits it.

### Institutional Learnings

- `docs/read_only_connections.md` is the canonical operator guide for the read-only contract; it must stay consistent with R5/R6 and the new wiring.
- The gem is fail-closed by design (`configuration.rb:4-7`): every misconfiguration surfaces at boot, never at first request. New validation (R4/R6) must follow this — raise in the boot path, not at call time.

---

## Key Technical Decisions

- **Connection name flows from operator config, resolved at call time** (not from a tool/plugin constant): thread the already-available `plugin_name` from `dispatch` into `invoke` → `Context`, and have `ctx.connection` resolve the wired name from `enabled_plugins[plugin_name][:connection]`. Rationale: reuses existing `plugin_name` plumbing; one source of truth (the operator's `connection:` option); removes the hardcoded constants cleanly. Resolution precedence: **explicit `ctx.connection(:name)` arg → plugin-wired `connection:` → tool's static `connection` DSL → ConfigurationError.** The static-DSL fallback preserves custom-tool behavior.
- **`requires_connection` becomes a no-arg marker.** A plugin declares it needs exactly one wired connection; the *name* is supplied by the operator. Role policy stays in each plugin's `validate_enablement!`. Rationale: decouples "needs a connection" (framework concern, enforced generically) from "needs a *reading/writing* connection" (plugin concern).
- **`role:` defaults to `:reading`.** Matches the read-biased design and the safe default; writers opt in explicitly. `database:` stays required because connection name and `database.yml` key are genuinely distinct (the README examples already differ, e.g. name `:replica_readonly` → database `"primary"`).
- **DB writes are gated by the deliberate `:writing`-role wiring, not by SQL inspection, and not by the boot warning.** The genuine safeguard is that the operator must *declare* a `role: :writing` connection **and** wire it into `:db` — two explicit, documented steps. The boot warning is **detection/audit only**, not risk mitigation: it does not gate, requires no acknowledgement, and fires once into a stream that may be unmonitored, so it cannot prevent the "wired the wrong connection" mistake — it only leaves a forensic trail. Rationale: the gem already does not parse SQL; layering a parser would be false security. (Per the locked decision, no second `allow_writes:` token is added — the role wiring is the opt-in.)
- **Boot-validation ordering is load-bearing and must be specified, not left to method-call order.** `validate_boot!` runs `PluginRegistry.validate_enabled!` (which invokes each plugin's `validate_enablement!`) **before** `ConnectionRegistry.validate!` (`railtie.rb:36-37`). So the generic "plugin requires a `connection:` but none/typo'd was wired" check must own that error: each plugin's `validate_enablement!` must `return` early when `opts[:connection]` is nil and must guard with `ConnectionRegistry.registered?` before calling `fetch` (which raises on a missing/`nil` name — `connection_registry.rb:41-45`). Otherwise the promised "clear, actionable" R4 error is pre-empted by `fetch`'s "not registered" message, or crashes on `nil.to_sym`. Rationale: keep one authoritative message per failure and preserve fail-closed-at-boot.
- **`config.authorize` cannot distinguish reads from writes on `db.query`** — the tool name is always `"db.query"` (`configuration.rb:88`), so an authorizer like `tool.start_with?("db.")` permits SELECT and UPDATE identically. The access control for the write path is **database-user privilege scoping**, not the authorizer. This is documented as an explicit limitation (U4/U6) rather than changing the authorize signature, consistent with "not changing auth."
- **`config.enabled` is resolved per-request inside the Rack app, not only at `build` time.** `rack_app` is memoized (`talk_to_your_app.rb:51`) and the host mounts it in `routes.rb`, which can be evaluated before the operator's initializer sets `enabled`. To avoid a stale-`enabled` app being captured at build time, the mounted Rack app checks `configuration.enabled` on each call and short-circuits to a disabled response when false; `validate_boot!` also returns early when disabled (skipping connection/plugin checks). **Auth validation is independent of `enabled`** — it is not "made invalid-when-enabled"; re-enabling a gem that was shipped without auth correctly fails closed at boot. Rationale: an operator must be able to ship the initializer and disable per-environment without the gem refusing to boot, without memoization/route-load ordering silently serving tools.
- **The disabled endpoint returns `503` (not `404`).** `503` is the machine-readable "temporarily unavailable" signal and distinguishes "gem disabled" from "route missing" for monitoring and for host catch-all routes that would swallow a `404`.

---

## Open Questions

### Resolved During Planning

- Scope of `enabled:` → global `config.enabled` only (user decision).
- DB + writing connection → opt-in writes allowed, warned, documented (user decision).
- Back-compat for hardcoded names → none; explicit `connection:` required (user decision).
- How tools learn their operator-wired connection → thread `plugin_name` into `Context` (see Key Technical Decisions).

### Deferred to Implementation

- Exact disabled-response body and whether to emit a one-line "gem disabled" log at boot — settle when wiring `RailsMount`. (Status code is decided: `503`.)

> **Resolved (was deferred):** `Context` exposes a public `connection_name` reader returning the *single* name resolved by `Context#connection`'s precedence, and `query.rb`'s `timeout_ms` reads that. This is a correctness requirement, not a style choice: a `Db.connection_name`-via-options helper would only see the plugin-wired name and would silently fetch the timeout from a different spec than the one a `ctx.connection(:explicit)` override actually ran on. Resolve the name once, in one place.

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

Operator-facing DSL, before → after:

```ruby
# BEFORE — magic names, hardcoded in the plugins
config.connection :replica_readonly, database: "primary", role: :reading
config.connection :flipper_writer,   database: "primary", role: :writing
config.plugin :db
config.plugin :flipper

# AFTER — define connections, wire them by name; role defaults to :reading
config.enabled = true                                  # global kill-switch (default true)
config.connection :read,  database: "primary"          # role: :reading implied
config.connection :write, database: "primary", role: :writing
config.plugin :db,      connection: :read              # read-only (write prevention on)
config.plugin :flipper, connection: :write             # requires a :writing connection

# AFTER — opt-in DB writes (deliberate, warned, documented)
config.plugin :db, connection: :write                  # db.query may execute writes
```

DB plugin role behavior (decision matrix):

| Wired connection role | DB plugin at boot | `db.query` behavior |
|---|---|---|
| `:reading` (default) | boots silently | reads only; writes raise `ActiveRecord::ReadOnlyError` (unchanged) |
| `:writing` (opt-in)  | boots **with a loud warning** | reads **and writes** execute |
| none wired           | **ConfigurationError** at boot | n/a |

Connection resolution at call time:

```
ctx.connection(:explicit)  → use :explicit
ctx.connection             → enabled_plugins[plugin_name][:connection]   (operator-wired)
                           → tool's static `connection` DSL              (custom tools)
                           → ConfigurationError
```

---

## Implementation Units

### U1. Global `config.enabled` switch

**Goal:** A `config.enabled` boolean (default `true`) that makes the gem inert — skips boot validation and serves nothing — without removing the initializer.

**Requirements:** R1

**Dependencies:** None

**Files:**
- Modify: `lib/talk_to_your_app/configuration.rb` (add `attr_accessor :enabled`; default `true` in `initialize`)
- Modify: `lib/talk_to_your_app/railtie.rb` (`validate_boot!` early-returns the *connection/plugin* checks when disabled)
- Modify: `lib/talk_to_your_app/transport/rails_mount.rb` (the mounted Rack app checks `configuration.enabled` **per request** and returns a `503` disabled response when false)
- Test: `test/talk_to_your_app/configuration_test.rb`; a new `test/integration/` test that boots the dummy app with `config.enabled = false` and drives a real request

**Approach:**
- Default `@enabled = true`. `validate_boot!` checks `return unless configuration.enabled` before the plugin/connection validation. **Do not** skip `validate_auth!` in a way that lets a re-enabled-without-auth gem boot — auth config is independent of `enabled`; the simplest correct shape is for the disabled early-return to skip only the connection/plugin checks (those are what an operator can't satisfy while intentionally disabled), or to accept that re-enabling without auth fails closed at boot (the desired behavior).
- The **disabled check must be evaluated per request**, not captured at `build` time: because `rack_app` is memoized (`talk_to_your_app.rb:51`) and `routes.rb` may load before the initializer runs, branching only inside `build` risks capturing a stale `enabled`. The built Rack app reads `configuration.enabled` on each call and returns a `503` (`{"content-type"=>"text/plain"}`, body `"disabled"`) when false, so the host's `mount TalkToYourApp.rack_app` always resolves and toggling `enabled` never serves a stale app. The `503` short-circuit sits in front of the auth middleware (nothing to protect when disabled).

**Patterns to follow:** `railtie.rb:44` `validate_auth!`'s early-return style; the `Auth::Middleware`-wrapping shape in `rails_mount.rb:32`.

**Test scenarios:**
- Happy path: `config.enabled` defaults to `true`; gem boots and serves normally as today.
- Edge case: `config.enabled = false` with a plugin enabled but **no connection configured** → boots without raising (connection/plugin validation skipped).
- Integration (real boot, not a direct `build` call): boot the dummy app with `config.enabled = false`, then drive a request to the mount path → `503`, no tool served, no audit line written. This specifically guards the route-load-before-initializer / memoization ordering that a unit test calling `build` cannot.
- Edge case: flip `enabled` from `false` to `true` on the *same* memoized `rack_app` (no `reset_configuration!`) → the endpoint now serves (proves the per-request check, not build-time capture).
- Edge case: toggling back to `true` after `reset_configuration!` restores normal boot validation.

**Verification:** A disabled gem boots on intentionally-incomplete config and serves `503`; flipping `enabled` is honored without a process restart or stale-app surprise; an enabled gem behaves exactly as before.

---

### U2. Default `role:` to `:reading` in `config.connection`

**Goal:** Make `role:` optional on `config.connection`, defaulting to `:reading`; keep `database:` required.

**Requirements:** R2

**Dependencies:** None

**Files:**
- Modify: `lib/talk_to_your_app/configuration.rb` (`#connection` — `role:` becomes a keyword with default `:reading`)
- Test: `test/talk_to_your_app/configuration_test.rb` (or `connection_registry_test.rb`)

**Approach:** Change the signature to `def connection(name, database:, role: :reading, replica: false, statement_timeout: nil)` — `role:` keeps a keyword default (not made positional), so existing explicit-`role:` calls keep working. Keep the existing `:reading`/`:writing` validation and the `replica: true` + `:writing` rejection (`configuration.rb:121-128`) unchanged.

**Patterns to follow:** existing keyword-default + validation in `configuration.rb:120`.

**Test scenarios:**
- Happy path: `config.connection :read, database: "primary"` produces a spec with `role: :reading`.
- Happy path: `config.connection :write, database: "primary", role: :writing` preserves `:writing`.
- Error path: `role: :nonsense` still raises `ConfigurationError`.
- Edge case: `replica: true` with explicit `role: :writing` still raises (unchanged); `replica: true` with defaulted role resolves to `:reading` and is accepted.

**Verification:** A read connection needs only name + `database:`; writer connections and all prior validations are unaffected.

---

### U3. Pluggable connection wiring (framework mechanism)

**Goal:** Route the operator's `config.plugin <name>, connection: <conn>` to tools at call time, replacing hardcoded connection names; fail closed when a connection-requiring plugin is wired none.

**Requirements:** R3, R4

**Dependencies:** None (U4/U5 adopt this)

**Files:**
- Modify: `lib/talk_to_your_app/plugin.rb` (`requires_connection` → no-arg marker; add `requires_connection?`; **remove the now-vestigial `required_connections` alias at `plugin.rb:24`** — after the rename it would return the marker's value, not connection names)
- Modify: `lib/talk_to_your_app.rb` (`required_connections` reads `opts[:connection]` for connection-requiring plugins instead of static names; **skip plugins whose `opts[:connection]` is nil** — `PluginRegistry` owns that error — so a `nil` name never reaches `ConnectionRegistry.registered?`/`reject`, which would `nil.to_sym`-crash)
- Modify: `lib/talk_to_your_app/plugin_registry.rb` (`validate_enabled!` raises when a `requires_connection?` plugin has no `connection:` opt — **before** any plugin's `validate_enablement!` body runs)
- Modify: `lib/talk_to_your_app/tool.rb` (thread `plugin_name` `dispatch → invoke → Context`; `Context#connection` resolution precedence; expose `Context#connection_name` returning the single resolved name)
- Test: `test/talk_to_your_app/plugin_test.rb`, `test/talk_to_your_app/plugin_registry_test.rb`, `test/talk_to_your_app/tool_test.rb`, `test/talk_to_your_app/connection_registry_test.rb`

**Approach:**
- `requires_connection` (no args) sets a flag; `requires_connection?` reads it. Drop the name-collecting behavior **and remove the `required_connections` alias** (`plugin.rb:24`) — the only caller, `TalkToYourApp.required_connections`, is rewritten here.
- `TalkToYourApp.required_connections`: for each enabled plugin where `plugin_class.requires_connection?` **and `opts[:connection]` is non-nil**, push `[opts[:connection], "Plugin #{name.inspect}"]`. Nil connections are *not* pushed — the missing-`connection:` error is owned by `PluginRegistry.validate_enabled!` and a `nil` must never reach `registered?(nil)`/`reject`. Remove the per-tool `tool_class.connection` gathering for bundled plugins.
- **Validation ordering (load-bearing — see Key Technical Decisions):** `PluginRegistry.validate_enabled!` raises `ConfigurationError` for a `requires_connection?` plugin with `opts[:connection].nil?` — message names the plugin and shows `config.plugin :name, connection: :your_connection` — and this missing-`connection:` check must execute *before* it calls any plugin's `validate_enablement!` (so the actionable R4 message wins, not a downstream `fetch` "not registered"). A typo'd-but-present name still flows to `ConnectionRegistry.validate!`, which emits the requester-naming "not registered" message; the per-plugin `validate_enablement!` (U4/U5) must guard with `registered?` before `fetch` so it doesn't pre-empt that.
- `Tool.dispatch` passes `plugin_name:` to `invoke`; `Context.new(..., plugin_name:)`. `Context#connection` resolves via the precedence in Key Technical Decisions, reading the plugin-wired name as `configuration.enabled_plugins[@plugin_name]&.dig(:connection)` so a `nil` `plugin_name` (a tool dispatched outside a plugin — `tool.rb:179` defaults `plugin_name: nil`) falls through to the static-DSL branch instead of raising `NoMethodError`. `Context#connection_name` returns the single resolved name for `timeout_ms` to reuse.

**Patterns to follow:** `Db.max_rows` (`plugins/db/plugin.rb:20`) for reading a plugin's own options; existing `plugin_name` threading at `tool.rb:160,172,180` (verified: `to_mcp_tool` → `dispatch` carries it; `invoke` at `tool.rb:192` does not yet — that gap is what this unit closes).

**Test scenarios:**
- Happy path: a tool calling `ctx.connection` (no arg) resolves to the connection wired via `config.plugin :p, connection: :c`.
- Happy path: `ctx.connection(:explicit)` overrides the wired connection, and `ctx.connection_name` returns `:explicit` (so a co-derived timeout reads the same spec).
- Edge case: a custom tool with a static `connection :foo` DSL and no plugin-wired connection still resolves to `:foo`.
- Edge case: a tool dispatched with `plugin_name: nil` and no static DSL falls through to the terminal `ConfigurationError` without raising `NoMethodError` (the `&.dig` guard).
- Edge case: a bundled tool that still carried a residual static `connection` DSL resolves to the *plugin-wired* connection, not the static one (precedence: plugin-wired beats static DSL — guards the U4/U5 constant removal).
- Error path: a `requires_connection?` plugin enabled **without** `connection:` raises `ConfigurationError` at boot from `PluginRegistry` (not a `fetch`/`nil.to_sym` error), naming the plugin and the fix.
- Error path: a plugin wired a **typo'd/undeclared** name raises the `ConnectionRegistry.validate!` "not registered (required by Plugin :x)" message — distinct from the missing-`connection:` case above.
- Error path: `ctx.connection` with no explicit arg, no wired connection, and no static DSL raises `ConfigurationError` (message in spirit of `tool.rb:57`).
- Integration: `required_connections` returns the operator-wired name for an enabled connection-requiring plugin; `ConnectionRegistry.validate!` still catches a missing `database.yml` key.

**Verification:** Tools run against the operator-wired connection; the two distinct misconfigurations (no `connection:` vs. wrong name) each produce their own clear boot error in the right order; no resolution path crashes on a `nil` connection or `nil` `plugin_name`.

---

### U4. DB plugin: use wired connection, allow opt-in writes

**Goal:** The DB plugin reads its connection from `connection:`; a `:reading` connection stays read-only, a `:writing` connection enables writes with a loud boot warning.

**Requirements:** R3, R5

**Dependencies:** U3

**Files:**
- Modify: `lib/talk_to_your_app/plugins/db/plugin.rb` (`requires_connection` marker; `validate_enablement!` — `:reading` ok silently, `:writing` ok + warn, drop the hard reject; add a `Db.connection_name` helper if chosen for `timeout_ms`)
- Modify: `lib/talk_to_your_app/plugins/db/tools/query.rb` (remove `CONNECTION`/static `connection`; `ctx.connection`; `timeout_ms` resolves the wired connection)
- Modify: `lib/talk_to_your_app/plugins/db/tools/tables.rb` (remove `CONNECTION`/static `connection`; `ctx.connection`)
- Modify: `lib/talk_to_your_app/plugins/db/tools/schema.rb` (same)
- Test: `test/talk_to_your_app/plugins/db/query_test.rb`, `test/integration/db_plugin_integration_test.rb`

**Approach:**
- `validate_enablement!(opts)`: **guard `return unless ConnectionRegistry.registered?(opts[:connection])`** first (mirroring the current `db/plugin.rb:43` guard) so the dedicated connection validation owns the missing/typo'd-name message; only once the spec is known to exist, branch on role: `spec.reading?` → return (silent); `:writing` → log a warning through `configuration.logger` (e.g. "DB plugin wired to a writable connection — db.query can execute writes"). No raise either way. The missing-`connection:` (nil) case is caught generically in U3, before this body runs.
- `timeout_ms` reads `ctx.connection_name` (the single name resolved by `Context#connection`, per U3) — **not** a `Db.connection_name`-via-options helper, which couldn't observe an explicit `ctx.connection(:other)` override and would fetch the timeout from a different spec than the query ran on.
- The write-execution path itself needs no new code: `ConnectionRegistry.with(name)` on a `:writing` role does not set `prevent_writes`, so writes flow; the `ActiveRecord::ReadOnlyError` rescue in `query.rb:44` simply won't trigger.
- **Security notes to carry into U6 docs (no code change here unless decided otherwise):** (a) `db.query`'s `:sql` argument is *not* `redact: true` (`query.rb:23`), so on the writable path full write statements **including literal values** are written to every audit destination (`audit_logger.rb:70`) — the README danger note must say so and recommend a log filter or subscriber scoping. (b) `config.authorize` receives only the tool name `"db.query"` (`configuration.rb:88`) and cannot distinguish reads from writes — database-user privilege scoping is the only write-level access control; document this explicitly so operators don't assume authorizer granularity they don't have.

**Patterns to follow:** existing `validate_enablement!` shape and its `registered?` guard (`db/plugin.rb:42-43`); `Db.max_rows` for option reading.

**Test scenarios:**
- Happy path (read): `config.plugin :db, connection: :read` (a `:reading` connection) → `SELECT` returns rows.
- Error path (read): same config → `UPDATE` is rejected with `ActiveRecord::ReadOnlyError` surfaced as a tool error (unchanged behavior).
- Happy path (write, opt-in): `config.plugin :db, connection: :write` (a `:writing` connection) → an `UPDATE`/`INSERT` executes and the change is visible on a follow-up `SELECT`.
- Edge case: enabling `:db` with a `:writing` connection logs the warning at boot (assert by capturing on a test logger / `ActiveSupport::Notifications`-style array logger — see `test/support/array_logger.rb`), and the gem boots (no raise).
- Error path: enabling `:db` with no `connection:` → `ConfigurationError` at boot from `PluginRegistry` (covered by U3, asserted here for the DB plugin specifically).
- Error path: enabling `:db` with a `connection:` naming an undeclared connection → the `ConnectionRegistry.validate!` "not registered" message, **not** a `fetch` error raised from inside the DB plugin's `validate_enablement!` (proves the `registered?` guard preserves error ordering).
- Integration: the per-query statement timeout still applies on the wired connection, resolved via `ctx.connection_name` (not the removed constant), including when a tool uses an explicit `ctx.connection(:other)` override.

**Verification:** DB plugin honors the wired connection's role — read-only by default, writable by deliberate opt-in with a logged warning.

---

### U5. Flipper plugin: use wired connection, require `:writing`

**Goal:** The Flipper plugin reads its connection from `connection:` and requires a `:writing` role (it toggles flags).

**Requirements:** R3, R6

**Dependencies:** U3

**Files:**
- Modify: `lib/talk_to_your_app/plugins/flipper/plugin.rb` (`requires_connection` marker; `validate_enablement!` requires wired role `:writing`, raises on `:reading`)
- Modify: `lib/talk_to_your_app/plugins/flipper/tools/list_flags.rb`, `read_flag.rb`, `enable_flag.rb`, `disable_flag.rb`, `enabled_flags.rb` (remove static `connection :flipper_writer`; use `ctx.connection`)
- Test: `test/talk_to_your_app/plugins/flipper/flipper_test.rb`, `test/integration/flipper_plugin_integration_test.rb`

**Approach:** Flipper currently has **no** `validate_enablement!` (only `requires_connection` + `requires_gem` — `flipper/plugin.rb:133-137`), so the registry checks the connection *exists* but never its role. This unit *adds* a role check: `validate_enablement!(opts)` guards `return unless ConnectionRegistry.registered?(opts[:connection])` (let U3/registry own the missing/typo'd-name error), then raises `ConfigurationError` ("Flipper plugin requires a connection with role: :writing") if the existing spec is not `:writing`. Tools switch to `ctx.connection`.

> **Behavior change (not preservation):** today a `:flipper_writer` declared with `role: :reading` boots and only fails later at write time. After this unit it fails *at boot*. This is a deliberate tightening — see the System-Wide Impact note; it is not an unchanged invariant.

**Patterns to follow:** U4's `validate_enablement!` + `registered?` guard; the DB plugin's prior role-enforcement shape (`db/plugin.rb:42-51`), inverted to require `:writing`.

**Test scenarios:**
- Happy path: `config.plugin :flipper, connection: :write` (a `:writing` connection) → `enable_flag`/`disable_flag` toggle and `read_flag`/`list_flags`/`enabled_flags` work.
- Error path (new behavior): `config.plugin :flipper, connection: :read` (a `:reading` connection) → `ConfigurationError` **at boot** (previously this would have booted and failed only on the first write — assert the boot-time failure explicitly).
- Error path: `config.plugin :flipper` with no `connection:` → `ConfigurationError` at boot (U3, asserted for Flipper).

**Verification:** Flipper runs against an operator-wired writer and refuses a read-only connection at boot.

---

### U6. Docs, dummy app, and install generator

**Goal:** Bring all operator-facing docs and templates in line with the new wiring, the `config.enabled` flag, and the opt-in DB-write example.

**Requirements:** R7

**Dependencies:** U1, U2, U3, U4, U5

**Files:**
- Modify: `README.md` (config table: `config.enabled` row; `config.connection` row → `role:` optional/default `:reading`; `config.plugin` row → `connection:` required for db/flipper; DB section → "running `:db` with a write DB" opt-in example + warning; Flipper section → `connection:` wiring)
- Modify: `docs/read_only_connections.md` (all examples → `config.plugin :db, connection: :replica_readonly`; note the writable opt-in points back to the README)
- Modify: `test/dummy/config/initializers/talk_to_your_app.rb` (`config.plugin :db, connection: :replica_readonly`; `config.plugin :flipper, connection: :flipper_writer`)
- Modify: install generator initializer template under `lib/generators/talk_to_your_app/install/` (generated initializer uses `connection:` wiring and shows `config.enabled`)
- Modify: `CHANGELOG.md` (breaking change note: explicit `connection:` now required; new `config.enabled`; opt-in DB writes)
- Test: `test/generators/install_generator_test.rb` (assert the generated initializer contains the new wiring)

**Approach:** Mechanical doc/template edits matching U1–U5. The README's DB write example must carry an explicit danger note covering all three plan-level security facts surfaced in U4: (1) `db.query` executes arbitrary writes — scope the DB user's privileges as the real control; (2) `config.authorize` cannot distinguish reads from writes (same tool name) — do not rely on it to gate writes; (3) full SQL **including literal values** appears in audit logs on the writable path — filter or scope log destinations accordingly. Also note that a custom tool using a static `connection :writer` DSL does **not** receive the DB plugin's boot warning — recommend custom tools rely on plugin wiring. The dummy app already declares `:replica_readonly` and `:flipper_writer` connections; add `connection:` to its `config.plugin :db`/`:flipper` lines, and **drop the now-redundant `role: :reading`** from its `:replica_readonly` declaration so the demo exercises the new default and stays consistent with the README "AFTER" examples (keep `role: :writing` on `:flipper_writer`, which is non-default).

**Execution note:** Update the install-generator template and its test together so the generated initializer stays assertion-covered.

**Test scenarios:**
- Integration: `install_generator_test` asserts the generated initializer wires `connection:` and references `config.enabled`.
- Test expectation: none for README/`read_only_connections.md`/CHANGELOG/dummy-initializer edits — documentation and demo config, no behavior of their own (the dummy initializer is exercised indirectly by the integration suite).

**Verification:** A fresh `rails g talk_to_your_app:install` produces a working initializer under the new API; docs match shipped behavior; the dummy app boots under the new wiring.

---

## System-Wide Impact

- **Interaction graph:** `Tool.dispatch → invoke → Context#connection` is the new connection-resolution path; `plugin_name` (already threaded to `dispatch`) now also reaches `Context`. `RailsMount.build` and `Railtie.validate_boot!` both gain an `enabled` gate.
- **Error propagation:** New *configuration* failures are boot-time `ConfigurationError`s (fail-closed) for correctly-shaped-but-wrong configs. One exception by construction: `Context#connection`'s terminal "no connection resolvable" error is call-time (`tool.rb:57`) — it cannot fire for bundled tools (their `plugin_name` is always set in `collect_tools`, `rails_mount.rb:42`) but is reachable for a misconfigured custom tool. The DB-write warning is a log line, not an error.
- **State lifecycle risks:** `config.enabled` interacts with the memoized `@rack_app` (`lib/talk_to_your_app.rb:51`) — `reset_configuration!` already clears it; tests toggling `enabled` must reset to avoid a stale app.
- **API surface parity:** This is a **breaking** operator-config change. Every initializer enabling `:db` or `:flipper` must add `connection:`. The dummy app, install generator, README, and `docs/read_only_connections.md` are the surfaces that must move together (U6).
- **Integration coverage:** The read-only-enforced vs writable DB distinction (U4) and Flipper's writer requirement (U5) are only proven by integration tests that actually switch roles and attempt writes — unit tests with mocked connections won't prove the `connected_to(role:)` behavior.
- **Unchanged invariants:** Auth *mechanics*, the transport, statement-timeout mechanics, `max_rows`, and the jobs/rake/custom_tools plugins keep their current behavior. The read-only guarantee for `:reading` connections (Rails write prevention + DB role) is unchanged. **Two deliberate behavior changes, not invariants:** (1) Flipper now enforces a `:writing` role *at boot* (previously a misrole'd connection failed only at write time — U5); (2) audit logs now carry write-statement SQL when the DB plugin is wired writable (new data flow, not a logging change — U4). Auth's *coverage* is unchanged but its *granularity* is a known limit on the writable path (authorize can't see read-vs-write).

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Operators silently get a writable `db.query` by wiring the wrong connection | The real guard is the **deliberate two-step opt-in**: declare a `role: :writing` connection *and* wire it into `:db`. The boot warning is **detection/audit only** — it does not prevent the mistake, it records it. Read-only stays the default. Per the locked decision, no second `allow_writes:` token is added. |
| A writable `db.query` is under-controlled by `config.authorize` and over-exposed in audit logs | Documented as explicit limitations (U4/U6): authorize can't distinguish read vs write on one tool name, so **database-user privilege scoping** is the write-level control; full SQL incl. literals appears in audit logs, so scope/filter log destinations. No SQL parsing is added (false security). |
| Breaking change strands existing initializers on upgrade | Two distinct, ordered boot errors (missing `connection:` vs. unknown name); CHANGELOG breaking-change note. **Premise:** acceptable because the gem is pre-1.0 (`0.1.0.pre`) with no known external installs and Rails apps hit boot before serving — stated as an assumption, not a guarantee. No upgrade generator is provided. |
| `config.enabled` honored late / stale due to memoized `rack_app` | The disabled check is evaluated **per request** inside the Rack app (not captured at `build`), so route-load-before-initializer ordering and memoization can't serve a stale-`enabled` app; covered by a real-boot integration test in U1. Returns `503` (distinguishable from a missing route). |
| Connection-resolution precedence regresses custom tools, or terminal error fires at call time | Static `connection` DSL retained as a fallback for custom tools (plugin-wired beats static for bundled tools); `plugin_name`-nil guarded with `&.dig`. The terminal `ConfigurationError` is inherently call-time — bundled tools avoid it because `plugin_name` is always set in `collect_tools` (`rails_mount.rb:42`); the "fails at boot" claim covers correctly-wired configs, not the resolution fallthrough. |

---

## Documentation / Operational Notes

- README, `docs/read_only_connections.md`, the install generator template, and the dummy initializer all move in U6; treat them as one consistency set.
- CHANGELOG must call out the breaking `connection:` requirement prominently so upgraders see it.

---

## Sources & References

- Connection DSL & validation: `lib/talk_to_your_app/configuration.rb`, `lib/talk_to_your_app/connection_registry.rb`
- Plugin/tool wiring: `lib/talk_to_your_app/plugin.rb`, `lib/talk_to_your_app.rb`, `lib/talk_to_your_app/tool.rb`, `lib/talk_to_your_app/plugin_registry.rb`
- DB / Flipper plugins: `lib/talk_to_your_app/plugins/db/`, `lib/talk_to_your_app/plugins/flipper/`
- Boot & transport: `lib/talk_to_your_app/railtie.rb`, `lib/talk_to_your_app/transport/rails_mount.rb`
- Operator docs: `README.md`, `docs/read_only_connections.md`, `test/dummy/config/initializers/talk_to_your_app.rb`
