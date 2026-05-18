# frozen_string_literal: true

module Aiweb
  module LocalBackendAuthz
    private

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
  end
end
