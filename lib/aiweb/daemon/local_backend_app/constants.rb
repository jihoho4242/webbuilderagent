# frozen_string_literal: true

module Aiweb
  class LocalBackendApp
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
  end
end
