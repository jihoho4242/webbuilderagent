# frozen_string_literal: true

require "json"
require "fileutils"
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
  end

  def test_bridge_default_engine_root_points_to_repo_bin
    bridge = Aiweb::CodexCliBridge.new

    assert_equal REPO_ROOT, bridge.engine_root
    assert_equal AIWEB, bridge.aiweb_bin
    assert File.file?(bridge.aiweb_bin), "default bridge should execute repo bin/aiweb"
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
    assert_includes payload.dig("backend", "guardrails"), "engine-run is exposed only through dedicated job APIs, not the generic command bridge"
    assert_equal "AIWEB_DAEMON_TOKEN", payload.dig("backend", "auth", "api_token_env")
    assert_equal "X-Aiweb-Token", payload.dig("backend", "auth", "api_token_header")
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
      File.write(File.join(run_dir, "qa", "preview.json"), JSON.pretty_generate("schema_version" => 1, "status" => "ready", "url" => "http://127.0.0.1:4321/"))
      File.write(File.join(run_dir, "qa", "screenshots.json"), JSON.pretty_generate("schema_version" => 1, "status" => "captured", "screenshots" => [{ "viewport" => "desktop", "path" => ".ai-web/runs/#{run_id}/screenshots/desktop.png", "url" => "http://127.0.0.1:4321/" }]))
      File.write(File.join(run_dir, "artifacts", "opendesign-contract.json"), JSON.pretty_generate("schema_version" => 1, "status" => "ready", "contract_hash" => "sha256:abc"))
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
          "preview_path" => ".ai-web/runs/#{run_id}/qa/preview.json",
          "screenshot_evidence_path" => ".ai-web/runs/#{run_id}/qa/screenshots.json",
          "opendesign_contract_path" => ".ai-web/runs/#{run_id}/artifacts/opendesign-contract.json",
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
