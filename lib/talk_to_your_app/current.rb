# frozen_string_literal: true

require "active_support/current_attributes"

module TalkToYourApp
  # Per-request context, set by the auth middleware and read by tool contexts
  # and the audit logger. The MCP SDK does not thread the Rack env through to
  # tool invocations, so we carry the principal and session id here.
  # ActiveSupport::CurrentAttributes is request-isolated and reset by the Rails
  # executor between requests.
  class Current < ActiveSupport::CurrentAttributes
    attribute :principal, :session_id, :ip
  end
end
