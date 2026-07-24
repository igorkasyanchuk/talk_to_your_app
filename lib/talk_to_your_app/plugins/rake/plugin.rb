# frozen_string_literal: true

require_relative "../../plugin"
require_relative "tools/run"

module TalkToYourApp
  module Plugins
    # The Rake plugin runs operator-approved rake tasks over MCP. It is
    # fail-closed and allow-list-only: it refuses to boot without an explicit
    # `allowed:` list, and refuses any task not on that list. Because rake tasks
    # can do anything, the allow-list is the security boundary — keep it tight,
    # and prefer read-only/reporting tasks.
    #
    #   config.plugin :rake, allowed: ["stats", "report:generate"]
    #   config.plugin :rake, allowed: [...], timeout: 60   # seconds, default 20
    module Rake
      DEFAULT_TIMEOUT = 20

      module_function

      def allowed_tasks
        options = TalkToYourApp.configuration.enabled_plugins[:rake] || {}
        Array(options[:allowed]).map(&:to_s)
      end

      def allowed?(task)
        allowed_tasks.include?(task.to_s)
      end

      # Per-task wall-clock limit in seconds. A task exceeding it is killed and
      # the tool returns an error. Override with `timeout:` on the plugin. A
      # non-positive or non-numeric value falls back to the default rather than
      # coercing to 0 (which would kill every task before it could run).
      def timeout
        options = TalkToYourApp.configuration.enabled_plugins[:rake] || {}
        value = options[:timeout].to_i
        value.positive? ? value : DEFAULT_TIMEOUT
      end

      class Plugin < TalkToYourApp::Plugin
        tools Tools::Run

        def self.validate_enablement!(options)
          return unless Array(options[:allowed]).empty?

          raise ConfigurationError,
            "talk_to_your_app: the rake plugin requires a non-empty `allowed:` list of rake task names, " \
            "e.g. `config.plugin :rake, allowed: [\"stats\", \"report:generate\"]`. Tasks not on the list are refused."
        end
      end
    end
  end
end

TalkToYourApp.register_plugin(:rake, TalkToYourApp::Plugins::Rake::Plugin)
