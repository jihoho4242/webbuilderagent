# frozen_string_literal: true

require "base64"
require "digest"
require "fileutils"
require "json"
require "openssl"
require "securerandom"
require "tmpdir"

module AiwebDaemonHarness
  REPO_ROOT = File.expand_path("../..", __dir__)
  API_TOKEN = "test-api-token"
  APPROVAL_TOKEN = "test-approval-token"

  def in_tmp
    Dir.mktmpdir("aiweb-daemon-test-") { |dir| yield dir }
  end

  def fake_engine_root(base_dir, script_body)
    engine_root = File.join(base_dir, "fake-engine-root-#{SecureRandom.hex(4)}")
    FileUtils.mkdir_p(File.join(engine_root, "bin"))
    File.write(File.join(engine_root, "bin", "aiweb"), script_body)
    engine_root
  end

  def app
    Aiweb::LocalBackendApp.new(
      bridge: Aiweb::CodexCliBridge.new(engine_root: REPO_ROOT),
      api_token: API_TOKEN,
      approval_token: APPROVAL_TOKEN
    )
  end

  def api_headers(extra = {})
    { "X-Aiweb-Token" => API_TOKEN }.merge(extra)
  end

  def approval_headers(extra = {})
    api_headers({ "X-Aiweb-Approval-Token" => APPROVAL_TOKEN }.merge(extra))
  end

  def project_claim_id(path)
    "project-#{Digest::SHA256.hexdigest(File.expand_path(path))[0, 12]}"
  end

  def claim_project_allowlist(path, project_id: project_claim_id(path), roles: "admin", user_roles: nil)
    [
      {
        "project_id" => project_id,
        "root" => path,
        "tenant_id" => "tenant-a",
        "user_ids" => ["user-a"],
        "roles" => roles,
        "user_roles" => user_roles
      }
    ]
  end

  def claim_headers(path, extra = {})
    api_headers(
      {
        "X-Aiweb-Tenant-Id" => "tenant-a",
        "X-Aiweb-Project-Id" => project_claim_id(path),
        "X-Aiweb-User-Id" => "user-a"
      }.merge(extra)
    )
  end

  def jwt_hs256_token(secret:, claims:, header: { "alg" => "HS256", "typ" => "JWT" })
    encoded_header = Base64.urlsafe_encode64(JSON.generate(header), padding: false)
    encoded_payload = Base64.urlsafe_encode64(JSON.generate(claims), padding: false)
    signing_input = "#{encoded_header}.#{encoded_payload}"
    signature = Base64.urlsafe_encode64(OpenSSL::HMAC.digest("SHA256", secret, signing_input), padding: false)
    "#{signing_input}.#{signature}"
  end

  def jwt_rs256_token(private_key:, claims:, kid:, header: { "alg" => "RS256", "typ" => "JWT" })
    encoded_header = Base64.urlsafe_encode64(JSON.generate(header.merge("kid" => kid)), padding: false)
    encoded_payload = Base64.urlsafe_encode64(JSON.generate(claims), padding: false)
    signing_input = "#{encoded_header}.#{encoded_payload}"
    signature = Base64.urlsafe_encode64(private_key.sign(OpenSSL::Digest::SHA256.new, signing_input), padding: false)
    "#{signing_input}.#{signature}"
  end

  def rsa_public_jwk(private_key, kid: "local-rs256-key")
    public_key = private_key.public_key
    {
      "kty" => "RSA",
      "kid" => kid,
      "alg" => "RS256",
      "use" => "sig",
      "n" => base64url_uint(public_key.n),
      "e" => base64url_uint(public_key.e)
    }
  end

  def base64url_uint(number)
    bytes = number.to_s(2).bytes.drop_while(&:zero?).pack("C*")
    Base64.urlsafe_encode64(bytes, padding: false)
  end

  def jwt_headers(path, secret: "jwt-local-secret", claims: {}, extra: {})
    token = jwt_hs256_token(
      secret: secret,
      claims: {
        "tenant_id" => "tenant-a",
        "project_id" => project_claim_id(path),
        "user_id" => "user-a",
        "exp" => Time.now.to_i + 300
      }.merge(claims)
    )
    api_headers({ "Authorization" => "Bearer #{token}" }.merge(extra))
  end

  def jwt_rs256_headers(path, private_key:, kid: "local-rs256-key", claims: {}, extra: {})
    token = jwt_rs256_token(
      private_key: private_key,
      kid: kid,
      claims: {
        "tenant_id" => "tenant-a",
        "project_id" => project_claim_id(path),
        "user_id" => "user-a",
        "exp" => Time.now.to_i + 300
      }.merge(claims)
    )
    api_headers({ "Authorization" => "Bearer #{token}" }.merge(extra))
  end

  def session_token_hash(token)
    "sha256:#{Digest::SHA256.hexdigest(token)}"
  end

  def session_headers(token = "session-token-1234567890", extra = {})
    api_headers({ "Authorization" => "Bearer #{token}" }.merge(extra))
  end
end
