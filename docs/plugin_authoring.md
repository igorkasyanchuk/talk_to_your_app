# Writing a plugin

This walks through building a small **Cache** plugin that exposes Rails cache statistics over MCP. Copy it and adapt. Everything here uses the same DSL the bundled plugins use — there is no privileged internal API.

## 1. Write a tool

A tool subclasses `TalkToYourApp::Tool`, declares its arguments, and implements `#call(args, ctx)`.

```ruby
# lib/cache_plugin/tools/stats.rb
class CachePlugin
  module Tools
    class Stats < TalkToYourApp::Tool
      name        "cache.stats"
      description "Return Rails cache statistics."
      argument    :namespace, :string, description: "Optional cache key namespace to filter by."

      def call(args, ctx)
        stats = Rails.cache.stats
        stats = stats.select { |key, _| key.to_s.start_with?(args[:namespace]) } if args[:namespace]
        json(stats)
      end
    end
  end
end
```

Things to know:

- `name` sets the MCP tool name. Note it overrides Ruby's `Class#name` as a setter, so `MyTool.name` returns the MCP name (`"cache.stats"`), not the class name; use `MyTool.tool_name` when you specifically want the MCP name. `argument(name, type, required:, enum:, default:, description:, redact:, minimum:, maximum:)` compiles to the JSON Schema the SDK validates against; `minimum:`/`maximum:` apply to `:integer`/`:number` arguments and become JSON Schema range constraints.
- `#call` receives the parsed `args` (with defaults applied) and a `ctx`. Return a `String` (becomes a text block), a Hash/array (becomes JSON), or use the helpers: `text(str)`, `json(obj)`, `error(message)`.
- `ctx` exposes `ctx.principal`, `ctx.session_id`, `ctx.ip`, `ctx.logger`, and `ctx.connection(:name) { |conn| ... }` for role-switched database access. With no name, `ctx.connection` resolves the connection the operator wired into this plugin; `ctx.connection_name` returns that resolved name (useful for deriving a timeout or logging which connection ran).
- Mark sensitive arguments `redact: true` to keep them out of the audit log.

## 2. Declare the plugin

A plugin subclasses `TalkToYourApp::Plugin` and lists its tools and any soft-dependency gem.

```ruby
# lib/cache_plugin.rb
class CachePlugin < TalkToYourApp::Plugin
  # requires_gem "SomeConst", gem_name: "some_gem"   # soft dependency, checked at boot
  tools Tools::Stats
end

TalkToYourApp.register_plugin(:cache, CachePlugin)
```

- `requires_gem` checks a constant at boot and raises an actionable error if the gem is absent.
- `log_level :debug` overrides the audit level for this plugin's tools.

The operator wires a connection into **every** plugin at enable time — a declared
connection name, or `connection: false` to opt out. To require a connection (or a
specific role), override `validate_enablement!` and inspect `wired_spec(options)`
(see "Per-plugin boot validation" and "Connection-using plugins" below).

## 3. Enable it

```ruby
# config/initializers/talk_to_your_app.rb
require "cache_plugin"

TalkToYourApp.configure do |config|
  config.plugin :cache, connection: false   # or connection: :some_declared_connection
end
```

Boot the app and the four-line plugin shows up in `tools/list`, audit-logged like everything else.

## Connection-using plugins

If your tool reads or writes a database, use the connection the operator wired into the plugin (`config.plugin :reports, connection: :readonly`):

```ruby
class ReportTool < TalkToYourApp::Tool
  name "reports.daily"

  def call(_args, ctx)
    # No name -> resolves the connection the operator wired into this plugin.
    rows = ctx.connection { |conn| conn.select_all("SELECT ...").to_a }
    json(rows)
  end
end

class ReportsPlugin < TalkToYourApp::Plugin
  tools ReportTool

  # Require a real connection (reject connection: false) and, say, a writer:
  def self.validate_enablement!(options)
    unless options[:connection]
      raise TalkToYourApp::ConfigurationError, "reports requires a connection: (connection: false is not valid)"
    end
    spec = wired_spec(options) # nil for an unregistered name (ConnectionRegistry.validate! owns that)
    raise TalkToYourApp::ConfigurationError, "reports needs a :writing connection" unless spec.nil? || spec.role == :writing
  end
end
```

`ctx.connection` runs the block on the wired connection switched to its declared role (reads on a reader, writes on a writer), then unwinds the switch when the block returns. `wired_spec(options)` returns the wired `ConnectionSpec` (or nil when the operator passed `connection: false` or an unregistered name) — see "Per-plugin boot validation" below.

## Per-plugin boot validation

Override `validate_enablement!(options)` to enforce plugin-specific requirements at boot — for example, requiring an option to be present:

```ruby
class CachePlugin < TalkToYourApp::Plugin
  def self.validate_enablement!(options)
    raise TalkToYourApp::ConfigurationError, "cache plugin needs a :store" unless options[:store]
  end
end
```

That's the whole contract. Bundled plugins (`db`, `solid_queue`, `flipper`) are good references — they live in `lib/talk_to_your_app/plugins/`.
