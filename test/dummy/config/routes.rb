# frozen_string_literal: true

Rails.application.routes.draw do
  # Root page showing database stats (see HomeController).
  root "home#index"

  # In tests the MCP endpoint is exercised per-test via Rack (see
  # test/support/mcp_driver.rb), so nothing is mounted here under RAILS_ENV=test.
  # For local development we mount it so an MCP client (e.g. Claude) can connect.
  if Rails.env.development?
    mount TalkToYourApp.rack_app, at: TalkToYourApp.configuration.mount_at
  end
end
