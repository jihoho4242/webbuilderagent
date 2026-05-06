# frozen_string_literal: true

module Aiweb
  class LocalBackendApp
    LOCAL_BIND_HOSTS = %w[127.0.0.1 localhost ::1].freeze
    LOCAL_ORIGIN_PATTERN = /\Ahttps?:\/\/(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?\z/.freeze
    API_TOKEN_ENV = "AIWEB_DAEMON_TOKEN"
    APPROVAL_TOKEN_ENV = "AIWEB_DAEMON_APPROVAL_TOKEN"
    API_TOKEN_HEADER = "x-aiweb-token"
    APPROVAL_TOKEN_HEADER = "x-aiweb-approval-token"
    SECRET_VALUE_PATTERN = /
      (?:-----BEGIN\ [A-Z ]*PRIVATE\ KEY-----)|
      (?:\bAKIA[0-9A-Z]{16}\b)|
      (?:\b(?:ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{10,}\b)|
      (?:\bxox[baprs]-[A-Za-z0-9-]{10,}\b)|
      (?:\b(?:sk|rk)_(?:live|test|proj)_[A-Za-z0-9_-]{10,}\b)|
      (?:\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b)
    /x.freeze
    SAFE_METADATA_DENY_KEY_PATTERN = /\A(?:context|context_files|content|stdout|stderr|diff|patch)\z/i.freeze
    SAFE_ARTIFACT_BYTES = 256 * 1024
    SAFE_ARTIFACT_PATTERN = %r{\A\.ai-web/(?:
      design-brief\.md|
      design-reference-brief\.md|
      DESIGN\.md|
      component-map\.json|
      workbench/(?:index\.html|workbench\.json)|
      design-candidates/[A-Za-z0-9_.-]+\.(?:md|html)|
      qa/results/[A-Za-z0-9_.-]+\.json|
      qa/screenshots/metadata\.json|
      visual/[A-Za-z0-9_.-]+\.(?:json|md)|
      tasks/[A-Za-z0-9_.-]+\.md|
      runs/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.json
    )\z}x.freeze

    attr_reader :bridge, :api_token, :approval_token

    def initialize(bridge: CodexCliBridge.new, api_token: ENV[API_TOKEN_ENV], approval_token: ENV[APPROVAL_TOKEN_ENV])
      @bridge = bridge
      @api_token = token_or_generate(api_token)
      @approval_token = approval_token.to_s.strip.empty? ? @api_token : approval_token.to_s
      @command_mutex = Mutex.new
    end

    def self.plan(host:, port:, bridge: CodexCliBridge.new)
      host = normalize_host!(host)
      port = normalize_port!(port)
      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => "planned local backend daemon",
        "changed_files" => [],
        "blocking_issues" => [],
        "missing_artifacts" => [],
        "backend" => {
          "schema_version" => 1,
          "status" => "planned",
          "host" => host,
          "port" => port,
          "frontend_attached" => false,
          "routes" => routes,
          "bridge" => bridge.metadata,
          "auth" => {
            "api_token_env" => API_TOKEN_ENV,
            "api_token_header" => "X-Aiweb-Token",
            "approval_token_env" => APPROVAL_TOKEN_ENV,
            "approval_token_header" => "X-Aiweb-Approval-Token",
            "api_token_configured" => !ENV[API_TOKEN_ENV].to_s.empty?,
            "approval_token_configured" => !ENV[APPROVAL_TOKEN_ENV].to_s.empty?
          },
          "guardrails" => [
            "bind only to localhost-class hosts for local-first use",
            "reject non-local browser origins at the daemon boundary",
            "require a local API token for every /api/* request",
            "do not expose raw shell execution to frontend",
            "read and command endpoints return JSON envelopes only",
            "serialize backend command execution to avoid concurrent state mutation",
            "cap request bodies and concurrent connections for local daemon safety",
            "secrets, tokens, .env, and .env.* paths are filtered or blocked"
          ]
        },
        "next_action" => "start aiweb daemon, then connect the future frontend workbench to these local JSON endpoints"
      }
    end

    def self.normalize_host!(host)
      value = host.to_s.strip.empty? ? "127.0.0.1" : host.to_s.strip
      unless LOCAL_BIND_HOSTS.include?(value)
        raise UserError.new("daemon host must be local-only: #{LOCAL_BIND_HOSTS.join(", ")}", 5)
      end

      value
    end

    def self.normalize_port!(port)
      value = Integer(port)
      raise UserError.new("daemon port must be between 0 and 65535", 1) unless value.between?(0, 65_535)

      value
    end

    def self.allowed_origin?(origin)
      value = origin.to_s.strip
      return true if value.empty?

      value.match?(LOCAL_ORIGIN_PATTERN)
    end

    def self.routes
      [
        "GET /health",
        "GET /api/engine",
        "GET /api/project/status?path=PROJECT_PATH",
        "GET /api/project/workbench?path=PROJECT_PATH",
        "GET /api/project/runs?path=PROJECT_PATH",
        "GET /api/project/artifact?path=PROJECT_PATH&artifact=ARTIFACT_PATH",
        "POST /api/project/command",
        "POST /api/codex/agent-run"
      ]
    end

    def call(method, target, headers = {}, body = "")
      headers = normalize_headers(headers)
      return json(403, error_payload("origin is not allowed", 5)) unless self.class.allowed_origin?(headers["origin"])

      path, query = split_target(target)
      return json(204, {}) if method == "OPTIONS"
      validate_api_token!(headers) if path.start_with?("/api/")
      case [method, path]
      when ["GET", "/health"]
        json(200, health_payload)
      when ["GET", "/api/engine"]
        json(200, engine_payload)
      when ["GET", "/api/project/status"]
        json(200, bridge_run(project_path: required_project_path!(query["path"]), command: "status"))
      when ["GET", "/api/project/workbench"]
        json(200, bridge_run(project_path: required_project_path!(query["path"]), command: "workbench", args: [], dry_run: true))
      when ["GET", "/api/project/runs"]
        json(200, runs_payload(query.fetch("path", "")))
      when ["GET", "/api/project/artifact"]
        json(200, artifact_payload(query.fetch("path", ""), query["artifact"] || query["file"] || query["artifact_path"]))
      when ["POST", "/api/project/command"]
        json(200, command_payload(parse_body(body), headers))
      when ["POST", "/api/codex/agent-run"]
        json(200, codex_agent_run_payload(parse_body(body), headers))
      else
        json(404, error_payload("route not found: #{method} #{path}", 404))
      end
    rescue UserError => e
      json(e.exit_code == 5 ? 403 : 400, error_payload(e.message, e.exit_code))
    rescue JSON::ParserError => e
      json(400, error_payload("invalid JSON body: #{e.message}", 1))
    rescue StandardError => e
      json(500, error_payload("#{e.class}: #{e.message}", 10))
    end

    private

    def json(status, payload)
      [status, payload]
    end

    def normalize_headers(headers)
      headers.to_h.each_with_object({}) do |(key, value), memo|
        memo[key.to_s.downcase] = value
      end
    end

    def token_or_generate(value)
      token = value.to_s.strip
      token.empty? ? SecureRandom.hex(24) : token
    end

    def health_payload
      {
        "schema_version" => 1,
        "status" => "ok",
        "service" => "aiweb-local-backend",
        "frontend_attached" => false,
        "engine" => bridge.metadata
      }
    end

    def engine_payload
      {
        "schema_version" => 1,
        "status" => "ready",
        "engine" => bridge.metadata,
        "routes" => self.class.routes
      }
    end

    def command_payload(payload, headers = {})
      approved = truthy?(payload["approved"])
      validate_approval!(approved, headers)
      bridge_run(
        project_path: required_project_path!(payload["path"]),
        command: payload.fetch("command", ""),
        args: payload["args"] || [],
        dry_run: truthy?(payload["dry_run"]),
        approved: approved
      )
    end

    def codex_agent_run_payload(payload, headers = {})
      approved = truthy?(payload["approved"])
      validate_approval!(approved, headers)
      @command_mutex.synchronize do
        bridge.agent_run(
          project_path: required_project_path!(payload["path"]),
          task: payload["task"] || "latest",
          dry_run: payload.key?("dry_run") ? truthy?(payload["dry_run"]) : true,
          approved: approved
        ).tap { |result| result["bridge"]["serialized_execution"] = true if result["bridge"].is_a?(Hash) }
      end
    end

    def validate_approval!(approved, headers)
      return unless approved

      supplied = headers[APPROVAL_TOKEN_HEADER].to_s
      supplied = headers[API_TOKEN_HEADER].to_s if supplied.empty? && approval_token == api_token
      if supplied.empty? || !secure_token_equal?(supplied, approval_token)
        raise UserError.new("approval token required for approved backend execution", 5)
      end
    end

    def validate_api_token!(headers)
      supplied = headers[API_TOKEN_HEADER].to_s
      if supplied.empty? || !secure_token_equal?(supplied, api_token)
        raise UserError.new("API token required for backend API requests", 5)
      end
    end

    def secure_token_equal?(left, right)
      return false unless left.bytesize == right.bytesize

      diff = 0
      left.bytes.zip(right.bytes) { |a, b| diff |= a ^ b }
      diff.zero?
    end

    def bridge_run(**kwargs)
      @command_mutex.synchronize do
        bridge.run(**kwargs).tap { |result| result["bridge"]["serialized_execution"] = true if result["bridge"].is_a?(Hash) }
      end
    end

    def runs_payload(path)
      root = safe_project_path(path)
      pattern = File.join(root, ".ai-web", "runs", "*", "*.json")
      runs = Dir.glob(pattern).sort.last(30).map do |file|
        safe_json_summary(root, file)
      end.compact
      {
        "schema_version" => 1,
        "status" => "ready",
        "project_path" => root,
        "runs" => runs
      }
    end

    def artifact_payload(path, artifact)
      root = safe_project_path(path)
      relative = safe_artifact_path!(root, artifact)
      full = File.join(root, relative)
      raise UserError.new("artifact does not exist: #{relative}", 1) unless File.file?(full)
      safe_artifact_realpath!(root, full, relative)

      size = File.size(full)
      raise UserError.new("artifact is too large for safe read: #{relative}", 5) if size > SAFE_ARTIFACT_BYTES

      raw = File.read(full)
      redacted = redact_text(raw)
      parsed = safe_artifact_json(relative, raw)
      content = artifact_media_type(relative) == "application/json" && parsed ? JSON.pretty_generate(parsed) : redacted
      {
        "schema_version" => 1,
        "status" => "ready",
        "project_path" => root,
        "artifact" => {
          "path" => relative,
          "size_bytes" => size,
          "sha256" => Digest::SHA256.file(full).hexdigest,
          "media_type" => artifact_media_type(relative),
          "redacted" => redacted != raw || content != raw,
          "content" => content,
          "json" => parsed
        }.compact
      }
    end

    def safe_artifact_path!(root, artifact)
      text = artifact.to_s.strip
      raise UserError.new("artifact path is required", 1) if text.empty?
      raise UserError.new("artifact path must be relative", 5) if text.start_with?("/") || text.match?(/\A[a-z][a-z0-9+.-]*:\/\//i)
      raise UserError.new("unsafe artifact path blocked: null bytes are not allowed", 5) if text.include?("\x00")
      raise UserError.new("unsafe artifact path blocked: .env/.env.* paths are not allowed", 5) if unsafe_env_path?(text)

      normalized = text.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
      parts = normalized.split("/")
      if normalized.empty? || parts.any? { |part| part.empty? || part == ".." }
        raise UserError.new("unsafe artifact path blocked: path traversal is not allowed", 5)
      end
      unless normalized.match?(SAFE_ARTIFACT_PATTERN)
        raise UserError.new("artifact path is not on the safe read allowlist: #{normalized}", 5)
      end

      full = File.expand_path(normalized, root)
      aiweb_root = File.expand_path(File.join(root, ".ai-web"))
      unless full == aiweb_root || full.start_with?("#{aiweb_root}#{File::SEPARATOR}")
        raise UserError.new("unsafe artifact path blocked: artifact must stay under .ai-web", 5)
      end

      normalized
    end

    def safe_artifact_realpath!(root, full, relative)
      raise UserError.new("artifact symlinks are not readable: #{relative}", 5) if File.lstat(full).symlink?

      real = File.realpath(full)
      aiweb_root = File.realpath(File.join(root, ".ai-web"))
      unless real.start_with?("#{aiweb_root}#{File::SEPARATOR}")
        raise UserError.new("unsafe artifact path blocked: artifact must stay under .ai-web", 5)
      end

      true
    rescue Errno::ENOENT
      raise UserError.new("artifact does not exist: #{relative}", 1)
    end

    def artifact_media_type(path)
      case File.extname(path).downcase
      when ".json" then "application/json"
      when ".html" then "text/html"
      when ".md" then "text/markdown"
      when ".yml", ".yaml" then "application/yaml"
      else "text/plain"
      end
    end

    def safe_artifact_json(path, content)
      return nil unless File.extname(path).downcase == ".json"

      safe_metadata(JSON.parse(content))
    rescue JSON::ParserError
      nil
    end

    def redact_text(text)
      text.to_s.gsub(SECRET_VALUE_PATTERN, "[redacted]").lines.map do |line|
        unsafe_env_path?(line) ? "[excluded unsafe .env reference]\n" : line
      end.join
    end

    def safe_json_summary(root, file)
      relative = file.sub(%r{\A#{Regexp.escape(root)}/?}, "")
      return nil if unsafe_env_path?(relative)

      data = JSON.parse(File.read(file))
      safe_metadata(data).merge("path" => relative, "size_bytes" => File.size(file))
    rescue JSON::ParserError, SystemCallError
      { "path" => relative, "status" => "unreadable" }
    end

    def safe_metadata(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), memo|
          key = key.to_s
          next if key.match?(SAFE_METADATA_DENY_KEY_PATTERN)
          next if key.match?(/secret|token|password|api[_-]?key|credential/i)
          next if unsafe_env_path?(item.to_s)

          memo[key] = safe_metadata(item)
        end
      when Array
        value.first(20).map { |item| safe_metadata(item) }
      when String
        return "[redacted]" if secret_value?(value)
        unsafe_env_path?(value) ? "[excluded]" : value[0, 300]
      else
        value
      end
    end

    def secret_value?(value)
      value.to_s.match?(SECRET_VALUE_PATTERN)
    end

    def safe_project_path(value)
      text = required_project_path!(value)
      raise UserError.new("unsafe project path blocked: .env/.env.* paths are not allowed", 5) if unsafe_env_path?(text)

      File.expand_path(text)
    end

    def required_project_path!(value)
      text = value.to_s.strip
      raise UserError.new("project path is required", 1) if text.empty?

      text
    end

    def unsafe_env_path?(path)
      value = path.to_s
      parts = value.split(/[\\\/]+/)
      parts.any? { |part| part == ".env" || part.start_with?(".env.") }
    end

    def parse_body(body)
      text = body.to_s.strip
      return {} if text.empty?

      parsed = JSON.parse(text)
      raise UserError.new("JSON body must be an object", 1) unless parsed.is_a?(Hash)

      parsed
    end

    def split_target(target)
      uri = URI.parse(target.to_s)
      path = uri.path.to_s.empty? ? "/" : uri.path
      query = URI.decode_www_form(uri.query.to_s).each_with_object({}) { |(key, value), memo| memo[key] = value }
      [path, query]
    rescue URI::InvalidURIError
      [target.to_s.split("?", 2).first, {}]
    end

    def truthy?(value)
      value == true || value.to_s == "true" || value.to_s == "1"
    end

    def error_payload(message, code)
      {
        "schema_version" => 1,
        "status" => "error",
        "error" => message,
        "exit_code" => code,
        "blocking_issues" => [message]
      }
    end
  end
end
