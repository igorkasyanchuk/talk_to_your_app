# frozen_string_literal: true

require_relative "../../../tool"

module TalkToYourApp
  module Plugins
    module Jobs
      module Tools
        # Base for the job-metric tools. Each adapter plugin (:sidekiq,
        # :solid_queue) builds concrete subclasses bound to its adapter via
        # `adapter_name`, with an adapter-namespaced MCP name (e.g.
        # "sidekiq.queue_sizes"). Subclasses inherit the arguments/description
        # DSL from their template (see Tool.inherited).
        class Base < TalkToYourApp::Tool
          class << self
            attr_accessor :adapter_name
          end

          private

          def adapter
            TalkToYourApp::Plugins::Jobs.adapter_for(self.class.adapter_name)
          end
        end
      end
    end
  end
end
