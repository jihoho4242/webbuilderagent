# frozen_string_literal: true

module Aiweb
  module LocalBackendAuthz
    private

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
  end
end
