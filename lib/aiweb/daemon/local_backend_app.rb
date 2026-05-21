# frozen_string_literal: true

require "digest"
require "fileutils"
require "base64"
require "openssl"
require "time"

require_relative "../authz_contract"
require_relative "../runtime/path_policy"
require_relative "local_backend_authz"
require_relative "local_backend_routes"

module Aiweb
  class LocalBackendApp
    include BackendArtifacts
    include BackendJobs
    include OpenManusReadiness
    include LocalBackendAuthz
    include Routes

    LOCAL_BIND_HOSTS = %w[127.0.0.1 localhost ::1].freeze
    LOCAL_ORIGIN_PATTERN = /\Ahttps?:\/\/(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?\z/.freeze
    API_TOKEN_ENV = Aiweb::AuthzContract::API_TOKEN_ENV
    APPROVAL_TOKEN_ENV = Aiweb::AuthzContract::APPROVAL_TOKEN_ENV
    API_TOKEN_HEADER = Aiweb::AuthzContract::API_TOKEN_HEADER
    APPROVAL_TOKEN_HEADER = Aiweb::AuthzContract::APPROVAL_TOKEN_HEADER
    AUTHZ_MODE_ENV = Aiweb::AuthzContract::AUTHZ_MODE_ENV
    AUTHZ_TENANT_ID_ENV = Aiweb::AuthzContract::AUTHZ_TENANT_ID_ENV
    AUTHZ_USER_ID_ENV = Aiweb::AuthzContract::AUTHZ_USER_ID_ENV
    AUTHZ_PROJECTS_ENV = Aiweb::AuthzContract::AUTHZ_PROJECTS_ENV
    AUTHZ_PROJECTS_FILE_ENV = Aiweb::AuthzContract::AUTHZ_PROJECTS_FILE_ENV
    AUTHZ_JWT_HS256_SECRET_ENV = Aiweb::AuthzContract::AUTHZ_JWT_HS256_SECRET_ENV
    AUTHZ_JWT_RS256_JWKS_FILE_ENV = Aiweb::AuthzContract::AUTHZ_JWT_RS256_JWKS_FILE_ENV
    AUTHZ_SESSION_STORE_FILE_ENV = Aiweb::AuthzContract::AUTHZ_SESSION_STORE_FILE_ENV
    AUTHZ_AUDIT_PATH = Aiweb::AuthzContract::AUTHZ_AUDIT_PATH
    AUTHORIZATION_HEADER = Aiweb::AuthzContract::AUTHORIZATION_HEADER
    TENANT_ID_HEADER = Aiweb::AuthzContract::TENANT_ID_HEADER
    PROJECT_ID_HEADER = Aiweb::AuthzContract::PROJECT_ID_HEADER
    USER_ID_HEADER = Aiweb::AuthzContract::USER_ID_HEADER
    CLAIM_HEADER_NAMES = Aiweb::AuthzContract::CLAIM_HEADER_NAMES
    JWT_HS256_REQUIRED_CLAIMS = Aiweb::AuthzContract::JWT_HS256_REQUIRED_CLAIMS
    JWT_HS256_CLAIM_ALIASES = Aiweb::AuthzContract::JWT_HS256_CLAIM_ALIASES
    SESSION_TOKEN_REQUIRED_CLAIMS = Aiweb::AuthzContract::SESSION_TOKEN_REQUIRED_CLAIMS
    AUTHZ_ROLE_LEVELS = Aiweb::AuthzContract::AUTHZ_ROLE_LEVELS
    AUTHZ_ACTION_REQUIRED_ROLES = Aiweb::AuthzContract::AUTHZ_ACTION_REQUIRED_ROLES
    ARTIFACT_ACL_POLICY = Aiweb::AuthzContract::ARTIFACT_ACL_POLICY
    AUTHZ_PROJECT_REGISTRY_POLICY = Aiweb::AuthzContract::AUTHZ_PROJECT_REGISTRY_POLICY
    SUPPORTED_AUTHZ_MODES = Aiweb::AuthzContract::SUPPORTED_AUTHZ_MODES
    CLAIM_ENFORCED_AUTHZ_MODES = Aiweb::AuthzContract::CLAIM_ENFORCED_AUTHZ_MODES
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
            "claim_enforced_mode" => Aiweb::AuthzContract.claim_enforced_mode?(ENV[AUTHZ_MODE_ENV]),
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
      route_response(method, path, query, headers, body)
    rescue UserError => e
      json(e.exit_code == 5 ? 403 : 400, error_payload(e.message, e.exit_code))
    rescue JSON::ParserError => e
      json(400, error_payload("invalid JSON body: #{e.message}", 1))
    rescue StandardError => e
      json(500, error_payload("#{e.class}: #{e.message}", 10))
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
      Aiweb::Runtime::PathPolicy.unsafe_env_path?(path)
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
