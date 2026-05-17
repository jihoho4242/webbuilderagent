# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "time"
require "timeout"
require "uri"

module Aiweb
  class LazywebClient
    DEFAULT_ENDPOINT = "https://www.lazyweb.com/mcp".freeze
    TOKEN_SOURCES = ["LAZYWEB_MCP_TOKEN", "~/.lazyweb/lazyweb_mcp_token", "~/.codex/lazyweb_mcp_token"].freeze
    REDACTED = "[REDACTED]".freeze

    class Error < StandardError; end
    class ConfigurationError < Error; end
    class ProtocolError < Error; end

    attr_reader :endpoint, :timeout_seconds, :audit_events
    attr_writer :audit_sink

    def initialize(endpoint: DEFAULT_ENDPOINT, token: nil, timeout_seconds: 45, token_sources: TOKEN_SOURCES, audit_sink: nil)
      @endpoint = endpoint.to_s
      @timeout_seconds = Integer(timeout_seconds)
      @token = present(token) || resolve_token(token_sources)
      @audit_sink = audit_sink
      @audit_events = []
      raise ArgumentError, "timeout_seconds must be positive" unless @timeout_seconds.positive?
      raise ArgumentError, "endpoint is required" if @endpoint.strip.empty?
    end

    def configured?
      !@token.to_s.empty?
    end

    def health
      require_configured!
      call_tool("lazyweb_health", {})
    end

    def search(query:, limit: 10, category: nil, company: nil, platform: "all", max_per_company: 1)
      require_configured!
      normalized_limit = positive_integer(limit, "limit")
      arguments = {
        "query" => query.to_s,
        "limit" => normalized_limit,
        "platform" => platform.to_s.empty? ? "all" : platform.to_s
      }
      arguments["category"] = category.to_s unless category.to_s.empty?
      arguments["company"] = company.to_s unless company.to_s.empty?

      response = call_tool("lazyweb_search", arguments)
      enforce_limit(dedupe_results(extract_results(response), max_per_company: max_per_company), normalized_limit)
    end

    def self.redact(value, token = nil)
      redacted = value.to_s.dup
      [token, ENV["LAZYWEB_MCP_TOKEN"]].compact.map(&:to_s).reject(&:empty?).uniq.each do |secret|
      redacted.gsub!(secret, REDACTED)
      end
      redacted.gsub!(%r{((?:https?|mcp)://)([^@\s/]+)@}i, "\\1#{REDACTED}@")
      redacted.gsub!(/(Authorization:\s*Bearer\s+)[^\s]+/i, "\\1#{REDACTED}")
      redacted.gsub!(/([?&](?:token|access_token|api[_-]?key|key|secret|password|credential|auth|authorization|signature|X-Amz-Signature)=)[^&\s]+/i, "\\1#{REDACTED}")
      redacted
    end

    private

    def require_configured!
      raise ConfigurationError, "Lazyweb token is not configured" unless configured?
    end

    def call_tool(name, arguments)
      initialize_session!
      rpc("tools/call", { "name" => name, "arguments" => arguments })
    rescue Error
      raise
    rescue StandardError => e
      raise ProtocolError, self.class.redact("#{e.class}: #{e.message}", @token)
    end

    def initialize_session!
      return if @initialized

      rpc(
        "initialize",
        {
          "protocolVersion" => "2024-11-05",
          "capabilities" => {},
          "clientInfo" => { "name" => "aiweb", "version" => "0.1.0" }
        }
      )
      begin
        rpc("notifications/initialized", {}, notification: true)
      rescue ProtocolError
        # Some Streamable HTTP MCP servers do not return a response body for notifications.
      end
      @initialized = true
    end

    def rpc(method, params, notification: false)
      payload = {
        "jsonrpc" => "2.0",
        "method" => method,
        "params" => params
      }
      payload["id"] = SecureRandom.uuid unless notification
      parsed = post_json(payload)
      return {} if notification && parsed.nil?
      raise ProtocolError, "MCP response was empty for #{method}" if parsed.nil?
      raise ProtocolError, self.class.redact(parsed["error"].inspect, @token) if parsed.is_a?(Hash) && parsed.key?("error")

      parsed.is_a?(Hash) && parsed.key?("result") ? parsed["result"] : parsed
    end

    def post_json(payload)
      uri = URI.parse(endpoint)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json, text/event-stream"
      request["Authorization"] = "Bearer #{@token}" if configured?
      request.body = JSON.generate(payload)

      audit = audit_event_base(payload, uri)
      emit_audit_event("tool.requested", audit.merge("message" => "requested Lazyweb MCP HTTP call"))
      emit_audit_event("policy.decision", audit.merge("message" => "Lazyweb MCP endpoint allowed by configured design-research adapter", "decision" => "allow"))
      emit_audit_event("tool.started", audit.merge("message" => "starting Lazyweb MCP HTTP call"))
      response = nil
      Timeout.timeout(timeout_seconds) do
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", read_timeout: timeout_seconds, open_timeout: timeout_seconds) do |http|
          response = http.request(request)
        end
      end
      unless response.is_a?(Net::HTTPSuccess)
        emit_lazyweb_terminal_failure(audit, "finished Lazyweb MCP HTTP call", "http_status" => response&.code.to_s)
        raise ProtocolError, self.class.redact("Lazyweb MCP HTTP #{response.code}: #{response.body}", @token)
      end

      parsed = parse_response_body(response.body)
      emit_audit_event("tool.finished", audit.merge("message" => "finished Lazyweb MCP HTTP call", "status" => "passed", "http_status" => response.code.to_s))
      parsed
    rescue JSON::ParserError => e
      emit_lazyweb_terminal_failure(audit, "failed to parse Lazyweb MCP HTTP response", "error_class" => e.class.name) if defined?(audit) && audit
      raise ProtocolError, self.class.redact("Lazyweb MCP returned invalid JSON: #{e.message}", @token)
    rescue Timeout::Error
      emit_lazyweb_terminal_failure(audit, "Lazyweb MCP request timed out", "error_class" => "Timeout::Error") if defined?(audit) && audit
      raise ProtocolError, "Lazyweb MCP request timed out after #{timeout_seconds}s"
    rescue StandardError => e
      emit_lazyweb_terminal_failure(audit, "failed Lazyweb MCP HTTP call", "error_class" => e.class.name) if defined?(audit) && audit
      raise
    end

    def audit_event_base(payload, uri)
      {
        "schema_version" => 1,
        "broker" => "aiweb.lazyweb.side_effect_broker",
        "scope" => "external_http.lazyweb_mcp",
        "target" => payload["method"].to_s,
        "tool" => "Net::HTTP",
        "endpoint" => self.class.redact(uri.to_s, @token),
        "host" => uri.hostname.to_s,
        "method" => "POST",
        "jsonrpc_method" => payload["method"].to_s,
        "request_id" => payload["id"].to_s.empty? ? "notification-#{SecureRandom.uuid}" : payload["id"].to_s,
        "timeout_seconds" => timeout_seconds,
        "requires_token" => true,
        "token_configured" => configured?
      }
    end

    def emit_audit_event(event, payload)
      record = payload.merge("event" => event, "created_at" => Time.now.utc.iso8601(6))
      @audit_events << record
      @audit_sink&.call(record)
      record
    end

    def emit_lazyweb_terminal_failure(audit, message, extra = {})
      return if @audit_events.reverse.any? { |event| %w[tool.finished tool.failed tool.blocked].include?(event["event"]) && event["request_id"] == audit["request_id"] }

      emit_audit_event("tool.failed", audit.merge("message" => message, "status" => "failed").merge(extra))
    end

    def parse_response_body(body)
      text = body.to_s.strip
      return nil if text.empty?
      return JSON.parse(text) unless text.start_with?("event:", "data:")

      data_lines = text.each_line.map do |line|
        stripped = line.strip
        stripped.sub(/^data:\s*/, "") if stripped.start_with?("data:")
      end.compact
      data = data_lines.reject { |line| line.empty? || line == "[DONE]" }.join("\n").strip
      data.empty? ? nil : JSON.parse(data)
    end

    def extract_results(response)
      payload = unwrap_content(response)
      case payload
      when Array then payload
      when Hash
        Array(payload["results"] || payload["screenshots"] || payload["items"] || payload.dig("data", "results"))
      else
        []
      end
    end

    def unwrap_content(response)
      return response unless response.is_a?(Hash)

      content = response["content"]
      return response unless content.is_a?(Array)

      text = content.map do |item|
        next unless item.is_a?(Hash)
        item["text"] if item["type"].to_s == "text" || item.key?("text")
      end.compact.join("\n").strip
      return response if text.empty?

      JSON.parse(text)
    rescue JSON::ParserError
      response
    end

    def dedupe_results(results, max_per_company:)
      max_for_company = positive_integer(max_per_company, "max_per_company")
      seen_ids = {}
      company_counts = Hash.new(0)
      results.each_with_object([]) do |result, memo|
        item = stringify_keys(result)
        key = present(item["screenshot_id"]) ||
              present(item["screenshotId"]) ||
              present(item["id"]) ||
              present(item["page_url"]) ||
              present(item["pageUrl"]) ||
              present(item["url"]) ||
              present(item["image_url"]) ||
              present(item["imageUrl"]) ||
              present([item["siteId"], item["path"]].compact.join(":")) ||
              item.inspect
        company = (item["company"] || item["company_name"] || item["companyName"] || item["brand"]).to_s.downcase.strip
        next if seen_ids[key]
        next if !company.empty? && company_counts[company] >= max_for_company

        seen_ids[key] = true
        company_counts[company] += 1 unless company.empty?
        memo << item
      end
    end

    def enforce_limit(results, limit)
      results.first(limit)
    end

    def stringify_keys(value)
      return value.each_with_object({}) { |(key, val), memo| memo[key.to_s] = val } if value.is_a?(Hash)

      { "value" => value }
    end

    def positive_integer(value, name)
      integer = Integer(value)
      raise ArgumentError, "#{name} must be positive" unless integer.positive?

      integer
    end

    def resolve_token(sources)
      Array(sources).each do |source|
        source = source.to_s
        if source !~ %r{[\\/]}
          value = present(ENV[source])
          return value if value
          next
        end

        path = File.expand_path(source)
        next unless File.file?(path)

        value = present(File.read(path))
        return value if value
      rescue SystemCallError
        next
      end
      nil
    end

    def present(value)
      string = value.to_s.strip
      string.empty? ? nil : string
    end
  end
end
