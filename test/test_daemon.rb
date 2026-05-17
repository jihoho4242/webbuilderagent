# frozen_string_literal: true

require "digest"
require "json"
require "fileutils"
require "base64"
require "openssl"
require "securerandom"
require "stringio"
require "tmpdir"
require "uri"
require "yaml"

require_relative "support/test_helper"

require "aiweb"

class AiwebDaemonTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)
  AIWEB = File.join(REPO_ROOT, "bin", "aiweb")
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

  class RecordingEngineBridge
    attr_reader :calls

    def initialize
      @calls = []
    end

    def metadata
      {
        "schema_version" => 1,
        "engine_root" => REPO_ROOT,
        "allowed_commands" => %w[engine-run]
      }
    end

    def engine_run(**kwargs)
      @calls << kwargs
      {
        "schema_version" => 1,
        "status" => "passed",
        "bridge" => {
          "command" => "engine-run",
          "project_path" => kwargs.fetch(:project_path),
          "goal" => kwargs[:goal],
          "agent" => kwargs[:agent],
          "mode" => kwargs[:mode],
          "sandbox" => kwargs[:sandbox],
          "max_cycles" => kwargs[:max_cycles],
          "approval_hash" => kwargs[:approval_hash],
          "resume" => kwargs[:resume],
          "run_id" => kwargs[:run_id],
          "dry_run" => kwargs[:dry_run],
          "approved" => kwargs[:approved]
        },
        "stdout_json" => {
          "engine_run" => {
            "status" => kwargs[:dry_run] ? "dry_run" : "passed",
            "run_id" => kwargs[:run_id] || kwargs[:resume] || "engine-run-test"
          }
        }
      }
    end

    def run(**kwargs)
      @calls << kwargs.merge(kind: :bridge_run)
      {
        "schema_version" => 1,
        "status" => "passed",
        "bridge" => {
          "command" => kwargs[:command],
          "project_path" => kwargs[:project_path],
          "args" => kwargs[:args],
          "dry_run" => kwargs[:dry_run],
          "approved" => kwargs[:approved]
        },
        "stdout_json" => {
          "action_taken" => "recorded #{kwargs[:command]}"
        }
      }
    end

    def agent_run(**kwargs)
      @calls << kwargs.merge(kind: :agent_run)
      {
        "schema_version" => 1,
        "status" => "passed",
        "bridge" => {
          "command" => "agent-run",
          "project_path" => kwargs[:project_path],
          "task" => kwargs[:task],
          "agent" => kwargs[:agent],
          "sandbox" => kwargs[:sandbox],
          "dry_run" => kwargs[:dry_run],
          "approved" => kwargs[:approved]
        },
        "stdout_json" => {
          "agent_run" => {
            "status" => kwargs[:dry_run] ? "dry_run" : "passed",
            "agent" => kwargs[:agent]
          }
        }
      }
    end
  end

  def test_bridge_default_engine_root_points_to_repo_bin
    bridge = Aiweb::CodexCliBridge.new

    assert_equal REPO_ROOT, bridge.engine_root
    assert_equal AIWEB, bridge.aiweb_bin
    assert File.file?(bridge.aiweb_bin), "default bridge should execute repo bin/aiweb"
  end

  def test_bridge_records_backend_side_effect_broker_for_cli_execution
    in_tmp do |dir|
      bridge = Aiweb::CodexCliBridge.new(engine_root: REPO_ROOT)

      result = bridge.run(project_path: dir, command: "init", args: ["--profile", "D"])

      assert_equal "passed", result["status"]
      broker = result.dig("bridge", "side_effect_broker")
      assert_equal "aiweb.backend.side_effect_broker", broker["broker"]
      assert_equal "backend.aiweb_cli", broker["scope"]
      assert_equal true, broker["events_recorded"]
      assert_match(%r{\A\.ai-web/runs/backend-bridge-[^/]+/side-effect-broker\.jsonl\z}, broker["events_path"])
      broker_path = File.join(dir, broker["events_path"])
      assert File.file?(broker_path), "backend bridge should persist side-effect broker evidence"
      events = File.readlines(broker_path, chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[tool.requested policy.decision tool.started tool.finished], events.map { |event| event["event"] }
      assert_equal "allow", events.find { |event| event["event"] == "policy.decision" }["decision"]
      assert_equal "passed", events.last["status"]
      assert_equal "init", events.last["target"]
      refute_includes JSON.generate(events), ".env"

      redacted = bridge.send(:redact_broker_command, ["bin/aiweb", "--token", "secret-token", "--api-key=secret-key", "--safe", "visible"])
      assert_equal ["bin/aiweb", "--token", "[REDACTED]", "[REDACTED]", "--safe", "visible"], redacted
    end
  end

  def test_bridge_public_response_redacts_secret_args
    in_tmp do |dir|
      engine_root = fake_engine_root(dir, "puts '{\"schema_version\":1,\"status\":\"ok\"}'\n")
      project_dir = File.join(dir, "project")
      FileUtils.mkdir_p(project_dir)
      bridge = Aiweb::CodexCliBridge.new(engine_root: engine_root, allowed_commands: ["status"])

      result = bridge.run(
        project_path: project_dir,
        command: "status",
        args: ["--api-key=super-secret-123", "--token", "second-secret-456"]
      )

      encoded = JSON.generate(result)
      refute_includes encoded, "super-secret-123"
      refute_includes encoded, "second-secret-456"
      assert_includes result.dig("bridge", "args"), "[REDACTED]"
      assert_includes result.dig("bridge", "argv"), "[REDACTED]"
      assert_equal false, result.dig("bridge", "side_effect_broker", "events_recorded")
    end
  end

  def test_bridge_broker_blocks_disallowed_deploy_and_keeps_read_only_inline
    in_tmp do |dir|
      bridge = Aiweb::CodexCliBridge.new(engine_root: REPO_ROOT)

      error = assert_raises(Aiweb::UserError) do
        bridge.run(project_path: dir, command: "deploy", dry_run: false)
      end
      assert_match(/dry-run only/, error.message)
      blocked_path = Dir.glob(File.join(dir, ".ai-web", "runs", "backend-bridge-*", "side-effect-broker.jsonl")).first
      assert blocked_path, "blocked deploy should leave broker denial evidence"
      blocked_events = File.readlines(blocked_path, chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[tool.requested policy.decision tool.blocked], blocked_events.map { |event| event["event"] }
      assert_equal "deny", blocked_events.find { |event| event["event"] == "policy.decision" }["decision"]
      assert_equal "blocked", blocked_events.last["status"]

      read_only_dir = File.join(dir, "read-only")
      FileUtils.mkdir_p(read_only_dir)
      status = bridge.run(project_path: read_only_dir, command: "status", dry_run: true)
      broker = status.dig("bridge", "side_effect_broker")
      assert_equal false, broker["events_recorded"]
      refute broker.key?("events_path"), "read-only inline broker should not write a project evidence path"
      assert_equal %w[tool.requested policy.decision tool.started tool.finished], status.dig("bridge", "side_effect_broker_events").map { |event| event["event"] }
      assert_empty Dir.glob(File.join(read_only_dir, ".ai-web", "runs", "backend-bridge-*", "side-effect-broker.jsonl"))

      dry_run_engine_root = fake_engine_root(dir, "puts '{\"schema_version\":1,\"status\":\"planned\"}'\n")
      dry_run_dir = File.join(dir, "dry-run-mutating")
      FileUtils.mkdir_p(dry_run_dir)
      dry_run_bridge = Aiweb::CodexCliBridge.new(engine_root: dry_run_engine_root, allowed_commands: ["init"])
      planned = dry_run_bridge.run(project_path: dry_run_dir, command: "init", dry_run: true)
      assert_equal false, planned.dig("bridge", "side_effect_broker", "events_recorded")
      refute planned.dig("bridge", "side_effect_broker").key?("events_path"), "dry-run mutating bridge command should keep broker evidence inline"
      assert_empty Dir.glob(File.join(dry_run_dir, ".ai-web", "runs", "backend-bridge-*", "side-effect-broker.jsonl"))
    end
  end

  def test_bridge_broker_records_failed_event_on_timeout
    in_tmp do |dir|
      engine_root = fake_engine_root(dir, "sleep 3\n")
      project_dir = File.join(dir, "project")
      FileUtils.mkdir_p(project_dir)
      bridge = Aiweb::CodexCliBridge.new(engine_root: engine_root, allowed_commands: ["init"], command_timeout: 0.1)

      error = assert_raises(Aiweb::UserError) do
        bridge.run(project_path: project_dir, command: "init")
      end
      assert_match(/timed out/, error.message)
      broker_path = Dir.glob(File.join(project_dir, ".ai-web", "runs", "backend-bridge-*", "side-effect-broker.jsonl")).first
      assert broker_path, "timeout should persist backend bridge broker evidence"
      events = File.readlines(broker_path, chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[tool.requested policy.decision tool.started tool.failed], events.map { |event| event["event"] }
      assert_equal "failed", events.last["status"]
      assert_equal "Aiweb::UserError", events.last["error_class"]
    end
  end

  def test_daemon_plan_reports_backend_contract_and_absolute_engine_path
    payload = Aiweb::LocalBackendDaemon.plan(host: "127.0.0.1", port: 4242, bridge: Aiweb::CodexCliBridge.new(engine_root: REPO_ROOT))

    assert_equal "planned local backend daemon", payload["action_taken"]
    assert_equal "planned", payload.dig("backend", "status")
    assert_includes payload.dig("backend", "routes"), "POST /api/codex/agent-run"
    assert_includes payload.dig("backend", "routes"), "GET /api/engine/openmanus-readiness"
    assert_equal REPO_ROOT, payload.dig("backend", "bridge", "engine_root")
    assert_equal AIWEB, payload.dig("backend", "bridge", "aiweb_bin")
    assert_includes payload.dig("backend", "routes"), "GET /api/project/artifact?path=PROJECT_PATH&artifact=ARTIFACT_PATH"
    assert_includes payload.dig("backend", "routes"), "GET /api/project/console?path=PROJECT_PATH"
    assert_includes payload.dig("backend", "routes"), "GET /api/project/run?path=PROJECT_PATH&run_id=RUN_ID"
    assert_includes payload.dig("backend", "routes"), "GET /api/project/run-stream?path=PROJECT_PATH&run_id=RUN_ID&cursor=N"
    assert_includes payload.dig("backend", "routes"), "GET /api/project/run-events?path=PROJECT_PATH&run_id=RUN_ID"
    assert_includes payload.dig("backend", "routes"), "GET /api/project/approvals?path=PROJECT_PATH"
    assert_includes payload.dig("backend", "routes"), "GET /api/project/job/status?path=PROJECT_PATH&run_id=RUN_ID"
    assert_includes payload.dig("backend", "routes"), "GET /api/project/job/timeline?path=PROJECT_PATH&limit=N"
    assert_includes payload.dig("backend", "routes"), "GET /api/project/job/summary?path=PROJECT_PATH&limit=N"
    assert_includes payload.dig("backend", "routes"), "POST /api/engine/run"
    assert_includes payload.dig("backend", "routes"), "POST /api/engine/approve"
    assert_includes payload.dig("backend", "routes"), "POST /api/project/job/cancel"
    assert_includes payload.dig("backend", "routes"), "POST /api/project/job/resume"
    assert_includes payload.dig("backend", "bridge", "allowed_commands"), "agent-run"
    assert_includes payload.dig("backend", "bridge", "allowed_commands"), "engine-run"
    assert_includes payload.dig("backend", "bridge", "allowed_commands"), "verify-loop"
    assert_includes payload.dig("backend", "bridge", "allowed_commands"), "ingest-reference"
    assert_includes payload.dig("backend", "bridge", "guardrails"), "frontend sends structured JSON only; no raw shell commands"
    assert_includes payload.dig("backend", "bridge", "guardrails"), "backend bridge command execution is recorded through aiweb.backend.side_effect_broker evidence before process launch"
    assert_includes payload.dig("backend", "guardrails"), "engine-run is exposed only through dedicated job APIs, not the generic command bridge"
    assert_equal "AIWEB_DAEMON_TOKEN", payload.dig("backend", "auth", "api_token_env")
    assert_equal "X-Aiweb-Token", payload.dig("backend", "auth", "api_token_header")
    assert_equal "AIWEB_DAEMON_AUTHZ_MODE", payload.dig("backend", "auth", "authz_mode_env")
    assert_equal %w[local_token claims jwt_hs256 jwt_rs256_jwks session_token], payload.dig("backend", "auth", "supported_authz_modes")
    assert_equal true, payload.dig("backend", "auth", "unsupported_authz_modes_fail_closed_for_project_routes")
    assert_equal "AIWEB_DAEMON_AUTHZ_PROJECTS", payload.dig("backend", "auth", "authz_project_allowlist_env")
    assert_equal "server_configured_project_allowlist", payload.dig("backend", "auth", "project_id_source")
    assert_equal "server_configured_project_allowlist", payload.dig("backend", "auth", "role_source")
    assert_equal ".ai-web/authz/audit.jsonl", payload.dig("backend", "auth", "authz_audit_path")
    assert_equal "viewer", payload.dig("backend", "auth", "route_required_roles", "view_status")
    assert_equal "operator", payload.dig("backend", "auth", "route_required_roles", "run_start")
    assert_equal "admin", payload.dig("backend", "auth", "route_required_roles", "approve")
    assert_equal "local_backend_artifact_acl_v1", payload.dig("backend", "auth", "artifact_acl_policy", "policy")
    assert_equal "operator", payload.dig("backend", "auth", "artifact_acl_policy", "sensitive_artifact_role")
    assert_equal true, payload.dig("backend", "auth", "claim_mode_requires_server_project_allowlist")
    assert_equal "X-Aiweb-Project-Id", payload.dig("backend", "auth", "claim_headers", "project_id")
    assert_equal "AIWEB_DAEMON_AUTHZ_PROJECTS_FILE", payload.dig("backend", "auth", "authz_project_registry_file_env")
    assert_equal "local_backend_project_registry_v1", payload.dig("backend", "auth", "authz_project_registry_policy", "policy")
    assert_equal "AIWEB_DAEMON_JWT_HS256_SECRET", payload.dig("backend", "auth", "jwt_hs256_secret_env")
    assert_equal "Authorization", payload.dig("backend", "auth", "jwt_hs256", "authorization_header")
    assert_includes payload.dig("backend", "auth", "jwt_hs256", "required_claims"), "tenant_id"
    assert_equal "AIWEB_DAEMON_JWT_RS256_JWKS_FILE", payload.dig("backend", "auth", "jwt_rs256_jwks_file_env")
    assert_equal "local_file_only_no_oidc_discovery", payload.dig("backend", "auth", "jwt_rs256_jwks", "jwks_source")
    assert_equal "AIWEB_DAEMON_SESSION_STORE_FILE", payload.dig("backend", "auth", "session_store_file_env")
    assert_equal "sha256_hash_only", payload.dig("backend", "auth", "session_token", "token_storage")
  end

  def test_backend_claim_enforced_authz_requires_tenant_project_user_for_project_actions
    in_tmp do |dir|
      bridge = RecordingEngineBridge.new
      local_app = Aiweb::LocalBackendApp.new(
        bridge: bridge,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "claims",
        authz_tenant_id: "tenant-a",
        authz_user_id: "user-a",
        authz_projects: claim_project_allowlist(dir)
      )
      body = JSON.generate("path" => dir, "goal" => "claim scoped dry run", "dry_run" => true)

      status, payload = local_app.call("POST", "/api/engine/run", api_headers, body)
      assert_equal 403, status
      assert_match(/tenant\/project\/user claims|required/i, payload["error"])

      unconfigured_app = Aiweb::LocalBackendApp.new(
        bridge: bridge,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "claims",
        authz_tenant_id: "tenant-a",
        authz_user_id: "user-a"
      )
      status, payload = unconfigured_app.call("POST", "/api/engine/run", claim_headers(dir), body)
      assert_equal 403, status
      assert_match(/project allowlist|AIWEB_DAEMON_AUTHZ_PROJECTS/i, payload["error"])

      status, payload = local_app.call("POST", "/api/engine/run", claim_headers(dir, "X-Aiweb-Project-Id" => "sha256:wrong"), body)
      assert_equal 403, status
      assert_match(/project_id claim/i, payload["error"])

      status, payload = local_app.call("POST", "/api/engine/run", claim_headers(dir, "X-Aiweb-Tenant-Id" => "tenant-b"), body)
      assert_equal 403, status
      assert_match(/tenant_id claim/i, payload["error"])

      status, payload = local_app.call("POST", "/api/engine/run", claim_headers(dir, "X-Aiweb-User-Id" => "user-b"), body)
      assert_equal 403, status
      assert_match(/user_id claim/i, payload["error"])

      random_project_id_app = Aiweb::LocalBackendApp.new(
        bridge: bridge,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "claims",
        authz_tenant_id: "tenant-a",
        authz_user_id: "user-a",
        authz_projects: claim_project_allowlist(dir, project_id: "server-random-project-id")
      )
      status, payload = random_project_id_app.call("POST", "/api/engine/run", claim_headers(dir), body)
      assert_equal 403, status
      assert_match(/project_id claim/i, payload["error"])

      status, payload = random_project_id_app.call("POST", "/api/engine/run", claim_headers(dir, "X-Aiweb-Project-Id" => "server-random-project-id"), body)
      assert_equal 200, status
      assert_equal "passed", payload["status"]

      other_dir = File.join(dir, "other")
      FileUtils.mkdir_p(other_dir)
      status, payload = local_app.call("POST", "/api/engine/run", claim_headers(dir), JSON.generate("path" => other_dir, "goal" => "wrong root", "dry_run" => true))
      assert_equal 403, status
      assert_match(/server-allowlisted|project_id claim/i, payload["error"])

      status, payload = local_app.call("POST", "/api/engine/run", claim_headers(dir), body)
      assert_equal 200, status
      assert_equal "passed", payload["status"]
      assert_equal dir, bridge.calls.last[:project_path]

      run_id = "engine-run-claims"
      run_dir = File.join(dir, ".ai-web", "runs", run_id)
      FileUtils.mkdir_p(run_dir)
      File.write(File.join(run_dir, "events.jsonl"), JSON.generate("schema_version" => 1, "seq" => 1, "type" => "run.created") + "\n")
      encoded_path = URI.encode_www_form_component(dir)

      status, payload = local_app.call("GET", "/api/project/run-events?path=#{encoded_path}&run_id=#{run_id}", api_headers)
      assert_equal 403, status
      assert_match(/claims|required/i, payload["error"])

      status, payload = local_app.call("GET", "/api/project/run-events?path=#{encoded_path}&run_id=#{run_id}", claim_headers(dir))
      assert_equal 200, status
      assert_equal "ready", payload["status"]
      assert_equal run_id, payload["run_id"]
    end
  end

  def test_backend_unsupported_authz_mode_fails_closed_instead_of_falling_back_to_local_token
    in_tmp do |dir|
      bridge = RecordingEngineBridge.new
      jwt_app = Aiweb::LocalBackendApp.new(
        bridge: bridge,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "jwt"
      )
      encoded_path = URI.encode_www_form_component(dir)

      status, payload = jwt_app.call("GET", "/api/engine", api_headers)
      assert_equal 200, status
      assert_equal "jwt", payload.dig("authz", "mode")
      assert_equal true, payload.dig("authz", "unsupported_modes_fail_closed_for_project_routes")

      status, payload = jwt_app.call("GET", "/api/project/status?path=#{encoded_path}", api_headers)
      assert_equal 403, status
      assert_match(/unsupported authz mode.*jwt.*fail-closed/i, payload["error"])

      status, payload = jwt_app.call("POST", "/api/engine/run", api_headers, JSON.generate("path" => dir, "goal" => "jwt must not fallback", "dry_run" => true))
      assert_equal 403, status
      assert_match(/raw JWT\/OIDC modes are not accepted|explicit supported verifier/i, payload["error"])
      assert_empty bridge.calls
    end
  end

  def test_backend_jwt_hs256_authz_verifies_bearer_claims_and_preserves_role_acl
    in_tmp do |dir|
      bridge = RecordingEngineBridge.new
      secret = "jwt-local-secret"
      local_app = Aiweb::LocalBackendApp.new(
        bridge: bridge,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "jwt_hs256",
        authz_tenant_id: "tenant-a",
        authz_user_id: "user-a",
        authz_projects: claim_project_allowlist(dir, roles: "viewer"),
        authz_jwt_hs256_secret: secret
      )
      encoded_path = URI.encode_www_form_component(dir)

      status, payload = local_app.call("GET", "/api/engine", api_headers)
      assert_equal 200, status
      assert_equal "jwt_hs256", payload.dig("authz", "mode")
      assert_equal true, payload.dig("authz", "claim_enforced")
      assert_equal [], payload.dig("authz", "required_claim_headers")
      assert_equal "Authorization", payload.dig("authz", "authorization_header")
      assert_includes payload.dig("authz", "jwt_hs256_required_claims"), "project_id"

      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", api_headers)
      assert_equal 403, status
      assert_match(/Authorization bearer JWT|required/i, payload["error"])

      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", jwt_headers(dir, secret: secret))
      assert_equal 200, status, payload.inspect

      body = JSON.generate("path" => dir, "goal" => "viewer cannot start jwt run", "dry_run" => true)
      status, payload = local_app.call("POST", "/api/engine/run", jwt_headers(dir, secret: secret), body)
      assert_equal 403, status
      assert_match(/role ACL denied|requires operator/i, payload["error"])
      refute bridge.calls.any? { |call| call[:goal] == "viewer cannot start jwt run" }, "role-denied JWT run_start must not reach the bridge"

      audit_path = File.join(dir, ".ai-web", "authz", "audit.jsonl")
      entries = File.readlines(audit_path).map { |line| JSON.parse(line) }
      assert_equal "jwt_hs256", entries.last.fetch("authz_mode")
      assert_equal "server_configured_project_allowlist", entries.last.fetch("role_source")
      refute_match(/user-a|tenant-a|jwt-local-secret/, File.read(audit_path), "authz audit must hash identities and never record JWT secrets")

      admin_app = Aiweb::LocalBackendApp.new(
        bridge: bridge,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "jwt_hs256",
        authz_tenant_id: "tenant-a",
        authz_user_id: "user-a",
        authz_projects: claim_project_allowlist(dir, roles: "admin"),
        authz_jwt_hs256_secret: secret
      )
      status, payload = admin_app.call("POST", "/api/engine/run", jwt_headers(dir, secret: secret), body)
      assert_equal 200, status, payload.inspect
      assert_equal "passed", payload["status"]
    end
  end

  def test_backend_jwt_hs256_authz_rejects_invalid_expired_and_unconfigured_tokens
    in_tmp do |dir|
      secret = "jwt-local-secret"
      local_app = Aiweb::LocalBackendApp.new(
        bridge: RecordingEngineBridge.new,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "jwt_hs256",
        authz_tenant_id: "tenant-a",
        authz_user_id: "user-a",
        authz_projects: claim_project_allowlist(dir),
        authz_jwt_hs256_secret: secret
      )
      encoded_path = URI.encode_www_form_component(dir)

      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", jwt_headers(dir, secret: "wrong-secret"))
      assert_equal 403, status
      assert_match(/signature is invalid/i, payload["error"])

      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", jwt_headers(dir, secret: secret, claims: { "exp" => Time.now.to_i - 1 }))
      assert_equal 403, status
      assert_match(/expired/i, payload["error"])

      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", jwt_headers(dir, secret: secret, claims: { "project_id" => "project-wrong" }))
      assert_equal 403, status
      assert_match(/project_id claim/i, payload["error"])

      unsigned_headers = jwt_headers(dir, secret: secret, claims: {}, extra: {})
      unsigned_headers["Authorization"] = "Bearer #{jwt_hs256_token(secret: secret, header: { "alg" => "none" }, claims: { "tenant_id" => "tenant-a", "project_id" => project_claim_id(dir), "user_id" => "user-a" })}"
      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", unsigned_headers)
      assert_equal 403, status
      assert_match(/alg must be HS256/i, payload["error"])

      unconfigured_app = Aiweb::LocalBackendApp.new(
        bridge: RecordingEngineBridge.new,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "jwt_hs256",
        authz_tenant_id: "tenant-a",
        authz_user_id: "user-a",
        authz_projects: claim_project_allowlist(dir)
      )
      status, payload = unconfigured_app.call("GET", "/api/project/status?path=#{encoded_path}", jwt_headers(dir, secret: secret))
      assert_equal 403, status
      assert_match(/AIWEB_DAEMON_JWT_HS256_SECRET|jwt_hs256 authz mode/i, payload["error"])
    end
  end

  def test_backend_jwt_rs256_jwks_authz_verifies_local_jwks_and_project_acl
    in_tmp do |dir|
      bridge = RecordingEngineBridge.new
      private_key = OpenSSL::PKey::RSA.generate(2048)
      jwks_path = File.join(dir, "jwks.json")
      File.write(jwks_path, JSON.pretty_generate("keys" => [rsa_public_jwk(private_key, kid: "local-rs256-key")]))
      local_app = Aiweb::LocalBackendApp.new(
        bridge: bridge,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "jwt_rs256_jwks",
        authz_projects: claim_project_allowlist(dir, roles: "operator"),
        authz_jwt_rs256_jwks_file: jwks_path
      )
      encoded_path = URI.encode_www_form_component(dir)

      status, payload = local_app.call("GET", "/api/engine", api_headers)
      assert_equal 200, status
      assert_equal "jwt_rs256_jwks", payload.dig("authz", "mode")
      assert_equal true, payload.dig("authz", "claim_enforced")
      assert_equal true, payload.dig("authz", "jwt_rs256_jwks_file_configured")
      assert_equal "local_file_only_no_oidc_discovery", payload.dig("authz", "jwt_rs256_jwks_source")
      assert_includes payload.dig("authz", "jwt_rs256_jwks_required_claims"), "project_id"

      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", api_headers)
      assert_equal 403, status
      assert_match(/Authorization bearer JWT|required/i, payload["error"])

      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", jwt_rs256_headers(dir, private_key: private_key))
      assert_equal 200, status, payload.inspect

      body = JSON.generate("path" => dir, "goal" => "rs256 jwks run", "dry_run" => true)
      status, payload = local_app.call("POST", "/api/engine/run", jwt_rs256_headers(dir, private_key: private_key), body)
      assert_equal 200, status, payload.inspect
      assert_equal "passed", payload["status"]
      assert_equal "rs256 jwks run", bridge.calls.last[:goal]

      unknown_key = OpenSSL::PKey::RSA.generate(2048)
      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", jwt_rs256_headers(dir, private_key: unknown_key, kid: "unknown-key"))
      assert_equal 403, status
      assert_match(/malformed|trusted local JWKS key|signature/i, payload["error"])

      duplicate_jwks_path = File.join(dir, "duplicate-jwks.json")
      File.write(
        duplicate_jwks_path,
        JSON.pretty_generate(
          "keys" => [
            rsa_public_jwk(private_key, kid: "duplicate-key"),
            rsa_public_jwk(OpenSSL::PKey::RSA.generate(2048), kid: "duplicate-key")
          ]
        )
      )
      duplicate_key_app = Aiweb::LocalBackendApp.new(
        bridge: RecordingEngineBridge.new,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "jwt_rs256_jwks",
        authz_projects: claim_project_allowlist(dir, roles: "operator"),
        authz_jwt_rs256_jwks_file: duplicate_jwks_path
      )
      status, payload = duplicate_key_app.call("GET", "/api/project/status?path=#{encoded_path}", jwt_rs256_headers(dir, private_key: private_key, kid: "duplicate-key"))
      assert_equal 403, status
      assert_match(/malformed|trusted local JWKS key/i, payload["error"])

      hs_headers = jwt_headers(dir)
      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", hs_headers)
      assert_equal 403, status
      assert_match(/alg must be RS256|malformed/i, payload["error"])

      audit_path = File.join(dir, ".ai-web", "authz", "audit.jsonl")
      entries = File.readlines(audit_path).map { |line| JSON.parse(line) }
      assert_equal "jwt_rs256_jwks", entries.last.fetch("authz_mode")
      refute_match(/user-a|tenant-a|BEGIN RSA|PRIVATE KEY/, File.read(audit_path), "RS256 authz audit must hash identities and never record key material")
    end
  end

  def test_backend_claim_authz_loads_file_backed_tenant_project_registry
    in_tmp do |dir|
      registry_path = File.join(dir, "tenant-registry.json")
      File.write(
        registry_path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "tenants" => [
            {
              "tenant_id" => "tenant-a",
              "members" => [
                { "user_id" => "user-a", "roles" => ["viewer"] },
                { "user_id" => "ops-user", "roles" => ["operator"] }
              ],
              "projects" => [
                {
                  "project_id" => project_claim_id(dir),
                  "root" => dir,
                  "members" => [
                    { "user_id" => "admin-user", "roles" => ["admin"] }
                  ]
                }
              ]
            }
          ]
        )
      )
      bridge = RecordingEngineBridge.new
      local_app = Aiweb::LocalBackendApp.new(
        bridge: bridge,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "claims",
        authz_projects_file: registry_path
      )
      encoded_path = URI.encode_www_form_component(dir)

      status, payload = local_app.call("GET", "/api/engine", api_headers)
      assert_equal 200, status
      assert_equal true, payload.dig("authz", "project_registry_file_configured")
      assert_equal "AIWEB_DAEMON_AUTHZ_PROJECTS_FILE", payload.dig("authz", "project_registry_file_env")
      assert_equal "local_backend_project_registry_v1", payload.dig("authz", "project_registry_policy", "policy")
      assert_equal 1, payload.dig("authz", "configured_project_count")
      assert_empty payload.dig("authz", "project_registry_errors")

      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", claim_headers(dir))
      assert_equal 200, status, payload.inspect

      body = JSON.generate("path" => dir, "goal" => "viewer denied by registry", "dry_run" => true)
      status, payload = local_app.call("POST", "/api/engine/run", claim_headers(dir), body)
      assert_equal 403, status
      assert_match(/role ACL denied|requires operator/i, payload["error"])
      refute bridge.calls.any? { |call| call[:goal] == "viewer denied by registry" }, "viewer-denied registry run_start must not reach the bridge"

      status, payload = local_app.call("POST", "/api/engine/run", claim_headers(dir, "X-Aiweb-User-Id" => "ops-user"), body)
      assert_equal 200, status, payload.inspect
      assert_equal "passed", payload["status"]

      audit_path = File.join(dir, ".ai-web", "authz", "audit.jsonl")
      entries = File.readlines(audit_path).map { |line| JSON.parse(line) }
      assert_equal ["allowed", "denied", "allowed"], entries.last(3).map { |entry| entry.fetch("decision") }
      assert_equal "server_configured_project_allowlist", entries.last.fetch("role_source")
      refute_match(/ops-user|user-a|tenant-a/, File.read(audit_path), "registry-backed audit must hash raw tenant/user ids")
    end
  end

  def test_backend_claim_authz_project_registry_file_errors_fail_closed
    in_tmp do |dir|
      local_app = Aiweb::LocalBackendApp.new(
        bridge: RecordingEngineBridge.new,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "claims",
        authz_projects_file: File.join(dir, "missing-registry.json")
      )
      encoded_path = URI.encode_www_form_component(dir)

      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", claim_headers(dir))
      assert_equal 403, status
      assert_match(/AIWEB_DAEMON_AUTHZ_PROJECTS_FILE does not exist|AUTHZ_PROJECTS_FILE/i, payload["error"])
    end
  end

  def test_backend_claim_authz_invalid_roles_fail_closed_instead_of_escalating
    in_tmp do |dir|
      bridge = RecordingEngineBridge.new
      local_app = Aiweb::LocalBackendApp.new(
        bridge: bridge,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "claims",
        authz_projects: [
          {
            "project_id" => project_claim_id(dir),
            "root" => dir,
            "tenant_id" => "tenant-a",
            "user_ids" => ["user-a"],
            "roles" => "opreator"
          }
        ]
      )
      body = JSON.generate("path" => dir, "goal" => "invalid role must not escalate", "dry_run" => true)

      status, payload = local_app.call("POST", "/api/engine/run", claim_headers(dir), body)
      assert_equal 403, status
      assert_match(/invalid role|opreator/i, payload["error"])
      assert_empty bridge.calls
    end
  end

  def test_backend_claim_authz_flat_project_registry_honors_project_members
    in_tmp do |dir|
      bridge = RecordingEngineBridge.new
      local_app = Aiweb::LocalBackendApp.new(
        bridge: bridge,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "claims",
        authz_projects: {
          "projects" => [
            {
              "project_id" => project_claim_id(dir),
              "root" => dir,
              "tenant_id" => "tenant-a",
              "members" => [
                { "user_id" => "ops-user", "roles" => ["operator"] }
              ]
            }
          ]
        }
      )
      body = JSON.generate("path" => dir, "goal" => "flat project member run", "dry_run" => true)

      status, payload = local_app.call("POST", "/api/engine/run", claim_headers(dir, "X-Aiweb-User-Id" => "ops-user"), body)
      assert_equal 200, status, payload.inspect
      assert_equal "passed", payload["status"]
      assert_equal "flat project member run", bridge.calls.last[:goal]
    end
  end

  def test_backend_session_token_authz_uses_hashed_store_and_project_acl
    in_tmp do |dir|
      session_token = "session-token-1234567890"
      session_store_path = File.join(dir, "sessions.json")
      File.write(
        session_store_path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "sessions" => [
            {
              "token_hash" => session_token_hash(session_token),
              "tenant_id" => "tenant-a",
              "project_id" => project_claim_id(dir),
              "user_id" => "user-a",
              "expires_at" => (Time.now.utc + 300).iso8601
            }
          ]
        )
      )
      bridge = RecordingEngineBridge.new
      local_app = Aiweb::LocalBackendApp.new(
        bridge: bridge,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "session_token",
        authz_projects: claim_project_allowlist(dir, roles: "operator"),
        authz_session_store_file: session_store_path
      )
      encoded_path = URI.encode_www_form_component(dir)

      status, payload = local_app.call("GET", "/api/engine", api_headers)
      assert_equal 200, status
      assert_equal "session_token", payload.dig("authz", "mode")
      assert_equal true, payload.dig("authz", "claim_enforced")
      assert_equal true, payload.dig("authz", "session_store_file_configured")
      assert_equal "sha256_hash_only", payload.dig("authz", "session_token_storage")

      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", api_headers)
      assert_equal 403, status
      assert_match(/bearer session token|required/i, payload["error"])

      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", session_headers(session_token))
      assert_equal 200, status, payload.inspect

      body = JSON.generate("path" => dir, "goal" => "session token run", "dry_run" => true)
      status, payload = local_app.call("POST", "/api/engine/run", session_headers(session_token), body)
      assert_equal 200, status, payload.inspect
      assert_equal "passed", payload["status"]
      assert_equal "session token run", bridge.calls.last[:goal]

      audit_path = File.join(dir, ".ai-web", "authz", "audit.jsonl")
      entries = File.readlines(audit_path).map { |line| JSON.parse(line) }
      assert_equal "session_token", entries.last.fetch("authz_mode")
      refute_match(/session-token-1234567890|user-a|tenant-a/, File.read(audit_path), "session audit must not log raw tokens or identities")
    end
  end

  def test_backend_session_token_authz_rejects_missing_revoked_and_expired_sessions
    in_tmp do |dir|
      valid_token = "valid-session-token-12345"
      expired_token = "expired-session-token-123"
      revoked_token = "revoked-session-token-123"
      no_expiry_token = "no-expiry-session-token"
      duplicate_token = "duplicate-session-token-123"
      session_store_path = File.join(dir, "sessions.json")
      File.write(
        session_store_path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "sessions" => [
            {
              "token_hash" => session_token_hash(valid_token),
              "tenant_id" => "tenant-a",
              "project_id" => project_claim_id(dir),
              "user_id" => "user-a",
              "expires_at" => Time.now.to_i + 300
            },
            {
              "token_hash" => session_token_hash(expired_token),
              "tenant_id" => "tenant-a",
              "project_id" => project_claim_id(dir),
              "user_id" => "user-a",
              "expires_at" => Time.now.to_i - 1
            },
            {
              "token_hash" => session_token_hash(revoked_token),
              "tenant_id" => "tenant-a",
              "project_id" => project_claim_id(dir),
              "user_id" => "user-a",
              "revoked" => true,
              "expires_at" => Time.now.to_i + 300
            },
            {
              "token_hash" => session_token_hash(no_expiry_token),
              "tenant_id" => "tenant-a",
              "project_id" => project_claim_id(dir),
              "user_id" => "user-a"
            },
            {
              "token_hash" => session_token_hash(duplicate_token),
              "tenant_id" => "tenant-a",
              "project_id" => project_claim_id(dir),
              "user_id" => "user-a",
              "expires_at" => Time.now.to_i + 300
            },
            {
              "token_hash" => session_token_hash(duplicate_token),
              "tenant_id" => "tenant-a",
              "project_id" => project_claim_id(dir),
              "user_id" => "user-a",
              "revoked" => true,
              "expires_at" => Time.now.to_i + 300
            }
          ]
        )
      )
      local_app = Aiweb::LocalBackendApp.new(
        bridge: RecordingEngineBridge.new,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "session_token",
        authz_projects: claim_project_allowlist(dir),
        authz_session_store_file: session_store_path
      )
      encoded_path = URI.encode_www_form_component(dir)

      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", session_headers("unknown-session-token-123"))
      assert_equal 403, status
      assert_match(/not authorized/i, payload["error"])

      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", session_headers(expired_token))
      assert_equal 403, status
      assert_match(/expired/i, payload["error"])

      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", session_headers(revoked_token))
      assert_equal 403, status
      assert_match(/revoked/i, payload["error"])

      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", session_headers(no_expiry_token))
      assert_equal 403, status
      assert_match(/expiry is required/i, payload["error"])

      status, payload = local_app.call("GET", "/api/project/status?path=#{encoded_path}", session_headers(duplicate_token))
      assert_equal 403, status
      assert_match(/duplicate session token hash/i, payload["error"])

      missing_store_app = Aiweb::LocalBackendApp.new(
        bridge: RecordingEngineBridge.new,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "session_token",
        authz_projects: claim_project_allowlist(dir),
        authz_session_store_file: File.join(dir, "missing-sessions.json")
      )
      status, payload = missing_store_app.call("GET", "/api/project/status?path=#{encoded_path}", session_headers(valid_token))
      assert_equal 403, status
      assert_match(/AIWEB_DAEMON_SESSION_STORE_FILE|session_token authz mode/i, payload["error"])
    end
  end

  def test_backend_claim_authz_enforces_server_side_roles_and_writes_audit
    in_tmp do |dir|
      bridge = RecordingEngineBridge.new
      viewer_app = Aiweb::LocalBackendApp.new(
        bridge: bridge,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "claims",
        authz_tenant_id: "tenant-a",
        authz_user_id: "user-a",
        authz_projects: claim_project_allowlist(dir, roles: "viewer")
      )
      encoded_path = URI.encode_www_form_component(dir)

      status, payload = viewer_app.call("GET", "/api/project/status?path=#{encoded_path}", claim_headers(dir))
      assert_equal 200, status, payload.inspect

      body = JSON.generate("path" => dir, "goal" => "viewer cannot start run", "dry_run" => true)
      status, payload = viewer_app.call("POST", "/api/engine/run", claim_headers(dir), body)
      assert_equal 403, status
      assert_match(/role ACL denied|requires operator/i, payload["error"])
      refute bridge.calls.any? { |call| call[:goal] == "viewer cannot start run" }, "role-denied run_start must not reach the bridge"

      audit_path = File.join(dir, ".ai-web", "authz", "audit.jsonl")
      assert File.file?(audit_path)
      entries = File.readlines(audit_path).map { |line| JSON.parse(line) }
      assert_equal ["allowed", "denied"], entries.last(2).map { |entry| entry.fetch("decision") }
      assert_equal "view_status", entries[-2].fetch("action")
      assert_equal "run_start", entries[-1].fetch("action")
      assert_equal "viewer", entries[-1].fetch("granted_roles").first
      assert_equal "operator", entries[-1].fetch("required_role")
      assert_equal "server_configured_project_allowlist", entries[-1].fetch("role_source")
      assert entries[-1].fetch("tenant_id_hash").start_with?("sha256:")
      assert entries[-1].fetch("user_id_hash").start_with?("sha256:")
      refute_match(/user-a|tenant-a/, File.read(audit_path), "authz audit must hash raw tenant/user ids")

      admin_app = Aiweb::LocalBackendApp.new(
        bridge: bridge,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "claims",
        authz_tenant_id: "tenant-a",
        authz_user_id: "user-a",
        authz_projects: claim_project_allowlist(dir, roles: "admin")
      )
      status, payload = admin_app.call("POST", "/api/engine/run", claim_headers(dir), body)
      assert_equal 200, status, payload.inspect
      assert_equal "passed", payload["status"]
    end
  end

  def test_backend_artifact_acl_requires_elevated_role_for_sensitive_artifacts
    in_tmp do |dir|
      FileUtils.mkdir_p(File.join(dir, ".ai-web", "diffs"))
      diff_path = ".ai-web/diffs/engine-run-sensitive.patch"
      File.write(File.join(dir, diff_path), "diff --git a/a b/a\n+safe visible diff\n")
      encoded_path = URI.encode_www_form_component(dir)
      encoded_artifact = URI.encode_www_form_component(diff_path)
      viewer_app = Aiweb::LocalBackendApp.new(
        bridge: RecordingEngineBridge.new,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "claims",
        authz_tenant_id: "tenant-a",
        authz_user_id: "user-a",
        authz_projects: claim_project_allowlist(dir, roles: "viewer")
      )

      status, payload = viewer_app.call("GET", "/api/project/artifact?path=#{encoded_path}&artifact=#{encoded_artifact}", claim_headers(dir))
      assert_equal 403, status
      assert_match(/role ACL denied|requires operator/i, payload["error"])
      audit_path = File.join(dir, ".ai-web", "authz", "audit.jsonl")
      audit_entries = File.readlines(audit_path).map { |line| JSON.parse(line) }
      denied = audit_entries.reverse.find { |entry| entry["decision"] == "denied" && entry["artifact_path"] == diff_path }
      assert denied, "expected denied artifact ACL audit event"
      assert_equal "view_artifact", denied.fetch("action")
      assert_equal "operator", denied.fetch("required_role")
      assert_equal "sensitive_run_artifact", denied.fetch("artifact_acl_category")

      operator_app = Aiweb::LocalBackendApp.new(
        bridge: RecordingEngineBridge.new,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "claims",
        authz_tenant_id: "tenant-a",
        authz_user_id: "user-a",
        authz_projects: claim_project_allowlist(dir, roles: "operator")
      )
      status, artifact = operator_app.call("GET", "/api/project/artifact?path=#{encoded_path}&artifact=#{encoded_artifact}", claim_headers(dir))
      assert_equal 200, status, artifact.inspect
      assert_equal "operator", artifact.dig("artifact", "acl", "required_role")
      assert_equal "text/x-diff", artifact.dig("artifact", "media_type")
      assert_match(/safe visible diff/, artifact.dig("artifact", "content"))
    end
  end

  def test_backend_claim_enforced_authz_covers_every_project_scoped_route
    in_tmp do |dir|
      bridge = RecordingEngineBridge.new
      local_app = Aiweb::LocalBackendApp.new(
        bridge: bridge,
        api_token: API_TOKEN,
        approval_token: APPROVAL_TOKEN,
        authz_mode: "claims",
        authz_tenant_id: "tenant-a",
        authz_user_id: "user-a",
        authz_projects: claim_project_allowlist(dir)
      )
      run_id = "engine-run-route-sweep"
      run_dir = File.join(dir, ".ai-web", "runs", run_id)
      FileUtils.mkdir_p(File.join(run_dir, "artifacts"))
      FileUtils.mkdir_p(File.join(dir, ".ai-web", "diffs"))
      File.write(File.join(run_dir, "engine-run.json"), JSON.pretty_generate("schema_version" => 1, "run_id" => run_id, "status" => "waiting_approval"))
      File.write(File.join(run_dir, "events.jsonl"), JSON.generate("schema_version" => 1, "seq" => 1, "type" => "run.created", "message" => "created") + "\n")
      File.write(File.join(run_dir, "approvals.jsonl"), JSON.generate("schema_version" => 1, "status" => "planned", "approval_hash" => "hash-route") + "\n")
      File.write(File.join(run_dir, "artifacts", "route.json"), JSON.pretty_generate("schema_version" => 1, "status" => "ready"))
      encoded_path = URI.encode_www_form_component(dir)
      encoded_artifact = URI.encode_www_form_component(".ai-web/runs/#{run_id}/artifacts/route.json")

      route_cases = [
        ["GET", "/api/project/status?path=#{encoded_path}", api_headers, "", "view_status"],
        ["GET", "/api/project/workbench?path=#{encoded_path}", api_headers, "", "view_workbench"],
        ["GET", "/api/project/console?path=#{encoded_path}", api_headers, "", "view_console"],
        ["GET", "/api/project/runs?path=#{encoded_path}", api_headers, "", "view_runs"],
        ["GET", "/api/project/run?path=#{encoded_path}&run_id=#{run_id}", api_headers, "", "view_run"],
        ["GET", "/api/project/run-stream?path=#{encoded_path}&run_id=#{run_id}&cursor=0&wait_ms=1", api_headers, "", "view_events_stream"],
        ["GET", "/api/project/run-events-sse?path=#{encoded_path}&run_id=#{run_id}&cursor=0&wait_ms=1", api_headers, "", "view_events_sse"],
        ["GET", "/api/project/run-events?path=#{encoded_path}&run_id=#{run_id}", api_headers, "", "view_events"],
        ["GET", "/api/project/approvals?path=#{encoded_path}", api_headers, "", "view_approvals"],
        ["GET", "/api/project/job/status?path=#{encoded_path}&run_id=#{run_id}", api_headers, "", "view_job_status"],
        ["GET", "/api/project/job/timeline?path=#{encoded_path}&limit=2", api_headers, "", "view_job_timeline"],
        ["GET", "/api/project/job/summary?path=#{encoded_path}&limit=2", api_headers, "", "view_job_summary"],
        ["GET", "/api/project/artifact?path=#{encoded_path}&artifact=#{encoded_artifact}", api_headers, "", "view_artifact"],
        ["POST", "/api/project/command", api_headers, JSON.generate("path" => dir, "command" => "status", "dry_run" => true), "command"],
        ["POST", "/api/engine/run", api_headers, JSON.generate("path" => dir, "goal" => "route sweep", "dry_run" => true), "run_start"],
        ["POST", "/api/engine/approve", approval_headers, JSON.generate("path" => dir, "run_id" => run_id, "approval_hash" => "hash-route"), "approve"],
        ["POST", "/api/project/job/cancel", api_headers, JSON.generate("path" => dir, "run_id" => run_id, "dry_run" => true), "cancel"],
        ["POST", "/api/project/job/resume", api_headers, JSON.generate("path" => dir, "run_id" => run_id, "dry_run" => true), "resume"],
        ["POST", "/api/codex/agent-run", api_headers, JSON.generate("path" => dir, "task" => "latest", "dry_run" => true), "codex_agent_run"]
      ]

      route_cases.each do |method, target, missing_claim_headers, body, action|
        status, payload = local_app.call(method, target, missing_claim_headers, body)
        assert_equal 403, status, "#{action} should reject a tokened project-scoped request without claims"
        assert_match(/claims|required/i, payload["error"], action)
      end

      route_cases.each do |method, target, _missing_claim_headers, body, action|
        headers = action == "approve" ? claim_headers(dir, "X-Aiweb-Approval-Token" => APPROVAL_TOKEN) : claim_headers(dir)
        status, payload = local_app.call(method, target, headers, body)
        assert_operator status, :<, 400, "#{action} should pass claim authz before route handling: #{payload.inspect}"
      end
      assert local_app.wait_for_background_jobs(timeout: 2), "background approval job should finish in route sweep"
    end
  end

  def test_backend_exposes_engine_run_events_and_approval_inbox_without_raw_shell
    in_tmp do |dir|
      run_id = "engine-run-20260513T010203Z"
      run_dir = File.join(dir, ".ai-web", "runs", run_id)
      FileUtils.mkdir_p(run_dir)
      File.write(
        File.join(run_dir, "events.jsonl"),
        [
          JSON.generate("schema_version" => 1, "type" => "run.created", "message" => "created", "at" => "now", "data" => {}),
          JSON.generate("schema_version" => 1, "type" => "tool.started", "message" => "build", "at" => "now", "data" => { "command" => "npm run build" })
        ].join("\n") + "\n"
      )
      File.write(
        File.join(run_dir, "approvals.jsonl"),
        JSON.generate(
          "schema_version" => 1,
          "status" => "planned",
          "approval_hash" => "abc123",
          "capability" => { "goal" => "patch hero", "forbidden" => ["external_network"] }
        ) + "\n"
      )

      encoded_path = URI.encode_www_form_component(dir)
      status, events = app.call("GET", "/api/project/run-events?path=#{encoded_path}&run_id=#{run_id}", api_headers)
      assert_equal 200, status
      assert_equal "ready", events["status"]
      assert_equal run_id, events["run_id"]
      assert_equal 2, events["count"]
      assert_equal "tool.started", events["events"].last["type"]

      status, approvals = app.call("GET", "/api/project/approvals?path=#{encoded_path}", api_headers)
      assert_equal 200, status
      assert_equal "ready", approvals["status"]
      assert_equal run_id, approvals["approvals"].first["run_id"]
      assert_equal "abc123", approvals["approvals"].first["approval_hash"]
    end
  end

  def test_engine_run_endpoint_maps_to_dedicated_bridge_without_raw_shell
    in_tmp do |dir|
      bridge = RecordingEngineBridge.new
      local_app = Aiweb::LocalBackendApp.new(bridge: bridge, api_token: API_TOKEN, approval_token: APPROVAL_TOKEN)

      status, payload = local_app.call(
        "POST",
        "/api/engine/run",
        api_headers,
        JSON.generate(
          "path" => dir,
          "goal" => "build a local console",
          "agent" => "openmanus",
          "mode" => "agentic_local",
          "sandbox" => "docker",
          "max_cycles" => 4,
          "dry_run" => true
        )
      )

      assert_equal 200, status
      assert_equal "passed", payload["status"]
      assert_equal "engine-run", payload.dig("bridge", "command")
      assert_equal "build a local console", bridge.calls.last[:goal]
      assert_equal "openmanus", bridge.calls.last[:agent]
      assert_equal "docker", bridge.calls.last[:sandbox]
      assert_equal 4, bridge.calls.last[:max_cycles]
      assert_equal true, bridge.calls.last[:dry_run]
      assert_equal false, bridge.calls.last[:approved]
      refute_includes JSON.generate(payload), ";"
    end
  end

  def test_engine_approval_endpoint_resumes_with_approval_token
    in_tmp do |dir|
      bridge = RecordingEngineBridge.new
      local_app = Aiweb::LocalBackendApp.new(bridge: bridge, api_token: API_TOKEN, approval_token: APPROVAL_TOKEN)

      status, blocked = local_app.call(
        "POST",
        "/api/engine/approve",
        api_headers,
        JSON.generate("path" => dir, "run_id" => "engine-run-20260513T010203Z", "approval_hash" => "abc123")
      )
      assert_equal 403, status
      assert_match(/approval token/i, blocked["error"])

      status, payload = local_app.call(
        "POST",
        "/api/engine/approve",
        approval_headers,
        JSON.generate(
          "path" => dir,
          "run_id" => "engine-run-20260513T010203Z",
          "approval_hash" => "abc123",
          "agent" => "codex",
          "mode" => "agentic_local"
        )
      )

      assert_equal 200, status
      assert_equal "queued", payload["status"]
      assert_match(/\Aengine-run-resume-/, payload.dig("engine_run", "run_id"))
      assert_equal true, payload.dig("engine_run", "async")
      assert_equal true, payload.dig("engine_run", "approval_resume")
      assert local_app.wait_for_background_jobs(timeout: 2), "background approval job should finish in test"
      assert_equal "engine-run-20260513T010203Z", bridge.calls.last[:resume]
      assert_equal "abc123", bridge.calls.last[:approval_hash]
      assert_match(/\Aengine-run-resume-/, bridge.calls.last[:run_id])
      assert_equal false, bridge.calls.last[:dry_run]
      assert_equal true, bridge.calls.last[:approved]
    end
  end

  def test_engine_run_real_execution_returns_durable_background_job
    in_tmp do |dir|
      bridge = RecordingEngineBridge.new
      local_app = Aiweb::LocalBackendApp.new(bridge: bridge, api_token: API_TOKEN, approval_token: APPROVAL_TOKEN)

      status, blocked = local_app.call(
        "POST",
        "/api/engine/run",
        api_headers,
        JSON.generate("path" => dir, "goal" => "ship console", "dry_run" => false, "approved" => false)
      )
      assert_equal 403, status
      assert_match(/approved=true/, blocked["error"])

      status, payload = local_app.call(
        "POST",
        "/api/engine/run",
        approval_headers,
        JSON.generate(
          "path" => dir,
          "goal" => "ship console",
          "agent" => "openmanus",
          "sandbox" => "docker",
          "dry_run" => false,
          "approved" => true,
          "job_run_id" => "engine-run-web-test"
        )
      )

      assert_equal 200, status
      assert_equal "queued", payload["status"]
      assert_equal "engine-run-web-test", payload.dig("engine_run", "run_id")
      assert_equal ".ai-web/runs/engine-run-web-test/job.json", payload.dig("engine_run", "job_path")
      assert_equal ".ai-web/runs/engine-run-web-test/events.jsonl", payload.dig("engine_run", "events_path")

      encoded_path = URI.encode_www_form_component(dir)
      status, stream = local_app.call("GET", "/api/project/run-stream?path=#{encoded_path}&run_id=engine-run-web-test&cursor=0&wait_ms=1", api_headers)
      assert_equal 200, status
      assert_includes stream["events"].map { |event| event["type"] }, "backend.job.queued"

      assert local_app.wait_for_background_jobs(timeout: 2), "background engine job should finish in test"
      lifecycle_events = File.readlines(File.join(dir, ".ai-web", "runs", "engine-run-web-test", "events.jsonl")).map { |line| JSON.parse(line) }
      %w[backend.job.queued backend.job.started backend.job.finished].each do |event_type|
        event = lifecycle_events.find { |candidate| candidate.fetch("type") == event_type }
        assert event, "#{event_type} should be present"
        %w[run_id actor phase trace_span_id redaction_status previous_event_hash event_hash].each do |field|
          assert_includes event, field
        end
        assert_equal "engine-run-web-test", event.fetch("run_id")
        assert_equal "aiweb.engine_run", event.fetch("actor")
        assert_match(/\Asha256:[a-f0-9]{64}\z/, event.fetch("event_hash"))
      end
      queued, started, finished = lifecycle_events.values_at(0, 1, 2)
      assert_nil queued["previous_event_hash"]
      assert_equal queued.fetch("event_hash"), started.fetch("previous_event_hash")
      assert_equal started.fetch("event_hash"), finished.fetch("previous_event_hash")
      assert_equal "engine-run-web-test", bridge.calls.last[:run_id]
      assert_equal "ship console", bridge.calls.last[:goal]
      assert_equal false, bridge.calls.last[:dry_run]
      assert_equal true, bridge.calls.last[:approved]

      status, job = local_app.call("GET", "/api/project/job/status?path=#{encoded_path}&run_id=engine-run-web-test", api_headers)
      assert_equal 200, status
      assert_equal "ready", job["status"]
      assert_equal "passed", job.dig("job", "status")
      assert_equal "passed", job.dig("job", "engine_status")
    end
  end

  def test_bridge_engine_run_can_pin_backend_job_run_id
    in_tmp do |dir|
      app.call("POST", "/api/project/command", api_headers, JSON.generate("path" => dir, "command" => "init", "args" => ["--profile", "D"]))
      bridge = Aiweb::CodexCliBridge.new(engine_root: REPO_ROOT)

      result = bridge.engine_run(
        project_path: dir,
        goal: "inspect fixed id",
        agent: "codex",
        mode: "agentic_local",
        run_id: "engine-run-fixed-web-id",
        dry_run: true,
        approved: false
      )

      assert_includes result.dig("bridge", "args"), "--run-id"
      assert_includes result.dig("bridge", "args"), "engine-run-fixed-web-id"
      assert_equal "engine-run-fixed-web-id", result.dig("stdout_json", "engine_run", "run_id")
    end
  end

  def test_backend_run_detail_stream_and_diff_artifact_for_console
    in_tmp do |dir|
      run_id = "engine-run-20260513T111213Z"
      run_dir = File.join(dir, ".ai-web", "runs", run_id)
      FileUtils.mkdir_p(File.join(run_dir, "artifacts"))
      FileUtils.mkdir_p(File.join(run_dir, "qa"))
      FileUtils.mkdir_p(File.join(run_dir, "screenshots"))
      FileUtils.mkdir_p(File.join(dir, ".ai-web", "diffs"))
      File.write(File.join(run_dir, "qa", "design-verdict.json"), JSON.pretty_generate("schema_version" => 1, "status" => "passed", "scores" => { "selected_design_fidelity" => 0.94 }))
      File.write(File.join(run_dir, "qa", "eval-benchmark.json"), JSON.pretty_generate("schema_version" => 1, "status" => "blocked", "benchmark_id" => "eval-benchmark-0123456789abcdef", "human_calibration_status" => "missing", "regression_gate" => { "status" => "passed" }))
      File.write(File.join(run_dir, "qa", "preview.json"), JSON.pretty_generate("schema_version" => 1, "status" => "ready", "url" => "http://127.0.0.1:4321/"))
      File.write(File.join(run_dir, "qa", "screenshots.json"), JSON.pretty_generate("schema_version" => 1, "status" => "captured", "screenshots" => [{ "viewport" => "desktop", "path" => ".ai-web/runs/#{run_id}/screenshots/desktop.png", "url" => "http://127.0.0.1:4321/" }]))
      File.write(File.join(run_dir, "artifacts", "opendesign-contract.json"), JSON.pretty_generate("schema_version" => 1, "status" => "ready", "contract_hash" => "sha256:abc"))
      File.write(File.join(run_dir, "artifacts", "authz-enforcement.json"), JSON.pretty_generate("schema_version" => 1, "run_id" => run_id, "run_id_is_not_authority" => true, "remote_exposure_status" => "blocked_until_tenant_project_user_claims_are_enforced"))
      File.write(File.join(run_dir, "artifacts", "run-memory.json"), JSON.pretty_generate("schema_version" => 1, "run_id" => run_id, "status" => "ready", "retrieval_strategy" => "bounded_lexical_cards", "rag_status" => "not_configured", "memory_record_count" => 1, "memory_records" => [{ "kind" => "component", "key" => "src/components/Hero.astro" }]))
      File.write(File.join(run_dir, "artifacts", "worker-adapter-registry.json"), JSON.pretty_generate("schema_version" => 1, "protocol_version" => "worker-adapter-v1", "selected_adapter" => "openmanus", "selected_adapter_status" => "implemented_container_worker", "adapters" => []))
      File.write(File.join(run_dir, "artifacts", "supply-chain-gate.json"), JSON.pretty_generate("schema_version" => 1, "status" => "waiting_approval", "required" => true))
      File.binwrite(File.join(run_dir, "screenshots", "desktop.png"), "png")
      File.write(
        File.join(run_dir, "engine-run.json"),
        JSON.pretty_generate(
          "schema_version" => 1,
          "run_id" => run_id,
          "status" => "waiting_approval",
          "agent" => "codex",
          "mode" => "agentic_local",
          "approval_hash" => "hash-123",
          "events_path" => ".ai-web/runs/#{run_id}/events.jsonl",
          "approval_path" => ".ai-web/runs/#{run_id}/approvals.jsonl",
          "diff_path" => ".ai-web/diffs/#{run_id}.patch",
          "design_verdict_path" => ".ai-web/runs/#{run_id}/qa/design-verdict.json",
          "eval_benchmark_path" => ".ai-web/runs/#{run_id}/qa/eval-benchmark.json",
          "preview_path" => ".ai-web/runs/#{run_id}/qa/preview.json",
          "screenshot_evidence_path" => ".ai-web/runs/#{run_id}/qa/screenshots.json",
          "opendesign_contract_path" => ".ai-web/runs/#{run_id}/artifacts/opendesign-contract.json",
          "run_memory_path" => ".ai-web/runs/#{run_id}/artifacts/run-memory.json",
          "authz_enforcement_path" => ".ai-web/runs/#{run_id}/artifacts/authz-enforcement.json",
          "worker_adapter_registry_path" => ".ai-web/runs/#{run_id}/artifacts/worker-adapter-registry.json",
          "supply_chain_gate_path" => ".ai-web/runs/#{run_id}/artifacts/supply-chain-gate.json",
          "stdout_log" => ".ai-web/runs/#{run_id}/logs/stdout.log",
          "stderr_log" => ".ai-web/runs/#{run_id}/logs/stderr.log",
          "copy_back_policy" => { "approval_issues" => ["package install requested"], "safe_changes" => [] },
          "context" => { "content" => "SECRET=must-not-leak" }
        )
      )
      FileUtils.mkdir_p(File.join(run_dir, "logs"))
      File.write(File.join(run_dir, "logs", "stdout.log"), "visible stdout\n")
      File.write(File.join(run_dir, "logs", "stderr.log"), "visible stderr\n")
      File.write(
        File.join(run_dir, "events.jsonl"),
        [
          JSON.generate("schema_version" => 1, "type" => "run.created", "message" => "created", "at" => "1", "data" => {}),
          JSON.generate("schema_version" => 1, "type" => "approval.requested", "message" => "needs approval", "at" => "2", "data" => { "reason" => "package install" })
        ].join("\n") + "\n"
      )
      File.write(
        File.join(run_dir, "approvals.jsonl"),
        JSON.generate("schema_version" => 1, "status" => "planned", "approval_hash" => "hash-123") + "\n"
      )
      File.write(File.join(dir, ".ai-web", "diffs", "#{run_id}.patch"), "diff --git a/src/App.js b/src/App.js\n")

      encoded_path = URI.encode_www_form_component(dir)
      status, detail = app.call("GET", "/api/project/run?path=#{encoded_path}&run_id=#{run_id}", api_headers)
      assert_equal 200, status
      assert_equal "ready", detail["status"]
      assert_equal run_id, detail.dig("run", "run_id")
      assert_equal "waiting_approval", detail.dig("run", "metadata", "status")
      assert_equal true, detail.dig("run", "console", "needs_approval")
      assert_equal ".ai-web/diffs/#{run_id}.patch", detail.dig("run", "artifact_refs").find { |entry| entry["role"] == "diff" }["path"]
      assert_equal ".ai-web/runs/#{run_id}/logs/stdout.log", detail.dig("run", "artifact_refs").find { |entry| entry["role"] == "stdout" }["path"]
      assert_equal ".ai-web/runs/#{run_id}/logs/stderr.log", detail.dig("run", "artifact_refs").find { |entry| entry["role"] == "stderr" }["path"]
      assert_equal "blocked", detail.dig("run", "panels", "eval_benchmark", "data", "status")
      assert_equal "waiting_approval", detail.dig("run", "panels", "supply_chain_gate", "data", "status")
      assert_equal "bounded_lexical_cards", detail.dig("run", "panels", "run_memory", "data", "retrieval_strategy")
      assert_equal true, detail.dig("run", "panels", "authz_enforcement", "data", "run_id_is_not_authority")
      assert_equal "openmanus", detail.dig("run", "panels", "worker_adapter_registry", "data", "selected_adapter")
      assert_equal "passed", detail.dig("run", "panels", "design_verdict", "data", "status")
      assert_equal "ready", detail.dig("run", "panels", "preview", "data", "status")
      assert_equal ["desktop"], detail.dig("run", "panels", "screenshots", "screenshots").map { |shot| shot["viewport"] }
      assert_equal "sha256:abc", detail.dig("run", "panels", "opendesign_contract", "data", "contract_hash")
      assert_equal ".ai-web/diffs/#{run_id}.patch", detail.dig("run", "panels", "diff", "artifact", "path")
      assert_equal "ready", detail.dig("run", "panels", "approvals", "status")
      refute_includes JSON.generate(detail), "must-not-leak"

      status, stream = app.call("GET", "/api/project/run-stream?path=#{encoded_path}&run_id=#{run_id}&cursor=1&wait_ms=25", api_headers)
      assert_equal 200, status
      assert_equal 1, stream["cursor"]
      assert_equal "long_poll", stream["stream_mode"]
      assert_equal 25, stream["wait_ms"]
      assert_equal 2, stream["next_cursor"]
      assert_equal ["approval.requested"], stream["events"].map { |event| event["type"] }

      artifact = URI.encode_www_form_component(".ai-web/diffs/#{run_id}.patch")
      status, diff = app.call("GET", "/api/project/artifact?path=#{encoded_path}&artifact=#{artifact}", api_headers)
      assert_equal 200, status
      assert_equal "text/x-diff", diff.dig("artifact", "media_type")
      assert_match(/diff --git/, diff.dig("artifact", "content"))
    end
  end

  def test_backend_console_payload_surfaces_latest_run_and_approval_count
    in_tmp do |dir|
      run_id = "engine-run-20260513T141516Z"
      run_dir = File.join(dir, ".ai-web", "runs", run_id)
      FileUtils.mkdir_p(run_dir)
      File.write(File.join(run_dir, "engine-run.json"), JSON.pretty_generate("schema_version" => 1, "run_id" => run_id, "status" => "waiting_approval"))
      File.write(File.join(run_dir, "approvals.jsonl"), JSON.generate("schema_version" => 1, "status" => "planned", "approval_hash" => "hash-456") + "\n")

      encoded_path = URI.encode_www_form_component(dir)
      status, payload = app.call("GET", "/api/project/console?path=#{encoded_path}", api_headers)

      assert_equal 200, status
      assert_equal "ready", payload["status"]
      assert_equal true, payload.dig("console", "backend_ready")
      assert_equal run_id, payload.dig("console", "latest_run", "run_id")
      assert_equal 1, payload.dig("console", "approval_count")
      assert_includes payload.dig("console", "routes"), "POST /api/engine/run"
    end
  end

  def test_backend_job_lifecycle_routes_map_to_bridge_and_require_tokens
    in_tmp do |dir|
      bridge = RecordingEngineBridge.new
      local_app = Aiweb::LocalBackendApp.new(bridge: bridge, api_token: API_TOKEN, approval_token: APPROVAL_TOKEN)
      encoded_path = URI.encode_www_form_component(dir)

      status, lifecycle = local_app.call("GET", "/api/project/job/status?path=#{encoded_path}&run_id=active", api_headers)
      assert_equal 200, status
      assert_equal "run-status", lifecycle.dig("bridge", "command")
      assert_equal ["--run-id", "active"], lifecycle.dig("bridge", "args")

      status, timeline = local_app.call("GET", "/api/project/job/timeline?path=#{encoded_path}&limit=7", api_headers)
      assert_equal 200, status
      assert_equal "run-timeline", timeline.dig("bridge", "command")
      assert_equal ["--limit", "7"], timeline.dig("bridge", "args")

      status, summary = local_app.call("GET", "/api/project/job/summary?path=#{encoded_path}&limit=3", api_headers)
      assert_equal 200, status
      assert_equal "observability-summary", summary.dig("bridge", "command")
      assert_equal ["--limit", "3"], summary.dig("bridge", "args")

      status, blocked = local_app.call(
        "POST",
        "/api/project/job/cancel",
        api_headers,
        JSON.generate("path" => dir, "run_id" => "active", "force" => true)
      )
      assert_equal 403, status
      assert_match(/approval token/i, blocked["error"])

      status, cancel = local_app.call(
        "POST",
        "/api/project/job/cancel",
        approval_headers,
        JSON.generate("path" => dir, "run_id" => "active", "force" => true)
      )
      assert_equal 200, status
      assert_equal "run-cancel", cancel.dig("bridge", "command")
      assert_equal ["--run-id", "active", "--force"], cancel.dig("bridge", "args")

      status, dry_cancel = local_app.call(
        "POST",
        "/api/project/job/cancel",
        api_headers,
        JSON.generate("path" => dir, "run_id" => "active", "dry_run" => true)
      )
      assert_equal 200, status
      assert_equal "run-cancel", dry_cancel.dig("bridge", "command")
      assert_equal true, dry_cancel.dig("bridge", "dry_run")
      assert_equal ["--run-id", "active"], dry_cancel.dig("bridge", "args")

      status, dry_resume = local_app.call(
        "POST",
        "/api/project/job/resume",
        api_headers,
        JSON.generate("path" => dir, "run_id" => "latest", "dry_run" => true)
      )
      assert_equal 200, status
      assert_equal "run-resume", dry_resume.dig("bridge", "command")
      assert_equal true, dry_resume.dig("bridge", "dry_run")

      status, blocked_resume = local_app.call(
        "POST",
        "/api/project/job/resume",
        api_headers,
        JSON.generate("path" => dir, "run_id" => "latest")
      )
      assert_equal 403, status
      assert_match(/approval token/i, blocked_resume["error"])
    end
  end

  def test_daemon_defaults_to_local_host_and_rejects_external_binding
    daemon = Aiweb::LocalBackendDaemon.new(port: 0)
    assert_equal "127.0.0.1", daemon.host

    blank_host = Aiweb::LocalBackendDaemon.new(host: "", port: 0)
    assert_equal "127.0.0.1", blank_host.host

    payload = Aiweb::LocalBackendDaemon.plan
    assert_equal "127.0.0.1", payload.dig("backend", "host")
    assert_equal 4242, payload.dig("backend", "port")

    error = assert_raises(Aiweb::UserError) do
      Aiweb::LocalBackendDaemon.new(host: "0.0.0.0", port: 0)
    end
    assert_match(/local-only/, error.message)

    assert Aiweb::LocalBackendApp.allowed_origin?("http://localhost:5173")
    assert Aiweb::LocalBackendApp.allowed_origin?("http://127.0.0.1:3000")
    refute Aiweb::LocalBackendApp.allowed_origin?("https://example.com")
  end

  def test_backend_app_rejects_non_local_origins
    status, payload = app.call("GET", "/health", { "Origin" => "https://evil.example" })
    assert_equal 403, status
    assert_match(/origin/i, payload["error"])

    status, payload = app.call("GET", "/health", { "Origin" => "http://localhost:5173" })
    assert_equal 200, status
    assert_equal "ok", payload["status"]
  end

  def test_daemon_cors_allows_claim_authz_headers_for_browser_clients
    daemon = Aiweb::LocalBackendDaemon.new(port: 0)
    socket = StringIO.new

    daemon.send(:write_text, socket, 204, "", content_type: "application/json", origin: "http://localhost:5173")

    response = socket.string
    assert_includes response, "Access-Control-Allow-Origin: http://localhost:5173"
    assert_includes response, "Access-Control-Allow-Headers: Content-Type, Authorization, X-Aiweb-Token, X-Aiweb-Approval-Token, X-Aiweb-Tenant-Id, X-Aiweb-Project-Id, X-Aiweb-User-Id"
  end

  def test_backend_api_requires_api_token
    status, payload = app.call("GET", "/health")
    assert_equal 200, status
    assert_equal "ok", payload["status"]

    status, payload = app.call("GET", "/api/engine")
    assert_equal 403, status
    assert_match(/API token/i, payload["error"])

    status, payload = app.call("GET", "/api/engine", { "X-Aiweb-Token" => "wrong" })
    assert_equal 403, status
    assert_match(/API token/i, payload["error"])

    status, payload = app.call("GET", "/api/engine", api_headers)
    assert_equal 200, status
    assert_equal "ready", payload["status"]
    assert_equal true, payload.dig("capabilities", "engine_run_async_jobs")
    assert_equal false, payload.dig("capabilities", "generic_engine_run_command")
    assert_equal false, payload.dig("openmanus_runtime", "check_image")
  end

  def test_backend_reports_openmanus_readiness_for_web_preflight
    status, payload = app.call("GET", "/api/engine/openmanus-readiness", api_headers)

    assert_equal 200, status
    assert_includes %w[ready missing_runtime missing_image unavailable], payload["status"]
    assert_equal true, payload["check_image"]
    assert_equal "openmanus:latest", payload["image"]
    assert_equal %w[docker podman], payload["providers"].map { |provider| provider["provider"] }
    assert payload["next_action"].is_a?(String)
  end

  def test_backend_app_health_and_status_use_latest_engine_bridge
    in_tmp do |dir|
      status, health = app.call("GET", "/health")
      assert_equal 200, status
      assert_equal "ok", health["status"]
      assert_equal AIWEB, health.dig("engine", "aiweb_bin")

      status, missing = app.call("GET", "/api/project/status", api_headers)
      assert_equal 400, status
      assert_match(/path/i, missing["error"])

      status, init = app.call(
        "POST",
        "/api/project/command",
        api_headers,
        JSON.generate("path" => dir, "command" => "init", "args" => ["--profile", "D"])
      )
      assert_equal 200, status
      assert_equal "passed", init["status"]
      assert_equal "phase-0", init.dig("stdout_json", "current_phase")

      encoded_path = URI.encode_www_form_component(dir)
      status, current = app.call("GET", "/api/project/status?path=#{encoded_path}", api_headers)
      assert_equal 200, status
      assert_equal "passed", current["status"]
      assert_equal "phase-0", current.dig("stdout_json", "current_phase")
    end
  end

  def test_codex_agent_run_endpoint_maps_to_dry_run_codex_bridge_without_raw_shell
    in_tmp do |dir|
      app.call("POST", "/api/project/command", api_headers, JSON.generate("path" => dir, "command" => "init", "args" => ["--profile", "D"]))
      status, payload = app.call(
        "POST",
        "/api/codex/agent-run",
        api_headers,
        JSON.generate("path" => dir, "task" => "latest", "dry_run" => true)
      )

      assert_equal 200, status
      assert_equal "failed", payload["status"]
      assert_equal "agent-run", payload.dig("bridge", "command")
      assert_equal ["--task", "latest", "--agent", "codex"], payload.dig("bridge", "args")
      assert_equal true, payload.dig("bridge", "dry_run")
      assert_equal "blocked", payload.dig("stdout_json", "agent_run", "status")
      assert_match(/implementation task|safe source/i, payload.dig("stdout_json", "agent_run", "blocking_issues").join("\n"))
      refute_includes payload.dig("bridge", "argv").join(" "), ";"
    end
  end

  def test_codex_agent_run_endpoint_passes_openmanus_agent_selection
    in_tmp do |dir|
      app.call("POST", "/api/project/command", api_headers, JSON.generate("path" => dir, "command" => "init", "args" => ["--profile", "D"]))
      status, payload = app.call(
        "POST",
        "/api/codex/agent-run",
        api_headers,
        JSON.generate("path" => dir, "task" => "latest", "agent" => "openmanus", "dry_run" => true)
      )

      assert_equal 200, status
      assert_equal "agent-run", payload.dig("bridge", "command")
      assert_equal ["--task", "latest", "--agent", "openmanus"], payload.dig("bridge", "args")
      assert_equal true, payload.dig("bridge", "dry_run")
      assert_equal "openmanus", payload.dig("stdout_json", "agent_run", "agent")
    end
  end

  def test_bridge_timeout_cleans_process_group_without_waiting_on_descendant_stdout
    bridge = Aiweb::CodexCliBridge.new(engine_root: REPO_ROOT, command_timeout: 0.2)
    code = if RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/i)
             "sleep 3"
           else
             <<~RUBY
               fork do
                 STDOUT.sync = true
                 sleep 3
               end
               sleep 3
             RUBY
           end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    error = assert_raises(Aiweb::UserError) do
      bridge.send(:capture_argv, [RbConfig.ruby, "-e", code])
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_match(/timed out/, error.message)
    assert_operator elapsed, :<, 2.0
  end

  def test_approved_codex_bridge_execution_requires_backend_token
    in_tmp do |dir|
      app.call("POST", "/api/project/command", api_headers, JSON.generate("path" => dir, "command" => "init", "args" => ["--profile", "D"]))

      status, payload = app.call(
        "POST",
        "/api/codex/agent-run",
        api_headers,
        JSON.generate("path" => dir, "task" => "latest", "dry_run" => true, "approved" => true)
      )
      assert_equal 403, status
      assert_match(/approval token/i, payload["error"])

      status, payload = app.call(
        "POST",
        "/api/codex/agent-run",
        approval_headers("X-Aiweb-Approval-Token" => "wrong"),
        JSON.generate("path" => dir, "task" => "latest", "dry_run" => true, "approved" => true)
      )
      assert_equal 403, status
      assert_match(/approval token/i, payload["error"])

      status, payload = app.call(
        "POST",
        "/api/codex/agent-run",
        approval_headers,
        JSON.generate("path" => dir, "task" => "latest", "dry_run" => true, "approved" => true)
      )
      assert_equal 200, status
      assert_equal "failed", payload["status"]
      assert_equal true, payload.dig("bridge", "approved")
      assert_includes payload.dig("bridge", "argv"), "--approved"
    end
  end

  def test_bridge_rejects_backend_controlled_flags_and_env_paths
    in_tmp do |dir|
      [
        ["--path", "/tmp/other"],
        ["--path=/tmp/other"],
        ["--json"],
        ["--dry-run"],
        ["--approved"]
      ].each do |unsafe_args|
        status, blocked = app.call(
          "POST",
          "/api/project/command",
          api_headers,
          JSON.generate("path" => dir, "command" => "status", "args" => unsafe_args)
        )
        assert_equal 403, status, unsafe_args.inspect
        assert_match(/backend-controlled|--path/, blocked["error"], unsafe_args.inspect)
      end

      status, blocked_approved = app.call(
        "POST",
        "/api/project/command",
        api_headers,
        JSON.generate("path" => dir, "command" => "agent-run", "args" => ["--task", "latest", "--agent", "codex", "--approved"])
      )
      assert_equal 403, status
      assert_match(/--approved/, blocked_approved["error"])

      status, blocked_engine = app.call(
        "POST",
        "/api/project/command",
        api_headers,
        JSON.generate("path" => dir, "command" => "engine-run", "args" => ["--goal", "ship web"])
      )
      assert_equal 403, status
      assert_match(%r{/api/engine/run}, blocked_engine["error"])

      status, blocked_env = app.call(
        "POST",
        "/api/codex/agent-run",
        api_headers,
        JSON.generate("path" => dir, "task" => ".env", "dry_run" => true)
      )
      assert_equal 403, status
      assert_match(/\.env/, blocked_env["error"])

      [
        "foo/.env",
        "foo/.env.local",
        "--from=.env.local",
        "--from=./.env.local",
        "--from=foo/.env.local",
        "foo\\.env.local"
      ].each do |unsafe_arg|
        status, payload = app.call(
          "POST",
          "/api/project/command",
          api_headers,
          JSON.generate("path" => dir, "command" => "qa-report", "args" => [unsafe_arg])
        )
        assert_equal 403, status, unsafe_arg
        assert_match(/\.env/, payload["error"], unsafe_arg)
      end

      unsafe_project = URI.encode_www_form_component(File.join(dir, ".env.local"))
      status, payload = app.call("GET", "/api/project/runs?path=#{unsafe_project}", api_headers)
      assert_equal 403, status
      assert_match(/\.env/, payload["error"])
    end
  end

  def test_bridge_allows_ingest_reference_and_preserves_cli_env_rejection
    in_tmp do |dir|
      status, init = app.call(
        "POST",
        "/api/project/command",
        api_headers,
        JSON.generate("path" => dir, "command" => "init", "args" => ["--profile", "D"])
      )
      assert_equal 200, status
      assert_equal "passed", init["status"]

      state_path = File.join(dir, ".ai-web", "state.yaml")
      state = YAML.load_file(state_path)
      state["phase"]["current"] = "phase-3"
      File.write(state_path, YAML.dump(state))

      status, payload = app.call(
        "POST",
        "/api/project/command",
        api_headers,
        JSON.generate(
          "path" => dir,
          "command" => "ingest-reference",
          "args" => ["--type", "manual", "--notes", "hero hierarchy with trust card"],
          "dry_run" => true
        )
      )
      assert_equal 200, status
      assert_equal "passed", payload["status"]
      assert_equal "ingest-reference", payload.dig("bridge", "command")
      assert_equal true, payload.dig("stdout_json", "reference_ingestion", "pattern_constraints_only")

      status, blocked = app.call(
        "POST",
        "/api/project/command",
        api_headers,
        JSON.generate(
          "path" => dir,
          "command" => "ingest-reference",
          "args" => ["--source", ".env", "--notes", "safe notes"],
          "dry_run" => true
        )
      )
      assert_equal 403, status
      assert_match(/\.env/, blocked["error"])
    end
  end

  def test_backend_artifact_read_returns_reference_brief_with_safe_metadata
    in_tmp do |dir|
      status, init = app.call(
        "POST",
        "/api/project/command",
        api_headers,
        JSON.generate("path" => dir, "command" => "init", "args" => ["--profile", "D"])
      )
      assert_equal 200, status
      assert_equal "passed", init["status"]

      state_path = File.join(dir, ".ai-web", "state.yaml")
      state = YAML.load_file(state_path)
      state["phase"]["current"] = "phase-3"
      File.write(state_path, YAML.dump(state))

      status, ingest = app.call(
        "POST",
        "/api/project/command",
        api_headers,
        JSON.generate(
          "path" => dir,
          "command" => "ingest-reference",
          "args" => ["--type", "manual", "--notes", "hero hierarchy with trust card"]
        )
      )
      assert_equal 200, status
      assert_equal "passed", ingest["status"]

      encoded_path = URI.encode_www_form_component(dir)
      artifact = URI.encode_www_form_component(".ai-web/design-reference-brief.md")
      status, payload = app.call("GET", "/api/project/artifact?path=#{encoded_path}&artifact=#{artifact}", api_headers)

      assert_equal 200, status
      assert_equal "ready", payload["status"]
      assert_equal ".ai-web/design-reference-brief.md", payload.dig("artifact", "path")
      assert_equal "text/markdown", payload.dig("artifact", "media_type")
      assert_equal false, payload.dig("artifact", "redacted")
      assert_match(/pattern evidence/i, payload.dig("artifact", "content"))
      assert_match(/hero hierarchy with trust card/i, payload.dig("artifact", "content"))
      assert_match(/\A[0-9a-f]{64}\z/, payload.dig("artifact", "sha256"))
      assert_operator payload.dig("artifact", "size_bytes"), :>, 40
    end
  end

  def test_backend_artifact_read_rejects_unsafe_missing_and_secret_paths
    in_tmp do |dir|
      status, _init = app.call(
        "POST",
        "/api/project/command",
        api_headers,
        JSON.generate("path" => dir, "command" => "init", "args" => ["--profile", "D"])
      )
      assert_equal 200, status
      File.write(File.join(dir, ".env"), "SECRET=daemon-artifact-do-not-leak\n")
      encoded_path = URI.encode_www_form_component(dir)

      status, payload = app.call("GET", "/api/project/artifact?path=#{encoded_path}&artifact=.ai-web/DESIGN.md")
      assert_equal 403, status
      assert_match(/API token/i, payload["error"])

      status, payload = app.call("GET", "/api/project/artifact?artifact=.ai-web/DESIGN.md", api_headers)
      assert_equal 400, status
      assert_match(/path/i, payload["error"])

      status, payload = app.call("GET", "/api/project/artifact?path=#{encoded_path}", api_headers)
      assert_equal 400, status
      assert_match(/artifact path/i, payload["error"])

      [
        ".env",
        ".ai-web/../../.env",
        "../.ai-web/DESIGN.md",
        "/tmp/secret.txt",
        "https://example.com/.ai-web/DESIGN.md",
        ".git/config",
        ".ai-web/secrets/reference.md"
      ].each do |unsafe_artifact|
        artifact = URI.encode_www_form_component(unsafe_artifact)
        status, payload = app.call("GET", "/api/project/artifact?path=#{encoded_path}&artifact=#{artifact}", api_headers)
        assert_equal 403, status, unsafe_artifact
        refute_includes JSON.generate(payload), "daemon-artifact-do-not-leak"
      end
    end
  end

  def test_backend_artifact_read_rejects_symlink_targets_without_leaking
    in_tmp do |dir|
      status, _init = app.call(
        "POST",
        "/api/project/command",
        api_headers,
        JSON.generate("path" => dir, "command" => "init", "args" => ["--profile", "D"])
      )
      assert_equal 200, status
      File.write(File.join(dir, ".env"), "SECRET=daemon-symlink-env-do-not-leak\n")
      outside_secret = File.join(dir, "..", "outside-secret.txt")
      File.write(outside_secret, "SECRET=daemon-symlink-outside-do-not-leak\n")
      FileUtils.mkdir_p(File.join(dir, ".ai-web", "tasks"))
      FileUtils.mkdir_p(File.join(dir, ".ai-web", "design-candidates"))
      begin
        File.symlink(File.join(dir, ".env"), File.join(dir, ".ai-web", "tasks", "link.md"))
        File.symlink(File.expand_path(outside_secret), File.join(dir, ".ai-web", "design-candidates", "candidate-01.md"))
      rescue NotImplementedError, Errno::EACCES
        skip "symlink creation is not available in this Windows test environment"
      end
      encoded_path = URI.encode_www_form_component(dir)

      [".ai-web/tasks/link.md", ".ai-web/design-candidates/candidate-01.md"].each do |artifact_path|
        artifact = URI.encode_www_form_component(artifact_path)
        status, payload = app.call("GET", "/api/project/artifact?path=#{encoded_path}&artifact=#{artifact}", api_headers)
        assert_equal 403, status, artifact_path
        assert_match(/symlink|unsafe/i, payload["error"])
        refute_includes JSON.generate(payload), "daemon-symlink-env-do-not-leak"
        refute_includes JSON.generate(payload), "daemon-symlink-outside-do-not-leak"
      end
    end
  end

  def test_backend_artifact_read_run_json_summarizes_context_without_content_leak
    in_tmp do |dir|
      status, _init = app.call(
        "POST",
        "/api/project/command",
        api_headers,
        JSON.generate("path" => dir, "command" => "init", "args" => ["--profile", "D"])
      )
      assert_equal 200, status
      run_dir = File.join(dir, ".ai-web", "runs", "agent-run-test")
      FileUtils.mkdir_p(run_dir)
      run_path = File.join(run_dir, "agent-run.json")
      File.write(
        run_path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "status" => "passed",
          "context" => {
            "context_files" => [
              { "path" => "src/components/Hero.astro", "content" => "SECRET=run-json-context-do-not-leak" }
            ]
          },
          "stdout" => "SECRET=run-json-stdout-do-not-leak",
          "safe_field" => "visible-summary"
        )
      )
      encoded_path = URI.encode_www_form_component(dir)
      artifact = URI.encode_www_form_component(".ai-web/runs/agent-run-test/agent-run.json")
      status, payload = app.call("GET", "/api/project/artifact?path=#{encoded_path}&artifact=#{artifact}", api_headers)
      body = JSON.generate(payload)

      assert_equal 200, status
      assert_equal "application/json", payload.dig("artifact", "media_type")
      assert_equal true, payload.dig("artifact", "redacted")
      assert_equal "visible-summary", payload.dig("artifact", "json", "safe_field")
      refute payload.dig("artifact", "json").key?("context")
      refute payload.dig("artifact", "json").key?("stdout")
      refute_includes body, "run-json-context-do-not-leak"
      refute_includes body, "run-json-stdout-do-not-leak"
      refute_match(/\"content\"\s*:\s*\"SECRET=/, body)
    end
  end

  def test_project_and_codex_mutations_require_explicit_project_path
    status, payload = app.call(
      "POST",
      "/api/project/command",
      api_headers,
      JSON.generate("command" => "init", "args" => ["--profile", "D"])
    )
    assert_equal 400, status
    assert_match(/path/i, payload["error"])

    status, payload = app.call(
      "POST",
      "/api/codex/agent-run",
      api_headers,
      JSON.generate("task" => "latest", "dry_run" => true)
    )
    assert_equal 400, status
    assert_match(/path/i, payload["error"])
  end

  def test_real_deploy_is_blocked_by_bridge
    in_tmp do |dir|
      status, payload = app.call(
        "POST",
        "/api/project/command",
        api_headers,
        JSON.generate("path" => dir, "command" => "deploy", "dry_run" => false, "args" => ["--target", "vercel"])
      )
      assert_equal 403, status
      assert_match(/dry-run only/, payload["error"])
    end
  end

  def test_daemon_rejects_oversized_request_bodies
    daemon = Aiweb::LocalBackendDaemon.new(port: 0)

    error = assert_raises(Aiweb::UserError) do
      daemon.send(:read_body, StringIO.new(""), { "content-length" => (Aiweb::LocalBackendDaemon::MAX_BODY_BYTES + 1).to_s })
    end
    assert_match(/too large/, error.message)

    chunk_size = Aiweb::LocalBackendDaemon::MAX_BODY_BYTES + 1
    chunked = StringIO.new("#{chunk_size.to_s(16)}\r\n#{"a" * chunk_size}\r\n0\r\n\r\n")
    error = assert_raises(Aiweb::UserError) do
      daemon.send(:read_body, chunked, { "transfer-encoding" => "chunked" })
    end
    assert_match(/too large/, error.message)
  end

  def test_daemon_rejects_oversized_headers_and_invalid_content_length
    daemon = Aiweb::LocalBackendDaemon.new(port: 0)

    error = assert_raises(Aiweb::UserError) do
      daemon.send(:read_headers, StringIO.new("X-Test: #{"a" * Aiweb::LocalBackendDaemon::MAX_HEADER_LINE_BYTES}\r\n\r\n"))
    end
    assert_match(/header line too large/, error.message)

    error = assert_raises(Aiweb::UserError) do
      daemon.send(:read_body, StringIO.new(""), { "content-length" => "abc" })
    end
    assert_match(/invalid content length/, error.message)
  end

  def test_runs_payload_redacts_secret_looking_values_under_plain_keys
    in_tmp do |dir|
      run_dir = File.join(dir, ".ai-web", "runs", "manual")
      FileUtils.mkdir_p(run_dir)
      File.write(
        File.join(run_dir, "result.json"),
        JSON.generate("note" => "sk_live_#{'a' * 24}", "safe" => "visible")
      )

      encoded_path = URI.encode_www_form_component(dir)
      status, payload = app.call("GET", "/api/project/runs?path=#{encoded_path}", api_headers)
      assert_equal 200, status
      assert_equal "[redacted]", payload.dig("runs", 0, "note")
      assert_equal "visible", payload.dig("runs", 0, "safe")
    end
  end
end
