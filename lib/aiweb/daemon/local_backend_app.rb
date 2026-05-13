# frozen_string_literal: true

module Aiweb
  class LocalBackendApp
    include BackendArtifacts
    include BackendJobs
    include OpenManusReadiness

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
      diffs/[A-Za-z0-9_.-]+\.patch|
      qa/results/[A-Za-z0-9_.-]+\.json|
      qa/screenshots/metadata\.json|
      visual/[A-Za-z0-9_.-]+\.(?:json|md)|
      tasks/[A-Za-z0-9_.-]+\.md|
      runs/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.json|
      runs/[A-Za-z0-9_.-]+/(?:events|approvals)\.jsonl|
      runs/[A-Za-z0-9_.-]+/(?:artifacts|logs|qa|screenshots)/[A-Za-z0-9_.-]+\.(?:json|jsonl|log|txt|md|png)
    )\z}x.freeze

    attr_reader :bridge, :api_token, :approval_token

    def initialize(bridge: CodexCliBridge.new, api_token: ENV[API_TOKEN_ENV], approval_token: ENV[APPROVAL_TOKEN_ENV])
      @bridge = bridge
      @api_token = token_or_generate(api_token)
      @approval_token = approval_token.to_s.strip.empty? ? @api_token : approval_token.to_s
      @command_mutex = Mutex.new
      @job_mutex = Mutex.new
      @background_jobs = {}
    end

    def wait_for_background_jobs(timeout: 5)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout.to_f
      loop do
        jobs = @job_mutex.synchronize { @background_jobs.values }
        return true if jobs.empty?

        jobs.each do |thread|
          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          return false if remaining <= 0

          thread.join([remaining, 0.1].min)
        end
      end
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
            "engine-run is exposed only through dedicated job APIs, not the generic command bridge",
            "approved engine-run requests return a durable job id before background execution starts",
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
        "GET /api/engine/openmanus-readiness",
        "GET /api/project/status?path=PROJECT_PATH",
        "GET /api/project/workbench?path=PROJECT_PATH",
        "GET /api/project/console?path=PROJECT_PATH",
        "GET /api/project/runs?path=PROJECT_PATH",
        "GET /api/project/run?path=PROJECT_PATH&run_id=RUN_ID",
        "GET /api/project/run-stream?path=PROJECT_PATH&run_id=RUN_ID&cursor=N",
        "GET /api/project/run-events?path=PROJECT_PATH&run_id=RUN_ID",
        "GET /api/project/approvals?path=PROJECT_PATH",
        "GET /api/project/job/status?path=PROJECT_PATH&run_id=RUN_ID",
        "GET /api/project/job/timeline?path=PROJECT_PATH&limit=N",
        "GET /api/project/job/summary?path=PROJECT_PATH&limit=N",
        "GET /api/project/artifact?path=PROJECT_PATH&artifact=ARTIFACT_PATH",
        "POST /api/project/command",
        "POST /api/engine/run",
        "POST /api/engine/approve",
        "POST /api/project/job/cancel",
        "POST /api/project/job/resume",
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
      when ["GET", "/api/engine/openmanus-readiness"]
        json(200, openmanus_readiness_payload(check_image: true))
      when ["GET", "/api/project/status"]
        json(200, bridge_run(project_path: required_project_path!(query["path"]), command: "status"))
      when ["GET", "/api/project/workbench"]
        json(200, bridge_run(project_path: required_project_path!(query["path"]), command: "workbench", args: [], dry_run: true))
      when ["GET", "/api/project/console"]
        json(200, console_payload(query.fetch("path", "")))
      when ["GET", "/api/project/runs"]
        json(200, runs_payload(query.fetch("path", "")))
      when ["GET", "/api/project/run"]
        json(200, run_detail_payload(query.fetch("path", ""), query["run_id"] || query["run"]))
      when ["GET", "/api/project/run-stream"]
        json(200, run_stream_payload(query.fetch("path", ""), query["run_id"] || query["run"], query["cursor"], query["limit"], query["wait_ms"]))
      when ["GET", "/api/project/run-events"]
        json(200, run_events_payload(query.fetch("path", ""), query["run_id"] || query["run"]))
      when ["GET", "/api/project/approvals"]
        json(200, approvals_payload(query.fetch("path", "")))
      when ["GET", "/api/project/job/status"]
        json(200, job_status_payload(query.fetch("path", ""), query["run_id"] || query["run"]))
      when ["GET", "/api/project/job/timeline"]
        json(200, job_timeline_payload(query.fetch("path", ""), query["limit"]))
      when ["GET", "/api/project/job/summary"]
        json(200, job_summary_payload(query.fetch("path", ""), query["limit"]))
      when ["GET", "/api/project/artifact"]
        json(200, artifact_payload(query.fetch("path", ""), query["artifact"] || query["file"] || query["artifact_path"]))
      when ["POST", "/api/project/command"]
        json(200, command_payload(parse_body(body), headers))
      when ["POST", "/api/engine/run"]
        json(200, engine_run_payload(parse_body(body), headers))
      when ["POST", "/api/engine/approve"]
        json(200, engine_approve_payload(parse_body(body), headers))
      when ["POST", "/api/project/job/cancel"]
        json(200, job_cancel_payload(parse_body(body), headers))
      when ["POST", "/api/project/job/resume"]
        json(200, job_resume_payload(parse_body(body), headers))
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
        "openmanus_runtime" => openmanus_readiness_payload(check_image: false),
        "capabilities" => {
          "engine_run_async_jobs" => true,
          "approval_resume_jobs" => true,
          "generic_engine_run_command" => false
        },
        "routes" => self.class.routes
      }
    end

    def command_payload(payload, headers = {})
      approved = truthy?(payload["approved"])
      validate_approval!(approved, headers)
      command_name = payload.fetch("command", "").to_s.strip
      if command_name == "engine-run"
        raise UserError.new("engine-run must use POST /api/engine/run; the generic project command bridge is disabled for agentic engine execution", 5)
      end
      bridge_run(
        project_path: required_project_path!(payload["path"]),
        command: command_name,
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
          agent: payload["agent"] || "codex",
          sandbox: payload["sandbox"],
          dry_run: payload.key?("dry_run") ? truthy?(payload["dry_run"]) : true,
          approved: approved
        ).tap { |result| result["bridge"]["serialized_execution"] = true if result["bridge"].is_a?(Hash) }
      end
    end

    def engine_run_payload(payload, headers = {})
      approved = truthy?(payload["approved"])
      validate_approval!(approved, headers)
      dry_run = payload.key?("dry_run") ? truthy?(payload["dry_run"]) : true
      project_path = required_project_path!(payload["path"])
      kwargs = {
        project_path: project_path,
        goal: payload["goal"],
        agent: payload["agent"] || "codex",
        mode: payload["mode"] || "agentic_local",
        sandbox: payload["sandbox"],
        max_cycles: payload["max_cycles"] || 3,
        approval_hash: payload["approval_hash"] || payload["approval_request"],
        resume: payload["resume"] || payload["run_id"],
        run_id: nil,
        dry_run: dry_run,
        approved: approved
      }
      return bridge_engine_run(**kwargs) if dry_run

      unless approved
        raise UserError.new("approved=true and approval token are required for real engine-run backend jobs", 5)
      end

      run_id = backend_engine_run_id(payload["job_run_id"] || payload["new_run_id"])
      kwargs[:run_id] = run_id
      enqueue_engine_run_job(project_path: project_path, run_id: run_id, bridge_kwargs: kwargs, resume_from: kwargs[:resume])
    end

    def engine_approve_payload(payload, headers = {})
      validate_approval!(true, headers)
      parent_run_id = safe_run_id!(payload["run_id"] || payload["resume"])
      project_path = required_project_path!(payload["path"])
      run_id = backend_engine_run_id(payload["job_run_id"] || payload["new_run_id"], prefix: "engine-run-resume")
      enqueue_engine_run_job(
        project_path: project_path,
        run_id: run_id,
        resume_from: parent_run_id,
        bridge_kwargs: {
          project_path: project_path,
          run_id: run_id,
          goal: payload["goal"],
          agent: payload["agent"] || "codex",
          mode: payload["mode"] || "agentic_local",
          sandbox: payload["sandbox"],
          max_cycles: payload["max_cycles"] || 3,
          approval_hash: payload["approval_hash"] || payload["approval_request"],
          resume: parent_run_id,
          dry_run: false,
          approved: true
        }
      )
    end

    def job_status_payload(path, run_id)
      root = safe_project_path(path)
      if !run_id.to_s.strip.empty?
        local = backend_job_status_payload(root, safe_run_id!(run_id))
        return local if local
      end

      args = []
      args.concat(["--run-id", safe_run_id!(run_id)]) unless run_id.to_s.strip.empty?
      bridge_run(project_path: root, command: "run-status", args: args, dry_run: false, approved: false)
    end

    def job_timeline_payload(path, limit)
      size = parse_positive_integer(limit, default: 20, label: "limit")
      bridge_run(project_path: required_project_path!(path), command: "run-timeline", args: ["--limit", size.to_s], dry_run: false, approved: false)
    end

    def job_summary_payload(path, limit)
      size = parse_positive_integer(limit, default: 20, label: "limit")
      bridge_run(project_path: required_project_path!(path), command: "observability-summary", args: ["--limit", size.to_s], dry_run: false, approved: false)
    end

    def job_cancel_payload(payload, headers = {})
      dry_run = truthy?(payload["dry_run"])
      validate_approval!(!dry_run, headers)
      args = ["--run-id", safe_run_id!(payload["run_id"] || payload["run"] || "active")]
      args << "--force" if truthy?(payload["force"])
      bridge_run(project_path: required_project_path!(payload["path"]), command: "run-cancel", args: args, dry_run: dry_run, approved: false)
    end

    def job_resume_payload(payload, headers = {})
      dry_run = payload.key?("dry_run") ? truthy?(payload["dry_run"]) : false
      validate_approval!(!dry_run, headers)
      args = ["--run-id", safe_run_id!(payload["run_id"] || payload["run"] || "latest")]
      bridge_run(project_path: required_project_path!(payload["path"]), command: "run-resume", args: args, dry_run: dry_run, approved: false)
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

    def bridge_engine_run(**kwargs)
      @command_mutex.synchronize do
        bridge.engine_run(**kwargs).tap { |result| result["bridge"]["serialized_execution"] = true if result["bridge"].is_a?(Hash) }
      end
    end

    def safe_project_path(value)
      text = required_project_path!(value)
      raise UserError.new("unsafe project path blocked: .env/.env.* paths are not allowed", 5) if unsafe_env_path?(text)

      File.expand_path(text)
    end

    def safe_run_id!(value)
      text = value.to_s.strip
      raise UserError.new("run_id is required", 1) if text.empty?
      raise UserError.new("unsafe run_id blocked", 5) if text.include?("/") || text.include?("\\") || text.include?("..") || text.start_with?(".") || unsafe_env_path?(text)

      text
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

    def parse_nonnegative_integer(value, default:, label:)
      text = value.to_s.strip
      return default if text.empty?

      number = Integer(text)
      raise ArgumentError if number.negative?

      number
    rescue ArgumentError, TypeError
      raise UserError.new("#{label} must be a non-negative integer", 1)
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

    def parse_positive_integer(value, default:, label:)
      text = value.to_s.strip
      return default if text.empty?

      number = Integer(text)
      raise ArgumentError if number < 1

      number
    rescue ArgumentError, TypeError
      raise UserError.new("#{label} must be a positive integer", 1)
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
