# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

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

    def engine_run_screenshot_evidence(paths, preview, events, agent:, sandbox:)
      unless preview.fetch("status") == "ready"
        return {
          "schema_version" => 1,
          "status" => "skipped",
          "reason" => "preview is not ready",
          "runtime_attestation" => engine_run_browser_runtime_attestation(paths: paths, preview: preview, agent: agent, sandbox: sandbox, browser_commands: []),
          "screenshots" => [],
          "console_errors" => [],
          "network_errors" => [],
          "dom_snapshot" => engine_run_browser_evidence_unavailable("preview is not ready"),
          "a11y_report" => engine_run_browser_evidence_unavailable("preview is not ready"),
          "computed_style_summary" => engine_run_browser_evidence_unavailable("preview is not ready"),
          "interaction_states" => [],
          "keyboard_focus_traversal" => engine_run_browser_focus_unavailable("preview is not ready"),
          "action_recovery" => engine_run_browser_action_recovery_skipped("preview is not ready"),
          "action_loop" => engine_run_browser_action_loop_skipped("preview is not ready"),
          "blocking_issues" => []
        }
      end

      engine_run_event(paths.fetch(:events_path), events, "screenshot.capture.started", "capturing sandbox preview screenshots", preview_url: preview["url"])
      tool_request = engine_run_tool_request("browser.observe", ["node", "_aiweb/browser-observe.js", preview["url"].to_s], paths.fetch(:workspace_dir), { "mode" => "agentic_local", "goal" => "browser evidence", "agent" => agent, "sandbox" => sandbox }, risk_class: "localhost_browser_evidence", expected_outputs: [relative(paths.fetch(:screenshot_evidence_path))])
      engine_run_event(paths.fetch(:events_path), events, "tool.requested", "browser observation requested", tool_request)
      unless engine_run_local_preview_url?(preview["url"])
        issue = "browser observation only accepts local preview URLs on localhost, 127.0.0.1, or ::1"
        engine_run_event(paths.fetch(:events_path), events, "policy.decision", "tool broker blocked browser observation", tool_request.merge("decision" => "blocked", "reason" => issue))
        engine_run_event(paths.fetch(:events_path), events, "tool.blocked", "browser observation blocked by URL policy", preview_url: preview["url"])
        engine_run_stop_preview_if_needed(preview, paths, events, reason: "browser observation URL policy blocked")
        return {
          "schema_version" => 1,
          "status" => "failed",
          "preview_status" => preview["status"],
          "preview_url" => preview["url"],
          "network_policy" => "localhost-only",
          "runtime_attestation" => engine_run_browser_runtime_attestation(paths: paths, preview: preview, agent: agent, sandbox: sandbox, browser_commands: []),
          "screenshots" => [],
          "console_errors" => [],
          "network_errors" => [],
          "dom_snapshot" => engine_run_browser_evidence_unavailable(issue, status: "failed"),
          "a11y_report" => engine_run_browser_evidence_unavailable(issue, status: "failed"),
          "computed_style_summary" => engine_run_browser_evidence_unavailable(issue, status: "failed"),
          "interaction_states" => [],
          "keyboard_focus_traversal" => engine_run_browser_focus_unavailable(issue, status: "failed"),
          "action_recovery" => engine_run_browser_action_recovery_failed([issue]),
          "action_loop" => engine_run_browser_action_loop_failed([issue]),
          "blocking_issues" => [issue]
        }
      end
      engine_run_event(paths.fetch(:events_path), events, "policy.decision", "tool broker approved localhost browser observation", tool_request.merge("decision" => "approved", "reason" => "preview URL is local and evidence is redacted before display"))
      viewports = [
        ["desktop", 1440, 1000],
        ["tablet", 834, 1112],
        ["mobile", 390, 844]
      ]

      engine_run_write_browser_observer_script(paths.fetch(:workspace_dir))
      FileUtils.mkdir_p(paths.fetch(:screenshots_dir))
      workspace_evidence_dir = File.join(paths.fetch(:workspace_dir), "_aiweb", "browser-evidence")
      FileUtils.mkdir_p(workspace_evidence_dir)

      captures = []
      blockers = []
      browser_commands = []
      viewports.each do |viewport, width, height|
        workspace_screenshot = File.join("_aiweb", "browser-evidence", "#{viewport}.png")
        workspace_json = File.join("_aiweb", "browser-evidence", "#{viewport}.json")
        final_screenshot = File.join(paths.fetch(:screenshots_dir), "#{viewport}.png")
        command = engine_run_browser_observe_command(
          paths.fetch(:workspace_dir),
          preview["url"].to_s,
          viewport,
          width,
          height,
          workspace_screenshot,
          workspace_json,
          agent: agent,
          sandbox: sandbox
        )
        browser_commands << command
        engine_run_event(paths.fetch(:events_path), events, "tool.started", "starting browser observation", command: command.join(" "), viewport: viewport)
        broker_event_offset = engine_run_tool_broker_event_count(paths.fetch(:workspace_dir))
        stdout, stderr, status = engine_run_capture_command(command, paths.fetch(:workspace_dir), 90, env: engine_run_verification_env(paths.fetch(:workspace_dir), paths, sandbox))
        engine_run_emit_workspace_tool_broker_events(paths.fetch(:workspace_dir), paths.fetch(:events_path), events, cycle: "browser:#{viewport}", offset: broker_event_offset)
        if status != 0
          failed_capture = engine_run_read_browser_capture_if_present(paths.fetch(:workspace_dir), workspace_json)
          if failed_capture
            failed_capture["viewport"] ||= viewport
            failed_capture["width"] ||= width
            failed_capture["height"] ||= height
            failed_capture["stdout"] = agent_run_redact_process_output(stdout.to_s)[0, 1000] unless stdout.to_s.empty?
            failed_capture["stderr"] = agent_run_redact_process_output(stderr.to_s)[0, 1000] unless stderr.to_s.empty?
            blockers.concat(engine_run_browser_capture_blockers(failed_capture, viewport))
            captures << failed_capture
          end
          blockers << "browser observation #{viewport} failed with exit code #{status}: #{agent_run_redact_process_output(stderr.to_s)[0, 300]}".strip
          engine_run_event(paths.fetch(:events_path), events, "tool.finished", "browser observation failed", status: "failed", exit_code: status, viewport: viewport)
          next
        end

        capture = engine_run_read_browser_capture(paths.fetch(:workspace_dir), workspace_json)
        capture["stdout"] = agent_run_redact_process_output(stdout.to_s)[0, 1000] unless stdout.to_s.empty?
        capture["stderr"] = agent_run_redact_process_output(stderr.to_s)[0, 1000] unless stderr.to_s.empty?
        source_screenshot = File.join(paths.fetch(:workspace_dir), workspace_screenshot)
        unless File.file?(source_screenshot)
          blockers << "browser observation #{viewport} did not create screenshot evidence"
          engine_run_event(paths.fetch(:events_path), events, "tool.finished", "browser observation missing screenshot", status: "failed", exit_code: 1, viewport: viewport)
          next
        end
        png_evidence = engine_run_png_evidence(source_screenshot)
        unless png_evidence["valid"]
          blockers << "browser observation #{viewport} screenshot is not valid PNG evidence: #{png_evidence["reason"]}"
          engine_run_event(paths.fetch(:events_path), events, "tool.finished", "browser observation invalid screenshot", status: "failed", exit_code: 1, viewport: viewport, reason: png_evidence["reason"])
          next
        end
        FileUtils.cp(source_screenshot, final_screenshot)
        capture["screenshot"] ||= {}
        capture["screenshot"]["path"] = relative(final_screenshot)
        capture["screenshot"]["sha256"] = "sha256:#{Digest::SHA256.file(final_screenshot).hexdigest}"
        capture["screenshot"]["bytes"] = File.size(final_screenshot)
        capture["screenshot"]["capture_mode"] = "playwright_browser"
        capture["screenshot"]["mime_type"] = "image/png"
        capture["screenshot"]["png_signature_valid"] = true
        capture["screenshot"]["image_width"] = png_evidence["width"]
        capture["screenshot"]["image_height"] = png_evidence["height"]
        blockers.concat(engine_run_browser_capture_blockers(capture, viewport))
        captures << capture
        engine_run_event(paths.fetch(:events_path), events, "tool.finished", "browser observation finished", status: "passed", exit_code: status, viewport: viewport)
      end

      runtime_attestation = engine_run_browser_runtime_attestation(paths: paths, preview: preview, agent: agent, sandbox: sandbox, browser_commands: browser_commands)
      blockers.concat(runtime_attestation.fetch("blocking_issues")) unless runtime_attestation.fetch("status") == "passed"
      result = engine_run_browser_evidence_manifest(preview, captures, blockers, runtime_attestation)
      if blockers.empty?
        engine_run_event(paths.fetch(:events_path), events, "screenshot.capture.finished", "captured sandbox preview screenshots", count: result.fetch("screenshots").length)
      else
        engine_run_event(paths.fetch(:events_path), events, "screenshot.capture.failed", "browser evidence hard gate failed", blocking_issues: blockers)
      end
      engine_run_event(paths.fetch(:events_path), events, "browser.observation.recorded", "recorded browser observation evidence for visual QA", viewports: result.fetch("screenshots").map { |shot| shot["viewport"] }, preview_url: preview["url"], evidence: %w[screenshot dom_snapshot a11y computed_style interaction_states keyboard_focus action_recovery action_loop console_errors network_errors], status: result["status"])
      engine_run_event(paths.fetch(:events_path), events, "browser.action_recovery.recorded", "recorded reversible browser action and recovery evidence", viewports: result.dig("action_recovery", "viewports"), preview_url: preview["url"], status: result.dig("action_recovery", "status"), blocking_issues: result.dig("action_recovery", "blocking_issues"))
      engine_run_event(paths.fetch(:events_path), events, "browser.action_loop.recorded", "recorded bounded safe local browser action loop evidence", viewports: result.dig("action_loop", "viewports"), preview_url: preview["url"], status: result.dig("action_loop", "status"), autonomy_level: result.dig("action_loop", "autonomy_level"), blocking_issues: result.dig("action_loop", "blocking_issues"))
      engine_run_stop_preview_if_needed(preview, paths, events, reason: "browser observation complete")
      result
    rescue SystemCallError, JSON::ParserError => e
      engine_run_event(paths.fetch(:events_path), events, "screenshot.capture.failed", "screenshot capture failed", error: e.message)
      engine_run_stop_preview_if_needed(preview, paths, events, reason: "browser observation failed")
      {
        "schema_version" => 1,
        "status" => "failed",
        "runtime_attestation" => engine_run_browser_runtime_attestation(paths: paths, preview: preview, agent: agent, sandbox: sandbox, browser_commands: []),
        "screenshots" => [],
        "console_errors" => [],
        "network_errors" => [],
        "dom_snapshot" => engine_run_browser_evidence_unavailable("screenshot capture failed: #{e.message}", status: "failed"),
        "a11y_report" => engine_run_browser_evidence_unavailable("screenshot capture failed: #{e.message}", status: "failed"),
        "computed_style_summary" => engine_run_browser_evidence_unavailable("screenshot capture failed: #{e.message}", status: "failed"),
        "interaction_states" => [],
        "keyboard_focus_traversal" => engine_run_browser_focus_unavailable("screenshot capture failed: #{e.message}", status: "failed"),
        "action_recovery" => engine_run_browser_action_recovery_failed(["screenshot capture failed: #{e.message}"]),
        "action_loop" => engine_run_browser_action_loop_failed(["screenshot capture failed: #{e.message}"]),
        "blocking_issues" => ["screenshot capture failed: #{e.message}"]
      }
    end

    def engine_run_stop_preview_if_needed(preview, paths, events, reason:)
      pid = preview["pid"].to_i
      return unless pid.positive?

      stop_status = engine_run_stop_process(pid)
      preview["pid"] = nil
      preview["process_tree"] = []
      preview["teardown_required"] = false
      preview["stopped_at"] = now
      preview["stop_status"] = stop_status
      if preview["stdout_path"]
        full_stdout = File.join(root, preview["stdout_path"].to_s)
        preview["stdout"] = agent_run_redact_process_output(File.read(full_stdout, 64_000))[0, 2000] if File.file?(full_stdout)
      end
      if preview["stderr_path"]
        full_stderr = File.join(root, preview["stderr_path"].to_s)
        preview["stderr"] = agent_run_redact_process_output(File.read(full_stderr, 64_000))[0, 2000] if File.file?(full_stderr)
      end
      engine_run_event(paths.fetch(:events_path), events, "preview.stopped", "sandbox preview stopped", status: preview.fetch("status"), lifecycle: preview["lifecycle"], stop_status: stop_status, reason: reason)
    end

    def engine_run_local_preview_url?(url)
      uri = URI.parse(url.to_s)
      uri.scheme == "http" && %w[localhost 127.0.0.1 ::1].include?(uri.host.to_s)
    rescue URI::InvalidURIError
      false
    end

    def engine_run_browser_observe_command(workspace_dir, url, viewport, width, height, screenshot_path, evidence_path, agent:, sandbox:)
      command = [
        "node",
        File.join("_aiweb", "browser-observe.js"),
        url,
        viewport,
        width.to_s,
        height.to_s,
        screenshot_path,
        evidence_path
      ]
      if engine_run_container_worker_agent?(agent) && !sandbox.to_s.strip.empty?
        return engine_run_sandbox_tool_command(sandbox, workspace_dir, command, tool: "browser_observe", agent: agent)
      end
      command
    end

    def engine_run_read_browser_capture(workspace_dir, evidence_path)
      full = File.join(workspace_dir, evidence_path)
      raise JSON::ParserError, "browser observation evidence missing: #{evidence_path}" unless File.file?(full)

      data = JSON.parse(File.read(full, 200_000))
      data.is_a?(Hash) ? data : { "schema_version" => 1, "status" => "failed", "blocking_issues" => ["browser observation evidence was not an object"] }
    end

    def engine_run_read_browser_capture_if_present(workspace_dir, evidence_path)
      full = File.join(workspace_dir, evidence_path)
      return nil unless File.file?(full)

      engine_run_read_browser_capture(workspace_dir, evidence_path)
    rescue JSON::ParserError, SystemCallError => e
      {
        "schema_version" => 1,
        "status" => "failed",
        "console_errors" => [],
        "network_errors" => [],
        "blocking_issues" => ["browser observation failed and evidence could not be parsed: #{e.message}"]
      }
    end

    def engine_run_png_evidence(path)
      header = File.binread(path, 33)
      signature = "\x89PNG\r\n\x1A\n".b
      return { "valid" => false, "reason" => "png header is too short" } if header.bytesize < 33
      return { "valid" => false, "reason" => "png signature mismatch" } unless header.byteslice(0, 8) == signature
      return { "valid" => false, "reason" => "missing IHDR chunk" } unless header.byteslice(12, 4) == "IHDR"

      width, height = header.byteslice(16, 8).unpack("NN")
      return { "valid" => false, "reason" => "invalid PNG dimensions" } if width.to_i <= 1 || height.to_i <= 1
      return { "valid" => false, "reason" => "PNG dimensions look like placeholder output" } if File.size(path) < 128

      { "valid" => true, "width" => width, "height" => height }
    rescue SystemCallError => e
      { "valid" => false, "reason" => e.message }
    end

    def engine_run_browser_capture_blockers(capture, viewport)
      blockers = Array(capture["blocking_issues"])
      blockers << "browser observation #{viewport} did not finish successfully" unless capture["status"] == "captured"
      blockers << "browser observation #{viewport} missing DOM snapshot" unless capture.dig("dom_snapshot", "status") == "captured"
      blockers << "browser observation #{viewport} missing accessibility snapshot" unless capture.dig("a11y_report", "status") == "captured"
      blockers << "browser observation #{viewport} missing computed style evidence" unless capture.dig("computed_style_summary", "status") == "captured"
      console_errors = Array(capture["console_errors"])
      network_errors = Array(capture["network_errors"])
      blockers << "browser observation #{viewport} recorded console errors: #{console_errors.length}" unless console_errors.empty?
      blockers << "browser observation #{viewport} recorded network errors: #{network_errors.length}" unless network_errors.empty?
      required_states = %w[default hover focus-visible active disabled loading empty error success]
      observed_states = Array(capture["interaction_states"]).each_with_object({}) { |state, memo| memo[state["state"].to_s] = state["status"].to_s }
      missing_states = required_states.reject { |state| %w[captured not_applicable].include?(observed_states[state]) }
      blockers << "browser observation #{viewport} missing interaction state coverage: #{missing_states.join(", ")}" unless missing_states.empty?
      blockers << "browser observation #{viewport} missing keyboard focus traversal" unless capture.dig("keyboard_focus_traversal", "status") == "captured"
      action_recovery = capture["action_recovery"]
      blockers << "browser observation #{viewport} missing browser action/recovery loop" unless action_recovery.is_a?(Hash) && action_recovery["status"] == "captured"
      blockers << "browser observation #{viewport} missing browser action/recovery unsafe-navigation policy enforcement" unless action_recovery.is_a?(Hash) && action_recovery["unsafe_navigation_policy_enforced"] == true
      meaningful_actions = Array(action_recovery && action_recovery["actions"]).any? do |entry|
        entry.is_a?(Hash) && entry["status"].to_s != "not_applicable" && Array(entry["actions"]).any?
      end
      blockers << "browser observation #{viewport} missing meaningful safe browser action steps" unless meaningful_actions
      blockers << "browser observation #{viewport} missing browser action recovery steps" if action_recovery.is_a?(Hash) && Array(action_recovery["recovery_steps"]).empty?
      blockers.concat(Array(action_recovery && action_recovery["blocking_issues"]).map { |issue| "browser observation #{viewport} action/recovery: #{issue}" })
      blockers
    end

    def engine_run_browser_runtime_attestation(paths:, preview:, agent:, sandbox:, browser_commands:)
      sandbox_required = agent.to_s == "openmanus" && !sandbox.to_s.strip.empty?
      preview_command = preview.to_h["command"].to_s
      browser_tool_wrapped = if sandbox_required
                               Array(browser_commands).all? { |command| File.basename(command.first.to_s).sub(/\.cmd\z/i, "") == sandbox.to_s }
                             else
                               true
                             end
      preview_tool_wrapped = if sandbox_required
                               File.basename(preview_command.split(/\s+/).first.to_s).sub(/\.cmd\z/i, "") == sandbox.to_s
                             else
                               true
                             end
      blockers = []
      blockers << "browser evidence preview command did not use the selected sandbox wrapper" if sandbox_required && !preview_tool_wrapped
      blockers << "browser evidence observation command did not use the selected sandbox wrapper" if sandbox_required && !browser_tool_wrapped
      blockers << "browser evidence requires a ready local preview before attestation" unless preview.to_h["status"] == "ready"
      blockers << "browser evidence did not record any browser observation commands" if preview.to_h["status"] == "ready" && Array(browser_commands).empty?
      {
        "schema_version" => 1,
        "status" => blockers.empty? ? "passed" : (preview.to_h["status"] == "ready" ? "failed" : "skipped"),
        "agent" => agent,
        "sandbox" => sandbox,
        "sandbox_required" => sandbox_required,
        "workspace_path" => relative(paths.fetch(:workspace_dir)),
        "same_staged_workspace" => true,
        "same_container_instance" => false,
        "same_container_instance_reason" => "local Docker/Podman tool commands are isolated invocations; aiweb attests shared staged workspace and sandbox/tool-broker boundary, not a single long-lived container",
        "preview_status" => preview.to_h["status"],
        "preview_url" => preview.to_h["url"],
        "preview_command" => preview_command.empty? ? nil : preview_command,
        "preview_tool_wrapped" => preview_tool_wrapped,
        "browser_observe_commands" => Array(browser_commands).map { |command| command.join(" ") },
        "browser_tool_wrapped" => browser_tool_wrapped,
        "tool_broker_bin_path" => "_aiweb/tool-broker-bin",
        "tool_broker_path_prepend_required" => true,
        "network_policy" => "localhost-only",
        "browser_evidence_workspace_dir" => relative(File.join(paths.fetch(:workspace_dir), "_aiweb", "browser-evidence")),
        "blocking_issues" => blockers
      }
    end

    def engine_run_browser_evidence_manifest(preview, captures, blockers, runtime_attestation)
      screenshots = captures.select { |capture| capture.dig("screenshot", "path") && capture.dig("screenshot", "sha256") }.map do |capture|
        shot = capture.fetch("screenshot", {})
        {
          "viewport" => capture.fetch("viewport"),
          "width" => capture.fetch("width"),
          "height" => capture.fetch("height"),
          "url" => preview["url"],
          "path" => shot.fetch("path"),
          "sha256" => shot.fetch("sha256"),
          "bytes" => shot.fetch("bytes"),
          "capture_mode" => shot.fetch("capture_mode"),
          "mime_type" => shot.fetch("mime_type"),
          "png_signature_valid" => shot.fetch("png_signature_valid"),
          "image_width" => shot.fetch("image_width"),
          "image_height" => shot.fetch("image_height")
        }
      end
      {
        "schema_version" => 1,
        "status" => blockers.empty? && captures.length == 3 ? "captured" : "failed",
        "preview_status" => preview["status"],
        "preview_url" => preview["url"],
        "network_policy" => "localhost-only",
        "browser_runtime" => "playwright",
        "sandbox_boundary" => "staged_workspace_tool_broker",
        "runtime_attestation" => runtime_attestation,
        "screenshots" => screenshots,
        "viewport_evidence" => captures,
        "console_errors" => engine_run_merge_browser_observations(captures, "console_errors"),
        "network_errors" => engine_run_merge_browser_observations(captures, "network_errors"),
        "dom_snapshot" => engine_run_merge_browser_evidence(captures, "dom_snapshot"),
        "a11y_report" => engine_run_merge_browser_evidence(captures, "a11y_report"),
        "computed_style_summary" => engine_run_merge_browser_evidence(captures, "computed_style_summary"),
        "interaction_states" => engine_run_merge_interaction_states(captures),
        "keyboard_focus_traversal" => engine_run_merge_focus_traversal(captures),
        "action_recovery" => engine_run_merge_action_recovery(captures),
        "action_loop" => engine_run_browser_action_loop(captures),
        "blocking_issues" => blockers.uniq
      }
    end

    def engine_run_browser_action_recovery_skipped(reason)
      {
        "schema_version" => 1,
        "status" => "skipped",
        "required" => true,
        "policy" => "localhost-only reversible UI actions; external navigation is blocked and recorded",
        "reason" => reason.to_s,
        "viewports" => [],
        "action_sequences" => [],
        "recovery_attempts" => [],
        "external_requests_blocked" => [],
        "blocking_issues" => []
      }
    end

    def engine_run_browser_action_recovery_failed(blockers)
      {
        "schema_version" => 1,
        "status" => "failed",
        "required" => true,
        "policy" => "localhost-only reversible UI actions; external navigation is blocked and recorded",
        "viewports" => [],
        "action_sequences" => [],
        "recovery_attempts" => [],
        "external_requests_blocked" => [],
        "blocking_issues" => Array(blockers).compact.map(&:to_s)
      }
    end

    def engine_run_browser_action_loop_skipped(reason)
      engine_run_browser_action_loop_envelope(
        status: "skipped",
        viewports: [],
        planned_steps: [],
        executed_steps: [],
        recovery_steps: [],
        blocked_steps: [],
        blocking_issues: [],
        reason: reason.to_s
      )
    end

    def engine_run_browser_action_loop_failed(blockers)
      engine_run_browser_action_loop_envelope(
        status: "failed",
        viewports: [],
        planned_steps: [],
        executed_steps: [],
        recovery_steps: [],
        blocked_steps: [],
        blocking_issues: Array(blockers).compact.map(&:to_s)
      )
    end

    def engine_run_browser_evidence_unavailable(reason, status: "skipped")
      {
        "schema_version" => 1,
        "status" => status,
        "reason" => reason.to_s,
        "capture_mode" => nil,
        "viewports" => [],
        "items" => [],
        "blocking_issues" => status == "failed" ? [reason.to_s] : []
      }
    end

    def engine_run_browser_focus_unavailable(reason, status: "skipped")
      {
        "schema_version" => 1,
        "status" => status,
        "required" => true,
        "reason" => reason.to_s,
        "viewports" => []
      }
    end

    def engine_run_merge_browser_observations(captures, key)
      captures.flat_map do |capture|
        Array(capture[key]).map do |entry|
          if entry.is_a?(Hash)
            entry.merge("viewport" => entry["viewport"] || capture["viewport"])
          else
            { "viewport" => capture["viewport"], "message" => entry.to_s }
          end
        end
      end
    end

    def engine_run_merge_browser_evidence(captures, key)
      items = captures.map { |capture| capture[key] }.compact
      status = captures.any? && items.all? { |item| item["status"] == "captured" } && items.length == captures.length ? "captured" : "failed"
      {
        "schema_version" => 1,
        "status" => status,
        "capture_mode" => "playwright_browser",
        "viewports" => captures.map { |capture| capture["viewport"] },
        "items" => items,
        "required_fields" => %w[route viewport selector data_aiweb_id text_role computed_styles bounding_box]
      }
    end

    def engine_run_merge_interaction_states(captures)
      names = %w[default hover focus-visible active disabled loading empty error success]
      names.map do |name|
        per_viewport = captures.map do |capture|
          state = Array(capture["interaction_states"]).find { |item| item["state"] == name } || {}
          { "viewport" => capture["viewport"], "status" => state["status"], "evidence" => Array(state["evidence"]) }
        end
        {
          "state" => name,
          "status" => captures.any? && per_viewport.all? { |item| %w[captured not_applicable].include?(item["status"]) } ? "captured" : "failed",
          "viewports" => per_viewport
        }
      end
    end

    def engine_run_merge_focus_traversal(captures)
      {
        "schema_version" => 1,
        "status" => captures.any? && captures.all? { |capture| capture.dig("keyboard_focus_traversal", "status") == "captured" } ? "captured" : "failed",
        "required" => true,
        "viewports" => captures.map do |capture|
          {
            "viewport" => capture["viewport"],
            "steps" => Array(capture.dig("keyboard_focus_traversal", "steps"))
          }
        end
      }
    end

    def engine_run_merge_action_recovery(captures)
      per_viewport = captures.map do |capture|
        evidence = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        {
          "viewport" => capture["viewport"],
          "status" => evidence["status"] || "failed",
          "action_count" => Array(evidence["actions"]).length,
          "recovery_count" => Array(evidence["recovery_steps"]).length,
          "actionable_target_count" => evidence["actionable_target_count"].to_i,
          "unsafe_navigation_policy_enforced" => evidence["unsafe_navigation_policy_enforced"] == true,
          "unsafe_navigation_blocked" => evidence["unsafe_navigation_blocked"] == true,
          "external_request_block_count" => Array(evidence["external_requests_blocked"]).length,
          "blocking_issues" => Array(evidence["blocking_issues"])
        }
      end
      blockers = per_viewport.flat_map { |entry| Array(entry["blocking_issues"]).map { |issue| "#{entry["viewport"]}: #{issue}" } }
      action_sequences = captures.flat_map do |capture|
        evidence = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(evidence["actions"]).map do |action|
          action.is_a?(Hash) ? action.merge("viewport" => capture["viewport"]) : { "viewport" => capture["viewport"], "action" => action.to_s }
        end
      end
      recovery_attempts = captures.flat_map do |capture|
        evidence = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(evidence["recovery_steps"]).map do |step|
          step.is_a?(Hash) ? step.merge("viewport" => capture["viewport"]) : { "viewport" => capture["viewport"], "action" => step.to_s }
        end
      end
      external_requests_blocked = captures.flat_map do |capture|
        evidence = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(evidence["external_requests_blocked"]).map do |entry|
          entry.is_a?(Hash) ? entry.merge("viewport" => entry["viewport"] || capture["viewport"]) : { "viewport" => capture["viewport"], "url" => entry.to_s }
        end
      end
      {
        "schema_version" => 1,
        "status" => captures.any? && per_viewport.all? { |entry| entry["status"] == "captured" } && blockers.empty? ? "captured" : "failed",
        "required" => true,
        "policy" => "localhost-only reversible UI actions; external navigation is blocked and recorded",
        "viewports" => per_viewport,
        "action_sequences" => action_sequences,
        "recovery_attempts" => recovery_attempts,
        "external_requests_blocked" => external_requests_blocked,
        "blocking_issues" => blockers
      }
    end

    def engine_run_browser_action_loop(captures)
      viewports = captures.map do |capture|
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        actions = Array(recovery["actions"])
        recovery_steps = Array(recovery["recovery_steps"])
        blocked_requests = Array(recovery["external_requests_blocked"])
        blocking_issues = Array(recovery["blocking_issues"])
        {
          "viewport" => capture["viewport"],
          "status" => recovery["status"] == "captured" && blocking_issues.empty? ? "captured" : "failed",
          "planned_step_count" => actions.length,
          "executed_step_count" => actions.count { |action| action.is_a?(Hash) && %w[captured passed not_applicable].include?(action["status"].to_s) },
          "recovery_step_count" => recovery_steps.length + actions.sum { |action| action.is_a?(Hash) ? Array(action["recovery"]).length : 0 },
          "blocked_step_count" => blocked_requests.length,
          "unsafe_navigation_policy_enforced" => recovery["unsafe_navigation_policy_enforced"] == true,
          "unsafe_navigation_blocked" => recovery["unsafe_navigation_blocked"] == true,
          "blocking_issues" => blocking_issues
        }
      end
      planned_steps = captures.flat_map do |capture|
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(recovery["actions"]).map do |action|
          descriptor = action.is_a?(Hash) ? action : { "action" => action.to_s }
          descriptor.slice("index", "selector", "text_role", "data_aiweb_id", "bounding_box", "reason").merge(
            "viewport" => capture["viewport"],
            "planned_actions" => Array(descriptor["actions"]).map { |step| step.is_a?(Hash) ? step.slice("name", "status", "reason") : { "name" => step.to_s } }
          )
        end
      end
      executed_steps = captures.flat_map do |capture|
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(recovery["actions"]).flat_map do |action|
          next [] unless action.is_a?(Hash)

          Array(action["actions"]).map do |step|
            step = step.is_a?(Hash) ? step : { "name" => step.to_s }
            {
              "viewport" => capture["viewport"],
              "target_index" => action["index"],
              "selector" => action["selector"],
              "name" => step["name"],
              "status" => step["status"] || "recorded",
              "reason" => step["reason"]
            }.compact
          end
        end
      end
      recovery_steps = captures.flat_map do |capture|
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        direct_steps = Array(recovery["recovery_steps"]).map do |step|
          step = step.is_a?(Hash) ? step : { "action" => step.to_s }
          step.merge("viewport" => capture["viewport"])
        end
        nested_steps = Array(recovery["actions"]).flat_map do |action|
          next [] unless action.is_a?(Hash)

          Array(action["recovery"]).map do |step|
            step = step.is_a?(Hash) ? step : { "name" => step.to_s }
            step.merge(
              "viewport" => capture["viewport"],
              "target_index" => action["index"],
              "selector" => action["selector"]
            )
          end
        end
        direct_steps + nested_steps
      end
      blocked_steps = captures.flat_map do |capture|
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(recovery["external_requests_blocked"]).map do |entry|
          entry = entry.is_a?(Hash) ? entry : { "url" => entry.to_s }
          entry.merge("viewport" => capture["viewport"], "policy" => "non_local_request_blocked")
        end
      end
      scenarios = engine_run_browser_action_loop_scenarios(captures)
      scenario_plan = scenarios.map do |scenario|
        scenario.slice("scenario_id", "viewport", "goal", "policy", "target_count", "steps")
      end
      scenario_results = scenarios.map do |scenario|
        scenario.slice("scenario_id", "viewport", "status", "step_count", "recovery_step_count", "blocked_step_count", "blocking_issues")
      end
      multi_step_evidence = engine_run_browser_action_loop_multi_step_evidence(
        scenario_results: scenario_results,
        executed_steps: executed_steps,
        recovery_steps: recovery_steps,
        blocked_steps: blocked_steps
      )
      blockers = viewports.flat_map { |entry| Array(entry["blocking_issues"]).map { |issue| "#{entry["viewport"]}: #{issue}" } }
      status = captures.length == 3 &&
        viewports.all? { |entry| entry["status"] == "captured" && entry["unsafe_navigation_policy_enforced"] == true } &&
        scenario_results.length == captures.length &&
        scenario_results.all? { |scenario| scenario["status"] == "captured" } &&
        multi_step_evidence["multi_step_sequences_observed"] == true &&
        multi_step_evidence["all_scenarios_recovered"] == true &&
        executed_steps.any? &&
        recovery_steps.any? &&
        blockers.empty? ? "captured" : "failed"
      envelope = engine_run_browser_action_loop_envelope(
        status: status,
        viewports: viewports,
        planned_steps: planned_steps,
        executed_steps: executed_steps,
        recovery_steps: recovery_steps,
        blocked_steps: blocked_steps,
        scenario_plan: scenario_plan,
        scenario_results: scenario_results,
        multi_step_evidence: multi_step_evidence,
        blocking_issues: blockers
      )
      envelope["limits"]["observed_viewports"] = captures.length
      envelope
    end

    def engine_run_browser_action_loop_scenarios(captures)
      captures.map do |capture|
        viewport = capture["viewport"].to_s
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        actions = Array(recovery["actions"]).select { |action| action.is_a?(Hash) }
        direct_recovery_steps = Array(recovery["recovery_steps"])
        blocking_issues = Array(recovery["blocking_issues"]).compact.map(&:to_s)
        step_count = actions.sum { |action| Array(action["actions"]).length }
        recovery_step_count = direct_recovery_steps.length + actions.sum { |action| Array(action["recovery"]).length }
        blocked_step_count = Array(recovery["external_requests_blocked"]).length
        steps = actions.first(5).map do |action|
          {
            "target_index" => action["index"],
            "selector" => action["selector"],
            "text_role" => action["text_role"],
            "data_aiweb_id" => action["data_aiweb_id"],
            "planned_actions" => Array(action["actions"]).map do |step|
              step = step.is_a?(Hash) ? step : { "name" => step.to_s }
              step.slice("name", "status", "reason")
            end,
            "recovery_actions" => Array(action["recovery"]).map do |step|
              step = step.is_a?(Hash) ? step : { "name" => step.to_s }
              step.slice("name", "action", "status", "reason")
            end
          }.compact
        end
        status = recovery["status"] == "captured" &&
          blocking_issues.empty? &&
          step_count >= 2 &&
          recovery_step_count.positive? ? "captured" : "failed"
        {
          "scenario_id" => "safe-local-ui-probe-#{viewport}",
          "viewport" => viewport,
          "goal" => "probe reversible local UI interactions and recover preview state",
          "policy" => {
            "network" => "localhost-only",
            "reversible_only" => true,
            "external_navigation_blocked" => true,
            "form_submission_allowed" => false
          },
          "target_count" => actions.length,
          "steps" => steps,
          "status" => status,
          "step_count" => step_count,
          "recovery_step_count" => recovery_step_count,
          "blocked_step_count" => blocked_step_count,
          "blocking_issues" => blocking_issues
        }
      end
    end

    def engine_run_browser_action_loop_multi_step_evidence(scenario_results:, executed_steps:, recovery_steps:, blocked_steps:)
      results = Array(scenario_results)
      {
        "scenario_count" => results.length,
        "multi_step_sequences_observed" => results.any? { |scenario| scenario["step_count"].to_i >= 2 } || Array(executed_steps).length >= 2,
        "all_scenarios_recovered" => results.any? && results.all? { |scenario| scenario["status"] == "captured" && scenario["recovery_step_count"].to_i.positive? },
        "total_executed_step_count" => Array(executed_steps).length,
        "total_recovery_step_count" => Array(recovery_steps).length,
        "total_blocked_step_count" => Array(blocked_steps).length,
        "policy" => {
          "network" => "localhost-only",
          "reversible_only" => true,
          "external_navigation_blocked" => true,
          "form_submission_allowed" => false
        }
      }
    end

    def engine_run_browser_action_loop_envelope(status:, viewports:, planned_steps:, executed_steps:, recovery_steps:, blocked_steps:, blocking_issues:, reason: nil, scenario_plan: [], scenario_results: [], multi_step_evidence: nil)
      scenario_results = Array(scenario_results)
      multi_step_evidence ||= engine_run_browser_action_loop_multi_step_evidence(
        scenario_results: scenario_results,
        executed_steps: executed_steps,
        recovery_steps: recovery_steps,
        blocked_steps: blocked_steps
      )
      {
        "schema_version" => 1,
        "status" => status,
        "required" => true,
        "loop_type" => "bounded_safe_local_observation_loop",
        "goal_source" => "selected_design_fixture_and_browser_evidence",
        "autonomy_level" => "deterministic_observation_not_open_ended",
        "planner" => "static_safe_action_plan",
        "policy" => {
          "network" => "localhost-only",
          "allowed_actions" => %w[scroll_into_view hover focus fill_text_probe restore_input_value click_same_origin_anchor click_toggle_button escape restore_preview_url],
          "blocked_actions" => %w[external_navigation form_submit destructive_click credential_entry file_upload payment deploy],
          "reversible_only" => true,
          "external_navigation_blocked" => true,
          "form_submission_allowed" => false
        },
        "limits" => {
          "expected_viewports" => %w[desktop tablet mobile],
          "observed_viewports" => Array(viewports).length,
          "max_targets_per_viewport" => 5,
          "max_steps_per_target" => 4,
          "timeout_seconds_per_viewport" => 90
        },
        "stop_condition" => "all_viewports_observed_and_recovered_or_policy_blocked",
        "viewports" => Array(viewports),
        "planned_steps" => Array(planned_steps),
        "executed_steps" => Array(executed_steps),
        "recovery_steps" => Array(recovery_steps),
        "blocked_steps" => Array(blocked_steps),
        "scenario_plan" => Array(scenario_plan),
        "scenario_results" => scenario_results,
        "multi_step_evidence" => multi_step_evidence,
        "limitations" => [
          "not a production open-ended browser agent",
          "does not submit forms or perform irreversible clicks",
          "does not navigate beyond the local preview origin"
        ],
        "blocking_issues" => Array(blocking_issues).compact.map(&:to_s)
      }.tap do |payload|
        payload["reason"] = reason.to_s if reason
      end
    end

    def engine_run_browser_observer_script_source
      File.read(File.expand_path("../browser_observer_script.js", __dir__))
    end

    def engine_run_write_browser_observer_script(workspace_dir)
      path = File.join(workspace_dir, "_aiweb", "browser-observe.js")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, engine_run_browser_observer_script_source)
      path
    end

  end
end
