# frozen_string_literal: true

require_relative "../../plugin"
require_relative "interface"
require_relative "tools/queue_sizes"
require_relative "tools/recent_jobs"
require_relative "tools/failed_jobs"
require_relative "tools/rate_metrics"

module TalkToYourApp
  module Plugins
    # Background-job metrics, exposed as one plugin per backend: `:sidekiq` and
    # `:solid_queue`. Each is enabled independently
    # (`config.plugin :sidekiq, connection: false`) and exposes adapter-namespaced
    # tools (`sidekiq.queue_sizes`, `solid_queue.queue_sizes`, …), so both can run
    # at once — e.g. while migrating from one backend to the other. The job
    # backends read Redis / their own tables, not a wired SQL connection, so they
    # are enabled with `connection: false`.
    module Jobs
      @adapters = {}

      # The four metric tools, by MCP-name suffix. Each adapter plugin builds its
      # own concrete subclasses bound to its adapter.
      TOOL_TEMPLATES = {
        "queue_sizes" => Tools::QueueSizes,
        "recent_jobs" => Tools::RecentJobs,
        "failed_jobs" => Tools::FailedJobs,
        "rate_metrics" => Tools::RateMetrics,
      }.freeze

      class << self
        # Registers an adapter class under a name. The class duck-types
        # Jobs::Interface and exposes `required_gem` ({ const:, gem_name: }).
        def register_adapter(name, adapter_class)
          @adapters[name.to_sym] = adapter_class
        end

        def adapter_for(name)
          @adapters[name&.to_sym]
        end

        def known_adapter_names
          @adapters.keys
        end

        # Builds the four metric tools for an adapter, named "<adapter>.<suffix>"
        # and bound to the adapter so each plugin's tools target its own backend.
        def build_tools(adapter_name)
          TOOL_TEMPLATES.map do |suffix, template|
            Class.new(template) do
              name "#{adapter_name}.#{suffix}"
              self.adapter_name = adapter_name
            end
          end
        end

        # Boot validation shared by both adapter plugins: the adapter's backing
        # gem must be loadable and it must implement the full metrics interface.
        def validate_adapter!(adapter_name)
          adapter = adapter_for(adapter_name)
          unless adapter
            raise ConfigurationError,
              "talk_to_your_app: jobs adapter #{adapter_name.inspect} is not registered " \
              "(available: #{known_adapter_names.inspect})."
          end

          req = adapter.required_gem
          if req && !Object.const_defined?(req[:const])
            raise ConfigurationError,
              "talk_to_your_app: the #{adapter_name} plugin requires the `#{req[:gem_name]}` gem " \
              "(constant #{req[:const]} is not defined)."
          end

          unless Interface.satisfied_by?(adapter)
            raise ConfigurationError,
              "talk_to_your_app: jobs adapter #{adapter_name.inspect} does not implement the full interface " \
              "(#{Interface::METHODS.join(", ")})."
          end
        end
      end

      # The Sidekiq backend (reads Redis). Enable with `connection: false`.
      class SidekiqPlugin < TalkToYourApp::Plugin
        tools(*Jobs.build_tools(:sidekiq))

        def self.validate_enablement!(_options)
          Jobs.validate_adapter!(:sidekiq)
        end
      end

      # The Solid Queue backend (reads its own tables via the app's connection).
      # Enable with `connection: false`.
      class SolidQueuePlugin < TalkToYourApp::Plugin
        tools(*Jobs.build_tools(:solid_queue))

        def self.validate_enablement!(_options)
          Jobs.validate_adapter!(:solid_queue)
        end
      end
    end
  end
end

TalkToYourApp.register_plugin(:sidekiq, TalkToYourApp::Plugins::Jobs::SidekiqPlugin)
TalkToYourApp.register_plugin(:solid_queue, TalkToYourApp::Plugins::Jobs::SolidQueuePlugin)

# Bundled adapters self-register on load (after Jobs.register_adapter exists).
# They reference their backing gem's constants only inside method bodies, so
# loading them never requires the gem.
require_relative "adapters/sidekiq"
require_relative "adapters/solid_queue"
