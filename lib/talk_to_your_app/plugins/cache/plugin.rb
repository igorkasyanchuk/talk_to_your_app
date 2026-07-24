# frozen_string_literal: true

require_relative "../../plugin"
require_relative "../../tool"

module TalkToYourApp
  module Plugins
    module Cache
      # Clears the host app's cache store. Destructive (every cached entry is
      # dropped, and the app re-warms from cold), so it lives in its own opt-in
      # plugin rather than shipping enabled anywhere by default. Scope it to
      # trusted principals with `config.authorize`.
      class ClearTool < TalkToYourApp::Tool
        name        "cache.clear"
        description "Clear the Rails cache (Rails.cache.clear) — drops every cached entry."

        def call(_args, _ctx)
          Rails.cache.clear
          json(cleared: true, store: Rails.cache.class.name)
        end
      end

      # Cache tools operate on Rails.cache, not a wired SQL connection — enable
      # with `config.plugin :cache, connection: false`.
      class Plugin < TalkToYourApp::Plugin
        tools ClearTool
      end
    end
  end
end

TalkToYourApp.register_plugin(:cache, TalkToYourApp::Plugins::Cache::Plugin)
