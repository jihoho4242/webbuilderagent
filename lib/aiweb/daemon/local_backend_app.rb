# frozen_string_literal: true

require "digest"
require "fileutils"
require "base64"
require "openssl"
require "time"

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
    AUTHZ_MODE_ENV = "AIWEB_DAEMON_AUTHZ_MODE"
    AUTHZ_TENANT_ID_ENV = "AIWEB_DAEMON_TENANT_ID"
    AUTHZ_USER_ID_ENV = "AIWEB_DAEMON_USER_ID"
    AUTHZ_PROJECTS_ENV = "AIWEB_DAEMON_AUTHZ_PROJECTS"
    AUTHZ_PROJECTS_FILE_ENV = "AIWEB_DAEMON_AUTHZ_PROJECTS_FILE"
    AUTHZ_JWT_HS256_SECRET_ENV = "AIWEB_DAEMON_JWT_HS256_SECRET"
    AUTHZ_JWT_RS256_JWKS_FILE_ENV = "AIWEB_DAEMON_JWT_RS256_JWKS_FILE"
    AUTHZ_SESSION_STORE_FILE_ENV = "AIWEB_DAEMON_SESSION_STORE_FILE"
    AUTHZ_AUDIT_PATH = ".ai-web/authz/audit.jsonl"
    AUTHORIZATION_HEADER = "authorization"
    TENANT_ID_HEADER = "x-aiweb-tenant-id"
    PROJECT_ID_HEADER = "x-aiweb-project-id"
    USER_ID_HEADER = "x-aiweb-user-id"
    CLAIM_HEADER_NAMES = %w[X-Aiweb-Tenant-Id X-Aiweb-Project-Id X-Aiweb-User-Id].freeze
    JWT_HS256_REQUIRED_CLAIMS = %w[tenant_id project_id user_id].freeze
    JWT_HS256_CLAIM_ALIASES = {
      "tenant_id" => %w[tenant_id tid],
      "project_id" => %w[project_id pid],
      "user_id" => %w[user_id sub]
    }.freeze
    SESSION_TOKEN_REQUIRED_CLAIMS = %w[tenant_id project_id user_id].freeze
    AUTHZ_ROLE_LEVELS = { "viewer" => 1, "operator" => 2, "admin" => 3 }.freeze
    AUTHZ_ACTION_REQUIRED_ROLES = {
      "view_status" => "viewer",
      "view_workbench" => "viewer",
      "view_console" => "viewer",
      "view_runs" => "viewer",
      "view_run" => "viewer",
      "view_events" => "viewer",
      "view_approvals" => "viewer",
      "view_job_status" => "viewer",
      "view_job_timeline" => "viewer",
      "view_job_summary" => "viewer",
      "view_artifact" => "viewer",
      "command" => "operator",
      "codex_agent_run" => "operator",
      "run_start" => "operator",
      "resume" => "operator",
      "cancel" => "operator",
      "approve" => "admin",
      "copy_back" => "admin"
    }.freeze
    ARTIFACT_ACL_POLICY = {
      "policy" => "local_backend_artifact_acl_v1",
      "default_role" => "viewer",
      "sensitive_artifact_role" => "operator",
      "approval_artifact_role" => "admin",
      "sensitive_categories" => %w[diffs logs approvals sensitive_run_artifacts]
    }.freeze
    AUTHZ_PROJECT_REGISTRY_POLICY = {
      "policy" => "local_backend_project_registry_v1",
      "sources" => [AUTHZ_PROJECTS_ENV, AUTHZ_PROJECTS_FILE_ENV],
      "file_format" => "json",
      "supports_tenant_members" => true,
      "supports_project_members" => true,
      "role_source" => "server_configured_project_allowlist"
    }.freeze
    SUPPORTED_AUTHZ_MODES = %w[local_token claims jwt_hs256 jwt_rs256_jwks session_token].freeze
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

    attr_reader :bridge, :api_token, :approval_token, :authz_mode, :authz_tenant_id, :authz_user_id, :authz_project_entries, :authz_projects_file, :authz_project_registry_errors, :authz_jwt_hs256_secret, :authz_jwt_rs256_jwks_file, :authz_session_store_file

    def initialize(bridge: CodexCliBridge.new, api_token: ENV[API_TOKEN_ENV], approval_token: ENV[APPROVAL_TOKEN_ENV], authz_mode: ENV[AUTHZ_MODE_ENV], authz_tenant_id: ENV[AUTHZ_TENANT_ID_ENV], authz_user_id: ENV[AUTHZ_USER_ID_ENV], authz_projects: ENV[AUTHZ_PROJECTS_ENV], authz_projects_file: ENV[AUTHZ_PROJECTS_FILE_ENV], authz_jwt_hs256_secret: ENV[AUTHZ_JWT_HS256_SECRET_ENV], authz_jwt_rs256_jwks_file: ENV[AUTHZ_JWT_RS256_JWKS_FILE_ENV], authz_session_store_file: ENV[AUTHZ_SESSION_STORE_FILE_ENV])
      @bridge = bridge
      @api_token = token_or_generate(api_token)
      @approval_token = approval_token.to_s.strip.empty? ? @api_token : approval_token.to_s
      @authz_mode = authz_mode.to_s.strip.empty? ? "local_token" : authz_mode.to_s.strip
      @authz_tenant_id = authz_tenant_id.to_s.strip
      @authz_user_id = authz_user_id.to_s.strip
      @authz_projects_file = authz_projects_file.to_s.strip
      @authz_project_registry_errors = []
      @authz_jwt_hs256_secret = authz_jwt_hs256_secret.to_s
      @authz_jwt_rs256_jwks_file = authz_jwt_rs256_jwks_file.to_s.strip
      @authz_session_store_file = authz_session_store_file.to_s.strip
      @authz_project_entries = normalize_authz_project_entries(authz_projects) + normalize_authz_project_entries(authz_project_file_raw)
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
            "authz_mode_env" => AUTHZ_MODE_ENV,
            "supported_authz_modes" => SUPPORTED_AUTHZ_MODES,
            "unsupported_authz_modes_fail_closed_for_project_routes" => true,
            "authz_tenant_id_env" => AUTHZ_TENANT_ID_ENV,
            "authz_user_id_env" => AUTHZ_USER_ID_ENV,
            "authz_project_allowlist_env" => AUTHZ_PROJECTS_ENV,
            "authz_project_registry_file_env" => AUTHZ_PROJECTS_FILE_ENV,
            "authz_project_registry_policy" => AUTHZ_PROJECT_REGISTRY_POLICY,
            "jwt_hs256_secret_env" => AUTHZ_JWT_HS256_SECRET_ENV,
            "jwt_rs256_jwks_file_env" => AUTHZ_JWT_RS256_JWKS_FILE_ENV,
            "session_store_file_env" => AUTHZ_SESSION_STORE_FILE_ENV,
            "authz_audit_path" => AUTHZ_AUDIT_PATH,
            "claim_headers" => {
              "tenant_id" => "X-Aiweb-Tenant-Id",
              "project_id" => "X-Aiweb-Project-Id",
              "user_id" => "X-Aiweb-User-Id"
            },
            "jwt_hs256" => {
              "authorization_header" => "Authorization",
              "algorithm" => "HS256",
              "secret_env" => AUTHZ_JWT_HS256_SECRET_ENV,
              "required_claims" => JWT_HS256_REQUIRED_CLAIMS,
              "claim_aliases" => JWT_HS256_CLAIM_ALIASES
            },
            "jwt_rs256_jwks" => {
              "authorization_header" => "Authorization",
              "algorithm" => "RS256",
              "jwks_file_env" => AUTHZ_JWT_RS256_JWKS_FILE_ENV,
              "jwks_source" => "local_file_only_no_oidc_discovery",
              "required_claims" => JWT_HS256_REQUIRED_CLAIMS,
              "claim_aliases" => JWT_HS256_CLAIM_ALIASES
            },
            "session_token" => {
              "authorization_header" => "Authorization",
              "session_store_file_env" => AUTHZ_SESSION_STORE_FILE_ENV,
              "token_storage" => "sha256_hash_only",
              "required_claims" => SESSION_TOKEN_REQUIRED_CLAIMS
            },
            "project_id_source" => "server_configured_project_allowlist",
            "role_source" => "server_configured_project_allowlist",
            "role_hierarchy" => AUTHZ_ROLE_LEVELS.keys,
            "route_required_roles" => AUTHZ_ACTION_REQUIRED_ROLES,
            "artifact_acl_policy" => ARTIFACT_ACL_POLICY,
            "api_token_configured" => !ENV[API_TOKEN_ENV].to_s.empty?,
            "approval_token_configured" => !ENV[APPROVAL_TOKEN_ENV].to_s.empty?,
            "claim_enforced_mode" => %w[claims jwt_hs256 jwt_rs256_jwks session_token].include?(ENV[AUTHZ_MODE_ENV].to_s),
            "claim_mode_requires_server_project_allowlist" => true
          },
          "guardrails" => [
            "bind only to localhost-class hosts for local-first use",
            "reject non-local browser origins at the daemon boundary",
            "require a local API token for every /api/* request",
            "when AIWEB_DAEMON_AUTHZ_MODE=claims, require tenant/project/user claims and a server-configured project allowlist for every project-scoped API action",
            "when AIWEB_DAEMON_AUTHZ_MODE=jwt_hs256, require a verified Authorization bearer HS256 JWT plus the same server-configured project allowlist and role ACL",
            "when AIWEB_DAEMON_AUTHZ_MODE=jwt_rs256_jwks, require a verified Authorization bearer RS256 JWT against a local JWKS file plus the same server-configured project allowlist and role ACL",
            "when AIWEB_DAEMON_AUTHZ_MODE=session_token, require an Authorization bearer token whose sha256 hash exists in AIWEB_DAEMON_SESSION_STORE_FILE plus the same server-configured project allowlist and role ACL",
            "claim mode authorizes server-configured roles per route and records append-only authz audit evidence",
            "optional AIWEB_DAEMON_AUTHZ_PROJECTS_FILE JSON registry can supply tenant/project/user membership and roles without trusting client claims",
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
        "GET /api/project/run-events-sse?path=PROJECT_PATH&run_id=RUN_ID&cursor=N",
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
        json(200, bridge_run(project_path: authorized_project_path!(query["path"], headers, action: "view_status"), command: "status"))
      when ["GET", "/api/project/workbench"]
        json(200, bridge_run(project_path: authorized_project_path!(query["path"], headers, action: "view_workbench"), command: "workbench", args: [], dry_run: true))
      when ["GET", "/api/project/console"]
        json(200, console_payload(authorized_project_path!(query["path"], headers, action: "view_console")))
      when ["GET", "/api/project/runs"]
        json(200, runs_payload(authorized_project_path!(query["path"], headers, action: "view_runs")))
      when ["GET", "/api/project/run"]
        json(200, run_detail_payload(authorized_project_path!(query["path"], headers, action: "view_run"), query["run_id"] || query["run"]))
      when ["GET", "/api/project/run-stream"]
        json(200, run_stream_payload(authorized_project_path!(query["path"], headers, action: "view_events"), query["run_id"] || query["run"], query["cursor"], query["limit"], query["wait_ms"]))
      when ["GET", "/api/project/run-events-sse"]
        sse(200, run_events_sse_body(authorized_project_path!(query["path"], headers, action: "view_events"), query["run_id"] || query["run"], query["cursor"], query["limit"], query["wait_ms"]))
      when ["GET", "/api/project/run-events"]
        json(200, run_events_payload(authorized_project_path!(query["path"], headers, action: "view_events"), query["run_id"] || query["run"]))
      when ["GET", "/api/project/approvals"]
        json(200, approvals_payload(authorized_project_path!(query["path"], headers, action: "view_approvals")))
      when ["GET", "/api/project/job/status"]
        json(200, job_status_payload(authorized_project_path!(query["path"], headers, action: "view_job_status"), query["run_id"] || query["run"]))
      when ["GET", "/api/project/job/timeline"]
        json(200, job_timeline_payload(authorized_project_path!(query["path"], headers, action: "view_job_timeline"), query["limit"]))
      when ["GET", "/api/project/job/summary"]
        json(200, job_summary_payload(authorized_project_path!(query["path"], headers, action: "view_job_summary"), query["limit"]))
      when ["GET", "/api/project/artifact"]
        artifact_root = authorized_project_path!(query["path"], headers, action: "view_artifact")
        json(200, artifact_payload(artifact_root, query["artifact"] || query["file"] || query["artifact_path"], headers: headers))
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

    def normalize_authz_project_entries(value)
      raw = normalize_authz_project_raw(value)
      entries = case raw
                when Hash
                  if raw.key?("tenants")
                    authz_tenant_registry_entries(raw)
                  elsif raw.key?("projects")
                    Array(raw.fetch("projects"))
                  else
                    raw.map do |project_id, project_value|
                      project_value.is_a?(Hash) ? project_value.merge("project_id" => project_id) : { "project_id" => project_id, "root" => project_value }
                    end
                  end
                when Array
                  raw
                else
                  []
                end

      entries.each_with_object([]) do |entry, memo|
        next unless entry.is_a?(Hash)

        root = entry["root"] || entry["path"] || entry["project_root"]
        project_id = entry["project_id"] || entry["id"]
        tenant_id = entry["tenant_id"] || authz_tenant_id
        user_ids = authz_entry_user_ids(entry)
        roles_by_user = authz_entry_roles_by_user(entry, user_ids)
        next if root.to_s.strip.empty? || project_id.to_s.strip.empty?

        memo << {
          root: File.expand_path(root.to_s),
          project_id: project_id.to_s.strip,
          tenant_id: tenant_id.to_s.strip,
          user_ids: user_ids,
          roles_by_user: roles_by_user
        }
      end
    end

    def authz_project_file_raw
      return [] if authz_projects_file.empty?

      if unsafe_env_path?(authz_projects_file)
        authz_project_registry_errors << "#{AUTHZ_PROJECTS_FILE_ENV} must not point at .env/.env.*"
        return []
      end

      path = File.expand_path(authz_projects_file)
      unless File.file?(path)
        authz_project_registry_errors << "#{AUTHZ_PROJECTS_FILE_ENV} does not exist"
        return []
      end

      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      authz_project_registry_errors << "#{AUTHZ_PROJECTS_FILE_ENV} JSON parse failed: #{e.message}"
      []
    rescue SystemCallError => e
      authz_project_registry_errors << "#{AUTHZ_PROJECTS_FILE_ENV} read failed: #{e.class}"
      []
    end

    def authz_tenant_registry_entries(raw)
      Array(raw["tenants"]).flat_map do |tenant|
        next [] unless tenant.is_a?(Hash)

        tenant_id = (tenant["tenant_id"] || tenant["id"]).to_s.strip
        tenant_roles = authz_registry_member_roles(tenant["members"] || tenant["users"])
        Array(tenant["projects"]).filter_map do |project|
          next unless project.is_a?(Hash)

          project_roles = tenant_roles.merge(authz_registry_member_roles(project["members"] || project["users"])) do |_user_id, tenant_user_roles, project_user_roles|
            (Array(tenant_user_roles) + Array(project_user_roles)).uniq
          end
          explicit_user_ids = Array(project["user_ids"] || project["allowed_user_ids"]).flat_map { |item| item.to_s.split(",") }.map(&:strip).reject(&:empty?)
          explicit_user_ids.each do |user_id|
            project_roles[user_id] ||= normalize_authz_roles_config(project["roles"] || project["role"], default: ["viewer"], context: "authz project #{project["project_id"] || project["id"] || "unknown"} user #{user_id} roles")
          end
          user_ids = project_roles.keys
          project.merge(
            "tenant_id" => tenant_id,
            "user_ids" => user_ids,
            "user_roles" => project_roles
          )
        end
      end
    end

    def authz_registry_member_roles(value)
      case value
      when Hash
        value.each_with_object({}) do |(user_id, roles), memo|
          normalized_user = user_id.to_s.strip
          next if normalized_user.empty?

          normalized_roles = normalize_authz_roles_config(roles, default: ["viewer"], context: "authz project registry member #{normalized_user}")
          memo[normalized_user] = normalized_roles
        end
      else
        Array(value).each_with_object({}) do |member, memo|
          next unless member.is_a?(Hash)

          user_id = (member["user_id"] || member["id"] || member["sub"]).to_s.strip
          next if user_id.empty?

          roles = normalize_authz_roles_config(member["roles"] || member["role"], default: ["viewer"], context: "authz project registry member #{user_id}")
          memo[user_id] = roles
        end
      end
    end

    def normalize_authz_project_raw(value)
      return [] if value.nil?
      return value unless value.is_a?(String)

      text = value.strip
      return [] if text.empty?

      JSON.parse(text)
    rescue JSON::ParserError
      []
    end

    def authz_entry_user_ids(entry)
      ids = []
      ids.concat(authz_split_user_ids(entry["user_ids"] || entry["allowed_user_ids"] || entry["user_id"]))
      ids.concat(authz_split_user_ids(entry["users"])) unless authz_member_collection?(entry["users"])
      ids.concat(authz_entry_member_roles(entry).keys)
      ids << authz_user_id if ids.empty? && !authz_user_id.empty?
      ids.map(&:strip).reject(&:empty?).uniq
    end

    def authz_entry_roles_by_user(entry, user_ids)
      raw_map = entry["user_roles"] || entry["roles_by_user"] || entry["role_map"]
      member_roles = authz_entry_member_roles(entry)
      default_roles = normalize_authz_roles_config(entry["roles"] || entry["role"], default: ["viewer"], context: "authz project #{entry["project_id"] || entry["id"] || "unknown"} default roles")
      user_ids.each_with_object({}) do |user_id, memo|
        configured = raw_map.is_a?(Hash) ? raw_map[user_id] || raw_map[user_id.to_s] : nil
        roles = if configured
                  normalize_authz_roles_config(configured, default: [], context: "authz project #{entry["project_id"] || entry["id"] || "unknown"} user #{user_id} roles")
                elsif member_roles[user_id.to_s]
                  member_roles[user_id.to_s]
                else
                  default_roles
                end
        memo[user_id.to_s] = roles
      end
    end

    def authz_entry_member_roles(entry)
      authz_registry_member_roles(entry["members"]).merge(authz_registry_member_roles(entry["users"])) do |_user_id, left_roles, right_roles|
        (Array(left_roles) + Array(right_roles)).uniq
      end
    end

    def authz_member_collection?(value)
      value.is_a?(Hash) || Array(value).any? { |item| item.is_a?(Hash) }
    end

    def authz_split_user_ids(value)
      Array(value).flat_map { |item| item.to_s.split(",") }.map(&:strip).reject(&:empty?)
    end

    def normalize_authz_roles_config(value, default:, context:)
      raw = Array(value).flat_map { |item| item.to_s.split(",") }.map(&:strip).reject(&:empty?)
      return Array(default) if raw.empty?

      normalized = raw.map(&:downcase)
      invalid = normalized.reject { |role| AUTHZ_ROLE_LEVELS.key?(role) }.uniq
      unless invalid.empty?
        authz_project_registry_errors << "#{context} contains invalid role(s): #{invalid.join(", ")}"
        return []
      end

      normalized.uniq
    end

    def normalize_authz_roles(value)
      Array(value).flat_map { |item| item.to_s.split(",") }.map(&:strip).reject(&:empty?).map(&:downcase).select { |role| AUTHZ_ROLE_LEVELS.key?(role) }.uniq
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

    def authorized_project_path!(value, headers, action:)
      text = required_project_path!(value)
      validate_project_claims!(text, headers, action: action)
      text
    end

    def claim_authz_enforced?
      %w[claims jwt_hs256 jwt_rs256_jwks session_token].include?(authz_mode)
    end

    def supported_authz_mode?
      SUPPORTED_AUTHZ_MODES.include?(authz_mode)
    end

    def validate_project_claims!(project_path, headers, action:, required_role: nil, artifact_path: nil, artifact_acl_category: nil)
      root = safe_project_path(project_path)
      unless supported_authz_mode?
        raise UserError.new("unsupported authz mode #{authz_mode.inspect} is fail-closed for project-scoped API action #{action}; supported modes are #{SUPPORTED_AUTHZ_MODES.join(", ")}; raw JWT/OIDC modes are not accepted without an explicit supported verifier", 5)
      end
      return unless claim_authz_enforced?

      required_role ||= authz_required_role(action)
      validate_claim_authz_configuration!(action: action)
      token_claims = case authz_mode
                     when "jwt_hs256"
                       verified_jwt_hs256_claims!(root, headers, action: action, required_role: required_role, artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
                     when "jwt_rs256_jwks"
                       verified_jwt_rs256_jwks_claims!(root, headers, action: action, required_role: required_role, artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
                     when "session_token"
                       verified_session_token_claims!(root, headers, action: action, required_role: required_role, artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
                     end
      tenant_id = token_claims ? token_claim_value(token_claims, "tenant_id") : headers[TENANT_ID_HEADER].to_s
      project_id = token_claims ? token_claim_value(token_claims, "project_id") : headers[PROJECT_ID_HEADER].to_s
      user_id = token_claims ? token_claim_value(token_claims, "user_id") : headers[USER_ID_HEADER].to_s
      missing = []
      missing << "tenant_id" if tenant_id.empty?
      missing << "project_id" if project_id.empty?
      missing << "user_id" if user_id.empty?
      authz_deny!(root, action, "tenant/project/user claims required for project-scoped API action #{action}: missing #{missing.join(", ")}", tenant_id: tenant_id, project_id: project_id, user_id: user_id, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category) unless missing.empty?

      if !authz_tenant_id.empty? && !secure_token_equal?(tenant_id, authz_tenant_id)
        authz_deny!(root, action, "tenant_id claim is not authorized for project-scoped API action #{action}", tenant_id: tenant_id, project_id: project_id, user_id: user_id, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end
      expected_project_id = backend_project_claim_id(root)
      unless secure_token_equal?(project_id, expected_project_id)
        authz_deny!(root, action, "project_id claim is not authorized for project-scoped API action #{action}", tenant_id: tenant_id, project_id: project_id, user_id: user_id, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end
      if !authz_user_id.empty? && !secure_token_equal?(user_id, authz_user_id)
        authz_deny!(root, action, "user_id claim is not authorized for project-scoped API action #{action}", tenant_id: tenant_id, project_id: project_id, user_id: user_id, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end
      matching_project = authz_project_entries.find do |entry|
        canonical_path_equal?(root, entry.fetch(:root)) &&
          secure_token_equal?(project_id, entry.fetch(:project_id)) &&
          secure_token_equal?(tenant_id, entry.fetch(:tenant_id)) &&
          entry.fetch(:user_ids).any? { |allowed_user| secure_token_equal?(user_id, allowed_user) }
      end
      unless matching_project
        authz_deny!(root, action, "project_id claim is not server-allowlisted for project-scoped API action #{action}", tenant_id: tenant_id, project_id: project_id, user_id: user_id, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end
      granted_roles = authz_roles_for_user(matching_project, user_id)
      unless authz_roles_allow?(granted_roles, required_role)
        authz_deny!(root, action, "role ACL denied project-scoped API action #{action}: requires #{required_role}", tenant_id: tenant_id, project_id: project_id, user_id: user_id, required_role: required_role, granted_roles: granted_roles, artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end
      append_authz_audit(root, action: action, decision: "allowed", reason: "server-configured tenant/project/user claims and role ACL authorized", tenant_id: tenant_id, project_id: project_id, user_id: user_id, required_role: required_role, granted_roles: granted_roles, artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
    end

    def validate_artifact_acl!(root, relative, headers, artifact_acl)
      return unless claim_authz_enforced?

      validate_project_claims!(
        root,
        headers,
        action: "view_artifact",
        required_role: artifact_acl.fetch("required_role"),
        artifact_path: relative,
        artifact_acl_category: artifact_acl.fetch("category")
      )
    end

    def authz_required_role(action)
      AUTHZ_ACTION_REQUIRED_ROLES.fetch(action.to_s, "admin")
    end

    def authz_roles_for_user(project_entry, user_id)
      roles_by_user = project_entry.fetch(:roles_by_user, {})
      roles_by_user[user_id.to_s] || ["viewer"]
    end

    def authz_roles_allow?(roles, required_role)
      required_level = AUTHZ_ROLE_LEVELS.fetch(required_role.to_s, AUTHZ_ROLE_LEVELS.fetch("admin"))
      Array(roles).any? { |role| AUTHZ_ROLE_LEVELS.fetch(role.to_s, 0) >= required_level }
    end

    def authz_deny!(root, action, message, tenant_id:, project_id:, user_id:, required_role:, granted_roles:, artifact_path: nil, artifact_acl_category: nil)
      append_authz_audit(root, action: action, decision: "denied", reason: message, tenant_id: tenant_id, project_id: project_id, user_id: user_id, required_role: required_role, granted_roles: granted_roles, artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      raise UserError.new(message, 5)
    end

    def append_authz_audit(root, action:, decision:, reason:, tenant_id:, project_id:, user_id:, required_role:, granted_roles:, artifact_path: nil, artifact_acl_category: nil)
      path = File.join(root, AUTHZ_AUDIT_PATH)
      FileUtils.mkdir_p(File.dirname(path))
      entry = {
        "schema_version" => 1,
        "event_type" => "backend.authz.decision",
        "recorded_at" => Time.now.utc.iso8601,
        "decision" => decision,
        "action" => action.to_s,
        "project_id" => project_id.to_s.empty? ? nil : project_id.to_s,
        "tenant_id_hash" => digest_claim(tenant_id),
        "user_id_hash" => digest_claim(user_id),
        "required_role" => required_role,
        "granted_roles" => Array(granted_roles),
        "authz_mode" => authz_mode,
        "role_source" => "server_configured_project_allowlist",
        "audit_path" => AUTHZ_AUDIT_PATH,
        "reason" => reason.to_s
      }
      entry["artifact_path"] = artifact_path if artifact_path
      entry["artifact_acl_category"] = artifact_acl_category if artifact_acl_category
      File.open(path, "a") { |file| file.write(JSON.generate(entry) + "\n") }
      AUTHZ_AUDIT_PATH
    rescue SystemCallError => e
      raise UserError.new("authz audit write failed for project-scoped API action #{action}: #{e.class}", 5)
    end

    def digest_claim(value)
      text = value.to_s
      return nil if text.empty?

      "sha256:#{Digest::SHA256.hexdigest(text)[0, 16]}"
    end

    def validate_claim_authz_configuration!(action:)
      missing = []
      token_backed_authz = %w[jwt_hs256 jwt_rs256_jwks session_token].include?(authz_mode)
      registry_membership_configured = authz_project_entries.any? { |entry| !entry.fetch(:tenant_id).to_s.empty? && !entry.fetch(:user_ids).empty? }
      missing << AUTHZ_TENANT_ID_ENV if authz_tenant_id.empty? && !registry_membership_configured && !token_backed_authz
      missing << AUTHZ_USER_ID_ENV if authz_user_id.empty? && !registry_membership_configured && !token_backed_authz
      missing.concat(authz_project_registry_errors)
      missing << "#{AUTHZ_PROJECTS_ENV} or #{AUTHZ_PROJECTS_FILE_ENV}" if authz_project_entries.empty?
      missing << AUTHZ_JWT_HS256_SECRET_ENV if authz_mode == "jwt_hs256" && authz_jwt_hs256_secret.to_s.empty?
      missing.concat(authz_jwt_rs256_jwks_configuration_errors) if authz_mode == "jwt_rs256_jwks"
      missing.concat(authz_session_store_configuration_errors) if authz_mode == "session_token"
      return if missing.empty?

      mode_label = case authz_mode
                   when "jwt_hs256" then "jwt_hs256 authz mode"
                   when "jwt_rs256_jwks" then "jwt_rs256_jwks authz mode"
                   when "session_token" then "session_token authz mode"
                   else "claims authz mode"
                   end
      raise UserError.new("#{mode_label} requires server-configured tenant/user pins or project registry membership, project allowlist, and configured token verifier when applicable before project-scoped API action #{action}: missing #{missing.join(", ")}", 5)
    end

    def verified_jwt_hs256_claims!(root, headers, action:, required_role:, artifact_path: nil, artifact_acl_category: nil)
      authorization = headers[AUTHORIZATION_HEADER].to_s
      match = authorization.match(/\ABearer\s+([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\z/i)
      unless match
        authz_deny!(root, action, "Authorization bearer JWT is required for jwt_hs256 project-scoped API action #{action}", tenant_id: nil, project_id: nil, user_id: nil, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end

      token = match[1]
      header_segment, payload_segment, signature_segment = token.split(".", 3)
      header = JSON.parse(base64url_decode(header_segment))
      payload = JSON.parse(base64url_decode(payload_segment))
      unless header.is_a?(Hash) && payload.is_a?(Hash)
        authz_deny!(root, action, "JWT header and payload must be JSON objects for jwt_hs256 project-scoped API action #{action}", tenant_id: nil, project_id: nil, user_id: nil, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end
      unless header["alg"].to_s == "HS256"
        authz_deny!(root, action, "JWT alg must be HS256 for jwt_hs256 project-scoped API action #{action}", tenant_id: nil, project_id: nil, user_id: nil, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end
      if header.key?("crit")
        authz_deny!(root, action, "JWT crit headers are not supported for jwt_hs256 project-scoped API action #{action}", tenant_id: nil, project_id: nil, user_id: nil, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end

      signing_input = "#{header_segment}.#{payload_segment}"
      expected_signature = Base64.urlsafe_encode64(OpenSSL::HMAC.digest("SHA256", authz_jwt_hs256_secret.to_s, signing_input), padding: false)
      unless secure_token_equal?(expected_signature, signature_segment.to_s)
        authz_deny!(root, action, "JWT signature is invalid for jwt_hs256 project-scoped API action #{action}", tenant_id: nil, project_id: nil, user_id: nil, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end

      now = Time.now.to_i
      if payload.key?("exp") && numeric_time(payload["exp"]) <= now
        authz_deny!(root, action, "JWT is expired for jwt_hs256 project-scoped API action #{action}", tenant_id: token_claim_value(payload, "tenant_id"), project_id: token_claim_value(payload, "project_id"), user_id: token_claim_value(payload, "user_id"), required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end
      if payload.key?("nbf") && numeric_time(payload["nbf"]) > now
        authz_deny!(root, action, "JWT is not yet valid for jwt_hs256 project-scoped API action #{action}", tenant_id: token_claim_value(payload, "tenant_id"), project_id: token_claim_value(payload, "project_id"), user_id: token_claim_value(payload, "user_id"), required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end

      payload
    rescue JSON::ParserError, ArgumentError
      authz_deny!(root, action, "JWT is malformed for jwt_hs256 project-scoped API action #{action}", tenant_id: nil, project_id: nil, user_id: nil, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
    end

    def verified_jwt_rs256_jwks_claims!(root, headers, action:, required_role:, artifact_path: nil, artifact_acl_category: nil)
      authorization = headers[AUTHORIZATION_HEADER].to_s
      match = authorization.match(/\ABearer\s+([A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)\z/i)
      unless match
        authz_deny!(root, action, "Authorization bearer JWT is required for jwt_rs256_jwks project-scoped API action #{action}", tenant_id: nil, project_id: nil, user_id: nil, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end

      token = match[1]
      header_segment, payload_segment, signature_segment = token.split(".", 3)
      header = JSON.parse(base64url_decode(header_segment))
      payload = JSON.parse(base64url_decode(payload_segment))
      unless header.is_a?(Hash) && payload.is_a?(Hash)
        authz_deny!(root, action, "JWT header and payload must be JSON objects for jwt_rs256_jwks project-scoped API action #{action}", tenant_id: nil, project_id: nil, user_id: nil, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end
      unless header["alg"].to_s == "RS256"
        authz_deny!(root, action, "JWT alg must be RS256 for jwt_rs256_jwks project-scoped API action #{action}", tenant_id: nil, project_id: nil, user_id: nil, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end
      if header.key?("crit")
        authz_deny!(root, action, "JWT crit headers are not supported for jwt_rs256_jwks project-scoped API action #{action}", tenant_id: nil, project_id: nil, user_id: nil, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end

      key = jwt_rs256_jwks_public_key(header)
      signature = base64url_decode(signature_segment)
      unless key.verify(OpenSSL::Digest::SHA256.new, signature, "#{header_segment}.#{payload_segment}")
        authz_deny!(root, action, "JWT signature is invalid for jwt_rs256_jwks project-scoped API action #{action}", tenant_id: nil, project_id: nil, user_id: nil, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end

      now = Time.now.to_i
      if payload.key?("exp") && numeric_time(payload["exp"]) <= now
        authz_deny!(root, action, "JWT is expired for jwt_rs256_jwks project-scoped API action #{action}", tenant_id: token_claim_value(payload, "tenant_id"), project_id: token_claim_value(payload, "project_id"), user_id: token_claim_value(payload, "user_id"), required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end
      if payload.key?("nbf") && numeric_time(payload["nbf"]) > now
        authz_deny!(root, action, "JWT is not yet valid for jwt_rs256_jwks project-scoped API action #{action}", tenant_id: token_claim_value(payload, "tenant_id"), project_id: token_claim_value(payload, "project_id"), user_id: token_claim_value(payload, "user_id"), required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end

      payload
    rescue JSON::ParserError, ArgumentError, OpenSSL::PKey::PKeyError, OpenSSL::ASN1::ASN1Error
      authz_deny!(root, action, "JWT is malformed or has no trusted local JWKS key for jwt_rs256_jwks project-scoped API action #{action}", tenant_id: nil, project_id: nil, user_id: nil, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
    end

    def verified_session_token_claims!(root, headers, action:, required_role:, artifact_path: nil, artifact_acl_category: nil)
      authorization = headers[AUTHORIZATION_HEADER].to_s
      match = authorization.match(/\ABearer\s+([A-Za-z0-9._~+\-]{16,})\z/)
      unless match
        authz_deny!(root, action, "Authorization bearer session token is required for session_token project-scoped API action #{action}", tenant_id: nil, project_id: nil, user_id: nil, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end

      errors = authz_session_store_configuration_errors
      authz_deny!(root, action, "session token store is not configured for project-scoped API action #{action}: #{errors.join(", ")}", tenant_id: nil, project_id: nil, user_id: nil, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category) unless errors.empty?

      token_hash = "sha256:#{Digest::SHA256.hexdigest(match[1])}"
      store = JSON.parse(File.read(File.expand_path(authz_session_store_file)))
      sessions = Array(store["sessions"] || store["tokens"])
      matching_sessions = sessions.select do |entry|
        next false unless entry.is_a?(Hash)

        stored_hash = normalize_session_token_hash(entry["token_hash"] || entry["sha256"])
        !stored_hash.empty? && secure_token_equal?(stored_hash, token_hash)
      end
      session = matching_sessions.first
      unless session
        authz_deny!(root, action, "session token is not authorized for project-scoped API action #{action}", tenant_id: nil, project_id: nil, user_id: nil, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end
      if matching_sessions.length > 1
        authz_deny!(root, action, "duplicate session token hash entries are not allowed for project-scoped API action #{action}", tenant_id: token_claim_value(session, "tenant_id"), project_id: token_claim_value(session, "project_id"), user_id: token_claim_value(session, "user_id"), required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end
      if truthy?(session["revoked"])
        authz_deny!(root, action, "session token is revoked for project-scoped API action #{action}", tenant_id: token_claim_value(session, "tenant_id"), project_id: token_claim_value(session, "project_id"), user_id: token_claim_value(session, "user_id"), required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end

      now = Time.now.to_i
      expires_at = session_token_time(session["expires_at"] || session["exp"])
      unless expires_at
        authz_deny!(root, action, "session token expiry is required for project-scoped API action #{action}", tenant_id: token_claim_value(session, "tenant_id"), project_id: token_claim_value(session, "project_id"), user_id: token_claim_value(session, "user_id"), required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end
      if expires_at <= now
        authz_deny!(root, action, "session token is expired for project-scoped API action #{action}", tenant_id: token_claim_value(session, "tenant_id"), project_id: token_claim_value(session, "project_id"), user_id: token_claim_value(session, "user_id"), required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end
      not_before = session_token_time(session["not_before"] || session["nbf"])
      if not_before && not_before > now
        authz_deny!(root, action, "session token is not yet valid for project-scoped API action #{action}", tenant_id: token_claim_value(session, "tenant_id"), project_id: token_claim_value(session, "project_id"), user_id: token_claim_value(session, "user_id"), required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      end

      session
    rescue JSON::ParserError, SystemCallError
      authz_deny!(root, action, "session token store is unreadable or malformed for project-scoped API action #{action}", tenant_id: nil, project_id: nil, user_id: nil, required_role: required_role, granted_roles: [], artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
    end

    def authz_jwt_rs256_jwks_configuration_errors
      return [AUTHZ_JWT_RS256_JWKS_FILE_ENV] if authz_jwt_rs256_jwks_file.empty?
      return ["#{AUTHZ_JWT_RS256_JWKS_FILE_ENV} must not point at .env/.env.*"] if unsafe_env_path?(authz_jwt_rs256_jwks_file)

      path = File.expand_path(authz_jwt_rs256_jwks_file)
      return ["#{AUTHZ_JWT_RS256_JWKS_FILE_ENV} does not exist"] unless File.file?(path)

      []
    end

    def jwt_rs256_jwks_public_key(header)
      kid = header["kid"].to_s
      raise ArgumentError, "JWT kid header is required" if kid.empty?

      jwks = JSON.parse(File.read(File.expand_path(authz_jwt_rs256_jwks_file)))
      keys = Array(jwks["keys"])
      matches = keys.select { |candidate| candidate.is_a?(Hash) && secure_token_equal?(candidate["kid"].to_s, kid) }
      raise ArgumentError, "no matching JWKS key" if matches.empty?
      raise ArgumentError, "duplicate JWKS kid entries are not allowed" if matches.length > 1

      jwk = matches.first
      raise ArgumentError, "JWKS key must be RSA" unless jwk["kty"].to_s == "RSA"
      raise ArgumentError, "JWKS key alg must be RS256" if jwk.key?("alg") && jwk["alg"].to_s != "RS256"
      raise ArgumentError, "JWKS key use must be sig" if jwk.key?("use") && jwk["use"].to_s != "sig"

      jwt_rs256_public_key_from_jwk(jwk)
    rescue JSON::ParserError, SystemCallError
      raise ArgumentError, "JWKS file is unreadable or malformed"
    end

    def jwt_rs256_public_key_from_jwk(jwk)
      modulus = OpenSSL::BN.new(base64url_decode(jwk.fetch("n")), 2)
      exponent = OpenSSL::BN.new(base64url_decode(jwk.fetch("e")), 2)
      rsa_sequence = OpenSSL::ASN1::Sequence([
        OpenSSL::ASN1::Integer(modulus),
        OpenSSL::ASN1::Integer(exponent)
      ])
      algorithm = OpenSSL::ASN1::Sequence([
        OpenSSL::ASN1::ObjectId("rsaEncryption"),
        OpenSSL::ASN1::Null(nil)
      ])
      public_key_info = OpenSSL::ASN1::Sequence([
        algorithm,
        OpenSSL::ASN1::BitString(rsa_sequence.to_der)
      ])
      OpenSSL::PKey.read(public_key_info.to_der)
    end

    def authz_session_store_configuration_errors
      return [AUTHZ_SESSION_STORE_FILE_ENV] if authz_session_store_file.empty?
      return ["#{AUTHZ_SESSION_STORE_FILE_ENV} must not point at .env/.env.*"] if unsafe_env_path?(authz_session_store_file)

      path = File.expand_path(authz_session_store_file)
      return ["#{AUTHZ_SESSION_STORE_FILE_ENV} does not exist"] unless File.file?(path)

      []
    end

    def normalize_session_token_hash(value)
      text = value.to_s.strip.downcase
      return "" if text.empty?
      text = "sha256:#{text}" if text.match?(/\A[a-f0-9]{64}\z/)
      return text if text.match?(/\Asha256:[a-f0-9]{64}\z/)

      ""
    end

    def session_token_time(value)
      return nil if value.nil? || value.to_s.strip.empty?
      return Integer(value) if value.is_a?(Integer) || value.to_s.match?(/\A\d+\z/)

      Time.iso8601(value.to_s).to_i
    rescue ArgumentError, TypeError
      0
    end

    def token_claim_value(claims, canonical_name)
      JWT_HS256_CLAIM_ALIASES.fetch(canonical_name).each do |name|
        value = claims[name]
        return value.to_s unless value.nil? || value.to_s.empty?
      end
      ""
    end

    def base64url_decode(value)
      text = value.to_s
      raise ArgumentError, "empty base64url segment" if text.empty? || text.match?(/[^A-Za-z0-9_-]/)

      Base64.urlsafe_decode64(text + ("=" * ((4 - text.length % 4) % 4)))
    end

    def numeric_time(value)
      Integer(value)
    end

    def backend_project_claim_id(root)
      entry = authz_project_entries.find { |candidate| canonical_path_equal?(root, candidate.fetch(:root)) }
      entry&.fetch(:project_id, nil).to_s
    end

    def canonical_path_equal?(left, right)
      left_path = File.expand_path(left.to_s)
      right_path = File.expand_path(right.to_s)
      if RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/i)
        left_path.casecmp?(right_path)
      else
        left_path == right_path
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
