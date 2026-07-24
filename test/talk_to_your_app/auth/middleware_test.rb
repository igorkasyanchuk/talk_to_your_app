# frozen_string_literal: true

require "test_helper"
require "base64"
require "support/array_logger"

class TalkToYourApp::Auth::MiddlewareTest < TalkToYourApp::TestCase
  def downstream
    lambda do |env|
      @principal = TalkToYourApp::Current.principal
      @env_principal = env["ttya.principal"]
      @session_id = TalkToYourApp::Current.session_id
      [200, { "Content-Type" => "text/plain" }, ["ok"]]
    end
  end

  def middleware
    TalkToYourApp::Auth::Middleware.new(downstream)
  end

  def env_for(headers = {})
    { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/mcp" }.merge(headers)
  end

  # Captures the audit logger so the auth-failure lines can be asserted on.
  def capturing_logger
    logger = TalkToYourApp::ArrayLogger.new
    TalkToYourApp.configure { |c| c.logger = logger }
    logger
  end

  def auth_failure_line(logger)
    logger.messages_at("WARN").find { |line| line.include?("event=auth_failure") }
  end

  def test_missing_authorization_returns_401
    TalkToYourApp.configure { |c| c.api_keys = { "k" => "sekret" } }
    status, headers, = middleware.call(env_for)
    assert_equal 401, status
    refute_match(/sekret/, headers.to_s)
    assert_equal "Bearer", headers["WWW-Authenticate"]
  end

  def test_www_authenticate_advertises_basic_when_only_basic_configured
    TalkToYourApp.configure { |c| c.basic_auth { |_u, _p| false } }
    _status, headers, = middleware.call(env_for)
    assert_equal "Basic", headers["WWW-Authenticate"]
  end

  def test_www_authenticate_advertises_both_schemes_when_both_configured
    TalkToYourApp.configure do |c|
      c.api_keys = { "k" => "sekret" }
      c.basic_auth { |_u, _p| false }
    end
    _status, headers, = middleware.call(env_for)
    assert_equal "Bearer, Basic", headers["WWW-Authenticate"]
  end

  def test_valid_bearer_sets_principal_and_forwards
    TalkToYourApp.configure { |c| c.api_keys = { "claude-desktop" => "sk-good" } }
    status, = middleware.call(env_for("HTTP_AUTHORIZATION" => "Bearer sk-good"))
    assert_equal 200, status
    assert_equal "claude-desktop", @principal
    assert_equal "claude-desktop", @env_principal
  end

  def test_wrong_bearer_returns_401
    TalkToYourApp.configure { |c| c.api_keys = { "claude-desktop" => "sk-good" } }
    status, = middleware.call(env_for("HTTP_AUTHORIZATION" => "Bearer sk-wrong"))
    assert_equal 401, status
  end

  def test_valid_basic_sets_username_principal
    TalkToYourApp.configure do |c|
      c.basic_auth { |user, pass| user == "alice" && pass == "secret" }
    end
    creds = Base64.strict_encode64("alice:secret")
    status, = middleware.call(env_for("HTTP_AUTHORIZATION" => "Basic #{creds}"))
    assert_equal 200, status
    assert_equal "alice", @principal
  end

  def test_invalid_basic_returns_401
    TalkToYourApp.configure { |c| c.basic_auth { |_u, _p| false } }
    creds = Base64.strict_encode64("alice:wrong")
    status, = middleware.call(env_for("HTTP_AUTHORIZATION" => "Basic #{creds}"))
    assert_equal 401, status
  end

  def test_session_id_header_is_captured
    TalkToYourApp.configure { |c| c.api_keys = { "k" => "sk-good" } }
    middleware.call(env_for(
      "HTTP_AUTHORIZATION" => "Bearer sk-good",
      "HTTP_MCP_SESSION_ID" => "sess-123",
    ))
    assert_equal "sess-123", @session_id
  end

  def test_constant_time_compare_rejects_length_mismatch
    refute TalkToYourApp::Auth::ApiKey.secure_compare("abc", "abcd")
    assert TalkToYourApp::Auth::ApiKey.secure_compare("abc", "abc")
  end

  def test_unrecognized_scheme_is_rejected
    TalkToYourApp.configure { |c| c.api_keys = { "k" => "sk-good" } }
    status, = middleware.call(env_for("HTTP_AUTHORIZATION" => "Token sk-good"))
    assert_equal 401, status
  end

  def test_current_principal_is_reset_after_rejected_request
    TalkToYourApp.configure { |c| c.api_keys = { "k" => "sk-good" } }
    middleware.call(env_for) # 401
    assert_nil TalkToYourApp::Current.principal
  end

  def test_raising_basic_auth_callable_yields_401_not_500
    TalkToYourApp.configure { |c| c.basic_auth { |_u, _p| raise "db down" } }
    creds = Base64.strict_encode64("alice:secret")
    _out, _err = capture_io do
      @status, = middleware.call(env_for("HTTP_AUTHORIZATION" => "Basic #{creds}"))
    end
    assert_equal 401, @status
  end

  # A Basic password may legitimately contain ":" — the credential is split on
  # the FIRST colon only, so the full password must reach the callable intact.
  # A regression to an unlimited split would silently truncate the password and
  # let a wrong-but-prefix-matching credential through (or reject a valid one).
  def test_basic_auth_password_may_contain_colons
    seen = nil
    TalkToYourApp.configure { |c| c.basic_auth { |u, p| seen = [u, p]; true } }
    creds = Base64.strict_encode64("alice:pa:ss:word")
    status, = middleware.call(env_for("HTTP_AUTHORIZATION" => "Basic #{creds}"))
    assert_equal 200, status
    assert_equal ["alice", "pa:ss:word"], seen
  end

  # --- Auth-failure logging -------------------------------------------------
  # A 401 that leaves no trace makes credential guessing and endpoint scanning
  # undetectable, so every rejection must produce exactly one WARN line naming
  # the reason and the client IP.

  def test_missing_credentials_are_logged_with_reason_and_ip
    logger = capturing_logger
    TalkToYourApp.configure { |c| c.api_keys = { "k" => "sekret" } }
    middleware.call(env_for("REMOTE_ADDR" => "203.0.113.4"))

    line = auth_failure_line(logger)
    refute_nil line, "a rejected request must emit an auth_failure line"
    assert_match(/reason=missing_credentials/, line)
    assert_match(/ip=203\.0\.113\.4/, line)
  end

  def test_wrong_bearer_is_logged_without_the_presented_token
    logger = capturing_logger
    TalkToYourApp.configure { |c| c.api_keys = { "claude-desktop" => "sk-good" } }
    middleware.call(env_for("HTTP_AUTHORIZATION" => "Bearer sk-wrong"))

    line = auth_failure_line(logger)
    assert_match(/reason=invalid_credentials/, line)
    assert_match(/scheme=bearer/, line)
    refute_match(/sk-wrong/, line, "the presented credential must never be logged")
    refute_match(/sk-good/, line, "the configured key must never be logged")
  end

  # The scheme comes from a client-controlled header, so an unknown one is
  # reported as "other" rather than interpolated into the log line verbatim.
  def test_unsupported_scheme_is_logged_without_echoing_the_client_value
    logger = capturing_logger
    TalkToYourApp.configure { |c| c.api_keys = { "k" => "sk-good" } }
    middleware.call(env_for("HTTP_AUTHORIZATION" => "Token\nevent=auth_success"))

    line = auth_failure_line(logger)
    assert_match(/reason=unsupported_scheme/, line)
    assert_match(/scheme=other/, line)
    refute_match(/auth_success/, line, "a client value must not be able to forge log fields")
  end

  def test_raising_validator_is_logged_as_validator_error
    logger = capturing_logger
    TalkToYourApp.configure { |c| c.basic_auth { |_u, _p| raise "db down" } }
    creds = Base64.strict_encode64("alice:secret")
    middleware.call(env_for("HTTP_AUTHORIZATION" => "Basic #{creds}"))

    line = auth_failure_line(logger)
    assert_match(/reason=validator_error/, line)
    assert_match(/error_class=RuntimeError/, line)
  end

  def test_authenticated_request_logs_no_auth_failure
    logger = capturing_logger
    TalkToYourApp.configure { |c| c.api_keys = { "claude-desktop" => "sk-good" } }
    middleware.call(env_for("HTTP_AUTHORIZATION" => "Bearer sk-good"))

    assert_nil auth_failure_line(logger)
  end

  def test_auth_failure_emits_a_structured_event
    payloads = []
    subscriber = ActiveSupport::Notifications.subscribe("talk_to_your_app.auth_failure") do |*args|
      payloads << ActiveSupport::Notifications::Event.new(*args).payload
    end
    TalkToYourApp.configure { |c| c.api_keys = { "k" => "sekret" } }
    middleware.call(env_for("REMOTE_ADDR" => "198.51.100.7"))

    assert_equal 1, payloads.size
    assert_equal "missing_credentials", payloads.first[:reason]
    assert_equal "198.51.100.7", payloads.first[:ip]
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # Multiple API keys (key rotation) each map to their own principal name, so a
  # request is attributed to the specific key it presented — critical for audit
  # and for `config.authorize` decisions.
  def test_api_keys_support_rotation_and_map_to_the_matching_principal
    TalkToYourApp.configure { |c| c.api_keys = { "old-client" => "sk-old", "new-client" => "sk-new" } }
    middleware.call(env_for("HTTP_AUTHORIZATION" => "Bearer sk-old"))
    assert_equal "old-client", @principal
    middleware.call(env_for("HTTP_AUTHORIZATION" => "Bearer sk-new"))
    assert_equal "new-client", @principal
  end
end
