# frozen_string_literal: true

module Aiweb
  module ProjectRuntimeCommands
    private

    def qa_static_browser_tool(key:, label:, run_prefix:, executable:, result_check_id:, category:, severity:, url:, task_id:, force:, dry_run:)
      assert_initialized!

      state, state_error = runtime_state_snapshot
      ensure_scaffold_state_defaults!(state) if state
      scaffold = runtime_scaffold_summary(state)
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary
      missing_files = self.class::SCAFFOLD_PROFILE_D_REQUIRED_FILES.reject { |path| File.exist?(File.join(root, path)) }
      blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files)
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
          stdout, stderr, process_status = Open3.capture3({ "AIWEB_QA_URL" => target["url"] }, *qa_static_command_parts(executable, target["url"], relative(tool_report_path)), chdir: root)
          exit_code = process_status.exitstatus
          status = process_status.success? ? "passed" : "failed"
          blocking_issues << "#{command} failed with exit code #{exit_code}" unless process_status.success?
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

    def qa_screenshot_payload(state:, metadata:, screenshot_metadata:, changed_files:, planned_changes:, action_taken:, blocking_issues:, next_action:)
      payload = {
        "schema_version" => 1,
        "current_phase" => state&.dig("phase", "current"),
        "action_taken" => action_taken,
        "changed_files" => changed_files,
        "blocking_issues" => blocking_issues,
        "missing_artifacts" => [],
        "screenshot_qa" => metadata,
        "qa_screenshot" => metadata,
        "screenshot_metadata" => screenshot_metadata,
        "next_action" => next_action
      }
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

    def qa_static_payload(key:, state:, metadata:, changed_files:, action_taken:, blocking_issues:, next_action:)
      {
        "schema_version" => 1,
        "current_phase" => state&.dig("phase", "current"),
        "action_taken" => action_taken,
        "changed_files" => changed_files,
        "blocking_issues" => blocking_issues,
        "missing_artifacts" => [],
        key => metadata,
        "next_action" => next_action
      }
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
