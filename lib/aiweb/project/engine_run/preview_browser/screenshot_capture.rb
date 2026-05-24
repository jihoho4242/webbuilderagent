# frozen_string_literal: true

require_relative "screenshot_capture/manifest"

module Aiweb
  module ProjectEngineRun
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

  end
end
