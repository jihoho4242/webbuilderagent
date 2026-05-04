# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"

require_relative "support/fake_mcp_http_server"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
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

  def test_redact_removes_bearer_and_url_tokens
    text = "Authorization: Bearer abc123 https://x.test/image.png?token=abc123&safe=1"

    redacted = Aiweb::LazywebClient.redact(text, "abc123")

    refute_includes redacted, "abc123"
    assert_includes redacted, "[REDACTED]"
  end
end
