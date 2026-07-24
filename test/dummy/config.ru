# frozen_string_literal: true

# Rack entrypoint for running the dummy app locally (e.g. to connect an MCP
# client such as Claude). See ../../LOCAL_DEVELOPMENT.md.
require_relative "config/environment"

run Rails.application
Rails.application.load_server if Rails.application.respond_to?(:load_server)
