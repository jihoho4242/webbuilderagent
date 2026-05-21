# frozen_string_literal: true

module Aiweb
  module ProjectRuntimeCommands
    private

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
