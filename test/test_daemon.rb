# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "fileutils"
require "stringio"
require "tmpdir"
require "uri"
require "yaml"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "aiweb"

class AiwebDaemonTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)
  AIWEB = File.join(REPO_ROOT, "bin", "aiweb")
  API_TOKEN = "test-api-token"
  APPROVAL_TOKEN = "test-approval-token"

  def in_tmp
    Dir.mktmpdir("aiweb-daemon-test-") { |dir| yield dir }
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

  def test_daemon_plan_reports_backend_contract_and_absolute_engine_path
    payload = Aiweb::LocalBackendDaemon.plan(host: "127.0.0.1", port: 4242, bridge: Aiweb::CodexCliBridge.new(engine_root: REPO_ROOT))

    assert_equal "planned local backend daemon", payload["action_taken"]
    assert_equal "planned", payload.dig("backend", "status")
    assert_includes payload.dig("backend", "routes"), "POST /api/codex/agent-run"
    assert_equal REPO_ROOT, payload.dig("backend", "bridge", "engine_root")
    assert_equal AIWEB, payload.dig("backend", "bridge", "aiweb_bin")
    assert_includes payload.dig("backend", "routes"), "GET /api/project/artifact?path=PROJECT_PATH&artifact=ARTIFACT_PATH"
    assert_includes payload.dig("backend", "bridge", "allowed_commands"), "agent-run"
    assert_includes payload.dig("backend", "bridge", "allowed_commands"), "ingest-reference"
    assert_includes payload.dig("backend", "bridge", "guardrails"), "frontend sends structured JSON only; no raw shell commands"
    assert_equal "AIWEB_DAEMON_TOKEN", payload.dig("backend", "auth", "api_token_env")
    assert_equal "X-Aiweb-Token", payload.dig("backend", "auth", "api_token_header")
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

  def test_bridge_timeout_cleans_process_group_without_waiting_on_descendant_stdout
    bridge = Aiweb::CodexCliBridge.new(engine_root: REPO_ROOT, command_timeout: 0.2)
    code = <<~RUBY
      fork do
        STDOUT.sync = true
        sleep 3
      end
      sleep 3
    RUBY

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
      File.symlink(File.join(dir, ".env"), File.join(dir, ".ai-web", "tasks", "link.md"))
      File.symlink(File.expand_path(outside_secret), File.join(dir, ".ai-web", "design-candidates", "candidate-01.md"))
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
