# frozen_string_literal: true

module Aiweb
  module ProjectRuntimeCommands
    private

    def qa_screenshot_payload(state:, metadata:, screenshot_metadata:, changed_files:, planned_changes:, action_taken:, blocking_issues:, next_action:)
      payload = runtime_command_payload(key: "screenshot_qa", state: state, metadata: metadata, changed_files: changed_files, action_taken: action_taken, blocking_issues: blocking_issues, next_action: next_action)
      payload["qa_screenshot"] = metadata
      payload["screenshot_metadata"] = screenshot_metadata
      payload["planned_changes"] = planned_changes unless planned_changes.empty?
      payload
    end

    def qa_screenshot_blocked_payload(state, blockers, dry_run:, command:, target:)
      qa_screenshot_payload(
        state: state,
        metadata: {
          "schema_version" => 1,
          "status" => "blocked",
          "command" => command,
          "url" => target && target["url"],
          "dry_run" => dry_run,
          "blocking_issues" => blockers
        },
        screenshot_metadata: nil,
        changed_files: [],
        planned_changes: [],
        action_taken: "screenshot QA blocked",
        blocking_issues: blockers,
        next_action: "resolve screenshot QA blockers, then rerun aiweb qa-screenshot"
      ).tap do |payload|
        payload["status"] = "error"
        payload["error"] = { "message" => blockers.join("; ") }
      end
    end

    def qa_screenshot_viewports
      [
        { "name" => "mobile", "width" => 390, "height" => 844 },
        { "name" => "tablet", "width" => 768, "height" => 1024 },
        { "name" => "desktop", "width" => 1440, "height" => 900 }
      ]
    end

    def qa_screenshot_command(url, viewport, output_path)
      qa_screenshot_command_parts(url, viewport, output_path).join(" ")
    end

    def qa_screenshot_command_parts(url, viewport, output_path)
      parts = ["pnpm", "exec", "playwright", "screenshot"]
      if viewport
        parts << "--viewport-size=#{viewport.fetch("width")},#{viewport.fetch("height")}"
        parts << "--wait-for-timeout=1000"
      end
      parts << url unless url.to_s.empty?
      parts << output_path unless output_path.to_s.empty?
      parts
    end

    def qa_screenshot_metadata(run_id:, task_id:, status:, target:, screenshots:, metadata_path:, run_metadata_path:, result_path:, started_at:, finished_at:, dry_run:, blocking_issues:)
      {
        "schema_version" => 1,
        "type" => "qa_screenshot_metadata",
        "run_id" => run_id,
        "task_id" => task_id,
        "status" => status,
        "url" => target["url"],
        "preview_url" => target["url"],
        "preview_run_id" => target["preview_run_id"],
        "route" => "/",
        "route_name" => "home",
        "created_at" => now,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "dry_run" => dry_run,
        "metadata_path" => relative(metadata_path),
        "run_metadata_path" => relative(run_metadata_path),
        "result_path" => relative(result_path),
        "visual_critique" => {
          "from_screenshots" => "latest",
          "metadata_path" => relative(metadata_path),
          "command" => "aiweb visual-critique --metadata #{relative(metadata_path)}"
        },
        "screenshots" => qa_screenshot_viewports.each_with_object({}) do |viewport, memo|
          name = viewport.fetch("name")
          path = screenshots.fetch(name)
          expanded = File.expand_path(path)
          item = {
            "name" => name,
            "route" => "/",
            "route_name" => "home",
            "path" => relative(path),
            "viewport" => {
              "width" => viewport.fetch("width"),
              "height" => viewport.fetch("height"),
              "name" => name
            }
          }
          if File.file?(expanded)
            item["bytes"] = File.size(expanded)
            item["sha256"] = Digest::SHA256.file(expanded).hexdigest
          end
          memo[name] = item
        end,
        "blocking_issues" => blocking_issues
      }
    end

    def qa_screenshot_run_metadata(run_id:, task_id:, status:, commands:, started_at:, finished_at:, exit_code:, target:, stdout_log:, stderr_log:, screenshot_metadata_path:, result_path:, metadata_path:, blocking_issues:, dry_run:)
      adapter = browser_qa_adapter(load_state_if_present)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "task_id" => task_id,
        "status" => status,
        "commands" => commands,
        "command" => commands.join(" && "),
        "cwd" => root,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "exit_code" => exit_code,
        "url" => target["url"],
        "preview_url" => target["url"],
        "preview_run_id" => target["preview_run_id"],
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "screenshot_metadata_path" => screenshot_metadata_path,
        "result_path" => result_path,
        "metadata_path" => screenshot_metadata_path,
        "run_metadata_path" => metadata_path,
        "provider" => adapter["provider"],
        "evidence_schema" => adapter["evidence_schema"],
        "allowed_hosts" => Array(adapter["allowed_hosts"]),
        "file_access" => adapter["file_access"],
        "dry_run" => dry_run,
        "blocking_issues" => blocking_issues
      }
    end

    def qa_screenshot_result(task_id:, status:, started_at:, finished_at:, duration_minutes:, timed_out:, target:, check:, evidence:, viewport:)
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
          "viewport" => { "width" => viewport.fetch("width"), "height" => viewport.fetch("height"), "name" => viewport.fetch("name") },
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

    def qa_screenshot_pending_check
      {
        "id" => "QA-SCREENSHOT",
        "category" => "design",
        "severity" => "high",
        "status" => "pending",
        "expected" => "Local Playwright screenshot capture writes mobile, tablet, and desktop home-route evidence for visual critique.",
        "actual" => "Dry run only; no files, browsers, Node processes, installs, repairs, or deploys are started.",
        "evidence" => [],
        "notes" => "No files or browser processes are created during --dry-run.",
        "accepted_risk_id" => nil
      }
    end

    def qa_screenshot_status_check(status, blocking_issues, screenshot_evidence, screenshot_metadata_path, stdout_path, stderr_path)
      {
        "id" => "QA-SCREENSHOT",
        "category" => "design",
        "severity" => "high",
        "status" => status == "passed" ? "passed" : status,
        "expected" => "Local screenshot QA captures mobile-home.png, tablet-home.png, desktop-home.png, and metadata.json without installs, builds, repairs, deploys, external hosts, or .env mutation.",
        "actual" => blocking_issues.empty? ? "Screenshot evidence captured successfully." : blocking_issues.join("; "),
        "evidence" => [screenshot_evidence, relative(screenshot_metadata_path), relative(stdout_path), relative(stderr_path)].flatten.compact,
        "notes" => "Runner command uses node_modules/.bin/playwright through pnpm exec from the project root and only targets local preview URLs.",
        "accepted_risk_id" => nil
      }
    end

    def qa_screenshot_next_action(status)
      case status
      when "passed" then "run aiweb visual-critique --metadata .ai-web/qa/screenshots/metadata.json or aiweb visual-critique --from-screenshots latest for visual review"
      when "blocked" then "resolve the blocked local screenshot QA precondition, then rerun aiweb qa-screenshot"
      else "inspect .ai-web/runs screenshot QA logs, fix the scaffold or preview, then rerun aiweb qa-screenshot"
      end
    end
  end
end
