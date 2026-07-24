# frozen_string_literal: true

require "rack"
require_relative "api_key"
require_relative "basic"
require_relative "../current"

module TalkToYourApp
  module Auth
    # Rack middleware sitting in front of the MCP transport. It authenticates
    # every request and establishes the per-request principal. Requests that
    # fail never reach the transport. Host/Origin validation (DNS-rebinding
    # protection per MCP spec 2025-11-25) is owned by the SDK transport, which
    # receives `allowed_hosts`/`allowed_origins` and handles same-origin and
    # case-folding — no duplicate check here.
    class Middleware
      def initialize(app)
        @app = app
      end

      def call(env)
        config = TalkToYourApp.configuration

        principal = authenticate(env, config)
        return unauthorized(config) if principal.nil?

        TalkToYourApp::Current.principal = principal
        TalkToYourApp::Current.session_id = env["HTTP_MCP_SESSION_ID"]
        TalkToYourApp::Current.ip = Rack::Request.new(env).ip
        env["ttya.principal"] = principal

        @app.call(env)
      ensure
        TalkToYourApp::Current.reset
      end

      private

      def authenticate(env, config)
        header = env["HTTP_AUTHORIZATION"]
        return nil if header.nil? || header.empty?

        scheme, value = header.split(" ", 2)
        case scheme&.downcase
        when "bearer" then ApiKey.principal_for(value, config.api_keys)
        when "basic"  then Basic.principal_for(value, config.basic_auth)
        end
      rescue StandardError => e
        # An operator-supplied basic_auth callable (or any validator) that
        # raises must surface as a controlled auth failure, not a 500 leaking a
        # stack trace to the client.
        warn("talk_to_your_app: authentication raised: #{e.class}: #{e.message}")
        nil
      end

      # Body stays generic; WWW-Authenticate lists only the schemes that are
      # actually configured so clients know how to retry.
      def unauthorized(config)
        [401, { "Content-Type" => "application/json", "WWW-Authenticate" => www_authenticate(config) },
         [{ error: "unauthorized" }.to_json]]
      end

      def www_authenticate(config)
        schemes = []
        schemes << "Bearer" if config.api_keys.any?
        schemes << "Basic" if config.basic_auth
        schemes = ["Bearer"] if schemes.empty?
        schemes.join(", ")
      end
    end
  end
end
