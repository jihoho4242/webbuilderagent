# frozen_string_literal: true

module Aiweb
  class LocalBackendApp
    module Routes
    def route_response(method, path, query, headers, body)
      return get_route_response(path, query, headers) if method == "GET"
      return post_route_response(path, headers, body) if method == "POST"

      json(404, error_payload("route not found: #{method} #{path}", 404))
    end

    def get_route_response(path, query, headers)
      case path
      when "/health"
        json(200, health_payload)
      when "/api/engine"
        json(200, engine_payload)
      when "/api/engine/openmanus-readiness"
        json(200, openmanus_readiness_payload(check_image: true))
      when "/api/project/status"
        json(200, bridge_run(project_path: authorized_project_path!(query["path"], headers, action: "view_status"), command: "status"))
      when "/api/project/workbench"
        json(200, bridge_run(project_path: authorized_project_path!(query["path"], headers, action: "view_workbench"), command: "workbench", args: [], dry_run: true))
      when "/api/project/console"
        json(200, console_payload(authorized_project_path!(query["path"], headers, action: "view_console")))
      when "/api/project/runs"
        json(200, runs_payload(authorized_project_path!(query["path"], headers, action: "view_runs")))
      when "/api/project/run"
        json(200, run_detail_payload(authorized_project_path!(query["path"], headers, action: "view_run"), query["run_id"] || query["run"]))
      when "/api/project/run-stream"
        json(200, run_stream_payload(authorized_project_path!(query["path"], headers, action: "view_events"), query["run_id"] || query["run"], query["cursor"], query["limit"], query["wait_ms"]))
      when "/api/project/run-events-sse"
        sse(200, run_events_sse_body(authorized_project_path!(query["path"], headers, action: "view_events"), query["run_id"] || query["run"], query["cursor"], query["limit"], query["wait_ms"]))
      when "/api/project/run-events"
        json(200, run_events_payload(authorized_project_path!(query["path"], headers, action: "view_events"), query["run_id"] || query["run"]))
      when "/api/project/approvals"
        json(200, approvals_payload(authorized_project_path!(query["path"], headers, action: "view_approvals")))
      when "/api/project/job/status"
        json(200, job_status_payload(authorized_project_path!(query["path"], headers, action: "view_job_status"), query["run_id"] || query["run"]))
      when "/api/project/job/timeline"
        json(200, job_timeline_payload(authorized_project_path!(query["path"], headers, action: "view_job_timeline"), query["limit"]))
      when "/api/project/job/summary"
        json(200, job_summary_payload(authorized_project_path!(query["path"], headers, action: "view_job_summary"), query["limit"]))
      when "/api/project/artifact"
        artifact_root = authorized_project_path!(query["path"], headers, action: "view_artifact")
        json(200, artifact_payload(artifact_root, query["artifact"] || query["file"] || query["artifact_path"], headers: headers))
      else
        json(404, error_payload("route not found: GET #{path}", 404))
      end
    end

    def post_route_response(path, headers, body)
      case path
      when "/api/project/command"
        json(200, command_payload(parse_body(body), headers))
      when "/api/engine/run"
        json(200, engine_run_payload(parse_body(body), headers))
      when "/api/engine/approve"
        json(200, engine_approve_payload(parse_body(body), headers))
      when "/api/project/job/cancel"
        json(200, job_cancel_payload(parse_body(body), headers))
      when "/api/project/job/resume"
        json(200, job_resume_payload(parse_body(body), headers))
      when "/api/codex/agent-run"
        json(200, codex_agent_run_payload(parse_body(body), headers))
      else
        json(404, error_payload("route not found: POST #{path}", 404))
      end
    end

    private

    def json(status, payload)
      [status, payload]
    end

    def sse(status, body)
      [status, body, { "content_type" => "text/event-stream", "cache_control" => "no-cache", "x_accel_buffering" => "no" }]
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
          "event_sse" => true,
          "claim_enforced_project_authz" => claim_authz_enforced?,
          "generic_engine_run_command" => false
        },
        "authz" => {
          "mode" => authz_mode,
          "supported_modes" => SUPPORTED_AUTHZ_MODES,
          "unsupported_modes_fail_closed_for_project_routes" => true,
          "claim_enforced" => claim_authz_enforced?,
          "required_claim_headers" => authz_mode == "claims" ? CLAIM_HEADER_NAMES : [],
          "authorization_header" => "Authorization",
          "jwt_hs256_secret_configured" => !authz_jwt_hs256_secret.to_s.empty?,
          "jwt_hs256_required_claims" => authz_mode == "jwt_hs256" ? JWT_HS256_REQUIRED_CLAIMS : [],
          "jwt_hs256_claim_aliases" => JWT_HS256_CLAIM_ALIASES,
          "jwt_rs256_jwks_file_env" => AUTHZ_JWT_RS256_JWKS_FILE_ENV,
          "jwt_rs256_jwks_file_configured" => !authz_jwt_rs256_jwks_file.empty?,
          "jwt_rs256_jwks_source" => "local_file_only_no_oidc_discovery",
          "jwt_rs256_jwks_required_claims" => authz_mode == "jwt_rs256_jwks" ? JWT_HS256_REQUIRED_CLAIMS : [],
          "session_store_file_env" => AUTHZ_SESSION_STORE_FILE_ENV,
          "session_store_file_configured" => !authz_session_store_file.empty?,
          "session_token_required_claims" => authz_mode == "session_token" ? SESSION_TOKEN_REQUIRED_CLAIMS : [],
          "session_token_storage" => "sha256_hash_only",
          "project_id_source" => "server_configured_project_allowlist",
          "role_source" => "server_configured_project_allowlist",
          "project_registry_source" => "inline_env_or_file_json",
          "role_hierarchy" => AUTHZ_ROLE_LEVELS.keys,
          "route_required_roles" => AUTHZ_ACTION_REQUIRED_ROLES,
          "artifact_acl_policy" => ARTIFACT_ACL_POLICY,
          "audit_path" => AUTHZ_AUDIT_PATH,
          "project_registry_file_env" => AUTHZ_PROJECTS_FILE_ENV,
          "project_registry_file_configured" => !authz_projects_file.empty?,
          "project_registry_policy" => AUTHZ_PROJECT_REGISTRY_POLICY,
          "project_registry_errors" => authz_project_registry_errors,
          "configured_project_count" => authz_project_entries.length
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
      project_path = authorized_project_path!(payload["path"], headers, action: "command")
      bridge_run(
        project_path: project_path,
        command: command_name,
        args: payload["args"] || [],
        dry_run: truthy?(payload["dry_run"]),
        approved: approved
      )
    end

    def codex_agent_run_payload(payload, headers = {})
      approved = truthy?(payload["approved"])
      validate_approval!(approved, headers)
      project_path = authorized_project_path!(payload["path"], headers, action: "codex_agent_run")
      @command_mutex.synchronize do
        bridge.agent_run(
          project_path: project_path,
          task: payload["task"] || "latest",
          agent: payload["agent"] || "codex",
          sandbox: payload["sandbox"],
          approval_hash: payload["approval_hash"],
          dry_run: payload.key?("dry_run") ? truthy?(payload["dry_run"]) : true,
          approved: approved
        ).tap { |result| result["bridge"]["serialized_execution"] = true if result["bridge"].is_a?(Hash) }
      end
    end

    def engine_run_payload(payload, headers = {})
      approved = truthy?(payload["approved"])
      validate_approval!(approved, headers)
      dry_run = payload.key?("dry_run") ? truthy?(payload["dry_run"]) : true
      project_path = authorized_project_path!(payload["path"], headers, action: "run_start")
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
      project_path = authorized_project_path!(payload["path"], headers, action: "approve")
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
      bridge_run(project_path: authorized_project_path!(payload["path"], headers, action: "cancel"), command: "run-cancel", args: args, dry_run: dry_run, approved: false)
    end

    def job_resume_payload(payload, headers = {})
      dry_run = payload.key?("dry_run") ? truthy?(payload["dry_run"]) : false
      validate_approval!(!dry_run, headers)
      args = ["--run-id", safe_run_id!(payload["run_id"] || payload["run"] || "latest")]
      bridge_run(project_path: authorized_project_path!(payload["path"], headers, action: "resume"), command: "run-resume", args: args, dry_run: dry_run, approved: false)
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

    end
  end
end
