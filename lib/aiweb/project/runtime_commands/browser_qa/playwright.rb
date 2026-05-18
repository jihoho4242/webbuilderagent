# frozen_string_literal: true

module Aiweb
  module ProjectRuntimeCommands
    def qa_playwright(url: nil, task_id: nil, force: false, dry_run: false)
      context = runtime_readiness_context(capability: :browser_qa)
      state = context.fetch(:state)
      blockers = context.fetch(:blockers)
      return qa_playwright_blocked_payload(state, blockers, dry_run: dry_run, command: qa_playwright_command(nil), target: nil) unless blockers.empty?

      preview = running_preview_metadata
      target = qa_playwright_target(url: url, preview: preview)
      target_blockers = qa_playwright_target_blockers(state, target, preview: preview, force: force)
      return qa_playwright_blocked_payload(state, target_blockers, dry_run: dry_run, command: qa_playwright_command(target && target["url"]), target: target) unless target_blockers.empty?

      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      run_id = "playwright-qa-#{timestamp}"
      result_task_id = qa_playwright_task_id(task_id, run_id)
      run_dir = File.join(aiweb_dir, "runs", run_id)
      spec_path = File.join(run_dir, "smoke.spec.js")
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      result_path = File.join(aiweb_dir, "qa", "results", "qa-#{timestamp}-#{slug(result_task_id)}.json")
      metadata_path = File.join(run_dir, "playwright-qa.json")
      command = qa_playwright_command(relative(spec_path))
      planned_changes = [relative(run_dir), relative(spec_path), relative(stdout_path), relative(stderr_path), relative(result_path), relative(metadata_path)]

      if dry_run
        result = qa_playwright_result(
          task_id: result_task_id,
          status: "pending",
          started_at: nil,
          finished_at: nil,
          duration_minutes: 0,
          timed_out: false,
          target: target,
          checks: [qa_playwright_pending_check],
          evidence: [],
          console_errors: [],
          network_errors: []
        )
        validate_qa_result!(result)
        metadata = qa_playwright_run_metadata(
          run_id: run_id,
          task_id: result_task_id,
          status: "dry_run",
          command: command,
          started_at: nil,
          finished_at: nil,
          exit_code: nil,
          target: target,
          spec_path: relative(spec_path),
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          result_path: relative(result_path),
          metadata_path: relative(metadata_path),
          blocking_issues: [],
          dry_run: true
        )
        metadata["qa_result"] = result
        return qa_playwright_payload(
          state: state,
          metadata: metadata,
          changed_files: planned_changes,
          action_taken: "planned Playwright QA",
          blocking_issues: [],
          next_action: "rerun aiweb qa-playwright without --dry-run to execute local Playwright QA against #{target["url"]}"
        )
      end

      changes = []
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << relative(run_dir)
        changes << write_file(spec_path, qa_playwright_spec, false)
        started_at = Time.now.utc
        status = "blocked"
        exit_code = nil
        blocking_issues = []
        stdout = ""
        stderr = ""
        executable = qa_playwright_executable_path

        if executable.nil?
          blocking_issues << "Local Playwright executable node_modules/.bin/playwright is missing; install project dependencies outside aiweb qa-playwright, then rerun."
          stderr = blocking_issues.join("\n") + "\n"
        elsif executable_path("pnpm").nil?
          blocking_issues << "pnpm executable is missing; install project dependencies outside aiweb qa-playwright, then rerun."
          stderr = blocking_issues.join("\n") + "\n"
        else
          result = runtime_process_runner.capture(
            Aiweb::Runtime::CommandSpec.new(
              argv: ["pnpm", "exec", "playwright", "test", relative(spec_path), "--reporter=json"],
              cwd: root,
              env: runtime_tool_env({ "PLAYWRIGHT_BASE_URL" => target["url"] }, passthrough: %w[PLAYWRIGHT_FAKE_STATUS]),
              timeout: 180,
              description: command
            )
          )
          stdout = result.stdout
          stderr = result.stderr
          exit_code = result.exit_code
          status = result.success? ? "passed" : "failed"
          blocking_issues << "#{command} failed with exit code #{exit_code}" unless result.success?
        end

        finished_at = Time.now.utc
        duration_minutes = ((finished_at - started_at) / 60.0).round(4)
        changes << write_file(stdout_path, stdout, false)
        changes << write_file(stderr_path, stderr, false)
        result = qa_playwright_result(
          task_id: result_task_id,
          status: status == "passed" ? "passed" : status,
          started_at: started_at.iso8601,
          finished_at: finished_at.iso8601,
          duration_minutes: duration_minutes,
          timed_out: false,
          target: target,
          checks: [qa_playwright_status_check(status, blocking_issues, stdout_path, stderr_path)],
          evidence: [relative(stdout_path), relative(stderr_path)],
          console_errors: [],
          network_errors: []
        )
        validate_qa_result!(result)
        changes << write_json(result_path, result, false)
        metadata = qa_playwright_run_metadata(
          run_id: run_id,
          task_id: result_task_id,
          status: status,
          command: command,
          started_at: started_at.iso8601,
          finished_at: finished_at.iso8601,
          exit_code: exit_code,
          target: target,
          spec_path: relative(spec_path),
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          result_path: relative(result_path),
          metadata_path: relative(metadata_path),
          blocking_issues: blocking_issues,
          dry_run: false
        )
        changes << write_json(metadata_path, metadata, false)
        state["qa"] ||= {}
        state["qa"]["last_result"] = relative(result_path)
        add_decision!(state, "qa_playwright", "Recorded Playwright QA result #{result["status"]} for #{result["task_id"]}")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)
        return qa_playwright_payload(
          state: state,
          metadata: metadata,
          changed_files: compact_changes(changes),
          action_taken: status == "blocked" ? "playwright QA blocked" : "ran Playwright QA",
          blocking_issues: blocking_issues,
          next_action: qa_playwright_next_action(status)
        )
      end
    end

  end
end
