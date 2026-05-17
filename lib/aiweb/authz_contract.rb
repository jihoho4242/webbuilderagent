# frozen_string_literal: true

module Aiweb
  module AuthzContract
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
    REQUIRED_CLAIMS = %w[tenant_id project_id user_id].freeze
    JWT_HS256_REQUIRED_CLAIMS = REQUIRED_CLAIMS
    JWT_HS256_CLAIM_ALIASES = {
      "tenant_id" => %w[tenant_id tid],
      "project_id" => %w[project_id pid],
      "user_id" => %w[user_id sub]
    }.freeze
    SESSION_TOKEN_REQUIRED_CLAIMS = REQUIRED_CLAIMS
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
    CLAIM_ENFORCED_AUTHZ_MODES = %w[claims jwt_hs256 jwt_rs256_jwks session_token].freeze
    PROJECT_ID_SOURCE = "server_configured_project_allowlist"
    ROLE_SOURCE = "server_configured_project_allowlist"
    PROJECT_REGISTRY_SOURCE = "inline_env_or_file_json"
    JWT_HS256_STATUS = "local_hs256_supported_with_server_secret"
    JWT_RS256_JWKS_STATUS = "local_rs256_jwks_file_supported_no_oidc_discovery"
    SESSION_TOKEN_STATUS = "local_hashed_session_store_supported"
    SESSION_TOKEN_STORAGE = "sha256_hash_only"
    OIDC_STATUS = "not_implemented_fail_closed"
    RAW_JWT_OIDC_STATUS = "unsupported_modes_fail_closed"
    ENABLE_WITH = "AIWEB_DAEMON_AUTHZ_MODE=claims, AIWEB_DAEMON_AUTHZ_MODE=jwt_hs256, AIWEB_DAEMON_AUTHZ_MODE=jwt_rs256_jwks, or AIWEB_DAEMON_AUTHZ_MODE=session_token"

    module_function

    def copy(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, child), memo| memo[key] = copy(child) }
      when Array
        value.map { |child| copy(child) }
      else
        value
      end
    end

    def claim_enforced_mode?(mode)
      CLAIM_ENFORCED_AUTHZ_MODES.include?(mode.to_s)
    end

    def local_backend_claim_enforced_mode(route_required_roles:)
      shared_local_backend_fields("required_headers").merge(
        "available" => true,
        "enable_with" => ENABLE_WITH,
        "route_required_roles" => copy(route_required_roles),
        "project_allowlist_env" => AUTHZ_PROJECTS_ENV,
        "project_registry_file_env" => AUTHZ_PROJECTS_FILE_ENV,
        "server_project_allowlist_required" => true
      )
    end

    def local_backend_enforcement(route_required_roles:, route_permissions:)
      {
        "api_token_required_for_api_routes" => true,
        "approval_token_required_for_approved_execution" => true,
        "safe_project_path_required" => true,
        "artifact_reference_must_be_project_relative" => true,
        "raw_run_id_without_project_path_is_rejected" => true,
        "claim_enforced_project_authz_available" => true,
        "claim_enforced_mode_required_for_remote_exposure" => true
      }.merge(shared_local_backend_fields("claim_headers")).merge(
        "route_required_roles" => copy(route_required_roles),
        "server_project_allowlist_required" => true,
        "project_allowlist_env" => AUTHZ_PROJECTS_ENV,
        "project_registry_file_env" => AUTHZ_PROJECTS_FILE_ENV,
        "route_permissions" => copy(route_permissions)
      )
    end

    def shared_local_backend_fields(header_key)
      {
        "supported_authz_modes" => copy(SUPPORTED_AUTHZ_MODES),
        "unsupported_authz_modes_fail_closed_for_project_routes" => true,
        "jwt_hs256_status" => JWT_HS256_STATUS,
        "jwt_hs256_secret_env" => AUTHZ_JWT_HS256_SECRET_ENV,
        "jwt_hs256_required_claims" => copy(JWT_HS256_REQUIRED_CLAIMS),
        "jwt_hs256_claim_aliases" => copy(JWT_HS256_CLAIM_ALIASES),
        "jwt_rs256_jwks_status" => JWT_RS256_JWKS_STATUS,
        "jwt_rs256_jwks_file_env" => AUTHZ_JWT_RS256_JWKS_FILE_ENV,
        "jwt_rs256_jwks_required_claims" => copy(REQUIRED_CLAIMS),
        "session_token_status" => SESSION_TOKEN_STATUS,
        "session_store_file_env" => AUTHZ_SESSION_STORE_FILE_ENV,
        "session_token_storage" => SESSION_TOKEN_STORAGE,
        "session_token_required_claims" => copy(SESSION_TOKEN_REQUIRED_CLAIMS),
        "oidc_status" => OIDC_STATUS,
        "raw_jwt_oidc_status" => RAW_JWT_OIDC_STATUS,
        header_key => copy(CLAIM_HEADER_NAMES),
        "project_id_source" => PROJECT_ID_SOURCE,
        "role_source" => ROLE_SOURCE,
        "project_registry_source" => PROJECT_REGISTRY_SOURCE,
        "project_registry_policy" => copy(AUTHZ_PROJECT_REGISTRY_POLICY),
        "role_hierarchy" => copy(AUTHZ_ROLE_LEVELS.keys),
        "artifact_acl_policy" => copy(ARTIFACT_ACL_POLICY),
        "audit_path" => AUTHZ_AUDIT_PATH
      }
    end
  end
end
