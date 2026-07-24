# frozen_string_literal: true

require "json"
require "time"
require "active_support"
require "active_support/notifications"

module TalkToYourApp
  # Emits exactly one structured log line per tool invocation. Wrapping happens
  # at the tool dispatch boundary, where the principal, params, plugin, tool, and
  # timing are all in scope. Defaults to the configured logger (Rails.logger) at
  # the plugin's level (default INFO). Re-raises on failure so the SDK still
  # surfaces a tool error to the client.
  module AuditLogger
    module_function

    # Runs the block, times it, and logs the outcome. Returns the block's value.
    def around(tool_class:, plugin_name:, log_level:, params:)
      started = monotonic
      error_class = nil
      outcome = "success"
      begin
        result = yield
        outcome = "error" if result.is_a?(MCP::Tool::Response) && result.error?
        result
      rescue StandardError => e
        outcome = "error"
        error_class = e.class.name
        raise
      ensure
        # A logging failure must never replace the tool's result or its
        # exception (an exception raised in `ensure` would do exactly that), so
        # emit defensively and swallow any logger error to $stderr.
        begin
          emit(
            plugin_name: plugin_name,
            tool_class: tool_class,
            params: params,
            outcome: outcome,
            error_class: error_class,
            duration_ms: ((monotonic - started) * 1000).round(2),
            log_level: log_level,
          )
        rescue StandardError => e
          warn("talk_to_your_app: audit logging failed: #{e.class}: #{e.message}")
        end
      end
    end

    # One line per rejected request, at WARN, plus a structured
    # `talk_to_your_app.auth_failure` event. Without this a 401 leaves no trace
    # at all, so credential guessing and endpoint scanning are undetectable —
    # every successful call is logged but every failed one was invisible. The
    # level is fixed at :warn rather than following `log_level`: an auth failure
    # is not routine traffic. Carries no credential material — only a coarse
    # reason, the scheme, and the client IP.
    def auth_failure(reason:, scheme: nil, ip: nil, error_class: nil)
      fields = { ts: Time.now.utc.iso8601(3), event: "auth_failure", reason: reason, scheme: scheme, ip: ip }
      fields[:error_class] = error_class if error_class

      # Log line first: a subscriber that raises would otherwise suppress the
      # only record of a rejected request.
      logger.warn { format_line(fields) }
      ActiveSupport::Notifications.instrument("talk_to_your_app.auth_failure", fields)
    rescue StandardError => e
      # Same contract as the tool-call path: a logging failure must not turn a
      # 401 into a 500.
      warn("talk_to_your_app: auth failure logging failed: #{e.class}: #{e.message}")
    end

    def emit(plugin_name:, tool_class:, params:, outcome:, error_class:, duration_ms:, log_level:)
      fields = build_fields(plugin_name, tool_class, params, outcome, error_class, duration_ms)

      # Structured event for anyone who wants to persist a full audit trail
      # (e.g. an Activity table with IP + principal). Subscribers receive the
      # `fields` hash as the payload. See the README "Custom audit logging".
      ActiveSupport::Notifications.instrument("talk_to_your_app.tool_call", fields)

      level = (log_level || TalkToYourApp.configuration.log_level || :info)
      logger.public_send(level) { format_line(fields) }
    end

    # The structured audit payload for one tool invocation.
    def build_fields(plugin_name, tool_class, params, outcome, error_class, duration_ms)
      fields = {
        ts: Time.now.utc.iso8601(3),
        principal: TalkToYourApp::Current.principal,
        session_id: TalkToYourApp::Current.session_id,
        ip: TalkToYourApp::Current.ip,
        plugin: plugin_name,
        tool: tool_class.tool_name,
        params: redact(tool_class, params),
        outcome: outcome,
        duration_ms: duration_ms,
      }
      fields[:error_class] = error_class if error_class
      fields
    end

    def format_line(fields)
      "talk_to_your_app " + fields.map { |k, v| "#{k}=#{format_value(v)}" }.join(" ")
    end

    # Replaces any argument declared with `redact: true` with [REDACTED].
    def redact(tool_class, params)
      params.each_with_object({}) do |(key, value), acc|
        opts = tool_class.arguments[key.to_sym]
        acc[key] = opts && opts[:redact] ? "[REDACTED]" : value
      end
    end

    def format_value(value)
      case value
      when Hash, Array then value.to_json
      when nil then "-"
      else value.to_s
      end
    end

    def logger
      TalkToYourApp.configuration.logger || default_logger
    end

    def default_logger
      if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
        Rails.logger
      else
        require "logger"
        @fallback_logger ||= Logger.new($stdout)
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
