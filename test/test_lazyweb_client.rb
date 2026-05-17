# frozen_string_literal: true

require "json"
require "tmpdir"

require_relative "support/test_helper"
require_relative "support/fake_mcp_http_server"

require "aiweb/lazyweb_client"

class LazywebClientTest < Minitest::Test
  def with_fake_mcp_server(responses)
    FakeMcpHttpServer.open(responses) do |endpoint, received|
      yield endpoint, received
    end
  end

  def test_configured_is_false_without_token
    client = Aiweb::LazywebClient.new(endpoint: "http://example.invalid/mcp", token_sources: [])

    refute client.configured?
  end

  def test_search_calls_mcp_and_enforces_limit_dedupe_and_company_cap
    responses = lambda do |payload|
      case payload.fetch("method")
      when "initialize"
        { "jsonrpc" => "2.0", "id" => payload.fetch("id"), "result" => { "capabilities" => {} } }
      when "notifications/initialized"
        { "jsonrpc" => "2.0", "result" => {} }
      when "tools/call"
        assert_equal "lazyweb_search", payload.dig("params", "name")
        {
          "jsonrpc" => "2.0",
          "id" => payload.fetch("id"),
          "result" => {
            "content" => [{ "type" => "text", "text" => JSON.generate("results" => [
              { "screenshot_id" => 1, "company" => "Acme", "vision_description" => "Hero CTA" },
              { "screenshot_id" => 1, "company" => "Acme", "vision_description" => "Duplicate" },
              { "screenshot_id" => 2, "company" => "Acme", "vision_description" => "Second Acme" },
              { "screenshot_id" => 3, "company" => "Beta", "vision_description" => "Pricing CTA" }
            ]) }]
          }
        }
      else
        flunk "unexpected MCP method #{payload.fetch("method")}"
      end
    end

    with_fake_mcp_server(responses) do |endpoint, received|
      client = Aiweb::LazywebClient.new(endpoint: endpoint, token: "secret-token", timeout_seconds: 5)
      results = client.search(query: "developer tools pricing", limit: 2, max_per_company: 1)

      assert_equal 2, results.length
      assert_equal [1, 3], results.map { |item| item.fetch("screenshot_id") }
      assert received.all? { |request| request.fetch("authorization") == "Bearer secret-token" }
    end
  end

  def test_search_emits_redacted_lazyweb_side_effect_broker_events
    responses = lambda do |payload|
      case payload.fetch("method")
      when "initialize"
        { "jsonrpc" => "2.0", "id" => payload.fetch("id"), "result" => { "capabilities" => {} } }
      when "notifications/initialized"
        { "jsonrpc" => "2.0", "result" => {} }
      when "tools/call"
        {
          "jsonrpc" => "2.0",
          "id" => payload.fetch("id"),
          "result" => { "content" => [{ "type" => "text", "text" => JSON.generate("results" => [{ "screenshot_id" => 1, "company" => "Acme" }]) }] }
        }
      else
        flunk "unexpected MCP method #{payload.fetch("method")}"
      end
    end

    with_fake_mcp_server(responses) do |endpoint, _received|
      events = []
      client = Aiweb::LazywebClient.new(endpoint: "#{endpoint}?token=secret-token", token: "secret-token", timeout_seconds: 5, audit_sink: ->(event) { events << event })

      client.search(query: "developer tools pricing", limit: 1)

      assert_operator events.length, :>=, 8
      assert_includes events.map { |event| event.fetch("event") }, "tool.requested"
      assert_includes events.map { |event| event.fetch("event") }, "policy.decision"
      assert_includes events.map { |event| event.fetch("event") }, "tool.started"
      assert_includes events.map { |event| event.fetch("event") }, "tool.finished"
      encoded = JSON.generate(events)
      refute_includes encoded, "secret-token"
      assert_includes encoded, "[REDACTED]"
      assert events.all? { |event| event.fetch("broker") == "aiweb.lazyweb.side_effect_broker" }
      assert events.all? { |event| event.fetch("scope") == "external_http.lazyweb_mcp" }
    end
  end

  def test_invalid_json_emits_only_failed_terminal_broker_event
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      client = server.accept
      request_line = client.gets
      while (line = client.gets)
        break if line.strip.empty?
      end
      raise "expected HTTP request" if request_line.to_s.empty?

      body = "{not json"
      client.write(
        "HTTP/1.1 200 OK\r\n" \
        "Content-Type: application/json\r\n" \
        "Content-Length: #{body.bytesize}\r\n" \
        "Connection: close\r\n" \
        "\r\n" \
        "#{body}"
      )
    ensure
      client&.close unless client&.closed?
    end
    begin
      endpoint = "http://127.0.0.1:#{server.addr[1]}/mcp"
      events = []
      client = Aiweb::LazywebClient.new(endpoint: endpoint, token: "secret-token", timeout_seconds: 5, audit_sink: ->(event) { events << event })

      error = assert_raises(Aiweb::LazywebClient::ProtocolError) do
        client.search(query: "developer tools pricing", limit: 1)
      end
      assert_match(/invalid JSON/i, error.message)
      terminal_events = events.select { |event| %w[tool.finished tool.failed tool.blocked].include?(event["event"]) }
      assert_equal 1, terminal_events.length
      assert_equal "tool.failed", terminal_events.first["event"]
      assert_equal "failed", terminal_events.first["status"]
      refute events.any? { |event| event["event"] == "tool.finished" && event["status"] == "passed" }
    ensure
      server.close unless server.closed?
      thread.join(1)
    end
  end

  def test_transport_failure_emits_terminal_failure_broker_event
    events = []
    original_start = Net::HTTP.method(:start)
    Net::HTTP.singleton_class.define_method(:start) do |*|
      raise IOError, "synthetic transport failure"
    end
    begin
      client = Aiweb::LazywebClient.new(endpoint: "https://lazyweb.test/mcp?api_key=secret-api-key", token: "secret-token", timeout_seconds: 1, audit_sink: ->(event) { events << event })

      assert_raises(Aiweb::LazywebClient::ProtocolError) do
        client.search(query: "developer tools pricing", limit: 1)
      end
      terminal_events = events.select { |event| %w[tool.finished tool.failed tool.blocked].include?(event["event"]) }
      assert_equal 1, terminal_events.length
      assert_equal "tool.failed", terminal_events.first["event"]
      assert_equal "failed", terminal_events.first["status"]
      assert_equal "IOError", terminal_events.first["error_class"]
      encoded = JSON.generate(events)
      refute_includes encoded, "secret-api-key"
    ensure
      Net::HTTP.singleton_class.define_method(:start, original_start)
    end
  end

  def test_search_applies_company_cap_to_lazyweb_camel_case_results
    responses = lambda do |payload|
      case payload.fetch("method")
      when "initialize"
        { "jsonrpc" => "2.0", "id" => payload.fetch("id"), "result" => { "capabilities" => {} } }
      when "notifications/initialized"
        { "jsonrpc" => "2.0", "result" => {} }
      when "tools/call"
        {
          "jsonrpc" => "2.0",
          "id" => payload.fetch("id"),
          "result" => {
            "content" => [{ "type" => "text", "text" => JSON.generate("results" => [
              { "siteId" => 1, "path" => "/pricing", "companyName" => "Acme", "imageUrl" => "https://lazyweb.test/1.png" },
              { "siteId" => 2, "path" => "/pricing", "companyName" => "Acme", "imageUrl" => "https://lazyweb.test/2.png" },
              { "siteId" => 3, "path" => "/pricing", "companyName" => "Beta", "imageUrl" => "https://lazyweb.test/3.png" }
            ]) }]
          }
        }
      else
        flunk "unexpected MCP method #{payload.fetch("method")}"
      end
    end

    with_fake_mcp_server(responses) do |endpoint, _received|
      client = Aiweb::LazywebClient.new(endpoint: endpoint, token: "secret-token", timeout_seconds: 5)
      results = client.search(query: "developer tools pricing", limit: 3, max_per_company: 1)

      assert_equal ["Acme", "Beta"], results.map { |item| item.fetch("companyName") }
    end
  end

  def test_redact_removes_bearer_url_tokens_and_userinfo
    text = "Authorization: Bearer abc123 https://user:pass@x.test/image.png?api_key=secret-api-key&token=abc123&secret=secret-value&safe=1 https://secret-userinfo@x.test/path"

    redacted = Aiweb::LazywebClient.redact(text, "abc123")

    refute_includes redacted, "abc123"
    refute_includes redacted, "secret-api-key"
    refute_includes redacted, "secret-value"
    refute_includes redacted, "user:pass"
    refute_includes redacted, "secret-userinfo"
    assert_includes redacted, "[REDACTED]"
  end
end
