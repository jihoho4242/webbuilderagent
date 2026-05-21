# frozen_string_literal: true

require_relative "qa_artifacts/screenshot"

module Aiweb
  module ProjectRuntimeCommands
    private

    def qa_static_browser_tool(key:, label:, run_prefix:, executable:, result_check_id:, category:, severity:, url:, task_id:, force:, dry_run:)
      assert_initialized!

      state, state_error = runtime_state_snapshot
      ensure_scaffold_state_defaults!(state) if state
      scaffold = runtime_scaffold_summary(state)
      contract = runtime_profile_contract(scaffold)
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary(contract)
      missing_files = runtime_missing_required_files(contract)
      blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files, contract)
      blockers.concat(runtime_capability_blockers(contract, :browser_qa))
      return qa_static_blocked_payload(key, label, state, blockers, dry_run: dry_run, command: qa_static_command(executable, nil, nil), target: nil) unless blockers.empty?

      preview = running_preview_metadata
      target = qa_playwright_target(url: url, preview: preview)
      target_blockers = qa_playwright_target_blockers(state, target, preview: preview, force: force)
      return qa_static_blocked_payload(key, label, state, target_blockers, dry_run: dry_run, command: qa_static_command(executable, target && target["url"], nil), target: target) unless target_blockers.empty?

      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      run_id = "#{run_prefix}-#{timestamp}"
      result_task_id = qa_playwright_task_id(task_id, run_id)
      run_dir = File.join(aiweb_dir, "runs", run_id)
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      tool_report_path = File.join(run_dir, "#{run_prefix}.json")
      result_path = File.join(aiweb_dir, "qa", "results", "qa-#{timestamp}-#{slug(result_task_id)}.json")
      metadata_path = File.join(run_dir, "#{run_prefix}.json")
      metadata_path = File.join(run_dir, "#{run_prefix}-metadata.json") if metadata_path == tool_report_path
      command = qa_static_command(executable, target["url"], relative(tool_report_path))
      planned_changes = [relative(run_dir), relative(stdout_path), relative(stderr_path), relative(tool_report_path), relative(result_path), relative(metadata_path)]

      if dry_run
        result = qa_static_result(
          task_id: result_task_id,
          status: "pending",
          started_at: nil,
          finished_at: nil,
          duration_minutes: 0,
          timed_out: false,
          target: target,
          check: qa_static_pending_check(result_check_id, label, category, severity),
          evidence: [],
          browser: executable
        )
        validate_qa_result!(result)
        metadata = qa_static_run_metadata(
          run_id: run_id,
          task_id: result_task_id,
          status: "dry_run",
          command: command,
          started_at: nil,
          finished_at: nil,
          exit_code: nil,
          target: target,
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          tool_report: relative(tool_report_path),
          result_path: relative(result_path),
          metadata_path: relative(metadata_path),
          blocking_issues: [],
          dry_run: true
        )
        metadata["qa_result"] = result
        return qa_static_payload(
          key: key,
          state: state,
          metadata: metadata,
          changed_files: planned_changes,
          action_taken: "planned #{label} QA",
          blocking_issues: [],
          next_action: "rerun aiweb #{key.tr('_', '-').sub('-qa', '') == 'a11y' ? 'qa-a11y' : 'qa-lighthouse'} without --dry-run to execute local #{label} QA against #{target["url"]}"
        )
      end

      changes = []
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << relative(run_dir)
        started_at = Time.now.utc
        status = "blocked"
        exit_code = nil
        blocking_issues = []
        stdout = ""
        stderr = ""

        if qa_static_executable_path(executable).nil?
          blocking_issues << "Local #{label} executable node_modules/.bin/#{executable} is missing; install project dependencies outside aiweb #{key.tr('_', '-')}, then rerun."
          stderr = blocking_issues.join("\n") + "\n"
        elsif executable_path("pnpm").nil?
          blocking_issues << "pnpm executable is missing; install project dependencies outside aiweb #{key.tr('_', '-')}, then rerun."
          stderr = blocking_issues.join("\n") + "\n"
        else
          result = runtime_process_runner.capture(
            Aiweb::Runtime::CommandSpec.new(
              argv: qa_static_command_parts(executable, target["url"], relative(tool_report_path)),
              cwd: root,
              env: runtime_tool_env({ "AIWEB_QA_URL" => target["url"] }, passthrough: %w[AIWEB_STATIC_QA_STATUS A11Y_FAKE_STATUS LIGHTHOUSE_FAKE_STATUS]),
              timeout: 180,
              description: command
            )
          )
          stdout = result.stdout
          stderr = result.stderr
          exit_code = result.exit_code
          status = result.success? ? "passed" : result.status
          blocking_issues << "#{command} failed with exit code #{exit_code || result.status}" unless result.success?
        end

        finished_at = Time.now.utc
        duration_minutes = ((finished_at - started_at) / 60.0).round(4)
        changes << write_file(stdout_path, stdout, false)
        changes << write_file(stderr_path, stderr, false)
        changes << write_file(tool_report_path, stdout.to_s.empty? ? "{}\n" : stdout, false) unless File.exist?(tool_report_path)
        result = qa_static_result(
          task_id: result_task_id,
          status: status,
          started_at: started_at.iso8601,
          finished_at: finished_at.iso8601,
          duration_minutes: duration_minutes,
          timed_out: false,
          target: target,
          check: qa_static_status_check(result_check_id, label, category, severity, status, blocking_issues, stdout_path, stderr_path, tool_report_path),
          evidence: [relative(stdout_path), relative(stderr_path), relative(tool_report_path)],
          browser: executable
        )
        validate_qa_result!(result)
        changes << write_json(result_path, result, false)
        metadata = qa_static_run_metadata(
          run_id: run_id,
          task_id: result_task_id,
          status: status,
          command: command,
          started_at: started_at.iso8601,
          finished_at: finished_at.iso8601,
          exit_code: exit_code,
          target: target,
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          tool_report: relative(tool_report_path),
          result_path: relative(result_path),
          metadata_path: relative(metadata_path),
          blocking_issues: blocking_issues,
          dry_run: false
        )
        changes << write_json(metadata_path, metadata, false)
        state["qa"] ||= {}
        state["qa"]["last_result"] = relative(result_path)
        add_decision!(state, key, "Recorded #{label} QA result #{result["status"]} for #{result["task_id"]}")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)
        qa_static_payload(
          key: key,
          state: state,
          metadata: metadata,
          changed_files: compact_changes(changes),
          action_taken: status == "blocked" ? "#{label} QA blocked" : "ran #{label} QA",
          blocking_issues: blocking_issues,
          next_action: qa_static_next_action(key, label, status)
        )
      end
    end

    def qa_static_payload(key:, state:, metadata:, changed_files:, action_taken:, blocking_issues:, next_action:)
      runtime_command_payload(key: key, state: state, metadata: metadata, changed_files: changed_files, action_taken: action_taken, blocking_issues: blocking_issues, next_action: next_action)
    end

    def qa_static_blocked_payload(key, label, state, blockers, dry_run:, command:, target:)
      qa_static_payload(
        key: key,
        state: state,
        metadata: {
          "schema_version" => 1,
          "status" => "blocked",
          "command" => command,
          "url" => target && target["url"],
          "dry_run" => dry_run,
          "blocking_issues" => blockers
        },
        changed_files: [],
        action_taken: "#{label} QA blocked",
        blocking_issues: blockers,
        next_action: "resolve #{label} QA blockers, then rerun aiweb #{key == "a11y_qa" ? "qa-a11y" : "qa-lighthouse"}"
      )
    end

    def qa_static_run_metadata(run_id:, task_id:, status:, command:, started_at:, finished_at:, exit_code:, target:, stdout_log:, stderr_log:, tool_report:, result_path:, metadata_path:, blocking_issues:, dry_run:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "task_id" => task_id,
        "status" => status,
        "command" => command,
        "cwd" => root,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "exit_code" => exit_code,
        "url" => target["url"],
        "preview_url" => target["url"],
        "preview_run_id" => target["preview_run_id"],
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "tool_report" => tool_report,
        "result_path" => result_path,
        "metadata_path" => metadata_path,
        "dry_run" => dry_run,
        "blocking_issues" => blocking_issues
      }
    end

    def qa_static_command(executable, url, report_path)
      qa_static_command_parts(executable, url, report_path).join(" ")
    end

    def qa_static_command_parts(executable, url, report_path)
      parts = ["pnpm", "exec", executable]
      parts << url unless url.to_s.empty?
      if executable == "lighthouse"
        parts += ["--output=json", "--output-path=#{report_path}", "--quiet", "--chrome-flags=--headless"] unless report_path.to_s.empty?
      else
        parts << "--reporter=json"
      end
      parts
    end

    def qa_static_executable_path(executable)
      path = File.join(root, "node_modules", ".bin", executable)
      local_executable_path(path)
    end

    def qa_static_result(task_id:, status:, started_at:, finished_at:, duration_minutes:, timed_out:, target:, check:, evidence:, browser:)
      {
        "schema_version" => 1,
        "task_id" => task_id,
        "status" => status,
        "started_at" => started_at || now,
        "finished_at" => finished_at || now,
        "duration_minutes" => duration_minutes,
        "timed_out" => timed_out,
        "environment" => {
          "url" => target["url"],
          "browser" => browser,
          "browser_version" => "unknown",
          "viewport" => { "width" => 1440, "height" => 900, "name" => "desktop" },
          "commit_sha" => git_commit_sha,
          "server_command" => target["server_command"].to_s
        },
        "checks" => [check],
        "evidence" => evidence,
        "console_errors" => [],
        "network_errors" => [],
        "recommended_action" => status == "passed" ? "advance" : "create_fix_packet",
        "created_fix_task" => nil
      }
    end

    def qa_static_pending_check(id, label, category, severity)
      {
        "id" => id,
        "category" => category,
        "severity" => severity,
        "status" => "pending",
        "expected" => "#{label} QA runs only against a local preview URL under the configured browser QA adapter contract.",
        "actual" => "Dry run only; no files, browsers, Node processes, installs, repairs, or deploys are started.",
        "evidence" => [],
        "notes" => "No files or browser processes are created during --dry-run.",
        "accepted_risk_id" => nil
      }
    end

    def qa_static_status_check(id, label, category, severity, status, blocking_issues, stdout_path, stderr_path, tool_report_path)
      {
        "id" => id,
        "category" => category,
        "severity" => severity,
        "status" => status == "passed" ? "passed" : status,
        "expected" => "Local #{label} QA completes without installs, builds, repairs, deploys, external hosts, or .env mutation.",
        "actual" => blocking_issues.empty? ? "#{label} command completed successfully." : blocking_issues.join("; "),
        "evidence" => [relative(stdout_path), relative(stderr_path), relative(tool_report_path)],
        "notes" => "Runner command uses node_modules/.bin tooling through pnpm exec from the project root.",
        "accepted_risk_id" => nil
      }
    end

    def qa_static_next_action(key, label, status)
      command = key == "a11y_qa" ? "qa-a11y" : "qa-lighthouse"
      case status
      when "passed" then "use the recorded qa-result-v1 evidence for QA gate review or rerun aiweb qa-report --from if a phase report is required"
      when "blocked" then "resolve the blocked local #{label} QA precondition, then rerun aiweb #{command}"
      else "inspect .ai-web/runs #{label} QA logs, fix the scaffold or tests, then rerun aiweb #{command}"
      end
    end

  end
end
