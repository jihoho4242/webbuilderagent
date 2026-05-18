# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    def engine_run_preview_result(workspace_dir, paths, events, agent:, sandbox:)
      package_path = File.join(workspace_dir, "package.json")
      return engine_run_preview_skipped("package.json is missing in staged workspace") unless File.file?(package_path)

      package = JSON.parse(File.read(package_path))
      scripts = package["scripts"].is_a?(Hash) ? package["scripts"] : {}
      script = scripts.key?("dev") ? "dev" : (scripts.key?("preview") ? "preview" : nil)
      return engine_run_preview_skipped("package.json has no dev or preview script") unless script

      command = engine_run_package_command(workspace_dir, script, agent: agent, sandbox: sandbox)
      return engine_run_preview_skipped("package manager executable missing") unless command

      capability = { "mode" => "agentic_local", "goal" => "sandbox preview", "agent" => agent, "sandbox" => sandbox }
      tool_request = engine_run_tool_request("preview.#{script}", command, workspace_dir, capability, risk_class: "local_preview", expected_outputs: [relative(paths.fetch(:preview_path))])
      engine_run_event(paths.fetch(:events_path), events, "tool.requested", "preview requested sandbox #{script}", tool_request)
      engine_run_event(paths.fetch(:events_path), events, "policy.decision", "tool broker approved sandbox preview", tool_request.merge("decision" => "approved", "reason" => "preview uses local staged package script"))
      engine_run_event(paths.fetch(:events_path), events, "preview.started", "starting sandbox preview", command: command.join(" "))
      broker_event_offset = engine_run_tool_broker_event_count(workspace_dir)
      result = engine_run_start_preview_process(command, workspace_dir, paths, timeout_sec: 20, env: engine_run_verification_env(workspace_dir, paths, sandbox))
      engine_run_emit_workspace_tool_broker_events(workspace_dir, paths.fetch(:events_path), events, cycle: "preview:#{script}", offset: broker_event_offset)
      if result.fetch("status") == "ready"
        engine_run_event(paths.fetch(:events_path), events, "preview.ready", "sandbox preview reported ready", url: result["url"], exit_code: result["exit_code"], lifecycle: result["lifecycle"], pid: result["pid"])
        unless result["pid"]
          engine_run_event(paths.fetch(:events_path), events, "preview.stopped", "sandbox preview process already exited after readiness", status: result.fetch("status"), lifecycle: result["lifecycle"])
        end
      else
        engine_run_event(paths.fetch(:events_path), events, "preview.failed", "sandbox preview failed", exit_code: result["exit_code"])
        engine_run_event(paths.fetch(:events_path), events, "preview.stopped", "sandbox preview stopped", status: result.fetch("status"), lifecycle: result["lifecycle"])
      end
      result.merge("script" => script, "command" => command.join(" "))
    rescue JSON::ParserError => e
      engine_run_preview_failed("package.json is malformed in staged workspace: #{e.message}")
    end

    def engine_run_start_preview_process(command, cwd, paths, timeout_sec:, env:)
      stdout_path = File.join(paths.fetch(:logs_dir), "preview-stdout.log")
      stderr_path = File.join(paths.fetch(:logs_dir), "preview-stderr.log")
      FileUtils.mkdir_p(File.dirname(stdout_path))
      File.write(stdout_path, "")
      File.write(stderr_path, "")
      started_at = now
      pid = Aiweb::Runtime::ProcessLauncher.spawn(argv: command, cwd: cwd, env: env, stdout: stdout_path, stderr: stderr_path)
      url = nil
      exit_code = nil
      timed_out = false
      deadline = Time.now + timeout_sec
      loop do
        stdout = File.file?(stdout_path) ? File.read(stdout_path, 64_000) : ""
        url ||= engine_run_preview_url(stdout)
        exit_code = engine_run_try_reap_process(pid)
        break if url || !exit_code.nil?
        if Time.now >= deadline
          timed_out = true
          break
        end
        sleep 0.1
      end

      if url
        stability_deadline = Time.now + 1.0
        loop do
          exit_code = engine_run_try_reap_process(pid)
          break if exit_code || Time.now >= stability_deadline
          sleep 0.05
        end
        if exit_code && exit_code != 0
          stdout = File.file?(stdout_path) ? File.read(stdout_path, 64_000) : ""
          stderr = File.file?(stderr_path) ? File.read(stderr_path, 64_000) : ""
          return {
            "schema_version" => 1,
            "status" => "failed",
            "pid" => nil,
            "process_tree" => [],
            "lifecycle" => "exited_after_ready_with_error",
            "teardown_required" => false,
            "url" => url,
            "exit_code" => exit_code,
            "stdout_path" => relative(stdout_path),
            "stderr_path" => relative(stderr_path),
            "stdout" => agent_run_redact_process_output(stdout)[0, 2000],
            "stderr" => agent_run_redact_process_output(stderr)[0, 2000],
            "started_at" => started_at,
            "finished_at" => now,
            "blocking_issues" => ["preview exited with code #{exit_code} after reporting readiness"]
          }
        end
        live = exit_code.nil? && engine_run_process_alive?(pid)
        return {
          "schema_version" => 1,
          "status" => "ready",
          "pid" => live ? pid : nil,
          "process_tree" => live ? [pid] : [],
          "lifecycle" => live ? "persistent_ready" : "exited_after_ready",
          "teardown_required" => live,
          "url" => url,
          "exit_code" => exit_code,
          "stdout_path" => relative(stdout_path),
          "stderr_path" => relative(stderr_path),
          "stdout" => agent_run_redact_process_output(File.read(stdout_path, 64_000))[0, 2000],
          "stderr" => agent_run_redact_process_output(File.read(stderr_path, 64_000))[0, 2000],
          "started_at" => started_at,
          "ready_at" => now,
          "blocking_issues" => []
        }
      end

      engine_run_stop_process(pid) if exit_code.nil?
      stdout = File.file?(stdout_path) ? File.read(stdout_path, 64_000) : ""
      stderr = File.file?(stderr_path) ? File.read(stderr_path, 64_000) : ""
      exit_code ||= timed_out ? 124 : 1
      issue = timed_out ? "preview readiness timed out after #{timeout_sec}s" : "preview failed with exit code #{exit_code}"
      {
        "schema_version" => 1,
        "status" => "failed",
        "pid" => nil,
        "process_tree" => [],
        "lifecycle" => timed_out ? "readiness_timeout" : "exited_before_ready",
        "teardown_required" => false,
        "url" => nil,
        "exit_code" => exit_code,
        "stdout_path" => relative(stdout_path),
        "stderr_path" => relative(stderr_path),
        "stdout" => agent_run_redact_process_output(stdout)[0, 2000],
        "stderr" => agent_run_redact_process_output(stderr)[0, 2000],
        "started_at" => started_at,
        "finished_at" => now,
        "blocking_issues" => [issue]
      }
    rescue SystemCallError => e
      {
        "schema_version" => 1,
        "status" => "failed",
        "pid" => nil,
        "process_tree" => [],
        "lifecycle" => "spawn_failed",
        "teardown_required" => false,
        "url" => nil,
        "exit_code" => 127,
        "stdout" => "",
        "stderr" => agent_run_redact_process_output(e.message)[0, 2000],
        "blocking_issues" => ["preview failed to start: #{e.message}"]
      }
    end

    def engine_run_preview_skipped(reason)
      {
        "schema_version" => 1,
        "status" => "skipped",
        "blocking_issues" => [],
        "reason" => reason
      }
    end

    def engine_run_preview_failed(issue)
      {
        "schema_version" => 1,
        "status" => "failed",
        "blocking_issues" => [issue]
      }
    end

    def engine_run_preview_url(stdout)
      stdout.to_s[/https?:\/\/(?:127\.0\.0\.1|localhost|\[?::1\]?)[^\s'"<>]+/]
    end

  end
end
