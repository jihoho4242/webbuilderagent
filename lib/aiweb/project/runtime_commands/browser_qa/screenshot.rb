# frozen_string_literal: true

module Aiweb
  module ProjectRuntimeCommands
    def qa_screenshot(url: nil, task_id: nil, force: false, dry_run: false)
      context = runtime_readiness_context(capability: :browser_qa)
      state = context.fetch(:state)
      blockers = context.fetch(:blockers)
      return qa_screenshot_blocked_payload(state, blockers, dry_run: dry_run, command: qa_screenshot_command(nil, nil, nil), target: nil) unless blockers.empty?

      preview = running_preview_metadata
      target = qa_playwright_target(url: url, preview: preview)
      target_blockers = qa_playwright_target_blockers(state, target, preview: preview, force: force)
      return qa_screenshot_blocked_payload(state, target_blockers, dry_run: dry_run, command: qa_screenshot_command(target && target["url"], nil, nil), target: target) unless target_blockers.empty?

      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      run_id = "qa-screenshot-#{timestamp}"
      result_task_id = qa_playwright_task_id(task_id, run_id)
      run_dir = File.join(aiweb_dir, "runs", run_id)
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      result_path = File.join(aiweb_dir, "qa", "results", "qa-#{timestamp}-#{slug(result_task_id)}.json")
      run_metadata_path = File.join(run_dir, "qa-screenshot.json")
      screenshot_dir = File.join(aiweb_dir, "qa", "screenshots")
      screenshot_paths = qa_screenshot_viewports.to_h { |viewport| [viewport.fetch("name"), File.join(screenshot_dir, "#{viewport.fetch("name")}-home.png")] }
      screenshot_metadata_path = File.join(screenshot_dir, "metadata.json")
      commands = qa_screenshot_viewports.map { |viewport| qa_screenshot_command(target["url"], viewport, relative(screenshot_paths.fetch(viewport.fetch("name")))) }
      planned_changes = [relative(screenshot_dir), screenshot_paths.values.map { |path| relative(path) }, relative(screenshot_metadata_path), relative(run_dir), relative(stdout_path), relative(stderr_path), relative(result_path), relative(run_metadata_path)].flatten

      if dry_run
        result = qa_screenshot_result(
          task_id: result_task_id,
          status: "pending",
          started_at: nil,
          finished_at: nil,
          duration_minutes: 0,
          timed_out: false,
          target: target,
          check: qa_screenshot_pending_check,
          evidence: [],
          viewport: qa_screenshot_viewports.last
        )
        validate_qa_result!(result)
        screenshot_metadata = qa_screenshot_metadata(
          run_id: run_id,
          task_id: result_task_id,
          status: "dry_run",
          target: target,
          screenshots: screenshot_paths,
          metadata_path: screenshot_metadata_path,
          run_metadata_path: run_metadata_path,
          result_path: result_path,
          started_at: nil,
          finished_at: nil,
          dry_run: true,
          blocking_issues: []
        )
        run_metadata = qa_screenshot_run_metadata(
          run_id: run_id,
          task_id: result_task_id,
          status: "dry_run",
          commands: commands,
          started_at: nil,
          finished_at: nil,
          exit_code: nil,
          target: target,
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          screenshot_metadata_path: relative(screenshot_metadata_path),
          result_path: relative(result_path),
          metadata_path: relative(run_metadata_path),
          blocking_issues: [],
          dry_run: true
        )
        run_metadata["screenshots"] = screenshot_metadata["screenshots"]
        run_metadata["qa_result"] = result
        return qa_screenshot_payload(
          state: state,
          metadata: run_metadata,
          screenshot_metadata: screenshot_metadata,
          changed_files: [],
          planned_changes: planned_changes,
          action_taken: "planned screenshot QA",
          blocking_issues: [],
          next_action: "rerun aiweb qa-screenshot without --dry-run to capture local screenshot evidence against #{target["url"]}"
        )
      end

      changes = []
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        FileUtils.mkdir_p(screenshot_dir)
        changes << relative(run_dir)
        changes << relative(screenshot_dir)
        started_at = Time.now.utc
        status = "blocked"
        exit_code = nil
        blocking_issues = []
        stdout_chunks = []
        stderr_chunks = []
        executable = qa_playwright_executable_path

        if executable.nil?
          blocking_issues << "Local Playwright executable node_modules/.bin/playwright is missing; install project dependencies outside aiweb qa-screenshot, then rerun."
          stderr_chunks << blocking_issues.join("\n")
        elsif executable_path("pnpm").nil?
          blocking_issues << "pnpm executable is missing; install project dependencies outside aiweb qa-screenshot, then rerun."
          stderr_chunks << blocking_issues.join("\n")
        else
          status = "passed"
          qa_screenshot_viewports.each do |viewport|
            output_path = screenshot_paths.fetch(viewport.fetch("name"))
            command_parts = qa_screenshot_command_parts(target["url"], viewport, relative(output_path))
            result = runtime_process_runner.capture(
              Aiweb::Runtime::CommandSpec.new(
                argv: command_parts,
                cwd: root,
                env: runtime_tool_env({ "AIWEB_QA_SCREENSHOT_URL" => target["url"] }, passthrough: %w[QA_SCREENSHOT_FAKE_STATUS]),
                timeout: 180,
                description: command_parts.join(" ")
              )
            )
            stdout = result.stdout
            stderr = result.stderr
            stdout_chunks << "$ #{command_parts.join(" ")}\n#{stdout}"
            stderr_chunks << "$ #{command_parts.join(" ")}\n#{stderr}"
            unless result.success?
              exit_code = result.exit_code
              status = result.status
              blocking_issues << "#{command_parts.join(" ")} failed with exit code #{exit_code || result.status}"
              break
            end
          end
          if status == "passed"
            exit_code = 0
            missing = screenshot_paths.values.reject { |path| File.file?(path) }
            unless missing.empty?
              status = "failed"
              blocking_issues << "Playwright screenshot command completed but did not create expected screenshots: #{missing.map { |path| relative(path) }.join(", ")}"
            end
          end
        end

        finished_at = Time.now.utc
        duration_minutes = ((finished_at - started_at) / 60.0).round(4)
        changes << write_file(stdout_path, stdout_chunks.join("\n"), false)
        changes << write_file(stderr_path, stderr_chunks.join("\n"), false)
        screenshot_evidence = screenshot_paths.values.select { |path| File.file?(path) }.map { |path| relative(path) }
        screenshot_metadata = qa_screenshot_metadata(
          run_id: run_id,
          task_id: result_task_id,
          status: status,
          target: target,
          screenshots: screenshot_paths,
          metadata_path: screenshot_metadata_path,
          run_metadata_path: run_metadata_path,
          result_path: result_path,
          started_at: started_at.iso8601,
          finished_at: finished_at.iso8601,
          dry_run: false,
          blocking_issues: blocking_issues
        )
        changes << write_json(screenshot_metadata_path, screenshot_metadata, false)
        evidence = [screenshot_evidence, relative(screenshot_metadata_path), relative(stdout_path), relative(stderr_path)].flatten.compact
        result = qa_screenshot_result(
          task_id: result_task_id,
          status: status,
          started_at: started_at.iso8601,
          finished_at: finished_at.iso8601,
          duration_minutes: duration_minutes,
          timed_out: false,
          target: target,
          check: qa_screenshot_status_check(status, blocking_issues, screenshot_evidence, screenshot_metadata_path, stdout_path, stderr_path),
          evidence: evidence,
          viewport: qa_screenshot_viewports.last
        )
        validate_qa_result!(result)
        changes << write_json(result_path, result, false)
        run_metadata = qa_screenshot_run_metadata(
          run_id: run_id,
          task_id: result_task_id,
          status: status,
          commands: commands,
          started_at: started_at.iso8601,
          finished_at: finished_at.iso8601,
          exit_code: exit_code,
          target: target,
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          screenshot_metadata_path: relative(screenshot_metadata_path),
          result_path: relative(result_path),
          metadata_path: relative(run_metadata_path),
          blocking_issues: blocking_issues,
          dry_run: false
        )
        run_metadata["screenshots"] = screenshot_metadata["screenshots"]
        changes << write_json(run_metadata_path, run_metadata, false)
        state["qa"] ||= {}
        state["qa"]["last_result"] = relative(result_path)
        state["qa"]["latest_screenshot_result"] = relative(result_path)
        state["qa"]["latest_screenshot_metadata"] = relative(screenshot_metadata_path)
        state["visual"] ||= {}
        state["visual"]["latest_screenshot_metadata"] = relative(screenshot_metadata_path)
        add_decision!(state, "qa_screenshot", "Recorded screenshot QA result #{result["status"]} for #{result["task_id"]}")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)
        qa_screenshot_payload(
          state: state,
          metadata: run_metadata,
          screenshot_metadata: screenshot_metadata,
          changed_files: compact_changes(changes),
          planned_changes: [],
          action_taken: status == "blocked" ? "screenshot QA blocked" : "captured screenshot QA evidence",
          blocking_issues: blocking_issues,
          next_action: qa_screenshot_next_action(status)
        )
      end
    end
  end
end
