---
title: Sidekiq metrics API needs an explicit lazy `require "sidekiq/api"`
date: 2026-06-16
category: runtime-errors
module: jobs plugin (Sidekiq adapter)
problem_type: runtime_error
component: background_job
symptoms:
  - "NameError: uninitialized constant Sidekiq::Stats (also ::Queue, ::RetrySet, ::DeadSet)"
  - "sidekiq.queue_sizes / recent_jobs / failed_jobs / rate_metrics return a tool error on a fresh web worker"
  - "the tools start working only after a method that required sidekiq/api has run once in the same process"
root_cause: wrong_api
resolution_type: code_fix
severity: high
tags: [sidekiq, soft-dependency, require, lazy-loading, background-jobs, mcp]
---

# Sidekiq metrics API needs an explicit lazy `require "sidekiq/api"`

## Problem
The jobs plugin's Sidekiq adapter referenced `Sidekiq::Stats`, `Sidekiq::Queue`, `Sidekiq::RetrySet`, and `Sidekiq::DeadSet`, but only one method (`health`) ever required `sidekiq/api`. On Sidekiq 7+/8, `require "sidekiq"` does **not** load that API, so the other four data methods raised `NameError` on any worker that had not yet called `health`.

## Symptoms
- `NameError: uninitialized constant Sidekiq::Stats` (and `::Queue` / `::RetrySet` / `::DeadSet`) when calling `sidekiq.queue_sizes`, `sidekiq.recent_jobs`, `sidekiq.failed_jobs`, or `sidekiq.rate_metrics`.
- The error is caught by the tool-level `rescue`, so it surfaces as a generic tool error rather than a crash — easy to misread as a Sidekiq connectivity problem.
- Order-dependent: the tools work only *after* a method that required `sidekiq/api` inline has run once in the process, which masks the bug in manual testing.

## What Didn't Work
- **Hoisting `require "sidekiq/api"` to the top of the adapter file.** This breaks the soft-dependency contract. The adapter file is `require_relative`'d at gem load even when Sidekiq is not installed (the design references backing-gem constants only inside method bodies). A top-level `require "sidekiq/api"` raises `LoadError` at boot for any app that doesn't use Sidekiq — turning a per-tool failure into a gem-won't-load failure.

## Solution
Load the API lazily, at call time, from a single shared helper that every data method calls. `require` is idempotent, so repeated calls are cheap, and the load never happens at gem-load time.

Before — `require` buried in one of five methods:
```ruby
def queue_sizes
  ::Sidekiq::Stats.new.queues          # NameError until something requires sidekiq/api
end

def health
  require "sidekiq/api"                # the only require — masks the bug
  # ...
end
```

After — one lazy helper, called by each data method:
```ruby
def queue_sizes
  load_api
  ::Sidekiq::Stats.new.queues
end

# ...recent_jobs / failed_jobs / rate_metrics all call load_api first...

# Sidekiq's metrics API (Stats/Queue/RetrySet/DeadSet) is not loaded by
# `require "sidekiq"`. Load it lazily at call time — never at gem load —
# so an app without Sidekiq can still load this adapter file. `require`
# is idempotent, so repeated calls are cheap.
def load_api
  require "sidekiq/api"
end
```

## Why This Works
- **Call-time, not load-time.** The require runs only when a tool actually executes, by which point the boot-time `validate_enablement!` check has already confirmed the `Sidekiq` constant is defined (the gem is installed). Apps without Sidekiq still `require_relative` the adapter file at gem load without triggering the require.
- **Idempotent + centralized.** `require` short-circuits on `$LOADED_FEATURES` after the first call, so calling `load_api` at the top of every method costs nothing after the first. One helper means there is a single place that can't be forgotten — the original bug was exactly that the require lived in only one of five methods.

## Prevention
- **Soft-dependency adapters must reference the backing gem's constants only inside method bodies, and load any extra `require` lazily at call time — never at file top.** A top-of-file `require` of an optional gem defeats the whole soft-dependency design.
- **Centralize a repeated lazy require in one helper** rather than scattering it across methods (or, as here, into just one). Scattered requires drift; one method gets it, the rest `NameError`.
- **`require "sidekiq"` ≠ `require "sidekiq/api"` on Sidekiq 7+.** The client (`require "sidekiq"`, loaded in the web process) does not pull in the metrics/admin API classes; those need the explicit `sidekiq/api` require.
- **Test each adapter method in isolation**, not only after `health`, so an order-dependent `NameError` is caught. A regression test that exercises `queue_sizes`/`recent_jobs`/`failed_jobs`/`rate_metrics` directly on a fresh process would have caught this.

## Related Issues
- `docs/solutions/architecture-patterns/mcp-ruby-sdk-rails-integration-2026-06-01.md` — the broader MCP/Rails integration patterns for this gem.
- `docs/plugin_authoring.md` — the `requires_gem` soft-dependency contract that this adapter implements.
