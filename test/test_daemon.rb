# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "fileutils"
require "stringio"
require "tmpdir"
require "uri"

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
    assert_includes payload.dig("backend", "bridge", "allowed_commands"), "agent-run"
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
      assert_equal "passed", payload["status"]
      assert_equal "agent-run", payload.dig("bridge", "command")
      assert_equal ["--task", "latest", "--agent", "codex"], payload.dig("bridge", "args")
      assert_equal true, payload.dig("bridge", "dry_run")
      assert_equal "dry_run", payload.dig("stdout_json", "agent_run", "status")
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
      assert_equal "passed", payload["status"]
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
