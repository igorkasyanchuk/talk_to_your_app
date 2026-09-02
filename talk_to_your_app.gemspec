# frozen_string_literal: true

require_relative "lib/talk_to_your_app/version"

Gem::Specification.new do |spec|
  spec.name        = "talk_to_your_app"
  spec.version     = TalkToYourApp::VERSION
  spec.authors     = ["Igor Kasyanchuk"]
  spec.email       = ["igorkasyanchuk@gmail.com"]

  spec.summary     = "Rails-native MCP server: ask your running app real questions over MCP."
  spec.description = <<~DESC
    A thin Rails layer over the official MCP Ruby SDK. Mounts a Streamable HTTP
    MCP endpoint, gates access behind API-key or HTTP Basic auth, enforces
    fail-closed per-tool database roles, and ships seven bundled plugins
    (DB, Sidekiq, Solid Queue, Flipper, Rake, Cache, Custom Tools) plus a Ruby
    DSL for writing your own.
  DESC
  spec.homepage    = "https://github.com/igorkasyanchuk/talk_to_your_app"
  spec.license     = "MIT"

  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"]   = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  # Ship only operator-facing docs — not plans, brainstorms, or internal notes.
  spec.files = Dir[
    "lib/**/*",
    "docs/read_only_connections.md",
    "docs/plugin_authoring.md",
    "LOCAL_DEVELOPMENT.md",
    "README.md",
    "CHANGELOG.md",
    "SECURITY.md",
    "LICENSE"
  ]
  spec.require_paths = ["lib"]

  # Protocol/transport layer — the official MCP Ruby SDK (published as `mcp`).
  # Pin to the 1.x line; see README "Upgrade discipline".
  spec.add_dependency "mcp", "~> 1.4"

  # Rails integration. Hard deps: we are a Rails-native gem.
  spec.add_dependency "activerecord", ">= 7.2"
  spec.add_dependency "railties", ">= 7.2"

  # sidekiq, solid_queue, and flipper are SOFT dependencies — intentionally not
  # declared here. The relevant plugin refuses to boot with an actionable error
  # if the operator enables it without the backing gem in their Gemfile.
end
