---
date: 2026-06-01
topic: talk-to-your-app-gem-v1
---

# talk_to_your_app — Rails-native MCP server gem (v1)

## Summary

A public OSS Ruby gem that mounts an MCP server in a Rails app over HTTP/SSE, exposing a bundled "ops console" of tools (read-only DB, jobs introspection across Sidekiq + Solid Queue, Flipper flag management, user-defined health checks) behind authentication, with a simple Ruby DSL for adding more tools. The gem's distinguishing posture is per-tool DB-role declaration with fail-closed defaults.

---

## Problem Frame

Operators of mid-sized Rails apps regularly want to ask their running production system small, real questions — "how many users signed up today", "are video-generation jobs succeeding", "is feature X enabled for account Y", "is the third-party transcription service still healthy". Today those questions land in some mix of: SSH into a box and open a Rails console, a hand-rolled admin dashboard, Grafana, ad-hoc Slack-bot scripts, or a paid observability tool that doesn't really know the app's domain. Each of those has friction (SSH ceremony, dashboard maintenance, switching tools) and none of them is conversational.

MCP-capable LLM clients (Claude Desktop, Claude Code, agent frameworks) create the opportunity to ask those questions in natural language against a typed tool surface. Existing Ruby MCP gems exist but are framework-agnostic — they don't know about Rails replicas, jobs backends, feature-flag tooling, or Rails-shaped auth. An operator wiring one up still has to write all the Rails glue themselves.

The cost shape is small but cumulative: every time the operator wants a new operational signal, they either build dashboard infrastructure or live with SSH. For solo developers and small teams running Rails apps, this friction blocks the lightweight "just ask the app" workflow that LLM clients now make plausible.

---

## Actors

- A1. Gem operator: the Rails developer who installs the gem in their own app, configures the initializer, declares DB connections, enables plugins, manages API keys. Owns the security posture for their deployment.
- A2. MCP client: an LLM client (Claude Desktop via bridge, Claude Code, an agent framework) that connects over HTTP/SSE to query and act on the Rails app on behalf of A1.
- A3. Plugin author: a Ruby developer (could be A1, could be a third party) who writes a custom plugin against the DSL to expose app-specific tools.

---

## Requirements

**Transport and mounting**
- R1. The gem ships an HTTP/SSE MCP transport implementation as the only supported transport in v1. stdio is explicitly out of scope.
- R2. The gem mounts in a host Rails app as a Rack-mountable engine (or equivalent). The mount point is configurable; default is `/mcp`.
- R3. The gem targets Rails 7.1+ and is tested against Rails 7.1, 7.2, and 8.x.

**Authentication**
- R4. The gem supports two authentication mechanisms in v1: HTTP basic auth and API key (header-based). At least one must be configured; the engine refuses to boot if no auth is configured.
- R5. Each authenticated request is associated with a principal identifier (the API key label or basic-auth username) that is available to tools and is included in every audit log line.

**Plugin model**
- R6. v1 bundles four plugins in the main gem: DB (read-only), Jobs, Flipper, Health. All four are part of the single `talk_to_your_app` install.
- R7. Each plugin is independently enable/disable-able via the initializer. Plugins are off by default; the operator opts in.
- R8. The gem provides a Ruby DSL for declaring custom plugins and tools. The bundled plugins serve as reference implementations of the DSL.
- R9. Plugins declare which DB connection(s) they require by name (e.g., `:replica_readonly`, `:flipper_writer`). The gem refuses to boot if a plugin is enabled and its required connection is not configured.
- R10. Plugin dependencies on third-party gems (sidekiq, solid_queue, flipper) are soft dependencies. If a plugin is enabled but its underlying gem is not present, the gem emits a clear, actionable error at boot ("plugin X requires gem Y in your Gemfile") rather than crashing late.

**DB plugin**
- R11. The DB plugin exposes a tool that accepts a raw SQL string and returns rows.
- R12. The DB plugin connects via a read-only DB connection separately configured by the operator (typically a replica with a read-only role). The gem does not infer or downgrade an existing connection.
- R13. The DB plugin enforces a statement timeout. Default is 30 seconds. The default is overridable globally and per-plugin.
- R14. The DB plugin returns query results in MCP content blocks the operator chooses: JSON (default for structured data), plain text, or HTML table. Format is requestable per-call by the MCP client.

**Jobs plugin**
- R15. The jobs plugin exposes a common interface for job-system introspection: queue sizes, recent jobs, failed jobs, enqueue/processing rates over a time window.
- R16. The jobs plugin ships two adapters in v1: Sidekiq and Solid Queue. At boot it selects the adapter the operator declared, or refuses to boot if none is declared and the plugin is enabled.
- R17. The jobs plugin is read-only in v1: introspection only, no enqueueing, retrying, or killing of jobs from MCP.

**Flipper plugin**
- R18. The Flipper plugin exposes tools to list flags, read flag state for a given actor, enable/disable a flag globally, and enable/disable a flag for a specific actor.
- R19. The Flipper plugin uses a writer-capable DB connection declared by the operator. The gem does not reuse the read-only DB plugin's connection for Flipper writes.

**Health plugin**
- R20. The health plugin lets the operator register named health checks in Ruby (a block or callable that returns pass/fail and an optional value).
- R21. The health plugin exposes a tool to list registered checks and a tool to run a named check on demand. Each check returns pass/fail plus the value the check produced.
- R22. The v1 health plugin does no scheduling, no aggregation across runs, no alerting, and no historical storage.

**Logging and audit**
- R23. Every tool invocation is logged using the host Rails logger by default. The default log level is INFO. Log level is overridable globally and per-plugin.
- R24. The logger is swappable: the operator can substitute any object that responds to the Logger interface (e.g., to log into a DB, send to an external service, or wrap with structured-logging middleware).
- R25. Each invocation log line includes at minimum: timestamp, principal identifier (R5), plugin name, tool name, invocation parameters, outcome (success/failure), duration.

**Security defaults**
- R26. The gem is fail-closed: if required configuration is missing (no auth, no DB connection for an enabled plugin, no jobs adapter for the jobs plugin), the engine raises at boot rather than starting in a degraded or insecure state.
- R27. DB writes are not permitted via the DB plugin in v1. Writes are only possible through plugins that explicitly declare a writer connection (Flipper).
- R28. There is no "execute arbitrary Ruby" tool in v1.

**Packaging and distribution**
- R29. v1 ships as a single gem (`talk_to_your_app`) containing the engine, DSL, and all four bundled plugins. No companion gems in v1.
- R30. The internal directory layout treats each plugin as an isolated unit with no cross-plugin imports and no shared mutable state, so that a future split into optional-require or companion-gem packaging is mechanical rather than a rewrite.
- R31. The gem ships with a README that includes: install instructions, a minimal end-to-end "connect Claude and run your first query" walkthrough, configuration reference, examples for each bundled plugin, and a "write your own plugin" tutorial.

---

## Acceptance Examples

- AE1. **Covers R9, R26.** Given the Flipper plugin is enabled in the initializer but no `:flipper_writer` connection is configured, when the Rails app boots, the gem raises a clear configuration error naming the missing connection. The app does not start.
- AE2. **Covers R10.** Given the Sidekiq adapter for the jobs plugin is selected but the `sidekiq` gem is not in the Gemfile, when the Rails app boots, the gem raises with a message that names the missing gem and the plugin requiring it.
- AE3. **Covers R12, R13, R27.** Given an MCP client sends a SQL statement `UPDATE users SET admin=true` via the DB plugin, when the gem executes it on the read-only replica connection, the database rejects the write at the connection level and the gem returns the database error to the client. If the statement instead runs longer than the configured timeout, it is cancelled at 30 seconds and an error is returned.
- AE4. **Covers R14.** Given an MCP client requests the result of a `SELECT` query with `format: "html"`, when the DB plugin returns results, the response is a single MCP content block of type text containing a rendered HTML table. Given the same call with `format: "json"`, the same data is returned as a JSON content block.
- AE5. **Covers R20, R21.** Given the operator registered a health check named `:video_pipeline` in the initializer that returns pass/fail based on recent successful video generations, when an MCP client invokes the `health.run` tool with `name: "video_pipeline"`, the gem executes the check and returns the pass/fail result and the value the check produced.
- AE6. **Covers R23, R25.** Given an authenticated request invokes any tool, when the invocation completes (success or failure), exactly one log line is written at INFO containing the principal identifier, plugin name, tool name, parameters, outcome, and duration.

---

## Success Criteria

- An operator can install the gem in a Rails 7.1+ app, follow the README walkthrough, and have an MCP client successfully run a SQL query against their read-only replica within 30 minutes of starting.
- An operator can register a custom health check ("are the last N video-generation jobs succeeding?") and invoke it from an MCP client without writing any HTTP, MCP-protocol, or auth code themselves.
- A reviewer reading the README can answer "why this gem instead of fast-mcp / mcp-rb?" in one sentence (Rails-native: per-tool DB roles, bundled jobs + Flipper + health plugins, Rails engine mount).
- The plugin DSL is concrete enough that a third party can write a Redis plugin (not shipped in v1) by following the bundled plugins as examples, without reading the engine source.
- `ce-plan` can take this document and produce an implementation plan without inventing v1 scope, security posture, transport choice, or plugin boundaries.

---

## Scope Boundaries

- Custom-metrics + alerting plugin (the full "monitoring" capability with scheduling, aggregation, thresholds, notifications) — deferred to v1.1+.
- stdio transport and any Claude Desktop bridge — v1 documents using a community stdio↔HTTP bridge for Claude Desktop; first-party stdio is deferred.
- GoodJob, Resque, and other jobs-backend adapters beyond Sidekiq and Solid Queue.
- Redis plugin, Solid Cache plugin, ActiveStorage plugin, ActionMailer plugin.
- A generic "execute arbitrary Ruby" tool. Not shipped under any flag.
- SQL parsing or SELECT-only validation as a safety layer. Safety is enforced at the DB connection level (read-only role / replica) instead.
- Companion-gem split (`talk_to_your_app-sidekiq` etc.) — deferred until adoption justifies the release ceremony.
- OAuth, OIDC, SSO, JWT, or any auth mechanism beyond basic auth and API key.
- Multi-tenant request scoping (per-tenant data isolation enforced inside the gem).
- A web admin UI for managing the gem.
- Write tools in the jobs plugin (enqueue, retry, kill) — read-only introspection only in v1.

---

## Key Decisions

- HTTP/SSE only in v1, no stdio: matches the "connect to remote app" use case directly and keeps the v1 surface single-transport. Operators wanting Claude Desktop can use an existing bridge.
- Monolithic packaging (Approach A) over companion-gems (Approach B) and over optional-require (Approach C): single install, cohesive v1, lowest release ceremony. Internal layout follows C's structure so the future split is mechanical.
- Connection-level read-only enforcement instead of SQL parsing: pg/MySQL roles are reliable; SQL parsers have edge cases. Side effect: a separate replica/read-only-role connection is mandatory, which we accept as a real operator cost.
- Per-tool DB role as the headline feature: it is the natural consequence of the security posture, no other Ruby MCP gem ships it, and it gives the README a one-sentence answer for "why this gem".
- Health-check plugin included in v1 even though "monitoring" is deferred: the user's most concrete pain is health-check-shaped, so shipping at least a read-and-return-pass-fail capability anchors the gem in real use. Scheduling, aggregation, and alerting stay deferred.
- Jobs plugin is read-only in v1: enqueue/retry/kill via MCP raises a different threat-model question (write semantics, idempotency, authz granularity) that doesn't need to be answered to make v1 useful.

---

## Dependencies / Assumptions

- Assumption: "No validated pain with existing Ruby MCP gems" is explicit. The gem's bet is Rails-nativeness as a positioning differentiator, not a fix for a known feature gap in fast-mcp/mcp-rb. If a reviewer challenges "why not contribute to fast-mcp?", the answer is the Rails-native plugin model and per-tool DB roles, not a missing feature.
- Assumption: Operators of mid-sized Rails apps either have or can configure a read-only DB replica / read-only role. The gem cannot make sense without it. README must guide operators who do not yet have one.
- Assumption: Rails 7.1+ is an acceptable floor. This is driven by Solid Queue's effective floor and keeps the test matrix bounded; Rails 6.x is out.
- Dependency: MCP transport spec (Streamable HTTP / SSE) is stable enough at the time of v1 release to target. If the protocol shifts materially before release, the transport-layer requirement (R1) may need a v1.0 cut decision.
- Dependency: A Rails-shaped MCP protocol implementation (request parsing, content-block serialization, error mapping) must exist inside the gem. v1 is responsible for shipping it; the gem does not depend on a third-party Ruby MCP framework.

---

## Outstanding Questions

### Resolve Before Planning

- (none — scope is settled)

### Deferred to Planning

- [Affects R8][Technical] Concrete shape of the plugin DSL — class-based, block-based, or hybrid. Decision belongs in planning once the engine boundary is sketched.
- [Affects R1, R2][Technical] Whether to implement the MCP protocol layer from scratch inside the gem or vendor a small protocol-only Ruby implementation. Decide during planning after surveying current Ruby MCP libraries' protocol-layer fitness.
- [Affects R4][Technical] Exact header name and rotation/multi-key story for API key auth. Planning can decide based on common Rails patterns.
- [Affects R14][Technical] Whether HTML table rendering goes through ActionView or a tiny dedicated renderer. Planning decision; either is fine.
- [Affects R23, R25][Needs research] Whether the audit-log line should also include the MCP request ID / session ID for cross-system correlation, and what MCP's session model offers there.
- [Affects R16][Technical] Whether the Sidekiq and Solid Queue adapters share a single `Jobs::Adapter` abstract class or duck-type a module. Planning decision once one adapter is sketched.
