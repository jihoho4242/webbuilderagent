# frozen_string_literal: true

require "uri"
require_relative "../../runtime"

module Aiweb
  module ProjectRuntimePlaywrightQa
    private

    def qa_playwright_payload(state:, metadata:, changed_files:, action_taken:, blocking_issues:, next_action:)
      runtime_command_payload(key: "playwright_qa", state: state, metadata: metadata, changed_files: changed_files, action_taken: action_taken, blocking_issues: blocking_issues, next_action: next_action)
    end

    def qa_playwright_blocked_payload(state, blockers, dry_run:, command:, target:)
      qa_playwright_payload(
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
        action_taken: "playwright QA blocked",
        blocking_issues: blockers,
        next_action: "resolve Playwright QA blockers, then rerun aiweb qa-playwright"
      ).tap do |payload|
        payload["status"] = "error"
        payload["error"] = { "message" => blockers.join("; ") }
      end
    end

    def qa_playwright_run_metadata(run_id:, task_id:, status:, command:, started_at:, finished_at:, exit_code:, target:, spec_path:, stdout_log:, stderr_log:, result_path:, metadata_path:, blocking_issues:, dry_run:)
      adapter = browser_qa_adapter(load_state_if_present)
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
        "spec_path" => spec_path,
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "result_path" => result_path,
        "metadata_path" => metadata_path,
        "provider" => adapter["provider"],
        "evidence_schema" => adapter["evidence_schema"],
        "allowed_hosts" => Array(adapter["allowed_hosts"]),
        "file_access" => adapter["file_access"],
        "dry_run" => dry_run,
        "blocking_issues" => blocking_issues
      }
    end

    def qa_playwright_command(spec_path)
      parts = ["pnpm", "exec", "playwright", "test"]
      parts << spec_path unless spec_path.to_s.empty?
      parts << "--reporter=json"
      parts.join(" ")
    end

    def qa_playwright_executable_path
      path = File.join(root, "node_modules", ".bin", "playwright")
      local_executable_path(path)
    end

    def browser_qa_adapter(state)
      adapter = state&.dig("adapters", "browser_qa")
      adapter = {} unless adapter.is_a?(Hash)
      {
        "provider" => adapter["provider"] || "playwright_script",
        "allowed_hosts" => Array(adapter["allowed_hosts"]).empty? ? %w[localhost 127.0.0.1] : Array(adapter["allowed_hosts"]),
        "evidence_schema" => adapter["evidence_schema"] || "qa-result-v1",
        "file_access" => adapter["file_access"] || "workspace_only"
      }
    end

    def qa_playwright_target(url:, preview:)
      target_url = url.to_s.strip
      target_url = (preview && (preview["preview_url"] || preview["url"]).to_s) if target_url.empty?
      return nil if target_url.empty?

      {
        "url" => target_url,
        "preview_run_id" => preview && preview["run_id"],
        "server_command" => preview ? preview["command"].to_s : "external local preview (--force)",
        "source" => url.to_s.strip.empty? ? "recorded_preview" : "explicit_url"
      }
    end

    def qa_playwright_target_blockers(state, target, preview:, force:)
      blockers = []
      adapter = browser_qa_adapter(state)
      unless target
        blockers << "No running local preview was found; run aiweb preview first and keep it running before Playwright QA, or pass --url with an explicit local http://localhost or http://127.0.0.1 preview URL."
        return blockers
      end
      begin
        uri = URI.parse(target["url"].to_s)
        host = uri.host.to_s
        unless uri.scheme == "http" && %w[localhost 127.0.0.1].include?(host)
          blockers << "Playwright QA may only target local http preview URLs on localhost or 127.0.0.1; found #{target["url"].inspect}."
        end
        unless adapter.fetch("allowed_hosts").include?(host)
          blockers << "Preview host #{host.inspect} is not in adapters.browser_qa.allowed_hosts #{adapter.fetch("allowed_hosts").inspect}."
        end
      rescue URI::InvalidURIError
        blockers << "Preview URL #{target["url"].inspect} is not a valid URI."
      end

      if adapter["file_access"] == "unrestricted"
        blockers << "Playwright QA file_access must be workspace_only or explicit_paths, not unrestricted."
      end
      blockers
    end

    def qa_playwright_spec
      <<~JS
        const { test, expect } = require('@playwright/test');

        test('AI Web Director PR11 smoke', async ({ page }) => {
          const url = process.env.PLAYWRIGHT_BASE_URL;
          if (!url) throw new Error('PLAYWRIGHT_BASE_URL is required');
          await page.goto(url);
          await expect(page.locator('body')).toBeVisible();
        });
      JS
    end

    def qa_playwright_task_id(task_id, run_id)
      value = task_id.to_s.strip
      value.empty? ? run_id : value
    end

    def qa_playwright_result(task_id:, status:, started_at:, finished_at:, duration_minutes:, timed_out:, target:, checks:, evidence:, console_errors:, network_errors:)
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
          "browser" => "playwright",
          "browser_version" => "unknown",
          "viewport" => { "width" => 1440, "height" => 900, "name" => "desktop" },
          "commit_sha" => git_commit_sha,
          "server_command" => target["server_command"].to_s
        },
        "checks" => checks,
        "evidence" => evidence,
        "console_errors" => console_errors,
        "network_errors" => network_errors,
        "recommended_action" => status == "passed" ? "advance" : "create_fix_packet",
        "created_fix_task" => nil
      }
    end

    def qa_playwright_pending_check
      {
        "id" => "QA-PLAYWRIGHT",
        "category" => "flow",
        "severity" => "high",
        "status" => "pending",
        "expected" => "Playwright QA runs only against a local preview URL under the configured browser QA adapter contract.",
        "actual" => "Dry run only; no files, browsers, or Node processes are started.",
        "evidence" => [],
        "notes" => "No files or browser processes are created during --dry-run.",
        "accepted_risk_id" => nil
      }
    end

    def qa_playwright_status_check(status, blocking_issues, stdout_path, stderr_path)
      {
        "id" => "QA-PLAYWRIGHT",
        "category" => "flow",
        "severity" => "high",
        "status" => status == "passed" ? "passed" : status,
        "expected" => "Local Playwright QA completes without installs, builds, repairs, deploys, external hosts, or .env mutation.",
        "actual" => blocking_issues.empty? ? "Playwright command completed successfully." : blocking_issues.join("; "),
        "evidence" => [relative(stdout_path), relative(stderr_path)],
        "notes" => "Runner command uses node_modules/.bin/playwright with PLAYWRIGHT_BASE_URL and executes from the project root.",
        "accepted_risk_id" => nil
      }
    end

    def qa_playwright_next_action(status)
      case status
      when "passed" then "use the recorded qa-result-v1 evidence for QA gate review or rerun aiweb qa-report --from if a phase report is required"
      when "blocked" then "resolve the blocked local Playwright QA precondition, then rerun aiweb qa-playwright"
      else "inspect .ai-web/runs Playwright QA logs, fix the scaffold or tests, then rerun aiweb qa-playwright"
      end
    end

    def git_commit_sha
      result = runtime_process_runner.capture(
        Aiweb::Runtime::CommandSpec.new(
          argv: %w[git rev-parse HEAD],
          cwd: root,
          timeout: 10,
          max_output_bytes: 4096,
          risk_class: "local_read_only_git",
          description: "git rev-parse HEAD"
        )
      )
      result.success? ? result.stdout.strip : "unknown"
    rescue StandardError
      "unknown"
    end
  end
end
