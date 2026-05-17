# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "openssl"
require "rbconfig"
require "time"

require_relative "../errors"

module Aiweb
  module LocalBackendAuthz
    private

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
        authz_project_registry_errors << "#{self.class::AUTHZ_PROJECTS_FILE_ENV} must not point at .env/.env.*"
        return []
      end

      path = File.expand_path(authz_projects_file)
      unless File.file?(path)
        authz_project_registry_errors << "#{self.class::AUTHZ_PROJECTS_FILE_ENV} does not exist"
        return []
      end

      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      authz_project_registry_errors << "#{self.class::AUTHZ_PROJECTS_FILE_ENV} JSON parse failed: #{e.message}"
      []
    rescue SystemCallError => e
      authz_project_registry_errors << "#{self.class::AUTHZ_PROJECTS_FILE_ENV} read failed: #{e.class}"
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
      invalid = normalized.reject { |role| self.class::AUTHZ_ROLE_LEVELS.key?(role) }.uniq
      unless invalid.empty?
        authz_project_registry_errors << "#{context} contains invalid role(s): #{invalid.join(", ")}"
        return []
      end

      normalized.uniq
    end

    def normalize_authz_roles(value)
      Array(value).flat_map { |item| item.to_s.split(",") }.map(&:strip).reject(&:empty?).map(&:downcase).select { |role| self.class::AUTHZ_ROLE_LEVELS.key?(role) }.uniq
    end

    def validate_approval!(approved, headers)
      return unless approved

      supplied = headers[self.class::APPROVAL_TOKEN_HEADER].to_s
      supplied = headers[self.class::API_TOKEN_HEADER].to_s if supplied.empty? && approval_token == api_token
      if supplied.empty? || !secure_token_equal?(supplied, approval_token)
        raise UserError.new("approval token required for approved backend execution", 5)
      end
    end

    def validate_api_token!(headers)
      supplied = headers[self.class::API_TOKEN_HEADER].to_s
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
      self.class::CLAIM_ENFORCED_AUTHZ_MODES.include?(authz_mode)
    end

    def supported_authz_mode?
      self.class::SUPPORTED_AUTHZ_MODES.include?(authz_mode)
    end

    def validate_project_claims!(project_path, headers, action:, required_role: nil, artifact_path: nil, artifact_acl_category: nil)
      root = safe_project_path(project_path)
      unless supported_authz_mode?
        raise UserError.new("unsupported authz mode #{authz_mode.inspect} is fail-closed for project-scoped API action #{action}; supported modes are #{self.class::SUPPORTED_AUTHZ_MODES.join(", ")}; raw JWT/OIDC modes are not accepted without an explicit supported verifier", 5)
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
      tenant_id = token_claims ? token_claim_value(token_claims, "tenant_id") : headers[self.class::TENANT_ID_HEADER].to_s
      project_id = token_claims ? token_claim_value(token_claims, "project_id") : headers[self.class::PROJECT_ID_HEADER].to_s
      user_id = token_claims ? token_claim_value(token_claims, "user_id") : headers[self.class::USER_ID_HEADER].to_s
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
      self.class::AUTHZ_ACTION_REQUIRED_ROLES.fetch(action.to_s, "admin")
    end

    def authz_roles_for_user(project_entry, user_id)
      roles_by_user = project_entry.fetch(:roles_by_user, {})
      roles_by_user[user_id.to_s] || ["viewer"]
    end

    def authz_roles_allow?(roles, required_role)
      required_level = self.class::AUTHZ_ROLE_LEVELS.fetch(required_role.to_s, self.class::AUTHZ_ROLE_LEVELS.fetch("admin"))
      Array(roles).any? { |role| self.class::AUTHZ_ROLE_LEVELS.fetch(role.to_s, 0) >= required_level }
    end

    def authz_deny!(root, action, message, tenant_id:, project_id:, user_id:, required_role:, granted_roles:, artifact_path: nil, artifact_acl_category: nil)
      append_authz_audit(root, action: action, decision: "denied", reason: message, tenant_id: tenant_id, project_id: project_id, user_id: user_id, required_role: required_role, granted_roles: granted_roles, artifact_path: artifact_path, artifact_acl_category: artifact_acl_category)
      raise UserError.new(message, 5)
    end

    def append_authz_audit(root, action:, decision:, reason:, tenant_id:, project_id:, user_id:, required_role:, granted_roles:, artifact_path: nil, artifact_acl_category: nil)
      path = File.join(root, self.class::AUTHZ_AUDIT_PATH)
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
        "audit_path" => self.class::AUTHZ_AUDIT_PATH,
        "reason" => reason.to_s
      }
      entry["artifact_path"] = artifact_path if artifact_path
      entry["artifact_acl_category"] = artifact_acl_category if artifact_acl_category
      File.open(path, "a") { |file| file.write(JSON.generate(entry) + "\n") }
      self.class::AUTHZ_AUDIT_PATH
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
      token_backed_authz = self.class::CLAIM_ENFORCED_AUTHZ_MODES.include?(authz_mode) && authz_mode != "claims"
      registry_membership_configured = authz_project_entries.any? { |entry| !entry.fetch(:tenant_id).to_s.empty? && !entry.fetch(:user_ids).empty? }
      missing << self.class::AUTHZ_TENANT_ID_ENV if authz_tenant_id.empty? && !registry_membership_configured && !token_backed_authz
      missing << self.class::AUTHZ_USER_ID_ENV if authz_user_id.empty? && !registry_membership_configured && !token_backed_authz
      missing.concat(authz_project_registry_errors)
      missing << "#{self.class::AUTHZ_PROJECTS_ENV} or #{self.class::AUTHZ_PROJECTS_FILE_ENV}" if authz_project_entries.empty?
      missing << self.class::AUTHZ_JWT_HS256_SECRET_ENV if authz_mode == "jwt_hs256" && authz_jwt_hs256_secret.to_s.empty?
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
      authorization = headers[self.class::AUTHORIZATION_HEADER].to_s
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
      authorization = headers[self.class::AUTHORIZATION_HEADER].to_s
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
      authorization = headers[self.class::AUTHORIZATION_HEADER].to_s
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
      return [self.class::AUTHZ_JWT_RS256_JWKS_FILE_ENV] if authz_jwt_rs256_jwks_file.empty?
      return ["#{self.class::AUTHZ_JWT_RS256_JWKS_FILE_ENV} must not point at .env/.env.*"] if unsafe_env_path?(authz_jwt_rs256_jwks_file)

      path = File.expand_path(authz_jwt_rs256_jwks_file)
      return ["#{self.class::AUTHZ_JWT_RS256_JWKS_FILE_ENV} does not exist"] unless File.file?(path)

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
      return [self.class::AUTHZ_SESSION_STORE_FILE_ENV] if authz_session_store_file.empty?
      return ["#{self.class::AUTHZ_SESSION_STORE_FILE_ENV} must not point at .env/.env.*"] if unsafe_env_path?(authz_session_store_file)

      path = File.expand_path(authz_session_store_file)
      return ["#{self.class::AUTHZ_SESSION_STORE_FILE_ENV} does not exist"] unless File.file?(path)

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
      self.class::JWT_HS256_CLAIM_ALIASES.fetch(canonical_name).each do |name|
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
  end
end
