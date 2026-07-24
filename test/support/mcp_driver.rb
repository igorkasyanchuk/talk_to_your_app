# frozen_string_literal: true

require "rack/mock"
require "json"

module TalkToYourApp
  # Drives the mounted MCP Rack app over HTTP the way a real client would:
  # `initialize` to obtain a session id, then `tools/list` / `tools/call` with
  # the session and protocol-version headers on every request. Shared by the
  # integration tests.
  class McpDriver
    PROTOCOL_VERSION = "2025-11-25"

    def initialize(app, auth:)
      @mock = Rack::MockRequest.new(app)
      @auth = auth
      @session_id = nil
    end

    attr_reader :session_id

    # Performs the initialize handshake and stores the session id. Returns the
    # raw Rack::MockResponse so auth-failure cases can assert on status.
    def initialize_session(extra_headers = {})
      response = post(
        { jsonrpc: "2.0", id: 1, method: "initialize", params: {
          protocolVersion: PROTOCOL_VERSION, capabilities: {}, clientInfo: { name: "test", version: "1" }
        } },
        extra_headers,
        include_session: false,
      )
      @session_id = response.headers["Mcp-Session-Id"]
      response
    end

    def list_tools
      json_rpc(2, "tools/list")
    end

    def call_tool(name, arguments = {})
      json_rpc(3, "tools/call", { name: name, arguments: arguments })
    end

    # Returns the parsed JSON-RPC result hash for a tools/call.
    def call_tool_result(name, arguments = {})
      JSON.parse(call_tool(name, arguments).body)
    end

    private

    def json_rpc(id, method, params = nil)
      body = { jsonrpc: "2.0", id: id, method: method }
      body[:params] = params if params
      post(body, {}, include_session: true)
    end

    def post(body, extra_headers, include_session:)
      headers = {
        "CONTENT_TYPE" => "application/json",
        "HTTP_ACCEPT" => "application/json",
      }
      headers["HTTP_AUTHORIZATION"] = @auth if @auth
      if include_session
        headers["HTTP_MCP_SESSION_ID"] = @session_id if @session_id
        headers["HTTP_MCP_PROTOCOL_VERSION"] = PROTOCOL_VERSION
      end
      headers.merge!(extra_headers)
      @mock.post("/mcp", input: JSON.dump(body), **headers)
    end
  end
end
