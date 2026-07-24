---
title: "feat: talk_to_your_app gem v1 — Rails-native MCP server"
type: feat
status: completed
date: 2026-06-01
origin: docs/brainstorms/talk-to-your-app-gem-v1-requirements.md
---

# feat: talk_to_your_app gem v1 — Rails-native MCP server

## Summary

Build the `talk_to_your_app` gem as a thin Rails layer over the official `modelcontextprotocol-ruby-sdk`: a Railtie that mounts the SDK's Streamable HTTP transport at `/mcp`, an auth middleware accepting `Authorization: Bearer` (API key) or `Basic`, a fail-closed connection registry that gates plugin boot on declared DB roles, a class-based Tool DSL, an audit logger, and four bundled plugins (DB, Jobs with Sidekiq + Solid Queue adapters, Flipper, Health). 12 implementation units across foundations, plugins, and docs.

---

## Problem Frame

Operators of mid-sized Rails apps want to ask their running app real questions over MCP today, and the existing Ruby MCP gems are framework-agnostic — they don't know Rails replicas, jobs backends, or feature-flag tooling. Origin doc covers the WHAT; this plan defines HOW: depend on a maintained protocol implementation (the official Ruby SDK shipped May 2026), put the gem's value-add in the Rails-native layer above it, and keep the wire-protocol layer out of our maintenance burden. See origin for the full pain narrative.

---

## Requirements

- R1. HTTP/SSE transport only; no stdio.
- R2. Rack-mountable engine at configurable path, default `/mcp`.
- R3. Rails 7.1+ compatibility, tested against Rails 7.1, 7.2, 8.x.
- R4. Basic auth or API key auth; at least one must be configured or the engine refuses to boot.
- R5. Each request associated with a principal identifier exposed to tools and logs.
- R6. Four bundled plugins in v1: DB, Jobs, Flipper, Health.
- R7. Plugins enable/disable individually via initializer; off by default.
- R8. Ruby DSL for declaring custom plugins and tools.
- R9. Plugins declare required DB connections by name; gem refuses to boot if missing.
- R10. Soft dependencies on sidekiq, solid_queue, flipper handled with clear boot errors.
- R11. DB plugin exposes raw SQL tool returning rows.
- R12. DB plugin uses a separately-configured read-only connection.
- R13. DB plugin enforces statement timeout, default 30s, overridable.
- R14. DB plugin returns results in JSON, plain text, or HTML content blocks per call.
- R15. Jobs plugin exposes a common interface for queue sizes, recent jobs, failed jobs, rate metrics.
- R16. Jobs plugin ships Sidekiq + Solid Queue adapters; operator declares which.
- R17. Jobs plugin is read-only in v1.
- R18. Flipper plugin lists flags, reads flag state, enables/disables globally and per-actor.
- R19. Flipper plugin uses a writer-capable connection separate from the DB plugin's read-only one.
- R20. Health plugin lets the operator register named checks in Ruby.
- R21. Health plugin exposes list and run tools; each returns pass/fail plus value.
- R22. Health plugin does no scheduling, aggregation, alerting, or historical storage.
- R23. Every invocation logged via Rails logger, default INFO, overridable globally and per-plugin.
- R24. Logger is swappable to any Logger-interface-compatible object.
- R25. Invocation log line includes timestamp, principal, plugin, tool, params, outcome, duration.
- R26. Fail-closed: missing required config raises at boot, not at first request.
- R27. No DB writes via DB plugin; writes only through plugins with declared writer connections.
- R28. No "execute arbitrary Ruby" tool.
- R29. Ships as a single gem with all four plugins bundled.
- R30. Internal layout treats each plugin as isolated unit, no cross-plugin imports or shared mutable state.
- R31. README ships with install, walkthrough, configuration reference, plugin examples, plugin tutorial.

**Origin actors:** A1 (Gem operator), A2 (MCP client), A3 (Plugin author)
**Origin acceptance examples:** AE1 (covers R9, R26), AE2 (covers R10), AE3 (covers R12, R13, R27), AE4 (covers R14), AE5 (covers R20, R21), AE6 (covers R23, R25)

---

## Scope Boundaries

- No protocol-layer code in this gem — JSON-RPC framing, initialization handshake, capability negotiation, and content-block serialization are delegated to the `modelcontextprotocol-ruby-sdk` dependency.
- No 2024-11-05 deprecated transport (separate `/sse` and `/messages` endpoints).
- No stdio transport; no Claude Desktop bridge in v1.
- No 2026-07-28 RC behavior shipped in v1; design accommodates it but the gem targets 2025-11-25 spec on first release.
- No ActionView dependency for HTML rendering; gem ships a minimal table renderer.
- No new-plugin scaffolding generator (`rails g talk_to_your_app:plugin Foo`); README tutorial covers manual setup.
- No OAuth 2.1, PKCE, JWT, or any auth beyond static API keys and HTTP basic.
- No job write tools (enqueue/retry/kill) per origin R17.
- No generic "execute Ruby" tool per origin R28.
- No GoodJob, Resque, Que, or Delayed Job adapters in v1.
- No Redis plugin, Solid Cache plugin, ActionMailer plugin, or ActiveStorage plugin.
- No web admin UI; configuration is initializer-only.

### Deferred to Follow-Up Work

- Plugin scaffolding generator: `rails g talk_to_your_app:plugin Foo` to scaffold a custom plugin directory — separate follow-up once the manual flow has settled.
- 2026-07-28 RC migration: when the stateless-core spec lands, swap session middleware behavior under a config switch. Tracked separately.

---

## Context & Research

### Relevant Code and Patterns

- Repository is greenfield; no existing patterns to inherit. Conventions are established by this plan.
- Mount-as-Rack-app pattern: ActionCable, Sidekiq Web, GraphQL-Ruby — `mount RackApp, at: "/path"` inside the host app's `config/routes.rb`. Avoid full Rails engine; a Rack-compatible callable is the right granularity.
- Plugin DSL pattern: Warden's `Warden::Strategies.add(:name, ...)` strategy registry + ActiveJob's `ActiveJob::QueueAdapters::FooAdapter` namespace convention. Use Warden's explicit registration for plugins, ActiveJob's namespace convention for the Jobs plugin's adapter sub-modules.
- Railtie + `config.x.talk_to_your_app` configuration pattern for Rails integration (per Rails Guides on engines).

### Institutional Learnings

- None — `docs/solutions/` does not exist yet.

### External References

- **MCP Spec 2025-11-25**: <https://modelcontextprotocol.io/specification/2025-11-25/basic/transports> — single `/mcp` endpoint, POST + GET, optional `Mcp-Session-Id` header, origin validation, `MCP-Protocol-Version` header.
- **MCP 2026-07-28 RC**: <https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/> — pending breaking change (stateless model, no init handshake, new routing headers, list-response cache metadata). Out of v1 scope.
- **Official Ruby SDK**: <https://github.com/modelcontextprotocol/ruby-sdk> v0.18.0 (May 30, 2026). Ships `MCP::Server`, `StreamableHTTPTransport`, custom-transport interface, Rails mounting examples, OAuth 2.1 support. Pin `~> 0.18`.
- **fast-mcp** v1.6.0 (Sep 2025): reference only — uses deprecated 2024-11-05 SSE transport. Not a dependency.

---

## Key Technical Decisions

- **Depend on `modelcontextprotocol-ruby-sdk` for the protocol/transport layer**: The SDK ships a clean `MCP::Server` core, a maintained `StreamableHTTPTransport`, and a custom-transport interface. Re-implementing wire protocol would double the gem's scope and create version-drift risk. Trade-off: we accept v0.x API instability and pin `~> 0.18` with an explicit upgrade discipline note in the README.
- **Target MCP spec 2025-11-25; design session layer as swappable**: The 2026-07-28 RC removes sessions. Building against the stable spec today while keeping session handling in one place lets us flip to stateless via config later.
- **Class-based Tool DSL, not block-based**: `class FooTool < TalkToYourApp::Tool` with declarative `argument`, `connection`, and `call`. Matches Devise/Sidekiq/ActiveJob ergonomics and is the most common Ruby idiom for "extensible component". Block DSL is more compact but harder to test and inspect.
- **Plugin registry is a module-level hash, not autoload-by-convention**: `TalkToYourApp.register_plugin(:name, klass)` is explicit, testable without Rails boot, and matches Warden's pattern. Autoload-from-`app/mcp_plugins` directory is rejected — too much magic for an OSS gem where the contract should be visible.
- **Connection registry is gem-level naming, not direct `database.yml` reuse**: Operators declare `config.connection :replica_readonly, database: "primary", role: :reading` in the initializer. The gem-internal name (`:replica_readonly`) is what plugins reference; the operator maps it to their actual Rails DB config. This decouples plugin code from operator's `database.yml` conventions.
- **Per-query connection switching via `ActiveRecord::Base.connected_to(role:, shard:)`**: The standard Rails 6.1+ multi-DB API. No raw `ActiveRecord::Base.establish_connection` calls.
- **Statement timeout via `SET LOCAL statement_timeout`** inside a transaction wrapping each query: portable across PG (`statement_timeout`) and MySQL (`MAX_EXECUTION_TIME` hint or `max_execution_time` session var, branched per adapter).
- **Auth via single `Authorization` header**: `Bearer <api-key>` or `Basic <user:pass>`. Avoids inventing a custom `X-Api-Key` header and aligns with the SDK's auth conventions. Configuration accepts a hash of named API keys (`{ "claude-desktop" => "sk-..." }`) so the principal logged is the key's name.
- **Audit logging implemented as a Tool-decorator pattern**: Wrap each registered tool's `call` to emit one log line per invocation with required fields. Cleaner than middleware because the principal + tool + params are all in scope at the right point.
- **HTML rendering via a ~50-LOC table helper**, no ActionView dependency: keeps the gem's host-app coupling minimal and the response shape predictable.
- **Test infrastructure**: Minitest + `appraisal` for multi-Rails-version testing + `test/dummy/` minimal Rails app for integration. Standard Rails-gem convention.
- **Jobs adapter selection is explicit, not auto-detected**: Operator sets `config.plugin :jobs, adapter: :sidekiq` in the initializer. Refuses to boot if the named gem is missing. Origin doc said "selects the adapter the operator declared, or refuses to boot if none is declared"; this plan honors that explicitly rather than inferring.

---

## Open Questions

### Resolved During Planning

- Vendor an existing Ruby MCP protocol implementation or build our own? → Depend on `modelcontextprotocol-ruby-sdk` v0.18+. (Origin Q on R1, R2.)
- Plugin DSL shape — class-based, block-based, or hybrid? → Class-based. (Origin Q on R8.)
- API key header name? → `Authorization: Bearer <key>`. Multiple named keys supported via config hash. (Origin Q on R4.)
- HTML table rendering — ActionView or dedicated renderer? → Tiny gem-local renderer. (Origin Q on R14.)
- Adapter abstraction shape for jobs plugin? → Module + duck typing under `TalkToYourApp::Jobs::Adapters::` namespace; no abstract base class. (Origin Q on R16.)

### Deferred to Implementation

- Whether the SDK's existing tool-middleware hooks (if any in v0.18.0) are sufficient for the audit logger, or whether we wrap each tool's `call` at registration time. To be decided in U5 once the SDK's surface is read concretely.
- Exact session/middleware integration point for surfacing the MCP session ID into the audit log. Depends on whether the SDK exposes session ID via thread-local, Rack env, or transport callback. Decide during U5.
- Whether MySQL statement timeout uses the `MAX_EXECUTION_TIME` optimizer hint (injected into the SQL) or the `max_execution_time` session variable. Adapter-detect in U6 once the test matrix is running.

---

## Output Structure

    talk_to_your_app/
    ├── talk_to_your_app.gemspec
    ├── Gemfile
    ├── Rakefile
    ├── README.md
    ├── LICENSE
    ├── lib/
    │   ├── talk_to_your_app.rb
    │   └── talk_to_your_app/
    │       ├── version.rb
    │       ├── railtie.rb
    │       ├── configuration.rb
    │       ├── connection_registry.rb
    │       ├── tool.rb
    │       ├── plugin.rb
    │       ├── plugin_registry.rb
    │       ├── auth/
    │       │   ├── middleware.rb
    │       │   ├── api_key.rb
    │       │   └── basic.rb
    │       ├── transport/
    │       │   └── rails_mount.rb
    │       ├── audit_logger.rb
    │       ├── renderers/
    │       │   └── html_table.rb
    │       └── plugins/
    │           ├── db/
    │           │   ├── plugin.rb
    │           │   └── tools/query.rb
    │           ├── jobs/
    │           │   ├── plugin.rb
    │           │   ├── interface.rb
    │           │   ├── adapters/
    │           │   │   ├── sidekiq.rb
    │           │   │   └── solid_queue.rb
    │           │   └── tools/
    │           │       ├── queue_sizes.rb
    │           │       ├── recent_jobs.rb
    │           │       ├── failed_jobs.rb
    │           │       └── rate_metrics.rb
    │           ├── flipper/
    │           │   ├── plugin.rb
    │           │   └── tools/
    │           │       ├── list_flags.rb
    │           │       ├── read_flag.rb
    │           │       ├── enable_flag.rb
    │           │       └── disable_flag.rb
    │           └── health/
    │               ├── plugin.rb
    │               ├── registry.rb
    │               └── tools/
    │                   ├── list_checks.rb
    │                   └── run_check.rb
    ├── lib/generators/
    │   └── talk_to_your_app/
    │       └── install/
    │           ├── install_generator.rb
    │           └── templates/initializer.rb.tt
    └── test/
        ├── test_helper.rb
        ├── dummy/                    # minimal Rails app for integration tests
        └── talk_to_your_app/         # unit tests mirroring lib/ structure

---

## High-Level Technical Design

> *This illustrates the intended approach and is directional guidance for review, not implementation specification. The implementing agent should treat it as context, not code to reproduce.*

**Request flow (one MCP `tools/call` invocation):**

```
Rails router
  └─► Rack: TalkToYourApp::Auth::Middleware
        validates Authorization header → sets env["ttya.principal"]
        401 if invalid, never reaches transport
  └─► Rack: official SDK's StreamableHTTPTransport (mounted under our wrapper)
        decodes JSON-RPC, dispatches to MCP::Server
              └─► MCP::Server invokes registered tool
                    └─► TalkToYourApp::AuditLogger.wrap(tool) do
                          tool.call(args, ctx)
                            ├─ ctx.principal     = env["ttya.principal"]
                            ├─ ctx.session_id    = SDK session, if any
                            └─ ctx.connection(:replica_readonly) { ActiveRecord::Base.connected_to(...) }
                        end
                        emits one INFO log line: principal, plugin, tool, params, outcome, duration
```

**Tool DSL sketch (directional):**

```
class DbQueryTool < TalkToYourApp::Tool
  name        "db.query"
  description "Run a read-only SQL query."
  connection  :replica_readonly                  # registry lookup; boot fails if unconfigured
  argument    :sql,    :string, required: true
  argument    :format, :string, enum: %w[json text html], default: "json"

  def call(args, ctx)
    ctx.connection { |conn| conn.execute_with_timeout(args[:sql]) }
      .then { |rows| render(rows, format: args[:format]) }
  end
end
```

**Plugin contract sketch (directional):**

```
class TalkToYourApp::Plugins::Db < TalkToYourApp::Plugin
  requires_connection :replica_readonly
  requires_gem        nil                        # core ActiveRecord; no soft-dep

  tools DbQueryTool
end

TalkToYourApp.register_plugin(:db, TalkToYourApp::Plugins::Db)
```

**Boot-time validation sequence (fail-closed):**

```
Railtie.initializer "talk_to_your_app.validate" do
  1. Auth configured? (api_keys.any? || basic_auth.present?) else raise
  2. For each enabled plugin:
       2a. requires_gem present? else raise with actionable message
       2b. requires_connection registered? else raise naming the missing connection
  3. Mount the Rack stack at config.mount_at
end
```

---

## Implementation Units

### U1. Gem scaffold, Railtie, Configuration, install generator, test infrastructure

**Goal:** Establish the gem skeleton, configuration object, Railtie wiring, install generator, and Minitest+dummy-app test infrastructure. No behavior yet; foundation only.

**Requirements:** R3, R29, R30, R31

**Dependencies:** None

**Files:**
- Create: `talk_to_your_app.gemspec`, `Gemfile`, `Rakefile`, `lib/talk_to_your_app.rb`, `lib/talk_to_your_app/version.rb`, `lib/talk_to_your_app/railtie.rb`, `lib/talk_to_your_app/configuration.rb`
- Create: `lib/generators/talk_to_your_app/install/install_generator.rb`, `lib/generators/talk_to_your_app/install/templates/initializer.rb.tt`
- Create: `test/test_helper.rb`, `test/dummy/` (minimal Rails app: `config/application.rb`, `config/routes.rb`, `config/database.yml`, `db/schema.rb`)
- Create: `Appraisals` (Rails 7.1 / 7.2 / 8.0 matrix)
- Test: `test/talk_to_your_app/configuration_test.rb`, `test/generators/install_generator_test.rb`

**Approach:**
- Gemspec pins `~> 0.18` for `modelcontextprotocol-ruby-sdk`; Rails as `>= 7.1`; ActiveRecord as `>= 7.1`. Sidekiq, solid_queue, flipper are development-only deps in the Gemfile but NOT in the gemspec (soft deps).
- `TalkToYourApp.configure { |c| ... }` exposes config via a thread-safe singleton.
- Railtie registers an initializer block (named `talk_to_your_app.validate`) that runs at the end of Rails boot and triggers all validation in subsequent units. In U1, the block is a stub.
- Install generator copies a commented initializer template into `config/initializers/talk_to_your_app.rb` of the host app.

**Patterns to follow:**
- Sidekiq's gemspec for the "soft Rails dep + dev deps" pattern.
- ActionCable's mounting docs for the Rack-app convention.

**Test scenarios:**
- Happy path: `TalkToYourApp.configure { |c| c.mount_at = "/foo" }` sets and reads back the value.
- Happy path: `rails g talk_to_your_app:install` in the dummy app creates `config/initializers/talk_to_your_app.rb` with the documented template.
- Edge case: Calling `.configure` twice merges configuration rather than overwriting.
- Integration: Booting the dummy app with the gem in the Gemfile but no initializer present does not crash (validation is gated on plugin enablement, which is empty here).

**Verification:**
- `bundle exec rake test` runs in the dummy app; gem boots cleanly without an initializer.
- `appraisal rails-7.1 bundle exec rake test` passes; same for 7.2 and 8.0.

---

### U2. Connection registry — declared roles + fail-closed validation

**Goal:** Implement the named-connection registry that plugins reference and operators configure. Validate at boot that every required connection is registered. This is the gem's headline security feature.

**Requirements:** R9, R12, R19, R26, R27 (per origin AE1)

**Dependencies:** U1

**Files:**
- Create: `lib/talk_to_your_app/connection_registry.rb`
- Modify: `lib/talk_to_your_app/configuration.rb` (add `connection :name, database:, role:, replica:` builder)
- Modify: `lib/talk_to_your_app/railtie.rb` (extend validation block to call `ConnectionRegistry.validate!`)
- Test: `test/talk_to_your_app/connection_registry_test.rb`

**Approach:**
- `ConnectionRegistry` holds a hash of named connection specs. Each spec carries `database` (a Rails `database.yml` key), `role` (`:reading` / `:writing`), optional `replica: true`, optional per-connection statement timeout override.
- A connection is *registered* when the operator declares it; *required* when a plugin marks it via `requires_connection :name`.
- Validation: at boot, every required connection must be registered AND its referenced `database:` must resolve to an actual Rails connection config. Raises `TalkToYourApp::ConfigurationError` with the missing name listed.
- Lookup API: `ConnectionRegistry.with(:name) { |conn| ... }` wraps the block in `ActiveRecord::Base.connected_to(database: spec.database, role: spec.role)`.

**Patterns to follow:**
- Rails Guides on multi-DB / `connected_to` API.
- Warden's strategy registry for the named-hash idiom.

**Test scenarios:**
- Happy path: Operator declares `connection :replica_readonly, database: "primary", role: :reading`; plugin `requires_connection :replica_readonly`; validation passes.
- Happy path: `ConnectionRegistry.with(:replica_readonly) { |c| c.execute("SELECT 1") }` returns the result.
- Error path: **Covers AE1.** Plugin marks `requires_connection :flipper_writer` but no such connection is declared. `Railtie.run_initializers!` raises `ConfigurationError` whose message names `:flipper_writer` and the requesting plugin.
- Error path: Operator declares `connection :foo, database: "nonexistent"` but `nonexistent` is absent from `database.yml`. Boot raises with the missing database name.
- Edge case: A connection declared with both `replica: true` and `role: :writing` raises at configure-time as nonsensical.
- Integration: When `connected_to` is invoked, the resulting AR connection's `role` matches the spec's role (visible via `ActiveRecord::Base.current_role`).

**Verification:**
- A dummy plugin in `test/dummy/` that requires `:replica_readonly` causes Rails boot to fail with a clear error when the connection is omitted, and to succeed when it is declared.

---

### U3. Tool DSL + Plugin DSL + plugin registry

**Goal:** The class-based Tool DSL (`TalkToYourApp::Tool`), the Plugin base class (`TalkToYourApp::Plugin`), and the module-level plugin registry. This is the surface third-party authors extend.

**Requirements:** R8, R30 (per origin A3)

**Dependencies:** U1, U2

**Files:**
- Create: `lib/talk_to_your_app/tool.rb`, `lib/talk_to_your_app/plugin.rb`, `lib/talk_to_your_app/plugin_registry.rb`
- Modify: `lib/talk_to_your_app.rb` (expose `register_plugin`, `enabled_plugins`)
- Modify: `lib/talk_to_your_app/railtie.rb` (extend validation block to validate enabled plugins via the registry)
- Test: `test/talk_to_your_app/tool_test.rb`, `test/talk_to_your_app/plugin_test.rb`, `test/talk_to_your_app/plugin_registry_test.rb`

**Approach:**
- `Tool` base class with class-level DSL: `name`, `description`, `connection`, `argument(name, type, required:, enum:, default:, description:)`. Arguments compile down to the JSON Schema shape the MCP SDK expects.
- `call(args, ctx)` is the instance method tool authors implement. `ctx` exposes `principal`, `session_id`, `logger`, and `connection(:name) { |conn| ... }` (delegates to `ConnectionRegistry.with`).
- `Plugin` base class with class-level DSL: `requires_connection`, `requires_gem`, `tools(*tool_classes)`, `log_level` (override INFO).
- `PluginRegistry` is a module-level hash: `{ name => plugin_class }`. Registration is explicit. Iteration is in registration order (Hash insertion order).
- `requires_gem` accepts a Ruby constant path (e.g., `"Sidekiq"`) and a humanized gem name (e.g., `"sidekiq"`). Validation at boot checks the constant.

**Technical design:** *(directional)*

```
class TalkToYourApp::Tool
  class << self
    def name(value = nil);        @name = value if value;        @name        end
    def description(value = nil); @description = value if value; @description end
    def connection(name = nil);   @connection = name if name;    @connection  end
    def argument(name, type, **opts)
      arguments[name] = { type:, **opts }
    end
    def arguments; @arguments ||= {} end
    def to_mcp_definition
      # → { name:, description:, input_schema: { type: "object", properties: ..., required: ... } }
    end
  end
end
```

**Patterns to follow:**
- Devise's module DSL for the class-level macro style.
- Sidekiq::Job's `sidekiq_options` for the inheritable-class-attribute idiom.

**Test scenarios:**
- Happy path: Define a tool subclass with `name "foo.bar"`, two arguments, and a `call`; `to_mcp_definition` produces the JSON-Schema-shaped hash.
- Happy path: Define a plugin with two tools; registering it adds it to `PluginRegistry` and the plugin's tools are iterable.
- Error path: A tool that declares `connection :foo` but `:foo` is not in the registry causes validation to fail at boot, naming the tool and connection.
- Error path: **Covers AE2.** A plugin declares `requires_gem "Sidekiq"` but `Sidekiq` is not defined; validation raises with "Plugin :jobs requires gem `sidekiq` in your Gemfile" (or similar actionable message).
- Edge case: A tool with a required argument not provided at `call` time — the SDK enforces this via JSON Schema; verify our `to_mcp_definition` produces the right `required:` array so the SDK validates correctly.
- Edge case: An argument declared with `enum: %w[a b c]` produces a JSON Schema `enum` field; SDK rejects values outside it.
- Integration: A plugin enabled in the initializer but with a missing required connection raises at Railtie load — not at first MCP request.

**Verification:**
- A dummy plugin with one tool can be defined, registered, enabled, and inspected end-to-end in unit tests.
- All boot-time validation errors include both the plugin name and the specific reason.

---

### U4. Auth middleware + MCP transport mount

**Goal:** A Rack middleware validating `Authorization: Bearer` or `Authorization: Basic`, sitting in front of the SDK's `StreamableHTTPTransport` mounted at `config.mount_at`. Fail-closed at boot if no auth configured.

**Requirements:** R1, R2, R4, R5, R26 (per origin A1, A2)

**Dependencies:** U1, U3

**Files:**
- Create: `lib/talk_to_your_app/auth/middleware.rb`, `lib/talk_to_your_app/auth/api_key.rb`, `lib/talk_to_your_app/auth/basic.rb`
- Create: `lib/talk_to_your_app/transport/rails_mount.rb` (the Rack-callable that the host app mounts)
- Modify: `lib/talk_to_your_app/configuration.rb` (add `api_keys` hash, `basic_auth` block, `mount_at`)
- Modify: `lib/talk_to_your_app/railtie.rb` (extend validation block — at least one auth mechanism configured)
- Test: `test/talk_to_your_app/auth/middleware_test.rb`, `test/talk_to_your_app/transport/rails_mount_test.rb`, `test/integration/auth_integration_test.rb`

**Approach:**
- `Auth::Middleware` is a standard Rack middleware. It reads `HTTP_AUTHORIZATION`, dispatches to `ApiKey` or `Basic` validators based on scheme, sets `env["ttya.principal"]` to the key name (API key) or username (basic auth), and forwards. Returns 401 otherwise. Origin header validation per spec 2025-11-25 (DNS rebinding) happens here as well.
- `ApiKey` validator does constant-time comparison against the configured hash; the principal name is the hash key. Multiple keys supported for rotation.
- `Basic` validator delegates to a user-supplied callable that returns true/false given `(username, password)` — operator can wire to ActiveRecord, Devise, whatever. No assumption about the host app's user model.
- `Transport::RailsMount` wraps the SDK's `StreamableHTTPTransport` instance, injects the configured `MCP::Server`, and returns the Rack-callable the host app mounts via `mount`.

**Patterns to follow:**
- Rack's `Rack::Auth::Basic` for the Authorization-header parsing pattern.
- ActionCable's `mount` documentation for the host-app integration.

**Test scenarios:**
- Happy path: Request with `Authorization: Bearer sk-good` matches a configured key named `"claude-desktop"`; middleware sets `env["ttya.principal"] = "claude-desktop"` and forwards.
- Happy path: Request with `Authorization: Basic dXNlcjpwYXNz` (`user:pass` base64) where the basic-auth callable returns true; middleware sets `env["ttya.principal"] = "user"` and forwards.
- Error path: No `Authorization` header → 401, body indicates the missing/invalid auth without leaking which scheme is configured.
- Error path: `Authorization: Bearer sk-wrong` → 401, no log of the key value.
- Error path: `Origin: https://attacker.example` not in the configured allowlist → 403 (DNS rebinding protection per spec).
- Error path: Boot with `config.api_keys = {}` and no `basic_auth` block → Railtie raises `ConfigurationError("no authentication configured")`.
- Edge case: API key comparison is constant-time (test via timing — coarse but verifiable: equal-length keys diff at index 0 vs index N take comparable time).
- Edge case: Two configured keys with the same value but different names — last-wins is fine; document it.
- Integration: Full request round-trip through dummy app → middleware → mounted transport → SDK echoes back a `tools/list` response.

**Verification:**
- An unauthenticated `tools/list` request returns 401.
- An authenticated `tools/list` request returns the configured tools (none yet at this point — empty list is fine).

---

### U5. Audit logger

**Goal:** Emit exactly one INFO log line per tool invocation containing principal, plugin, tool, params, outcome (success/failure), duration. Use Rails.logger by default, swappable globally and per-plugin.

**Requirements:** R23, R24, R25 (per origin AE6)

**Dependencies:** U3, U4

**Files:**
- Create: `lib/talk_to_your_app/audit_logger.rb`
- Modify: `lib/talk_to_your_app/plugin_registry.rb` (wrap each registered tool's `call` with the logger at registration time)
- Modify: `lib/talk_to_your_app/configuration.rb` (add `logger`, `log_level` global; per-plugin overrides flow through the plugin DSL)
- Test: `test/talk_to_your_app/audit_logger_test.rb`, `test/integration/audit_log_integration_test.rb`

**Approach:**
- `AuditLogger.wrap(tool_class)` returns a wrapped class whose `call` captures: start time, end time, principal (from ctx), plugin name, tool name, params, exception (if any). Emits a single structured log line at the plugin's configured level (default INFO).
- Log line format: a tagged Rails log line with key=value pairs (or a JSON line if Rails.logger is a JSON formatter). Keys: `ts`, `principal`, `plugin`, `tool`, `params`, `outcome`, `duration_ms`, `session_id` (when SDK exposes it; null otherwise — see deferred-to-implementation note).
- Param redaction: `argument :secret, :string, redact: true` declares a redactable arg in the Tool DSL — augment U3's `argument` DSL with this option. Redacted args log as `"[REDACTED]"`. Not in the strict origin requirements but adds negligible code and is the right default for an OSS gem.
- Failure case: exception caught, logged with `outcome: error`, error class included; then re-raised so the SDK returns a tool error to the client.

**Patterns to follow:**
- Rails ActiveSupport::Notifications for the event-emission pattern (consider using it under the hood so consumers can subscribe).

**Test scenarios:**
- Happy path: **Covers AE6.** A tool invoked successfully emits one INFO line containing `principal=claude-desktop`, `plugin=db`, `tool=db.query`, `params={...}`, `outcome=success`, `duration_ms=N`.
- Error path: A tool that raises emits one INFO line with `outcome=error`, `error_class=ActiveRecord::StatementInvalid` (or similar), and re-raises so the SDK surfaces it.
- Edge case: Two concurrent invocations emit two distinct log lines; durations are per-invocation.
- Edge case: Arg marked `redact: true` appears as `[REDACTED]` in the log; other args are present verbatim.
- Edge case: Operator overrides `config.logger = MyLogger.new`; both INFO emission and level filtering route through it.
- Edge case: Plugin overrides `log_level :debug`; that plugin's invocations log at DEBUG even when global is INFO.
- Integration: An end-to-end MCP `tools/call` through dummy app produces exactly one log line; duration is non-zero; principal matches the auth token used.

**Verification:**
- Inspecting `Rails.logger`'s captured output after an MCP request shows the expected single-line audit record.

---

### U6. DB plugin — read-only SQL on declared connection, multi-format response, timeout

**Goal:** Implement the DB plugin's single tool `db.query`: takes raw SQL, executes on the `:replica_readonly` connection with a 30s statement timeout, returns rows as JSON / plain text / HTML table per `format` argument.

**Requirements:** R11, R12, R13, R14, R27 (per origin AE3, AE4)

**Dependencies:** U2, U3, U5

**Files:**
- Create: `lib/talk_to_your_app/plugins/db/plugin.rb`, `lib/talk_to_your_app/plugins/db/tools/query.rb`
- Create: `lib/talk_to_your_app/renderers/html_table.rb`
- Test: `test/talk_to_your_app/plugins/db/query_test.rb`, `test/talk_to_your_app/renderers/html_table_test.rb`, `test/integration/db_plugin_integration_test.rb`

**Approach:**
- `Plugins::Db < TalkToYourApp::Plugin` with `requires_connection :replica_readonly`, `tools Plugins::Db::Tools::Query`.
- `Plugins::Db::Tools::Query`: arguments `sql:string (required)`, `format:string (enum: json, text, html, default: json)`. `call` opens the declared connection, sets `SET LOCAL statement_timeout = <ms>` inside a transaction, executes the SQL, formats results.
- Statement timeout is per-query (transaction-scoped) so connection-pool poisoning is impossible. Adapter-detect: PG uses `statement_timeout`; MySQL uses session-level `MAX_EXECUTION_TIME` (resolved during implementation per Open Questions / Deferred).
- HTML renderer: `Renderers::HtmlTable.render(rows, columns:)` produces a `<table>` with `<thead>`/`<tbody>`, headers from result columns, cells HTML-escaped via `CGI.escape_html` (no ActionView, no `html_safe`). Returns a string suitable for an MCP text content block.
- JSON formatter: `{ columns: [...], rows: [[...], [...]] }`. Plain text: aligned columns, monospace-friendly.
- Connection is opened via `ConnectionRegistry.with(:replica_readonly) { |conn| ... }` which uses Rails `connected_to(role: :reading)`. Writes are rejected by the underlying read-only PG role / replica — gem does not parse SQL.

**Patterns to follow:**
- ActiveRecord's `connection.execute` for raw query dispatch.
- Rails 7+ `connected_to` for role-based connection switching.

**Test scenarios:**
- Happy path: `db.query` with `sql: "SELECT 1 AS one"` and `format: "json"` returns `{ columns: ["one"], rows: [[1]] }`.
- Happy path: **Covers AE4.** Same query with `format: "html"` returns an HTML string containing `<table>`, `<thead><tr><th>one</th></tr></thead>`, `<tbody><tr><td>1</td></tr></tbody>`. With `format: "text"`, returns a plain-text aligned table.
- Error path: **Covers AE3.** `sql: "UPDATE users SET admin = true"` against a read-only replica role raises an AR/PG error indicating read-only; tool returns the error to the MCP client; one audit log line with `outcome=error`.
- Error path: **Covers AE3.** A query that sleeps longer than the configured timeout (use `SELECT pg_sleep(2)` with timeout=1s in tests) is cancelled at the timeout boundary; error returned; no orphaned connection.
- Edge case: Result containing NULL renders as `null` in JSON, empty string in HTML, `NULL` in plain text. Decide and document.
- Edge case: Result containing HTML/script in a cell is escaped in HTML output (`<script>` → `&lt;script&gt;`).
- Edge case: Empty result set renders as a JSON object with `rows: []`, an HTML table with `<tbody></tbody>`, and a plain-text header-only block.
- Edge case: A query returning 100k rows — there is no row cap in v1; document this. (If a future limit is needed, it goes in deferred-to-follow-up.)
- Integration: Full MCP `tools/call` for `db.query` through the dummy app's HTTP endpoint returns the expected content block; one audit log line emitted.

**Verification:**
- The dummy app's seed data is queryable via MCP `tools/call`; writes are rejected; timeouts cancel cleanly.

---

### U7. Jobs plugin — common interface + namespace + adapter selection

**Goal:** Define `TalkToYourApp::Jobs::Interface` (the methods adapters must implement: `queue_sizes`, `recent_jobs(limit:)`, `failed_jobs(limit:)`, `rate_metrics(window:)`) and the `Plugins::Jobs` plugin that selects an adapter from config. The plugin ships with no adapter; U8 and U9 add Sidekiq and Solid Queue.

**Requirements:** R15, R16, R17 (per origin)

**Dependencies:** U3

**Files:**
- Create: `lib/talk_to_your_app/plugins/jobs/plugin.rb`, `lib/talk_to_your_app/plugins/jobs/interface.rb`
- Create: `lib/talk_to_your_app/plugins/jobs/tools/queue_sizes.rb`, `lib/talk_to_your_app/plugins/jobs/tools/recent_jobs.rb`, `lib/talk_to_your_app/plugins/jobs/tools/failed_jobs.rb`, `lib/talk_to_your_app/plugins/jobs/tools/rate_metrics.rb`
- Test: `test/talk_to_your_app/plugins/jobs/plugin_test.rb`, `test/talk_to_your_app/plugins/jobs/interface_test.rb`

**Approach:**
- `Jobs::Interface` is a module documenting the four methods. Adapters duck-type — no `include`, no abstract base class.
- `Plugins::Jobs` reads `adapter:` from its plugin-level config (`config.plugin :jobs, adapter: :sidekiq`) and resolves it to `TalkToYourApp::Jobs::Adapters::Sidekiq` (or Solid Queue). Refuses to boot if `adapter:` is not set or resolves to a non-loaded class.
- Each of the four tools is a thin wrapper that delegates to the configured adapter.

**Test scenarios:**
- Happy path: With `adapter: :sidekiq`, the four tools are registered and their `call` delegates to the Sidekiq adapter (mocked here; real adapter tested in U8).
- Error path: Plugin enabled but no `adapter:` set → boot raises naming the missing option.
- Error path: `adapter: :goodjob` (not shipped) → boot raises listing supported adapters.
- Edge case: The `recent_jobs` and `failed_jobs` tools accept a `limit` argument (default 50, max 500). Out-of-range raises a validation error from the SDK schema.
- Edge case: `rate_metrics` `window:` accepts ISO-8601 duration or seconds; document the choice. Default = last 30 minutes.

**Verification:**
- The plugin can be enabled in the dummy app with a stub adapter; `tools/list` shows the four jobs tools.

---

### U8. Jobs::Adapters::Sidekiq

**Goal:** Sidekiq adapter implementing the four interface methods using `Sidekiq::Stats`, `Sidekiq::Queue`, `Sidekiq::DeadSet`, and `Sidekiq::RetrySet`.

**Requirements:** R10, R15, R16

**Dependencies:** U7

**Files:**
- Create: `lib/talk_to_your_app/plugins/jobs/adapters/sidekiq.rb`
- Modify: `lib/talk_to_your_app/plugins/jobs/plugin.rb` (add `:sidekiq` to known adapters; `requires_gem "Sidekiq"` when this adapter is selected)
- Test: `test/talk_to_your_app/plugins/jobs/adapters/sidekiq_test.rb`, `test/integration/jobs_sidekiq_integration_test.rb`

**Approach:**
- `queue_sizes` → `Sidekiq::Stats.new.queues` (hash of name => size).
- `recent_jobs(limit:)` → recent jobs across queues. Sidekiq has no first-class "recent jobs" API, so this uses `Sidekiq::Queue.all.flat_map { |q| q.first(limit) }` and a `Sidekiq::RetrySet.new` scan, capped at `limit`.
- `failed_jobs(limit:)` → `Sidekiq::DeadSet.new.to_a.first(limit)`.
- `rate_metrics(window:)` → uses `Sidekiq::Stats::History` for processed/failed counts over the window in day-resolution; sub-day windows return current-stats snapshots with a note in the response that finer granularity is not available.
- The `recent_jobs`, `failed_jobs`, and `rate_metrics` responses are arrays of hashes — keys: `jid`, `class`, `queue`, `args`, `enqueued_at`, `error_message` (where applicable). Stable shape across adapters.

**Test scenarios:**
- Happy path: Enqueue 3 jobs in test mode; `queue_sizes` returns `{ "default" => 3 }`.
- Happy path: A dead job after retries exhausted appears in `failed_jobs` with its error message.
- Error path: **Covers AE2.** Plugin enabled with `adapter: :sidekiq` but `sidekiq` gem not loaded in the test bundle → boot raises with the actionable message from U3's `requires_gem`.
- Edge case: `recent_jobs(limit: 1000)` is clamped to 500 (the schema max).
- Edge case: Empty queue → returns `[]` and `{}` rather than nil.
- Integration: Full MCP `tools/call` for `jobs.queue_sizes` through dummy app + a Sidekiq server (test-mode) returns the expected response shape.

**Verification:**
- The four jobs tools work end-to-end against a test-mode Sidekiq.

---

### U9. Jobs::Adapters::SolidQueue

**Goal:** Solid Queue adapter implementing the four interface methods using Solid Queue's ActiveRecord models (`SolidQueue::Job`, `SolidQueue::ReadyExecution`, `SolidQueue::FailedExecution`).

**Requirements:** R10, R15, R16

**Dependencies:** U7

**Files:**
- Create: `lib/talk_to_your_app/plugins/jobs/adapters/solid_queue.rb`
- Modify: `lib/talk_to_your_app/plugins/jobs/plugin.rb` (add `:solid_queue` to known adapters)
- Test: `test/talk_to_your_app/plugins/jobs/adapters/solid_queue_test.rb`, `test/integration/jobs_solid_queue_integration_test.rb`

**Approach:**
- `queue_sizes` → `SolidQueue::ReadyExecution.group(:queue_name).count`.
- `recent_jobs(limit:)` → `SolidQueue::Job.order(created_at: :desc).limit(limit)`.
- `failed_jobs(limit:)` → `SolidQueue::FailedExecution.includes(:job).order(created_at: :desc).limit(limit)`.
- `rate_metrics(window:)` → `SolidQueue::Job.where(created_at: window.ago..).count` for enqueued; finished_jobs / failed_executions for processed/failed.
- Response shape matches Sidekiq's: same keys, same types where possible. Adapters explicitly map their native field names into the common shape.

**Approach** (continued): Solid Queue stores jobs in the host app's DB, so adapter queries run on the host's primary connection unless the operator declares a separate `:jobs_reader` connection. Default behavior is to use the primary connection; document the override.

**Test scenarios:**
- Happy path: With Solid Queue running in the dummy app, enqueue 3 jobs; `queue_sizes` returns the expected hash.
- Happy path: A failed job appears in `failed_jobs` with the same shape as the Sidekiq adapter produces.
- Error path: Plugin enabled with `adapter: :solid_queue` but `solid_queue` gem absent → boot raises (same mechanism as U8).
- Edge case: Empty tables return `[]` / `{}`.
- Integration: Same end-to-end test as U8, exercised against Solid Queue.

**Verification:**
- The four jobs tools work end-to-end against the dummy app's Solid Queue install. Adapter swap (Sidekiq ↔ Solid Queue) is config-only, no other changes.

---

### U10. Flipper plugin

**Goal:** Implement the Flipper plugin: tools to list flags, read a flag's state (globally or for an actor), enable/disable a flag globally, and enable/disable a flag for a specific actor. Uses the `:flipper_writer` connection.

**Requirements:** R18, R19 (per origin)

**Dependencies:** U2, U3

**Files:**
- Create: `lib/talk_to_your_app/plugins/flipper/plugin.rb`
- Create: `lib/talk_to_your_app/plugins/flipper/tools/list_flags.rb`, `read_flag.rb`, `enable_flag.rb`, `disable_flag.rb`
- Test: `test/talk_to_your_app/plugins/flipper/*_test.rb`, `test/integration/flipper_plugin_integration_test.rb`

**Approach:**
- `Plugins::Flipper < TalkToYourApp::Plugin` with `requires_connection :flipper_writer`, `requires_gem "Flipper"`, `tools (the four tool classes)`.
- Tools wrap each operation in `ConnectionRegistry.with(:flipper_writer) { ... Flipper.enable/disable/etc ... }`. Flipper's own adapter (typically `flipper-active_record`) reads from the connection active in `connected_to`.
- Actor lookup: `read_flag` and the per-actor enable/disable tools accept `actor_class:string` + `actor_id:string`. The tool reconstitutes a thin actor object — `OpenStruct.new(flipper_id: "#{actor_class};#{actor_id}")` — rather than `find`-ing the actual record. This avoids privilege leaks and keeps the tool independent of the host app's user model.
- Tool responses are JSON content blocks with the flag's resulting state.

**Test scenarios:**
- Happy path: `flipper.list_flags` returns the names of all configured flags.
- Happy path: `flipper.enable_flag` with `name: "new_ui"` enables globally; subsequent `flipper.read_flag` returns `{ enabled: true }`.
- Happy path: `flipper.enable_flag` with `name: "new_ui"`, `actor_class: "User"`, `actor_id: "42"` enables for that actor; reading for that actor returns enabled, for another actor returns disabled.
- Error path: A `flipper.enable_flag` call without `:flipper_writer` configured → boot already failed in U2; verify message clarity.
- Error path: A call to `flipper.read_flag` with `name: "nonexistent"` returns `{ enabled: false }` (Flipper's default for unknown flags) — confirm behavior and document.
- Edge case: Actor ID containing semicolons or special characters — actor string format chosen carefully; document the escaping or reject.
- Integration: End-to-end MCP `tools/call` through dummy app for each of the four flag operations.

**Verification:**
- A real Flipper instance in the dummy app responds to the four tools' operations and persists state to the writer connection.

---

### U11. Health plugin — register checks, list, run

**Goal:** Provide a Ruby DSL for registering named health checks and two tools (`health.list` and `health.run`) that expose them via MCP. No scheduling, no aggregation, no alerting — just on-demand evaluation.

**Requirements:** R20, R21, R22 (per origin A1, AE5)

**Dependencies:** U3, U5

**Files:**
- Create: `lib/talk_to_your_app/plugins/health/plugin.rb`, `lib/talk_to_your_app/plugins/health/registry.rb`
- Create: `lib/talk_to_your_app/plugins/health/tools/list_checks.rb`, `lib/talk_to_your_app/plugins/health/tools/run_check.rb`
- Test: `test/talk_to_your_app/plugins/health/registry_test.rb`, `test/integration/health_plugin_integration_test.rb`

**Approach:**
- `TalkToYourApp::Health.register(:name, description: "...") { ... }` (or `register(:name, callable)`) stores the check in a module-level hash. The callable returns either a bare boolean, or `{ status: :pass | :fail, value: ..., message: "..." }`. Normalize both shapes in the tool layer.
- `health.list` returns the registered checks' names + descriptions.
- `health.run` takes `name:`, looks up the callable, invokes it, normalizes the response. Wraps in `begin/rescue`: an exception in a health check returns `{ status: :error, error_class: ..., message: ... }` rather than crashing the request.
- Health checks intentionally have no DB role; they can use any DB connection through their own code or none at all. They are owned by the host app developer.

**Test scenarios:**
- Happy path: **Covers AE5.** Operator registers `:video_pipeline` returning `{ status: :pass, value: 0.98 }`; `health.run name: "video_pipeline"` returns the same structure as an MCP content block.
- Happy path: A check returning a bare `true` is normalized to `{ status: :pass }`. Bare `false` → `{ status: :fail }`.
- Happy path: `health.list` returns the registered checks' names + descriptions.
- Error path: A check that raises an exception returns `{ status: :error, error_class: "..." }`; the audit log records `outcome=error` (or `outcome=success` with a status field — decide and document).
- Error path: `health.run name: "nonexistent"` returns a clear "unknown check" response (an SDK-level tool error, not a 500).
- Edge case: Two checks registered with the same name — second-write wins; document this and warn at register time if the name was already taken.

**Verification:**
- A registered check is invokable via MCP `tools/call` end-to-end; results match the registered callable's return value.

---

### U12. README + plugin authoring tutorial + Rails-version test matrix

**Goal:** Ship the documented v1: README walkthrough, plugin-authoring tutorial, configuration reference, CI matrix for Rails 7.1 / 7.2 / 8.0.

**Requirements:** R31

**Dependencies:** U1–U11

**Files:**
- Create: `README.md`
- Create: `docs/plugin_authoring.md`
- Create: `.github/workflows/ci.yml` (matrix: Rails 7.1, 7.2, 8.0 × Ruby 3.2, 3.3)
- Modify: `talk_to_your_app.gemspec` (final metadata, homepage, license, summary)

**Approach:**
- README structure:
  1. One-paragraph pitch (Rails-native MCP server, per-tool DB roles as the headline).
  2. Install (`bundle add talk_to_your_app`, `rails g talk_to_your_app:install`).
  3. End-to-end "your first query" walkthrough: configure a read-only replica, enable the DB plugin, generate an API key, point Claude Code at `http://localhost:3000/mcp`, run a SELECT.
  4. Configuration reference (every initializer option).
  5. Plugin sections (DB, Jobs, Flipper, Health): what it does, example calls, configuration.
  6. Writing your own plugin (links to `docs/plugin_authoring.md`).
  7. Security model (fail-closed, per-tool roles, what the gem does NOT do).
  8. Compatibility table (Rails versions, Ruby versions, MCP spec version).
  9. Upgrade discipline note (SDK v0.x pinning).
- Plugin authoring tutorial: walks through writing a `Plugins::Cache` plugin with one tool exposing Rails cache stats. Concrete enough to copy and modify.
- CI: GitHub Actions matrix runs `appraisal` per Rails version.

**Test scenarios:**
- Test expectation: none for README/docs — these are documentation deliverables. Verify via `markdownlint` (if used) and the example code blocks parsing as Ruby. CI matrix passing across the version cells is the verification signal.

**Verification:**
- A reader following the README walkthrough on a fresh Rails 7.2 app reaches a successful SQL query via MCP in ≤30 minutes (origin success criterion).
- CI matrix is green across all three Rails versions.

---

## System-Wide Impact

- **Interaction graph:** Auth middleware → MCP transport (SDK) → registered tool (wrapped by audit logger) → ConnectionRegistry → ActiveRecord `connected_to`. Each layer is replaceable without touching the others, by design.
- **Error propagation:** Auth failures return 401 from the Rack layer; tool-execution failures return MCP error responses from the SDK layer; configuration failures raise at boot before any request is served. Three distinct error pathways with no overlap.
- **State lifecycle risks:** Connection-pool exhaustion under concurrent load — every tool invocation should release its `connected_to` block before returning. Audit logger must not hold the connection during log I/O. Verify in integration tests.
- **API surface parity:** All plugins follow the same Plugin DSL and Tool DSL; third-party plugins get the same lifecycle hooks the bundled ones use. No "internal API" backdoor for bundled plugins.
- **Integration coverage:** Multi-layer tests (auth → transport → tool → DB) live under `test/integration/`. Adapter-level interface conformance tests live under each plugin's test directory and run for every adapter.
- **Unchanged invariants:** The gem does not modify host-app routes (operator mounts explicitly), models, migrations, or initializers (operator runs the install generator). Uninstalling the gem leaves no residual state in the host app beyond the operator-owned initializer file.

---

## Risks & Dependencies

| Risk | Mitigation |
|------|------------|
| Official Ruby SDK v0.x API instability (breaking changes in minor releases) | Pin `~> 0.18`; isolate SDK touch points to `Transport::RailsMount` and tool registration (U3, U4); README warns about pinning discipline; subscribe to SDK releases |
| 2026-07-28 MCP spec RC removes sessions; current implementation assumes the 2025-11-25 stateful model | Session handling concentrated in one config switch (planned); migration is a follow-up plan, not a rewrite |
| Soft-dep version drift (sidekiq, solid_queue, flipper major upgrades break adapters) | Pin minor versions in the test matrix via Appraisal; CI catches breakage; adapters are isolated files (one breakage doesn't cascade) |
| Statement timeout behavior diverges between PG and MySQL adapters | Adapter-detect inside DB plugin; explicit tests against both PG and MySQL in CI (or document MySQL as best-effort if matrix grows too large for v1) |
| Operators run on a single DB and "fake" the read-only connection by pointing both names at the same connection, defeating the safety promise | README explicitly recommends against this; a `config.connection :replica_readonly, allow_same_as_primary: true` opt-in flag with a logged warning makes the unsafe path visible (low-cost addition, defer if not in v1 scope) |
| HTML renderer produces XSS if a cell is later interpreted as `html_safe` somewhere upstream | Always escape with `CGI.escape_html`; return as plain text content block, never `html_safe`; document that MCP content blocks are not rendered by the gem |
| Constant-time comparison for API keys leaks length via early termination on length mismatch | Compare length-prefix first; if length matches, compare bytes constant-time; the SDK or `OpenSSL.fixed_length_secure_compare` handles this — use that |
| Audit log lines containing query SQL leak sensitive data (PII in WHERE clauses) | The `argument :secret, :string, redact: true` opt-in exists for sensitive args; document that SQL itself is logged; consider adding a per-plugin `log_params: false` option as a v1.1 follow-up |

---

## Documentation / Operational Notes

- README is a v1 deliverable (U12). Origin R31 requires install, walkthrough, configuration reference, plugin examples, plugin authoring tutorial.
- Operational note: gem is mountable in production with no migrations and no data-store requirements beyond the operator's existing DB connections. Zero "setup ceremony" is part of the value proposition; preserve it.
- Versioning: follow semver. Pre-1.0 minor releases may break compatibility; document plainly in README. Target v1.0.0 once the 2026-07-28 RC migration lands.

---

## Sources & References

- **Origin document:** [docs/brainstorms/talk-to-your-app-gem-v1-requirements.md](../brainstorms/talk-to-your-app-gem-v1-requirements.md)
- MCP spec 2025-11-25: <https://modelcontextprotocol.io/specification/2025-11-25/basic/transports>
- MCP 2026-07-28 RC: <https://blog.modelcontextprotocol.io/posts/2026-07-28-release-candidate/>
- Official Ruby SDK: <https://github.com/modelcontextprotocol/ruby-sdk>
- fast-mcp (reference only): <https://github.com/yjacquin/fast-mcp>
- Rails Guides — Multiple Databases: <https://guides.rubyonrails.org/active_record_multiple_databases.html>
- Warden strategy registry pattern: <https://github.com/wardencommunity/warden>
- ActiveJob queue adapter convention: <https://api.rubyonrails.org/classes/ActiveJob/QueueAdapters.html>
