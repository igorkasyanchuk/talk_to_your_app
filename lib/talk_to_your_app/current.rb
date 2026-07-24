# frozen_string_literal: true

# `active_support` itself, not just the sub-file: CurrentAttributes references
# ActiveSupport::CodeGenerator at class-definition time, and the sub-require does
# not pull it in. Without this, `require "talk_to_your_app"` raises NameError
# anywhere ActiveSupport has not already been fully loaded — every Rails boot
# hides it, a plain script or a non-Rails Rack process does not.
require "active_support"
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
