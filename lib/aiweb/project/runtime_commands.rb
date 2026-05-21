# frozen_string_literal: true

require "digest"
require_relative "../profile_policy"
require_relative "../runtime"
require_relative "runtime_commands/qa_artifacts"
require_relative "runtime_commands/browser_qa"
require_relative "runtime_commands/setup"
module Aiweb
  module ProjectRuntimeCommands
    def runtime_plan
      context = runtime_readiness_context
      state = context.fetch(:state)
      scaffold = context.fetch(:scaffold)
      contract = context.fetch(:contract)
      metadata = context.fetch(:metadata)
      design = context.fetch(:design)
      package_json = context.fetch(:package_json)
      missing_files = context.fetch(:missing_files)
      blockers = context.fetch(:blockers)
      readiness = blockers.empty? ? runtime_contract_readiness(contract) : "blocked"

      {
        "schema_version" => 1,
        "current_phase" => state&.dig("phase", "current"),
        "action_taken" => "reported runtime plan",
        "changed_files" => [],
        "blocking_issues" => blockers,
        "missing_artifacts" => state ? [] : [".ai-web/state.yaml"],
        "runtime_plan" => {
          "readiness" => readiness,
          "profile_contract" => contract ? contract.to_h : runtime_unsupported_profile_contract(scaffold),
          "scaffold" => scaffold,
          "metadata" => metadata,
          "package_json" => package_json,
          "design" => design,
          "missing_required_scaffold_files" => missing_files,
          "blockers" => blockers
        },
        "next_action" => runtime_plan_next_action(readiness)
      }
    end

    def build(dry_run: false)
      assert_initialized!

      context = runtime_readiness_context(capability: :build)
      state = context.fetch(:state)
      scaffold = context.fetch(:scaffold)
      blockers = context.fetch(:blockers)
      return build_blocked_payload(state, blockers, dry_run: dry_run) unless blockers.empty?

      run_id = "build-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}"
      run_dir = File.join(aiweb_dir, "runs", run_id)
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      metadata_path = File.join(run_dir, "build.json")
      command = scaffold["build_command"].to_s.empty? ? "pnpm build" : scaffold["build_command"].to_s
      planned_changes = [relative(run_dir), relative(stdout_path), relative(stderr_path), relative(metadata_path)]

      if dry_run
        return build_payload(
          state: state,
          metadata: build_run_metadata(
            run_id: run_id,
            status: "dry_run",
            command: command,
            started_at: nil,
            finished_at: nil,
            exit_code: nil,
            stdout_log: relative(stdout_path),
            stderr_log: relative(stderr_path),
            metadata_path: relative(metadata_path),
            blocking_issues: [],
            dry_run: true
          ),
          changed_files: planned_changes,
          action_taken: "planned scaffold build",
          blocking_issues: [],
          next_action: "rerun aiweb build without --dry-run to execute #{command.inspect}"
        )
      end

      changes = []
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << relative(run_dir)
        started_at = now
        status = "blocked"
        exit_code = nil
        blocking_issues = []
        stdout = ""
        stderr = ""

        if executable_path("pnpm").nil?
          blocking_issues << "pnpm executable is missing; install project dependencies outside aiweb build, then rerun."
          stderr = blocking_issues.join("\n") + "\n"
        elsif !File.directory?(File.join(root, "node_modules"))
          blocking_issues << "node_modules is missing; run pnpm install outside aiweb build after reviewing package.json, then rerun."
          stderr = blocking_issues.join("\n") + "\n"
        else
          result = runtime_process_runner.capture(
            Aiweb::Runtime::CommandSpec.new(argv: build_command_argv(command), cwd: root, timeout: 180, description: command)
          )
          stdout = result.stdout
          stderr = result.stderr
          exit_code = result.exit_code
          status = result.success? ? "passed" : "failed"
          blocking_issues << "#{command} failed with exit code #{exit_code}" unless result.success?
        end

        changes << write_file(stdout_path, stdout, false)
        changes << write_file(stderr_path, stderr, false)
        metadata = build_run_metadata(
          run_id: run_id,
          status: status,
          command: command,
          started_at: started_at,
          finished_at: now,
          exit_code: exit_code,
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          metadata_path: relative(metadata_path),
          blocking_issues: blocking_issues,
          dry_run: false
        )
        changes << write_json(metadata_path, metadata, false)
        return build_payload(
          state: state,
          metadata: metadata,
          changed_files: compact_changes(changes),
          action_taken: status == "passed" ? "ran scaffold build" : "scaffold build #{status}",
          blocking_issues: blocking_issues,
          next_action: build_next_action(status)
        )
      end
    end

    def preview(dry_run: false, stop: false)
      assert_initialized!

      return stop_preview(dry_run: dry_run) if stop

      context = runtime_readiness_context(capability: :preview)
      state = context.fetch(:state)
      scaffold = context.fetch(:scaffold)
      blockers = context.fetch(:blockers)
      return preview_blocked_payload(state, blockers, dry_run: dry_run) unless blockers.empty?

      running = running_preview_metadata
      return preview_already_running_payload(state, running, dry_run: dry_run) if running

      run_id = "preview-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}"
      run_dir = File.join(aiweb_dir, "runs", run_id)
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      metadata_path = File.join(run_dir, "preview.json")
      command = preview_command(scaffold)
      port = preview_port(command)
      url = "http://127.0.0.1:#{port}/"
      planned_changes = [relative(run_dir), relative(stdout_path), relative(stderr_path), relative(metadata_path)]

      if dry_run
        return preview_payload(
          state: state,
          metadata: preview_run_metadata(
            run_id: run_id,
            status: "dry_run",
            command: command,
            started_at: nil,
            finished_at: nil,
            exit_code: nil,
            pid: nil,
            port: port,
            url: url,
            stdout_log: relative(stdout_path),
            stderr_log: relative(stderr_path),
            metadata_path: relative(metadata_path),
            blocking_issues: [],
            dry_run: true
          ),
          changed_files: planned_changes,
          action_taken: "planned scaffold preview",
          blocking_issues: [],
          next_action: "rerun aiweb preview without --dry-run to start #{command.inspect}"
        )
      end

      changes = []
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << relative(run_dir)
        started_at = now
        status = "blocked"
        blocking_issues = []
        pid = nil
        exit_code = nil

        if executable_path("pnpm").nil?
          blocking_issues << "pnpm executable is missing; install project dependencies outside aiweb preview, then rerun."
          changes << write_file(stdout_path, "", false)
          changes << write_file(stderr_path, blocking_issues.join("\n") + "\n", false)
        elsif !File.directory?(File.join(root, "node_modules"))
          blocking_issues << "node_modules is missing; run pnpm install outside aiweb preview after reviewing package.json, then rerun."
          changes << write_file(stdout_path, "", false)
          changes << write_file(stderr_path, blocking_issues.join("\n") + "\n", false)
        else
          FileUtils.touch(stdout_path)
          FileUtils.touch(stderr_path)
          stdout_file = File.open(stdout_path, "ab")
          stderr_file = File.open(stderr_path, "ab")
          begin
            pid = Aiweb::Runtime::ProcessLauncher.spawn(
              spec: Aiweb::Runtime::LaunchSpec.new(
                argv: preview_command_argv(command),
                cwd: root,
                env: subprocess_path_env,
                stdout: stdout_file,
                stderr: stderr_file,
                risk_class: "scaffold_preview_server",
                description: "scaffold preview server"
              )
            )
            Process.detach(pid)
            status = "running"
          ensure
            stdout_file.close
            stderr_file.close
          end
          changes << relative(stdout_path)
          changes << relative(stderr_path)
        end

        metadata = preview_run_metadata(
          run_id: run_id,
          status: status,
          command: command,
          started_at: started_at,
          finished_at: status == "running" ? nil : now,
          exit_code: exit_code,
          pid: pid,
          port: port,
          url: url,
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          metadata_path: relative(metadata_path),
          blocking_issues: blocking_issues,
          dry_run: false
        )
        changes << write_json(metadata_path, metadata, false)
        return preview_payload(
          state: state,
          metadata: metadata,
          changed_files: compact_changes(changes),
          action_taken: status == "running" ? "started scaffold preview" : "scaffold preview blocked",
          blocking_issues: blocking_issues,
          next_action: preview_next_action(status)
        )
      end
    end

    def qa_a11y(url: nil, task_id: nil, force: false, dry_run: false)
      qa_static_browser_tool(
        key: "a11y_qa",
        label: "axe accessibility",
        run_prefix: "a11y-qa",
        executable: "axe",
        result_check_id: "QA-A11Y",
        category: "accessibility",
        severity: "critical",
        url: url,
        task_id: task_id,
        force: force,
        dry_run: dry_run
      )
    end

    def qa_lighthouse(url: nil, task_id: nil, force: false, dry_run: false)
      qa_static_browser_tool(
        key: "lighthouse_qa",
        label: "Lighthouse",
        run_prefix: "lighthouse-qa",
        executable: "lighthouse",
        result_check_id: "QA-LIGHTHOUSE",
        category: "performance",
        severity: "high",
        url: url,
        task_id: task_id,
        force: force,
        dry_run: dry_run
      )
    end

    private

    def runtime_readiness_context(capability: nil)
      state, state_error = runtime_state_snapshot
      ensure_scaffold_state_defaults!(state) if state
      scaffold = runtime_scaffold_summary(state)
      contract = runtime_profile_contract(scaffold)
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary(contract)
      missing_files = runtime_missing_required_files(contract)
      blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files, contract)
      blockers.concat(runtime_capability_blockers(contract, capability)) if capability
      {
        state: state,
        scaffold: scaffold,
        contract: contract,
        metadata: metadata,
        design: design,
        package_json: package_json,
        missing_files: missing_files,
        blockers: blockers
      }
    end

    def build_blocked_payload(state, blockers, dry_run:)
      build_payload(
        state: state,
        metadata: {
          "schema_version" => 1,
          "status" => "blocked",
          "command" => "pnpm build",
          "dry_run" => dry_run,
          "blocking_issues" => blockers
        },
        changed_files: [],
        action_taken: "scaffold build blocked",
        blocking_issues: blockers,
        next_action: "resolve runtime-plan blockers, then rerun aiweb build"
      )
    end

    def build_payload(state:, metadata:, changed_files:, action_taken:, blocking_issues:, next_action:)
      runtime_command_payload(key: "build", state: state, metadata: metadata, changed_files: changed_files, action_taken: action_taken, blocking_issues: blocking_issues, next_action: next_action)
    end

    def build_run_metadata(run_id:, status:, command:, started_at:, finished_at:, exit_code:, stdout_log:, stderr_log:, metadata_path:, blocking_issues:, dry_run:)
      output_path = File.join(root, "dist")
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "command" => command,
        "cwd" => root,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "exit_code" => exit_code,
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "metadata_path" => metadata_path,
        "build_output_path" => File.directory?(output_path) ? "dist" : nil,
        "dry_run" => dry_run,
        "blocking_issues" => blocking_issues
      }
    end

    def build_next_action(status)
      case status
      when "passed" then "continue to the next approved roadmap stage; preview/QA/repair are intentionally outside aiweb build"
      when "blocked" then "resolve the blocked local build precondition, then rerun aiweb build"
      else "inspect .ai-web/runs build logs, fix the scaffold, then rerun aiweb build"
      end
    end

    def preview_blocked_payload(state, blockers, dry_run:)
      preview_payload(
        state: state,
        metadata: {
          "schema_version" => 1,
          "status" => "blocked",
          "command" => "pnpm dev --host 127.0.0.1",
          "dry_run" => dry_run,
          "blocking_issues" => blockers
        },
        changed_files: [],
        action_taken: "scaffold preview blocked",
        blocking_issues: blockers,
        next_action: "resolve runtime-plan blockers, then rerun aiweb preview"
      )
    end

    def preview_already_running_payload(state, metadata, dry_run:)
      payload_metadata = metadata.merge(
        "status" => "already_running",
        "dry_run" => dry_run,
        "blocking_issues" => []
      )
      preview_payload(
        state: state,
        metadata: payload_metadata,
        changed_files: [],
        action_taken: "scaffold preview already running",
        blocking_issues: [],
        next_action: "open #{payload_metadata["url"] || payload_metadata["preview_url"]} or run aiweb preview --stop before starting another preview"
      )
    end

    def preview_payload(state:, metadata:, changed_files:, action_taken:, blocking_issues:, next_action:)
      runtime_command_payload(key: "preview", state: state, metadata: metadata, changed_files: changed_files, action_taken: action_taken, blocking_issues: blocking_issues, next_action: next_action)
    end

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

    def runtime_command_payload(key:, state:, metadata:, changed_files:, action_taken:, blocking_issues:, next_action:)
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

    def preview_run_metadata(run_id:, status:, command:, started_at:, finished_at:, exit_code:, pid:, port:, url:, stdout_log:, stderr_log:, metadata_path:, blocking_issues:, dry_run:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "command" => command,
        "cwd" => root,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "exit_code" => exit_code,
        "pid" => pid,
        "port" => port,
        "url" => url,
        "preview_url" => url,
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "metadata_path" => metadata_path,
        "dry_run" => dry_run,
        "blocking_issues" => blocking_issues
      }
    end

    def preview_next_action(status)
      case status
      when "running" then "open the preview_url locally; run aiweb preview --stop when finished"
      when "stopped" then "rerun aiweb preview to start a new local preview"
      when "not_running" then "run aiweb preview to start the local preview"
      when "blocked" then "resolve the blocked local preview precondition, then rerun aiweb preview"
      else "inspect .ai-web/runs preview logs, fix the scaffold, then rerun aiweb preview"
      end
    end

    def preview_command(scaffold)
      base = scaffold["dev_command"].to_s.strip
      base = "pnpm dev" if base.empty?
      base.match?(/--host(?:\s|=)/) ? base : "#{base} --host 127.0.0.1"
    end

    def preview_command_argv(command)
      parts = Aiweb::Runtime::CommandSpec.argv_from_command(command, default: ["pnpm", "dev", "--host", "127.0.0.1"])
      executable = executable_path(parts.fetch(0))
      [executable || parts.fetch(0), *parts.drop(1)]
    rescue IndexError
      ["pnpm", "dev", "--host", "127.0.0.1"]
    end

    def preview_port(command)
      match = command.match(/(?:--port(?:=|\s+))(\d+)/)
      match ? match[1].to_i : 4321
    end

    def running_preview_metadata
      preview_metadata_files.reverse_each do |path|
        metadata = read_preview_metadata(path)
        next unless metadata
        next unless metadata["status"] == "running"

        pid = metadata["pid"].to_i
        next unless live_process?(pid)

        metadata["metadata_path"] ||= relative(path)
        return metadata
      end
      nil
    end

    def latest_preview_metadata
      preview_metadata_files.reverse_each do |path|
        metadata = read_preview_metadata(path)
        next unless metadata

        metadata["metadata_path"] ||= relative(path)
        return [metadata, path]
      end
      nil
    end

    def preview_metadata_files
      Dir.glob(File.join(aiweb_dir, "runs", "preview-*", "preview.json")).sort
    end

    def read_preview_metadata(path)
      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def live_process?(pid)
      return false unless pid.positive?

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def stop_preview(dry_run:)
      state, = runtime_state_snapshot
      latest = latest_preview_metadata
      metadata, path = latest if latest
      live = metadata && metadata["status"] == "running" && live_process?(metadata["pid"].to_i)

      if dry_run
        planned = metadata ? [metadata["metadata_path"] || relative(path)] : []
        status = live ? "dry_run" : "not_running"
        preview = (metadata || { "schema_version" => 1 }).merge(
          "status" => status,
          "dry_run" => true,
          "would_stop_pid" => live ? metadata["pid"] : nil,
          "blocking_issues" => []
        )
        return preview_payload(
          state: state,
          metadata: preview,
          changed_files: planned,
          action_taken: live ? "planned scaffold preview stop" : "scaffold preview not running",
          blocking_issues: [],
          next_action: live ? "rerun aiweb preview --stop without --dry-run to stop the recorded preview pid" : preview_next_action("not_running")
        )
      end

      return preview_payload(
        state: state,
        metadata: { "schema_version" => 1, "status" => "not_running", "dry_run" => false, "blocking_issues" => [] },
        changed_files: [],
        action_taken: "scaffold preview not running",
        blocking_issues: [],
        next_action: preview_next_action("not_running")
      ) unless live

      mutation(dry_run: false) do
        pid = metadata["pid"].to_i
        stop_process_tree(pid)
        begin
          Timeout.timeout(5) do
            sleep 0.05 while live_process?(pid)
          end
        rescue Timeout::Error
          # Leave the process alone after TERM timeout; metadata still records the stop request.
        end
        stopped = metadata.merge(
          "status" => "stopped",
          "pid" => nil,
          "stopped_pid" => pid,
          "finished_at" => now,
          "dry_run" => false,
          "blocking_issues" => []
        )
        write_json(path, stopped, false)
        preview_payload(
          state: state,
          metadata: stopped,
          changed_files: [relative(path)],
          action_taken: "stopped scaffold preview",
          blocking_issues: [],
          next_action: preview_next_action("stopped")
        )
      end
    end

    def stop_process_tree(pid)
      if windows?
        taskkill = File.join(ENV["WINDIR"].to_s.empty? ? "C:/Windows" : ENV["WINDIR"], "System32", "taskkill.exe")
        return if File.executable?(taskkill) && runtime_taskkill_process_tree(pid, taskkill)
        return if runtime_taskkill_process_tree(pid, "taskkill.exe")

        Process.kill("KILL", pid)
      else
        Process.kill("TERM", pid)
      end
    rescue Errno::ESRCH, Errno::EINVAL
      nil
    end

    def runtime_taskkill_process_tree(pid, command)
      result = runtime_process_runner.capture(
        Aiweb::Runtime::CommandSpec.new(
          argv: [command, "/PID", pid.to_s, "/T", "/F"],
          cwd: root,
          timeout: 10,
          max_output_bytes: 16_000,
          risk_class: "local_process_tree_cleanup",
          description: "taskkill preview process tree"
        )
      )
      result.success?
    rescue ArgumentError
      false
    end

    def runtime_state_snapshot
      return [nil, "Project is not initialized; run aiweb init --profile D or aiweb start before checking runtime readiness."] unless File.file?(state_path)

      state = YAML.load_file(state_path)
      return [state, nil] if state.is_a?(Hash)

      [nil, ".ai-web/state.yaml must be a YAML mapping; repair state before checking runtime readiness."]
    rescue Psych::Exception => e
      [nil, "Cannot parse .ai-web/state.yaml: #{e.message}"]
    end

    def runtime_profile_contract(scaffold)
      Aiweb::ProfilePolicy::Resolver.fetch(scaffold["profile"].to_s)
    end

    def runtime_contract_readiness(contract)
      contract&.runtime_readiness || "blocked"
    end

    def runtime_plan_next_action(readiness)
      case readiness
      when "ready"
        "runtime tools may inspect scripts next; do not install packages or launch Node from this read-only check"
      when "local_planning_only"
        "use local verification/reporting surfaces for this profile; build/preview/browser QA remain intentionally unsupported"
      else
        "resolve blockers, then rerun aiweb runtime-plan"
      end
    end

    def runtime_unsupported_profile_contract(scaffold)
      {
        "id" => scaffold["profile"],
        "runtime_readiness" => "unsupported",
        "supported_runtime_profiles" => %w[D S],
        "blocking_issues" => ["Runtime contract is only implemented for Profile D or Profile S"]
      }
    end

    def runtime_missing_required_files(contract)
      return [] unless contract

      contract.required_files.reject { |path| File.exist?(File.join(root, path)) }
    end

    def runtime_capability_blockers(contract, capability)
      return ["Runtime contract is not implemented for this profile; supported runtime profiles are D and S."] unless contract
      return [] if contract.supports?(capability)

      ["Profile #{contract.id} does not support #{capability} in the current runtime contract; use local verification/reporting surfaces instead."]
    end

    def runtime_process_runner
      @runtime_process_runner ||= Aiweb::Runtime::ProcessRunner.new
    end

    def runtime_tool_env(values = {}, passthrough: [])
      values = values.transform_keys(&:to_s)
      passthrough.each do |key|
        values[key.to_s] = ENV[key.to_s] if ENV.key?(key.to_s)
      end
      values
    end

    def build_command_argv(command)
      Aiweb::Runtime::CommandSpec.argv_from_command(command, default: ["pnpm", "build"])
    end

    def runtime_scaffold_summary(state)
      implementation = state&.fetch("implementation", {}) || {}
      profile = implementation["scaffold_profile"] || implementation["stack_profile"]
      metadata_path = runtime_scaffold_metadata_path(implementation["scaffold_metadata_path"], profile: profile)
      {
        "scaffold_created" => implementation["scaffold_created"] == true,
        "profile" => profile,
        "framework" => implementation["scaffold_framework"],
        "package_manager" => implementation["scaffold_package_manager"],
        "dev_command" => implementation["scaffold_dev_command"],
        "build_command" => implementation["scaffold_build_command"],
        "metadata_path" => metadata_path.fetch("path"),
        "metadata_path_state_value" => metadata_path.fetch("state_value"),
        "metadata_path_safe" => metadata_path.fetch("safe"),
        "metadata_path_error" => metadata_path.fetch("error")
      }
    end

    def runtime_scaffold_metadata_path(state_value, profile: nil)
      contract = Aiweb::ProfilePolicy::Resolver.fetch(profile.to_s)
      expected_path = contract&.metadata_path || self.class::SCAFFOLD_PROFILE_D_METADATA_PATH
      raw = state_value.to_s.strip
      return { "path" => expected_path, "state_value" => nil, "safe" => true, "error" => nil } if raw.empty?

      normalized = raw.tr("\\", "/")
      normalized = normalized.sub(%r{\A(?:\./)+}, "")
      parts = normalized.split("/")
      error = if raw.start_with?("/") || raw.match?(%r{\A[A-Za-z]:[\\/]})
                "scaffold metadata path must be relative to the project .ai-web directory, not absolute"
              elsif parts.any? { |part| part == ".." }
                "scaffold metadata path must not contain traversal"
              elsif parts.any? { |part| part.start_with?(".env") }
                "scaffold metadata path must not reference .env files"
              elsif normalized != expected_path
                "scaffold metadata path must be #{expected_path}"
              end

      {
        "path" => normalized,
        "state_value" => raw,
        "safe" => error.nil?,
        "error" => error
      }
    end

    def runtime_metadata_summary(scaffold)
      relative_metadata_path = scaffold["metadata_path"]
      summary = {
        "path" => relative_metadata_path,
        "present" => false,
        "valid_json" => false,
        "profile" => nil,
        "framework" => nil,
        "package_manager" => nil,
        "dev_command" => nil,
        "build_command" => nil,
        "selected_candidate" => nil,
        "selected_candidate_path" => nil,
        "path_safe" => scaffold["metadata_path_safe"] == true,
        "error" => scaffold["metadata_path_error"]
      }
      return summary unless summary["path_safe"]

      path = File.join(root, relative_metadata_path)
      summary["present"] = File.file?(path)
      return summary unless File.file?(path)

      data = JSON.parse(File.read(path))
      unless data.is_a?(Hash)
        summary["error"] = "metadata must be a JSON object"
        return summary
      end

      summary.merge!(
        "valid_json" => true,
        "profile" => data["profile"],
        "framework" => data["framework"],
        "package_manager" => data["package_manager"],
        "dev_command" => data["dev_command"],
        "build_command" => data["build_command"],
        "selected_candidate" => data["selected_candidate"],
        "selected_candidate_path" => data["selected_candidate_path"]
      )
    rescue JSON::ParserError => e
      summary["error"] = "invalid JSON: #{e.message}"
      summary
    rescue SystemCallError => e
      summary["error"] = e.message
      summary
    end

    def runtime_design_summary(state, metadata)
      state_selected = state&.dig("design_candidates", "selected_candidate").to_s.strip
      metadata_selected = metadata["selected_candidate"].to_s.strip if metadata && metadata["valid_json"]
      metadata_selected ||= ""
      selected = state_selected.empty? ? metadata_selected : state_selected
      design_path = File.join(aiweb_dir, "DESIGN.md")
      selected_path = selected.empty? ? nil : selected_candidate_artifact_path_from_snapshot(state, selected)
      generated_reference = runtime_generated_design_reference_summary
      {
        "selected_candidate" => selected.empty? ? nil : selected,
        "state_selected_candidate" => state_selected.empty? ? nil : state_selected,
        "metadata_selected_candidate" => metadata_selected.empty? ? nil : metadata_selected,
        "generated_reference" => generated_reference,
        "selected_candidate_present" => selected_path ? File.file?(selected_path) : false,
        "selected_candidate_path" => selected_path ? relative(selected_path) : nil,
        "design_md_path" => ".ai-web/DESIGN.md",
        "design_md_present" => File.file?(design_path),
        "design_md_substantive" => File.file?(design_path) && !stub_file?(design_path)
      }
    end

    def runtime_generated_design_reference_summary
      path = File.join(root, "src/content/site.json")
      summary = {
        "path" => "src/content/site.json",
        "present" => File.file?(path),
        "valid_json" => false,
        "selected_candidate" => nil,
        "selected_candidate_path" => nil,
        "error" => nil
      }
      return summary unless File.file?(path)

      data = JSON.parse(File.read(path))
      unless data.is_a?(Hash)
        summary["error"] = "src/content/site.json must be a JSON object"
        return summary
      end

      summary.merge!(
        "valid_json" => true,
        "selected_candidate" => data["selected_candidate"],
        "selected_candidate_path" => data["selected_candidate_path"]
      )
    rescue JSON::ParserError => e
      summary["error"] = "invalid JSON: #{e.message}"
      summary
    rescue SystemCallError => e
      summary["error"] = e.message
      summary
    end

    def selected_candidate_artifact_path_from_snapshot(state, selected)
      ref = Array(state&.dig("design_candidates", "candidates")).find { |candidate| candidate.is_a?(Hash) && candidate["id"].to_s == selected }
      candidates = []
      candidates << File.join(root, ref["path"].to_s) if ref && !ref["path"].to_s.strip.empty?
      candidates << File.join(aiweb_dir, "design-candidates", "#{selected}.html")
      candidates << File.join(aiweb_dir, "design-candidates", "#{selected}.md")
      candidates.find { |path| File.file?(path) } || candidates.first
    end

    def runtime_package_json_summary(contract = nil)
      expected_scripts = contract&.expected_scripts || {}
      expected_dependencies = Array(contract&.expected_dependencies)
      path = File.join(root, "package.json")
      summary = {
        "path" => "package.json",
        "present" => File.file?(path),
        "valid_json" => false,
        "scripts" => runtime_expected_map(expected_scripts),
        "dependencies" => runtime_expected_map(expected_dependencies.to_h { |name| [name, "present"] }),
        "package_manager" => nil,
        "error" => nil
      }
      return summary unless File.file?(path)

      data = JSON.parse(File.read(path))
      unless data.is_a?(Hash)
        summary["error"] = "package.json must be a JSON object"
        return summary
      end

      scripts = data["scripts"].is_a?(Hash) ? data["scripts"] : {}
      dependencies = data["dependencies"].is_a?(Hash) ? data["dependencies"] : {}
      summary["valid_json"] = true
      summary["package_manager"] = data["packageManager"].to_s.split("@").first unless data["packageManager"].to_s.strip.empty?
      summary["scripts"] = expected_scripts.each_with_object({}) do |(name, expected), memo|
        actual = scripts[name]
        memo[name] = {
          "expected" => expected,
          "actual" => actual,
          "present" => !actual.to_s.empty?,
          "matches" => actual == expected
        }
      end
      summary["dependencies"] = expected_dependencies.each_with_object({}) do |name, memo|
        actual = dependencies[name]
        memo[name] = {
          "expected" => "present",
          "actual" => actual,
          "present" => !actual.to_s.empty?
        }
      end
      summary
    rescue JSON::ParserError => e
      summary["error"] = "invalid JSON: #{e.message}"
      summary
    rescue SystemCallError => e
      summary["error"] = e.message
      summary
    end

    def runtime_expected_map(expected)
      expected.each_with_object({}) do |(name, value), memo|
        memo[name] = {
          "expected" => value,
          "actual" => nil,
          "present" => false,
          "matches" => false
        }
      end
    end

    def runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files, contract)
      blockers = []
      blockers << state_error if state_error
      unless scaffold["scaffold_created"]
        blockers << "Scaffold has not been created; run aiweb scaffold --profile D or --profile S after completing the required planning gates."
      end
      if contract.nil?
        blockers << "Runtime contract for Profile #{scaffold["profile"].inspect} is not implemented; supported runtime profiles are D and S."
        return blockers.compact.uniq
      end
      if scaffold["profile"].to_s != contract.id
        blockers << "Runtime contract mismatch: state requested Profile #{scaffold["profile"].inspect}, but resolved #{contract.id.inspect}."
      end
      unless scaffold["metadata_path_safe"]
        blockers << "Unsafe scaffold metadata path #{scaffold["metadata_path_state_value"].inspect}: #{scaffold["metadata_path_error"]}. Runtime plan only reads #{contract.metadata_path}."
      end
      blockers << "Scaffold metadata #{contract.metadata_path} is missing; rerun aiweb scaffold --profile #{contract.id} after reviewing existing files." if scaffold["metadata_path_safe"] && !metadata["present"]
      blockers << "Scaffold metadata #{metadata["path"]} is malformed: #{metadata["error"]}" if metadata["present"] && !metadata["valid_json"]
      runtime_expected_metadata_blockers(scaffold, metadata, contract).each { |blocker| blockers << blocker } if metadata["valid_json"]

      if contract.id == "D"
        runtime_selected_design_drift_blockers(design, contract).each { |blocker| blockers << blocker }
        unless design["design_md_present"]
          blockers << "Design source .ai-web/DESIGN.md is missing; run aiweb design-system resolve or restore the approved design source."
        end
        if design["design_md_present"] && !design["design_md_substantive"]
          blockers << "Design source .ai-web/DESIGN.md is stub-like; provide substantive design constraints before runtime QA."
        end
        if design["selected_candidate"].to_s.empty?
          blockers << "No selected design candidate recorded; run aiweb design --candidates 3 then aiweb select-design candidate-01|candidate-02|candidate-03."
        elsif !design["selected_candidate_present"]
          blockers << "Selected design candidate artifact #{design["selected_candidate_path"] || design["selected_candidate"]} is missing; rerun aiweb design --candidates 3 or select an existing candidate."
        end
      end

      missing_files.each do |path|
        blockers << "Required scaffold file #{path} is missing for Profile #{contract.id}; rerun aiweb scaffold --profile #{contract.id} to complete safe missing files."
      end
      runtime_package_blockers(package_json, contract).each { |blocker| blockers << blocker }
      blockers.compact.uniq
    end

    def runtime_expected_metadata_blockers(scaffold, metadata, contract)
      expected = contract.expected_metadata
      expected.each_with_object([]) do |(key, value), blockers|
        actual = metadata[key]
        blockers << "Scaffold metadata #{key} should be #{value.inspect}, found #{actual.inspect}; rerun aiweb scaffold --profile #{contract.id} or repair metadata." unless actual == value
        state_actual = scaffold[key]
        next if state_actual.to_s.empty? || state_actual == actual

        blockers << "State scaffold #{key} (#{state_actual.inspect}) does not match metadata (#{actual.inspect}); repair .ai-web/state.yaml or rerun scaffold with reviewed force."
      end
    end

    def runtime_selected_design_drift_blockers(design, contract = Aiweb::ProfilePolicy::ProfileD.contract)
      blockers = []
      state_selected = design["state_selected_candidate"].to_s.strip
      metadata_selected = design["metadata_selected_candidate"].to_s.strip
      generated = design.fetch("generated_reference", {})
      generated_selected = generated["selected_candidate"].to_s.strip

      if state_selected.empty? && !metadata_selected.empty?
        blockers << "Selected design drift: state design_candidates.selected_candidate is missing but scaffold metadata selected_candidate is #{metadata_selected.inspect}; reselect the intended candidate and rerun aiweb scaffold --profile D, or repair .ai-web/state.yaml."
      elsif !state_selected.empty? && metadata_selected.empty?
        blockers << "Selected design drift: state design_candidates.selected_candidate is #{state_selected.inspect} but scaffold metadata selected_candidate is missing; rerun aiweb scaffold --profile #{contract.id} or repair #{contract.metadata_path}."
      elsif state_selected != metadata_selected
        blockers << "Selected design drift: state design_candidates.selected_candidate (#{state_selected.inspect}) does not match scaffold metadata selected_candidate (#{metadata_selected.inspect}); reselect the intended candidate and rerun aiweb scaffold --profile D, or repair .ai-web/state.yaml and #{contract.metadata_path}."
      end

      if generated["present"] && !generated["valid_json"]
        blockers << "Generated scaffold content #{generated["path"]} is malformed: #{generated["error"]}; rerun aiweb scaffold --profile D after reviewing local edits."
      elsif generated["present"] && generated["valid_json"]
        expected = state_selected.empty? ? metadata_selected : state_selected
        if !expected.empty? && generated_selected.empty?
          blockers << "Selected design drift: generated scaffold content #{generated["path"]} selected_candidate is missing but selected design is #{expected.inspect}; rerun aiweb scaffold --profile D after reviewing generated content."
        elsif !expected.empty? && generated_selected != expected
          blockers << "Selected design drift: generated scaffold content #{generated["path"]} selected_candidate (#{generated_selected.inspect}) does not match selected design (#{expected.inspect}); rerun aiweb scaffold --profile D after reviewing generated content."
        end
        if !metadata_selected.empty? && !generated_selected.empty? && generated_selected != metadata_selected
          blockers << "Selected design drift: generated scaffold content #{generated["path"]} selected_candidate (#{generated_selected.inspect}) does not match scaffold metadata selected_candidate (#{metadata_selected.inspect}); rerun aiweb scaffold --profile D after reviewing generated content."
        end
      end

      blockers
    end

    def runtime_package_blockers(package_json, contract)
      blockers = []
      unless package_json["present"]
        blockers << "package.json is missing; rerun aiweb scaffold --profile #{contract.id} before runtime tools."
        return blockers
      end
      unless package_json["valid_json"]
        blockers << "package.json is malformed: #{package_json["error"]}; fix JSON before runtime tools."
        return blockers
      end
      package_json.fetch("scripts").each do |name, status|
        unless status["matches"]
          blockers << "package.json script #{name.inspect} should be #{status["expected"].inspect}; found #{status["actual"].inspect}."
        end
      end
      package_json.fetch("dependencies").each do |name, status|
        blockers << "package.json dependency #{name.inspect} is missing; restore Profile #{contract.id} scaffold dependencies." unless status["present"]
      end
      blockers
    end
  end
end
