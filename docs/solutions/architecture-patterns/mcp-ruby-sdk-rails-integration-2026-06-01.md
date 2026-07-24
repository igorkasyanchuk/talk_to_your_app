---
title: "Wrapping the official MCP Ruby SDK (the `mcp` gem) in a Rails-native layer"
date: 2026-06-01
category: architecture-patterns
module: talk_to_your_app
problem_type: architecture_pattern
component: tooling
severity: medium
applies_when:
  - Integrating the official MCP Ruby SDK into a Rails gem or engine
  - Building a custom Tool DSL that compiles down to MCP::Tool subclasses
  - Needing per-request auth context (principal, session id) inside MCP tool calls
  - Dynamically defining ActiveRecord connection classes at runtime
symptoms:
  - "Bundler cannot find a gem named modelcontextprotocol-ruby-sdk"
  - "JSON-Schema draft-04 metaschema rejects an empty required: [] array"
  - Per-request principal is nil inside tool invocations
  - "ActiveRecord raises \"Anonymous class is not allowed\" on connects_to"
related_components:
  - authentication
  - database
  - testing_framework
tags:
  - mcp
  - ruby-sdk
  - rails
  - activesupport-currentattributes
  - connects-to
  - json-schema
  - rack-middleware
  - tool-dsl
---

# Wrapping the official MCP Ruby SDK (the `mcp` gem) in a Rails-native layer

## Context

Building a Rails-native MCP server gem (`talk_to_your_app`) on top of the official
Model Context Protocol Ruby SDK. The SDK does the protocol/transport work; the gem
adds the Rails layer (auth, per-tool DB roles, a Tool/Plugin DSL, audit logging).
The integration sits at the seam of Rack middleware, the Rails request lifecycle,
and MCP protocol mechanics — and several of the SDK's conventions diverge from what
the plan, blog posts, and intuition suggest. Each of the gotchas below cost real
time because the failure mode was a confusing error (or silent wrong behavior),
not a clear one.

## Guidance

### 1. The gem is named `mcp`, not `modelcontextprotocol-ruby-sdk`

Plans and posts reference `modelcontextprotocol-ruby-sdk`; only `mcp` resolves on
RubyGems. Pin it tightly — it is pre-1.0 and minor releases can break.

```ruby
# Gemfile / gemspec
gem "mcp", "~> 0.18"
```

Public surface used: `MCP::Server`, `MCP::Tool`, `MCP::Server::Transports::StreamableHTTPTransport`.

### 2. `MCP::Tool` dispatches a **class** method — bridge your DSL into it

The SDK invokes `def self.call(**args, server_context:)` on an `MCP::Tool`
subclass, not an instance method. To expose a friendlier class-based DSL while
still using the SDK, compile your DSL down to an `MCP::Tool` via `MCP::Tool.define`:

```ruby
MCP::Tool.define(name: tool_name, description: desc, input_schema: schema_hash) do |server_context: nil, **args|
  MyTool.dispatch(args) # bridge into your own (instance) method
end
```

**Schema trap:** `input_schema` is a JSON-Schema hash `{ properties:, required: }`,
validated against the **draft-04 metaschema**, which rejects an empty `required: []`
("did not contain a minimum number of items 1"). Omit `required` entirely when
there are none:

```ruby
schema = { properties: properties }
schema[:required] = required unless required.empty?   # never emit required: []
```

### 3. Per-request context travels via `ActiveSupport::CurrentAttributes`, not the SDK

The Streamable HTTP transport does **not** thread the Rack `env` into tool
invocations, so the authenticated principal and the MCP session id cannot reach a
tool through the SDK call signature. Carry them out-of-band:

```ruby
class Current < ActiveSupport::CurrentAttributes
  attribute :principal, :session_id
end

# Rack auth middleware in front of the transport:
def call(env)
  Current.principal  = principal_from(env["HTTP_AUTHORIZATION"])
  Current.session_id = env["HTTP_MCP_SESSION_ID"]   # "Mcp-Session-Id" header
  @app.call(env)
ensure
  Current.reset
end
```

Tools (and the audit logger) then read `Current.principal`. Build the transport
with `enable_json_response: true` so tool dispatch runs **synchronously inside
`@app.call`** — the middleware `ensure` then resets *after* the tool has run. With
SSE/streaming responses the tool would execute *after* the `ensure` reset, leaving
`Current.principal` nil during dispatch — an environment-dependent trap worth a
pinning test.

### 4. The stateful handshake must be replayed by clients and tests

A client must `POST initialize` first; the response carries an `Mcp-Session-Id`
header. Every later request must send that header **plus** `MCP-Protocol-Version`
(e.g. `2025-11-25`). A test driver has to replay this or every `tools/*` call is
rejected for a missing session.

### 5. `connects_to` rejects anonymous classes

When a connection registry builds an abstract `ActiveRecord::Base` subclass
dynamically, `connects_to` raises `"Anonymous class is not allowed"` unless the
class has a real constant name first:

```ruby
klass = Class.new(ActiveRecord::Base) { self.abstract_class = true }
const_set("Conn0_primary_reading", klass)            # required before connects_to
klass.connects_to(database: { reading: :primary })
```

Use a collision-free name (e.g. an index prefix) if you register several at runtime.

## Why This Matters

Every one of these surfaces as a *non-obvious* failure:

- **Wrong gem name** → `bundle install` resolves nothing useful.
- **`required: []`** → the metaschema error never mentions `required`.
- **Missing `CurrentAttributes` carrier** → tools run with a nil principal (a silent
  auth gap), and the SSE-vs-JSON variant makes it environment-dependent.
- **Missing handshake headers** → unit tests pass, real clients get protocol errors.
- **Anonymous `connects_to` class** → Rails raises with no hint that `const_set` is the fix.

Knowing them up front turns a multi-hour spelunk into a few lines.

## When to Apply

- Mounting an MCP server inside a Rails/Rack app using the `mcp` gem.
- Wrapping the SDK in a higher-level Tool/Plugin DSL.
- Building authenticated or multi-principal MCP endpoints where tool calls must be
  scoped to a caller.
- Writing integration tests that exercise the full MCP protocol (not just tool logic).
- Creating dynamic ActiveRecord connection registries behind MCP tools.

## Examples

A minimal test driver that replays the handshake (the shape used by this gem's
`test/support/mcp_driver.rb`):

```ruby
PROTOCOL = "2025-11-25"

# 1) initialize -> capture the session id
res = post("/mcp", { jsonrpc: "2.0", id: 1, method: "initialize",
  params: { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: { name: "test", version: "1" } } },
  "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json",
  "HTTP_AUTHORIZATION" => "Bearer sk-good")
session_id = res.headers["Mcp-Session-Id"]

# 2) every later call echoes the session id + protocol version
post("/mcp", { jsonrpc: "2.0", id: 2, method: "tools/list" },
  "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json",
  "HTTP_AUTHORIZATION" => "Bearer sk-good",
  "HTTP_MCP_SESSION_ID" => session_id, "HTTP_MCP_PROTOCOL_VERSION" => PROTOCOL)
```

## Related

- Design-time counterpart: [docs/plans/2026-06-01-001-feat-talk-to-your-app-gem-v1-plan.md](../../plans/2026-06-01-001-feat-talk-to-your-app-gem-v1-plan.md) — this learning records what the plan assumed vs. what actually bit during implementation (U3/U4/U5).
- Tool/Plugin DSL reference: [docs/plugin_authoring.md](../../plugin_authoring.md).
- The `connects_to` role mechanics this gem builds on for read-only DB access: [docs/read_only_connections.md](../../read_only_connections.md).
