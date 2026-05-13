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

    def openmanus_readiness_payload(check_image:)
      image = ENV.fetch("AIWEB_OPENMANUS_IMAGE", "").to_s.strip
      image = "openmanus:latest" if image.empty?
      providers = %w[docker podman].map { |provider| openmanus_provider_readiness(provider, image, check_image: check_image) }
      ready = providers.find { |provider| provider["status"] == "ready" }
      missing_runtime = providers.all? { |provider| provider["executable_path"].to_s.empty? }
      status = if ready
                 "ready"
               elsif missing_runtime
                 "missing_runtime"
               elsif check_image
                 "missing_image"
               else
                 "unchecked"
               end
      blockers = providers.flat_map { |provider| Array(provider["blocking_issues"]) }.uniq
      blockers = [] if ready
      {
        "schema_version" => 1,
        "status" => status,
        "image" => image,
        "check_image" => check_image,
        "providers" => providers,
        "selected_provider" => ready && ready["provider"],
        "blocking_issues" => blockers,
        "next_action" => openmanus_readiness_next_action(status, image)
      }
    end

    def openmanus_provider_readiness(provider, image, check_image:)
      executable = find_executable(provider)
      unless executable
        return {
          "provider" => provider,
          "status" => "missing_runtime",
          "executable_path" => nil,
          "image" => image,
          "image_present" => false,
          "blocking_issues" => ["#{provider} executable is missing from PATH"]
        }
      end

      unless check_image
        return {
          "provider" => provider,
          "status" => "unchecked",
          "executable_path" => executable,
          "image" => image,
          "image_present" => nil,
          "blocking_issues" => []
        }
      end

      stdout, stderr, status = container_image_inspect(provider, image)
      if status&.success?
        {
          "provider" => provider,
          "status" => "ready",
          "executable_path" => executable,
          "image" => image,
          "image_present" => true,
          "inspect_stdout" => stdout.to_s[0, 300],
          "blocking_issues" => []
        }
      else
        {
          "provider" => provider,
          "status" => "missing_image",
          "executable_path" => executable,
          "image" => image,
          "image_present" => false,
          "inspect_stderr" => stderr.to_s[0, 300],
          "blocking_issues" => ["#{provider} image is missing locally: #{image}"]
        }
      end
    rescue Timeout::Error
      {
        "provider" => provider,
        "status" => "unavailable",
        "executable_path" => executable,
        "image" => image,
        "image_present" => false,
        "blocking_issues" => ["#{provider} image preflight timed out"]
      }
    rescue SystemCallError => e
      {
        "provider" => provider,
        "status" => "unavailable",
        "executable_path" => executable,
        "image" => image,
        "image_present" => false,
        "blocking_issues" => ["#{provider} image preflight failed: #{e.message}"]
      }
    end

    def container_image_inspect(provider, image)
      Timeout.timeout(2) do
        Open3.capture3(provider, "image", "inspect", image)
      end
    end

    def openmanus_readiness_next_action(status, image)
      case status
      when "ready"
        "start approved OpenManus engine-run jobs with --agent openmanus --sandbox docker|podman"
      when "missing_runtime"
        "install Docker or Podman locally, then prepare the #{image} image"
      when "missing_image"
        "build or pull the local #{image} image before approved OpenManus execution"
      else
        "call GET /api/engine/openmanus-readiness before enabling OpenManus run controls"
      end
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

    def enqueue_engine_run_job(project_path:, run_id:, bridge_kwargs:, resume_from: nil)
      root = safe_project_path(project_path)
      run_dir = backend_run_dir(root, run_id)
      FileUtils.mkdir_p(run_dir)
      events_path = File.join(run_dir, "events.jsonl")
      job_path = File.join(run_dir, "job.json")
      queued_at = now_utc
      job = backend_job_record(
        run_id: run_id,
        status: "queued",
        project_path: root,
        started_at: nil,
        finished_at: nil,
        events_path: events_path,
        resume_from: resume_from,
        bridge_kwargs: bridge_kwargs,
        queued_at: queued_at
      )
      backend_write_json(job_path, job)
      backend_append_event(events_path, "backend.job.queued", "queued engine-run background job", run_id: run_id, resume_from: resume_from)
      start_engine_run_worker(root: root, run_id: run_id, job_path: job_path, events_path: events_path, bridge_kwargs: bridge_kwargs, queued_at: queued_at, resume_from: resume_from)
      engine_job_payload(root: root, run_id: run_id, job: job)
    end

    def start_engine_run_worker(root:, run_id:, job_path:, events_path:, bridge_kwargs:, queued_at:, resume_from:)
      thread = Thread.new do
        started_at = now_utc
        begin
          backend_write_json(job_path, backend_job_record(
            run_id: run_id,
            status: "running",
            project_path: root,
            started_at: started_at,
            finished_at: nil,
            events_path: events_path,
            resume_from: resume_from,
            bridge_kwargs: bridge_kwargs,
            queued_at: queued_at
          ))
          backend_append_event(events_path, "backend.job.started", "started engine-run background job", run_id: run_id, resume_from: resume_from)
          result = bridge_engine_run(**bridge_kwargs)
          final_status = backend_engine_job_status(result)
          backend_write_json(job_path, backend_job_record(
            run_id: run_id,
            status: final_status,
            project_path: root,
            started_at: started_at,
            finished_at: now_utc,
            events_path: events_path,
            resume_from: resume_from,
            bridge_kwargs: bridge_kwargs,
            queued_at: queued_at,
            bridge_status: result["status"],
            exit_code: result["exit_code"],
            engine_run_id: result.dig("stdout_json", "engine_run", "run_id") || run_id,
            engine_status: result.dig("stdout_json", "engine_run", "status"),
            blocking_issues: Array(result.dig("stdout_json", "blocking_issues")) + Array(result.dig("stdout_json", "engine_run", "blocking_issues"))
          ))
          backend_append_event(events_path, "backend.job.finished", "finished engine-run background job", run_id: run_id, status: final_status)
        rescue StandardError => e
          backend_write_json(job_path, backend_job_record(
            run_id: run_id,
            status: "failed",
            project_path: root,
            started_at: started_at,
            finished_at: now_utc,
            events_path: events_path,
            resume_from: resume_from,
            bridge_kwargs: bridge_kwargs,
            queued_at: queued_at,
            blocking_issues: ["#{e.class}: #{e.message}"]
          ))
          backend_append_event(events_path, "backend.job.failed", "engine-run background job failed", run_id: run_id, error: "#{e.class}: #{e.message}")
        ensure
          @job_mutex.synchronize { @background_jobs.delete(run_id) }
        end
      end
      thread.abort_on_exception = false
      @job_mutex.synchronize { @background_jobs[run_id] = thread }
      thread
    end

    def engine_job_payload(root:, run_id:, job:)
      relative_events = job["events_path"]
      {
        "schema_version" => 1,
        "status" => "queued",
        "project_path" => root,
        "engine_run" => {
          "schema_version" => 1,
          "run_id" => run_id,
          "status" => "queued",
          "job_path" => File.join(".ai-web", "runs", run_id, "job.json").tr("\\", "/"),
          "events_path" => relative_events,
          "async" => true,
          "stream" => {
            "route" => "GET /api/project/run-stream?path=PROJECT_PATH&run_id=#{run_id}&cursor=N&wait_ms=MS",
            "cursor" => 0
          },
          "approval_resume" => !job["resume_from"].to_s.empty?
        },
        "job" => job,
        "next_action" => "poll run-stream and job/status for #{run_id}"
      }
    end

    def backend_job_status_payload(root, run_id)
      path = File.join(backend_run_dir(root, run_id), "job.json")
      return nil unless File.file?(path)

      job = safe_json_summary(root, path)
      {
        "schema_version" => 1,
        "status" => "ready",
        "project_path" => root,
        "run_id" => run_id,
        "job" => job
      }
    end

    def backend_job_record(run_id:, status:, project_path:, started_at:, finished_at:, events_path:, resume_from:, bridge_kwargs:, queued_at:, bridge_status: nil, exit_code: nil, engine_run_id: nil, engine_status: nil, blocking_issues: [])
      relative_events = events_path.sub(%r{\A#{Regexp.escape(project_path)}[\\/]?}, "").tr("\\", "/")
      {
        "schema_version" => 1,
        "kind" => "engine-run",
        "run_id" => run_id,
        "status" => status,
        "queued_at" => queued_at,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "updated_at" => now_utc,
        "events_path" => relative_events,
        "resume_from" => resume_from,
        "bridge" => {
          "command" => "engine-run",
          "agent" => bridge_kwargs[:agent],
          "mode" => bridge_kwargs[:mode],
          "sandbox" => bridge_kwargs[:sandbox],
          "max_cycles" => bridge_kwargs[:max_cycles],
          "dry_run" => bridge_kwargs[:dry_run],
          "approved" => bridge_kwargs[:approved]
        },
        "bridge_status" => bridge_status,
        "exit_code" => exit_code,
        "engine_run_id" => engine_run_id,
        "engine_status" => engine_status,
        "blocking_issues" => Array(blocking_issues).compact.map(&:to_s).reject(&:empty?).uniq
      }.compact
    end

    def backend_engine_job_status(result)
      engine_status = result.dig("stdout_json", "engine_run", "status").to_s
      return engine_status unless engine_status.empty?

      result["status"].to_s == "passed" ? "passed" : "failed"
    end

    def backend_run_dir(root, run_id)
      File.join(root, ".ai-web", "runs", safe_run_id!(run_id))
    end

    def backend_write_json(path, payload)
      FileUtils.mkdir_p(File.dirname(path))
      temp = "#{path}.tmp-#{Process.pid}-#{Thread.current.object_id}"
      File.write(temp, JSON.pretty_generate(payload) + "\n")
      File.rename(temp, path)
    ensure
      FileUtils.rm_f(temp) if temp && File.file?(temp)
    end

    def backend_append_event(path, type, message, data = {})
      FileUtils.mkdir_p(File.dirname(path))
      event = {
        "schema_version" => 1,
        "seq" => backend_next_event_seq(path),
        "type" => type,
        "message" => message,
        "at" => now_utc,
        "data" => data
      }
      File.open(path, "a") { |file| file.write(JSON.generate(event) + "\n") }
      event
    end

    def backend_next_event_seq(path)
      File.file?(path) ? File.readlines(path).length + 1 : 1
    rescue SystemCallError
      1
    end

    def backend_engine_run_id(value, prefix: "engine-run")
      requested = value.to_s.strip
      unless requested.empty?
        safe = safe_run_id!(requested)
        unless safe.match?(/\Aengine-run-[A-Za-z0-9_.-]+\z/)
          raise UserError.new("engine-run job_run_id must start with engine-run- and contain only letters, numbers, dot, underscore, or dash", 1)
        end
        return safe
      end

      "#{prefix}-#{Time.now.utc.strftime("%Y%m%dT%H%M%S%6NZ")}"
    end

    def now_utc
      Time.now.utc.iso8601
    end

    def console_payload(path)
      root = safe_project_path(path)
      runs = runs_payload(root).fetch("runs")
      approvals = approvals_payload(root).fetch("approvals")
      {
        "schema_version" => 1,
        "status" => "ready",
        "project_path" => root,
        "console" => {
          "backend_ready" => true,
          "frontend_attached" => false,
          "latest_run" => runs.last,
          "recent_run_count" => runs.length,
          "approval_count" => approvals.length,
          "approvals" => approvals.last(20),
          "routes" => self.class.routes,
          "capabilities" => {
            "engine_run" => true,
            "engine_run_async_jobs" => true,
            "approval_resume" => true,
            "approval_resume_jobs" => true,
            "openmanus_readiness" => true,
            "run_detail" => true,
            "event_polling" => true,
            "diff_artifacts" => true,
            "sse" => false,
            "websocket" => false
          }
        }
      }
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

    def run_detail_payload(path, run_id)
      root = safe_project_path(path)
      safe_id = safe_run_id!(run_id)
      run_dir = File.join(root, ".ai-web", "runs", safe_id)
      raise UserError.new("run does not exist: #{safe_id}", 1) unless Dir.exist?(run_dir)

      metadata = run_metadata_summary(root, safe_id)
      events_payload = run_stream_payload(root, safe_id, 0, 200)
      approvals = run_approvals(root, safe_id)
      artifact_refs = run_artifact_refs(root, safe_id, metadata)
      panels = run_typed_panels(root, safe_id, metadata, artifact_refs, events_payload, approvals)
      run_status = metadata["status"].to_s
      {
        "schema_version" => 1,
        "status" => "ready",
        "project_path" => root,
        "run" => {
          "run_id" => safe_id,
          "metadata" => metadata,
          "events" => events_payload.fetch("events"),
          "event_count" => events_payload.fetch("total_count"),
          "approvals" => approvals,
          "artifact_refs" => artifact_refs,
          "panels" => panels,
          "console" => {
            "needs_approval" => run_status == "waiting_approval" || approvals.any? { |entry| entry["status"].to_s == "planned" },
            "can_resume" => %w[waiting_approval cancelled failed blocked].include?(run_status),
            "latest_event_type" => events_payload.fetch("events").last&.fetch("type", nil)
          }
        }
      }
    end

    def run_typed_panels(root, run_id, metadata, artifact_refs, events_payload, approvals)
      {
        "design_verdict" => run_json_panel(root, metadata["design_verdict_path"], metadata["design_verdict"]),
        "screenshots" => run_screenshots_panel(root, metadata["screenshot_evidence_path"], metadata["screenshot_evidence"]),
        "preview" => run_json_panel(root, metadata["preview_path"], metadata["preview"]),
        "diff" => {
          "status" => artifact_refs.any? { |ref| ref["role"] == "diff" } ? "ready" : "empty",
          "artifact" => artifact_refs.find { |ref| ref["role"] == "diff" }
        },
        "opendesign_contract" => run_json_panel(root, metadata["opendesign_contract_path"], metadata["opendesign_contract"]),
        "repair_history" => {
          "status" => "ready",
          "events" => events_payload.fetch("events").select { |event| event["type"].to_s.start_with?("design.repair.") || event["type"].to_s == "repair.planned" }
        },
        "approvals" => {
          "status" => approvals.empty? ? "empty" : "ready",
          "items" => approvals
        }
      }
    end

    def run_json_panel(root, path, inline)
      relative = path.to_s
      data = inline
      if data.nil? && !relative.empty? && safe_artifact_reference?(root, relative)
        full = File.join(root, relative)
        data = safe_json_summary(root, full) if File.file?(full)
      end
      {
        "status" => data.nil? ? "empty" : "ready",
        "path" => relative.empty? ? nil : relative,
        "data" => data
      }.compact
    rescue UserError
      { "status" => "blocked", "path" => relative }
    end

    def run_screenshots_panel(root, path, inline)
      panel = run_json_panel(root, path, inline)
      screenshots = Array(panel.dig("data", "screenshots")).map do |shot|
        shot.slice("viewport", "width", "height", "url", "path", "sha256", "capture_mode")
      end
      panel.merge("screenshots" => screenshots)
    end

    def run_stream_payload(path, run_id, cursor, limit, wait_ms = nil)
      root = safe_project_path(path)
      safe_id = safe_run_id!(run_id)
      relative, lines = run_event_lines(root, safe_id)

      offset = parse_nonnegative_integer(cursor, default: 0, label: "cursor")
      size = parse_nonnegative_integer(limit, default: 200, label: "limit")
      wait = parse_nonnegative_integer(wait_ms, default: 0, label: "wait_ms")
      wait = [wait, 5000].min
      size = [[size, 1].max, 500].min
      if wait.positive? && lines.length <= offset
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + (wait / 1000.0)
        while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          sleep 0.05
          _relative, lines = run_event_lines(root, safe_id)
          break if lines.length > offset
        end
      end
      selected = lines.drop(offset).first(size)
      events = safe_jsonl_events(selected)
      next_cursor = offset + events.length
      {
        "schema_version" => 1,
        "status" => "ready",
        "project_path" => root,
        "run_id" => safe_id,
        "events_path" => relative,
        "stream_mode" => "long_poll",
        "wait_ms" => wait,
        "cursor" => offset,
        "next_cursor" => next_cursor,
        "has_more" => lines.length > next_cursor,
        "total_count" => lines.length,
        "events" => events
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

    def run_events_payload(path, run_id)
      root = safe_project_path(path)
      safe_id = safe_run_id!(run_id)
      relative, lines = run_event_lines(root, safe_id)
      events = safe_jsonl_events(lines.last(200))
      {
        "schema_version" => 1,
        "status" => "ready",
        "project_path" => root,
        "run_id" => safe_id,
        "events_path" => relative,
        "events" => events,
        "count" => events.length
      }
    end

    def run_event_lines(root, run_id)
      relative = safe_artifact_path!(root, File.join(".ai-web", "runs", run_id, "events.jsonl"))
      full = File.join(root, relative)
      raise UserError.new("run events do not exist: #{relative}", 1) unless File.file?(full)
      safe_artifact_realpath!(root, full, relative)

      [relative, File.readlines(full, chomp: true)]
    end

    def safe_jsonl_events(lines)
      lines.map do |line|
        safe_metadata(JSON.parse(line))
      rescue JSON::ParserError
        { "status" => "unreadable", "raw" => redact_text(line.to_s)[0, 300] }
      end
    end

    def approvals_payload(path)
      root = safe_project_path(path)
      approvals = Dir.glob(File.join(root, ".ai-web", "runs", "*", "approvals.jsonl")).sort.last(50).flat_map do |file|
        relative = file.sub(%r{\A#{Regexp.escape(root)}/?}, "")
        next [] unless relative.match?(SAFE_ARTIFACT_PATTERN)
        safe_artifact_realpath!(root, file, relative)

        approval_records(File.basename(File.dirname(file)), relative, File.readlines(file, chomp: true))
      rescue SystemCallError, UserError
        []
      end
      {
        "schema_version" => 1,
        "status" => "ready",
        "project_path" => root,
        "approvals" => approvals.compact.last(100)
      }
    end

    def run_metadata_summary(root, run_id)
      run_dir = File.join(root, ".ai-web", "runs", run_id)
      preferred = %w[engine-run.json agent-run.json verify-loop.json setup.json build.json preview.json]
      file = preferred.map { |name| File.join(run_dir, name) }.find { |candidate| File.file?(candidate) }
      file ||= Dir.glob(File.join(run_dir, "*.json")).sort.first
      raise UserError.new("run metadata does not exist: #{run_id}", 1) unless file

      safe_json_summary(root, file).merge("run_id" => run_id)
    end

    def run_approvals(root, run_id)
      file = File.join(root, ".ai-web", "runs", run_id, "approvals.jsonl")
      return [] unless File.file?(file)

      relative = safe_artifact_path!(root, File.join(".ai-web", "runs", run_id, "approvals.jsonl"))
      safe_artifact_realpath!(root, file, relative)
      approval_records(run_id, relative, File.readlines(file, chomp: true))
    end

    def approval_records(run_id, relative, lines)
      lines.map do |line|
        safe_metadata(JSON.parse(line)).merge("run_id" => run_id, "path" => relative)
      rescue JSON::ParserError
        { "run_id" => run_id, "path" => relative, "status" => "unreadable" }
      end
    end

    def run_artifact_refs(root, run_id, metadata)
      refs = []
      metadata.to_h.each do |key, value|
        next unless key.end_with?("_path") || key == "diff_path"

        relative = value.to_s
        next if relative.empty?
        next unless safe_artifact_reference?(root, relative)

        refs << artifact_ref(root, relative, artifact_role(key, relative))
      end
      Dir.glob(File.join(root, ".ai-web", "runs", run_id, "{artifacts,logs,qa,screenshots}", "*")).sort.each do |file|
        next unless File.file?(file)

        relative = file.sub(%r{\A#{Regexp.escape(root)}/?}, "").tr("\\", "/")
        next unless safe_artifact_reference?(root, relative)

        refs << artifact_ref(root, relative, artifact_role(File.basename(file, ".*"), relative))
      end
      refs.uniq { |entry| entry["path"] }
    end

    def safe_artifact_reference?(root, relative)
      safe_artifact_path!(root, relative)
      true
    rescue UserError
      false
    end

    def artifact_ref(root, relative, role)
      full = File.join(root, relative)
      {
        "path" => relative,
        "role" => role,
        "media_type" => artifact_media_type(relative),
        "size_bytes" => File.file?(full) ? File.size(full) : nil
      }.compact
    end

    def artifact_role(key, relative)
      return "diff" if key == "diff_path" || relative.end_with?(".patch")

      key.sub(/_path\z/, "")
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
      when ".jsonl" then "application/x-jsonlines"
      when ".patch" then "text/x-diff"
      when ".html" then "text/html"
      when ".md" then "text/markdown"
      when ".log" then "text/plain"
      when ".png" then "image/png"
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

    def find_executable(name)
      paths = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
      extensions = if RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/i)
                     ENV.fetch("PATHEXT", ".COM;.EXE;.BAT;.CMD").split(";")
                   else
                     [""]
                   end
      paths.each do |dir|
        extensions.each do |ext|
          candidate = File.join(dir, "#{name}#{ext}")
          return candidate if File.file?(candidate) && File.executable?(candidate)
        end
      end
      nil
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
