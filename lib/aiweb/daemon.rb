# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "socket"
require "thread"
require "timeout"
require "uri"

module Aiweb
  class CodexCliBridge
    DEFAULT_ALLOWED_COMMANDS = %w[
      status runtime-plan scaffold-status intent init start interview run design-brief design-research
      design-system design-prompt design select-design scaffold setup build preview qa-playwright
      qa-screenshot qa-a11y qa-lighthouse visual-critique repair visual-polish workbench
      component-map visual-edit agent-run github-sync deploy-plan deploy qa-checklist qa-report
      next-task advance rollback resolve-blocker snapshot supabase-secret-qa
    ].freeze

    UNSAFE_ARG_PATTERN = /(?:\A|=|[\x00\/\\])\.env(?:\.|\z|[\/\\])/.freeze
    BACKEND_CONTROLLED_ARG_PATTERN = /\A--(?:path(?:=|\z)|json\z|dry-run\z|approved\z)/.freeze
    COMMAND_TIMEOUT_SECONDS = 180

    attr_reader :engine_root, :aiweb_bin, :allowed_commands, :command_timeout

    def initialize(engine_root: File.expand_path("../..", __dir__), allowed_commands: DEFAULT_ALLOWED_COMMANDS, command_timeout: COMMAND_TIMEOUT_SECONDS)
      @engine_root = File.expand_path(engine_root)
      @aiweb_bin = File.join(@engine_root, "bin", "aiweb")
      @allowed_commands = allowed_commands.map(&:to_s).freeze
      @command_timeout = Float(command_timeout)
    end

    def metadata
      {
        "schema_version" => 1,
        "engine_root" => engine_root,
        "aiweb_bin" => aiweb_bin,
        "ruby" => RbConfig.ruby,
        "command_timeout_seconds" => command_timeout,
        "allowed_commands" => allowed_commands,
        "codex_agent_command" => "agent-run",
        "guardrails" => guardrails
      }
    end

    def guardrails
      [
        "frontend sends structured JSON only; no raw shell commands",
        "every /api/* request requires X-Aiweb-Token",
        "backend invokes bin/aiweb by absolute path through Ruby argv, never through shell interpolation",
        "project path is required and --path is controlled by backend",
        "frontend-supplied backend flags (--path, --json, --dry-run, --approved) are rejected inside command args",
        ".env and .env.* path segments are rejected before bridge execution",
        "bridge commands time out instead of blocking the backend indefinitely",
        "approved agent-run/setup execution requires a matching X-Aiweb-Approval-Token header or the API token when no separate approval token is configured",
        "agent-run maps to Codex CLI only through aiweb agent-run --agent codex and keeps approval semantics",
        "deploy is exposed as dry-run planning only through this bridge"
      ]
    end

    def run(project_path:, command:, args: [], dry_run: false, approved: false)
      project_path = safe_project_path!(project_path)
      command = command.to_s.strip
      raise UserError.new("bridge command is required", 1) if command.empty?
      raise UserError.new("bridge command #{command.inspect} is not allowed", 5) unless allowed_commands.include?(command)

      args = normalize_args(args)
      validate_args!(args)
      raise UserError.new("bridge deploy is dry-run only", 5) if command == "deploy" && !dry_run

      argv = [RbConfig.ruby, aiweb_bin, "--path", project_path, command]
      argv.concat(args)
      argv << "--approved" if %w[agent-run setup].include?(command) && approved
      argv << "--dry-run" if dry_run
      argv << "--json"

      stdout, stderr, status = capture_argv(argv)
      parsed = parse_json(stdout)
      {
        "schema_version" => 1,
        "status" => status.success? ? "passed" : "failed",
        "exit_code" => status.exitstatus,
        "bridge" => metadata.merge(
          "project_path" => project_path,
          "command" => command,
          "args" => args,
          "dry_run" => dry_run,
          "approved" => approved,
          "argv" => argv
        ),
        "stdout_json" => parsed,
        "stdout" => parsed ? nil : stdout.to_s[0, 20_000],
        "stderr" => stderr.to_s[0, 20_000]
      }
    end

    def agent_run(project_path:, task: "latest", dry_run: true, approved: false)
      run(
        project_path: project_path,
        command: "agent-run",
        args: ["--task", task.to_s, "--agent", "codex"],
        dry_run: dry_run,
        approved: approved
      )
    end

    private

    def parse_json(stdout)
      JSON.parse(stdout)
    rescue JSON::ParserError
      nil
    end

    def capture_argv(argv)
      stdout_data = +""
      stderr_data = +""
      status = nil
      timed_out = false

      Open3.popen3(*argv, pgroup: true) do |stdin, stdout, stderr, wait_thr|
        stdin.close
        stdout_reader = Thread.new { read_stream(stdout) }
        stderr_reader = Thread.new { read_stream(stderr) }

        unless wait_thr.join(command_timeout)
          timed_out = true
          terminate_process_tree(wait_thr.pid)
          close_stream(stdout)
          close_stream(stderr)
        end

        unless stdout_reader.join(1) && stderr_reader.join(1)
          terminate_process_tree(wait_thr.pid)
          close_stream(stdout)
          close_stream(stderr)
        end

        stdout_data = reader_value(stdout_reader)
        stderr_data = reader_value(stderr_reader)
        status = wait_thr.value if wait_thr.join(1)
      end

      raise UserError.new("bridge command timed out after #{command_timeout}s", 5) if timed_out

      [stdout_data, stderr_data, status]
    end

    def read_stream(stream)
      stream.read.to_s
    rescue IOError
      ""
    end

    def reader_value(thread)
      return thread.value.to_s if thread.join(0)

      thread.kill
      ""
    end

    def close_stream(stream)
      stream.close unless stream.closed?
    rescue IOError
      nil
    end

    def terminate_process_tree(pid)
      kill_process(-pid, "TERM") || kill_process(pid, "TERM")
      sleep 0.2
      kill_process(-pid, "KILL") || kill_process(pid, "KILL")
    end

    def kill_process(target, signal)
      Process.kill(signal, target)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def safe_project_path!(value)
      text = value.to_s.strip
      raise UserError.new("project path is required for backend bridge commands", 1) if text.empty?

      reject_unsafe_path!(text, "project path")
      File.expand_path(text)
    end

    def normalize_args(args)
      case args
      when nil then []
      when Array then args.map(&:to_s)
      else
        raise UserError.new("bridge args must be an array", 1)
      end
    end

    def validate_args!(args)
      args.each do |arg|
        raise UserError.new("bridge args must not contain null bytes", 5) if arg.include?("\x00")
        if arg.match?(BACKEND_CONTROLLED_ARG_PATTERN)
          raise UserError.new("bridge args must not include backend-controlled flags (--path, --json, --dry-run, --approved)", 5)
        end
        reject_unsafe_path!(arg, "argument")
      end
    end

    def reject_unsafe_path!(value, label)
      if value.to_s.match?(UNSAFE_ARG_PATTERN) || File.basename(value.to_s).match?(/\A\.env(?:\.|\z)/)
        raise UserError.new("unsafe #{label} blocked: .env/.env.* paths are not allowed", 5)
      end
    end
  end

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

  class LocalBackendDaemon
    MAX_BODY_BYTES = 1_048_576
    MAX_CONNECTIONS = 32
    READ_TIMEOUT_SECONDS = 5
    MAX_REQUEST_LINE_BYTES = 8_192
    MAX_HEADER_LINE_BYTES = 8_192
    MAX_HEADER_BYTES = 32_768

    attr_reader :host, :port, :app

    def initialize(host: "127.0.0.1", port: 4242, app: LocalBackendApp.new)
      @host = LocalBackendApp.normalize_host!(host)
      @port = LocalBackendApp.normalize_port!(port)
      @app = app
    end

    def self.plan(host: "127.0.0.1", port: 4242, bridge: CodexCliBridge.new)
      LocalBackendApp.plan(host: host, port: port, bridge: bridge)
    end

    def start
      server = TCPServer.new(host, port)
      slots = SizedQueue.new(MAX_CONNECTIONS)
      MAX_CONNECTIONS.times { slots << true }
      warn "aiweb local backend listening on http://#{host}:#{server.addr[1]}"
      warn "aiweb local backend token header: X-Aiweb-Token: #{app.api_token}" if ENV[LocalBackendApp::API_TOKEN_ENV].to_s.empty?
      loop do
        slot = slots.pop
        client = server.accept
        Thread.new(client, slot) do |socket, acquired_slot|
          begin
            handle(socket)
          ensure
            slots << acquired_slot
          end
        end
      end
    rescue Interrupt
      0
    ensure
      server&.close unless server&.closed?
    end

    private

    def handle(client)
      request_line = read_limited_line(client, MAX_REQUEST_LINE_BYTES, "request line")
      method, target = request_line.split(" ", 3)
      headers = read_headers(client)
      unless LocalBackendApp.allowed_origin?(headers["origin"])
        write_json(client, 403, "schema_version" => 1, "status" => "error", "error" => "origin is not allowed", "blocking_issues" => ["origin is not allowed"], origin: nil)
        return
      end
      body = read_body(client, headers)
      status, payload = app.call(method.to_s, target.to_s, headers, body)
      write_json(client, status, payload, origin: headers["origin"])
    rescue UserError => e
      status = e.exit_code == 5 ? 403 : 400
      write_json(client, status, "schema_version" => 1, "status" => "error", "error" => e.message, "blocking_issues" => [e.message])
    rescue StandardError => e
      write_json(client, 500, "schema_version" => 1, "status" => "error", "error" => "#{e.class}: #{e.message}")
    ensure
      client.close unless client.closed?
    end

    def read_headers(client)
      headers = {}
      bytes = 0
      while (line = read_limited_line(client, MAX_HEADER_LINE_BYTES, "header line"))
        bytes += line.bytesize
        raise UserError.new("request headers too large", 1) if bytes > MAX_HEADER_BYTES

        stripped = line.strip
        break if stripped.empty?

        name, value = stripped.split(":", 2)
        headers[name.downcase] = value.to_s.strip if name
      end
      headers
    end

    def read_body(client, headers)
      return read_chunked_body(client) if headers["transfer-encoding"].to_s.downcase.include?("chunked")

      length = headers.fetch("content-length", "0").to_i
      unless headers.fetch("content-length", "0").to_s.match?(/\A\d+\z/)
        raise UserError.new("invalid content length", 1)
      end
      raise UserError.new("invalid content length", 1) if length.negative?
      raise UserError.new("request body too large", 1) if length > MAX_BODY_BYTES

      length.positive? ? read_exact(client, length) : ""
    end

    def read_chunked_body(client)
      body = +""
      loop do
        size_line = read_limited_line(client, 32, "chunk size").strip
        raise UserError.new("invalid chunk size", 1) unless size_line.match?(/\A[0-9a-fA-F]+\z/)

        size = size_line.to_i(16)
        break if size.zero?
        raise UserError.new("request body too large", 1) if body.bytesize + size > MAX_BODY_BYTES

        body << read_exact(client, size)
        read_exact(client, 2)
      end
      read_headers(client)
      body
    end

    def read_limited_line(client, limit, label)
      line = Timeout.timeout(READ_TIMEOUT_SECONDS) { client.gets(limit + 1) }
      return nil if line.nil?
      raise UserError.new("#{label} too large", 1) if line.bytesize > limit

      line
    rescue Timeout::Error
      raise UserError.new("#{label} read timed out", 1)
    end

    def read_exact(client, length)
      Timeout.timeout(READ_TIMEOUT_SECONDS) { client.read(length).to_s }
    rescue Timeout::Error
      raise UserError.new("request body read timed out", 1)
    end

    def write_json(client, status, payload, origin: nil)
      body = JSON.generate(payload)
      reason = status == 200 ? "OK" : (status == 204 ? "No Content" : "Error")
      cors_origin = LocalBackendApp.allowed_origin?(origin) && !origin.to_s.strip.empty? ? origin.to_s.strip : nil
      cors_headers = +""
      if cors_origin
        cors_headers << "Access-Control-Allow-Origin: #{cors_origin}\r\n"
        cors_headers << "Vary: Origin\r\n"
      end
      client.write(
        "HTTP/1.1 #{status} #{reason}\r\n" \
        "Content-Type: application/json\r\n" \
        "#{cors_headers}" \
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n" \
        "Access-Control-Allow-Headers: Content-Type, X-Aiweb-Token, X-Aiweb-Approval-Token\r\n" \
        "Content-Length: #{body.bytesize}\r\n" \
        "Connection: close\r\n" \
        "\r\n" \
        "#{body}"
      )
    end
  end
end
