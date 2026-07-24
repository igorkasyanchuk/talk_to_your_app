# frozen_string_literal: true

require "rack"
require_relative "api_key"
require_relative "basic"
require_relative "../current"
require_relative "../audit_logger"

module TalkToYourApp
  module Auth
    # Rack middleware sitting in front of the MCP transport. It authenticates
    # every request and establishes the per-request principal. Requests that
    # fail never reach the transport, and each rejection is logged (see
    # AuditLogger.auth_failure). Host/Origin validation (DNS-rebinding
    # protection per MCP spec 2025-11-25) is owned by the SDK transport, which
    # receives `allowed_hosts`/`allowed_origins` and handles same-origin and
    # case-folding — no duplicate check here.
    class Middleware
      def initialize(app)
        @app = app
      end

      def call(env)
        config = TalkToYourApp.configuration
        ip = Rack::Request.new(env).ip

        principal = authenticate(env, config, ip)
        return unauthorized(config) if principal.nil?

        TalkToYourApp::Current.principal = principal
        TalkToYourApp::Current.session_id = env["HTTP_MCP_SESSION_ID"]
        TalkToYourApp::Current.ip = ip
        env["ttya.principal"] = principal

        @app.call(env)
      ensure
        TalkToYourApp::Current.reset
      end

      private

      # Schemes the log line is allowed to name. Anything else is reported as
      # "other": the value comes from a client-controlled header and must not be
      # interpolated into a log line verbatim.
      KNOWN_SCHEMES = %w[bearer basic].freeze

      # Returns the principal, or nil after recording why the request was
      # rejected. Every nil path logs — an unlogged 401 is an undetectable
      # credential-guessing attempt.
      def authenticate(env, config, ip)
        header = env["HTTP_AUTHORIZATION"]
        return reject("missing_credentials", nil, ip) if header.nil? || header.empty?

        scheme, value = header.split(" ", 2)
        principal = case scheme&.downcase
                    when "bearer" then ApiKey.principal_for(value, config.api_keys)
                    when "basic"  then Basic.principal_for(value, config.basic_auth)
                    else return reject("unsupported_scheme", scheme, ip)
                    end
        principal || reject("invalid_credentials", scheme, ip)
      rescue StandardError => e
        # An operator-supplied basic_auth callable (or any validator) that
        # raises must surface as a controlled auth failure, not a 500 leaking a
        # stack trace to the client.
        reject("validator_error", scheme, ip, error_class: e.class.name)
      end

      # Logs the rejection and returns nil, so callers can `return reject(...)`.
      def reject(reason, scheme, ip, error_class: nil)
        normalized = scheme.to_s.downcase
        TalkToYourApp::AuditLogger.auth_failure(
          reason: reason,
          scheme: (KNOWN_SCHEMES.include?(normalized) ? normalized : (scheme.nil? ? nil : "other")),
          ip: ip,
          error_class: error_class,
        )
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
