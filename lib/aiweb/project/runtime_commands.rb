# frozen_string_literal: true

module Aiweb
  module ProjectRuntimeCommands
    def runtime_plan
      state, state_error = runtime_state_snapshot
      ensure_scaffold_state_defaults!(state) if state

      scaffold = runtime_scaffold_summary(state)
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary
      missing_files = self.class::SCAFFOLD_PROFILE_D_REQUIRED_FILES.reject { |path| File.exist?(File.join(root, path)) }
      blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files)
      readiness = blockers.empty? ? "ready" : "blocked"

      {
        "schema_version" => 1,
        "current_phase" => state&.dig("phase", "current"),
        "action_taken" => "reported runtime plan",
        "changed_files" => [],
        "blocking_issues" => blockers,
        "missing_artifacts" => state ? [] : [".ai-web/state.yaml"],
        "runtime_plan" => {
          "readiness" => readiness,
          "scaffold" => scaffold,
          "metadata" => metadata,
          "package_json" => package_json,
          "design" => design,
          "missing_required_scaffold_files" => missing_files,
          "blockers" => blockers
        },
        "next_action" => readiness == "ready" ? "runtime tools may inspect scripts next; do not install packages or launch Node from this read-only check" : "resolve blockers, then rerun aiweb runtime-plan"
      }
    end

    def setup(install: false, approved: false, dry_run: false)
      assert_initialized!

      unless install
        return setup_blocked_payload(
          state: load_state,
          status: "unsupported",
          command: nil,
          dry_run: dry_run,
          blocking_issues: ["setup currently supports --install only"],
          next_action: "rerun aiweb setup --install with --dry-run or --approved"
        )
      end

      state, state_error = runtime_state_snapshot
      ensure_scaffold_state_defaults!(state) if state
      ensure_setup_state_defaults!(state) if state
      scaffold = runtime_scaffold_summary(state)
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary
      missing_files = self.class::SCAFFOLD_PROFILE_D_REQUIRED_FILES.reject { |path| File.exist?(File.join(root, path)) }
      blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files)
      package_manager = setup_package_manager(scaffold, metadata, package_json)
      command = setup_install_command(package_manager)
      blockers << "setup install currently supports pnpm only; detected #{package_manager.inspect}" unless package_manager == "pnpm"
      return setup_blocked_payload(state: state, status: "blocked", command: command, dry_run: dry_run, blocking_issues: blockers, next_action: "resolve runtime-plan blockers, then rerun aiweb setup --install") unless blockers.empty?

      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      run_id = "setup-#{timestamp}"
      run_dir = File.join(aiweb_dir, "runs", run_id)
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      metadata_path = File.join(run_dir, "setup.json")
      planned_changes = [relative(run_dir), relative(stdout_path), relative(stderr_path), relative(metadata_path)]
      lifecycle_warnings = package_lifecycle_script_warnings

      unless approved || dry_run
        return setup_payload(
          state: state,
          metadata: setup_run_metadata(
            run_id: run_id,
            status: "blocked",
            command: command,
            package_manager: package_manager,
            started_at: nil,
            finished_at: nil,
            exit_code: nil,
            stdout_log: relative(stdout_path),
            stderr_log: relative(stderr_path),
            metadata_path: relative(metadata_path),
            lifecycle_script_warnings: lifecycle_warnings,
            node_modules_present: File.directory?(File.join(root, "node_modules")),
            blocking_issues: ["--approved is required for real package install"],
            dry_run: false,
            approved: false,
            requires_approval: true
          ),
          changed_files: [],
          action_taken: "setup install blocked",
          blocking_issues: ["--approved is required for real package install"],
          next_action: "rerun aiweb setup --install --approved to execute locally, or --dry-run to inspect planned artifacts"
        )
      end

      if dry_run
        return setup_payload(
          state: state,
          metadata: setup_run_metadata(
            run_id: run_id,
            status: "dry_run",
            command: command,
            package_manager: package_manager,
            started_at: nil,
            finished_at: nil,
            exit_code: nil,
            stdout_log: relative(stdout_path),
            stderr_log: relative(stderr_path),
            metadata_path: relative(metadata_path),
            lifecycle_script_warnings: lifecycle_warnings,
            node_modules_present: File.directory?(File.join(root, "node_modules")),
            blocking_issues: [],
            dry_run: true,
            approved: approved,
            requires_approval: false
          ),
          changed_files: planned_changes,
          action_taken: "planned setup install",
          blocking_issues: [],
          next_action: "rerun aiweb setup --install --approved to execute #{command.inspect} locally"
        )
      end

      changes = []
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << relative(run_dir)
        started_at = now
        stdout = ""
        stderr = ""
        status = "blocked"
        exit_code = nil
        blocking_issues = []

        if executable_path("pnpm").nil?
          blocking_issues << "pnpm executable is missing; install pnpm locally, then rerun aiweb setup --install --approved."
          stderr = blocking_issues.join("\n") + "\n"
        else
          stdout, stderr, process_status = Open3.capture3(setup_child_env, *setup_install_argv(package_manager), chdir: root)
          stdout = redact_setup_output(stdout)
          stderr = redact_setup_output(stderr)
          exit_code = process_status.exitstatus
          status = process_status.success? ? "passed" : "failed"
          blocking_issues << "#{command} failed with exit code #{exit_code}" unless process_status.success?
        end

        changes << write_file(stdout_path, stdout, false)
        changes << write_file(stderr_path, stderr, false)
        metadata = setup_run_metadata(
          run_id: run_id,
          status: status,
          command: command,
          package_manager: package_manager,
          started_at: started_at,
          finished_at: now,
          exit_code: exit_code,
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          metadata_path: relative(metadata_path),
          lifecycle_script_warnings: lifecycle_warnings,
          node_modules_present: File.directory?(File.join(root, "node_modules")),
          blocking_issues: blocking_issues,
          dry_run: false,
          approved: true,
          requires_approval: false
        )
        changes << write_json(metadata_path, metadata, false)
        setup_state = state["setup"] ||= {}
        setup_state["latest_run"] = relative(metadata_path)
        setup_state["package_manager"] = package_manager
        setup_state["node_modules_present"] = metadata["node_modules_present"]
        setup_state["last_installed_at"] = metadata["finished_at"] if status == "passed"
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)

        return setup_payload(
          state: state,
          metadata: metadata,
          changed_files: compact_changes(changes),
          action_taken: status == "passed" ? "ran setup install" : "setup install failed",
          blocking_issues: blocking_issues,
          next_action: setup_next_action(status)
        )
      end
    end


    def build(dry_run: false)
      assert_initialized!

      state, state_error = runtime_state_snapshot
      ensure_scaffold_state_defaults!(state) if state
      scaffold = runtime_scaffold_summary(state)
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary
      missing_files = self.class::SCAFFOLD_PROFILE_D_REQUIRED_FILES.reject { |path| File.exist?(File.join(root, path)) }
      blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files)
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
          stdout, stderr, process_status = Open3.capture3(command, chdir: root)
          exit_code = process_status.exitstatus
          status = process_status.success? ? "passed" : "failed"
          blocking_issues << "#{command} failed with exit code #{exit_code}" unless process_status.success?
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

      state, state_error = runtime_state_snapshot
      ensure_scaffold_state_defaults!(state) if state
      scaffold = runtime_scaffold_summary(state)
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary
      missing_files = self.class::SCAFFOLD_PROFILE_D_REQUIRED_FILES.reject { |path| File.exist?(File.join(root, path)) }
      blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files)
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
            pid = Process.spawn(command, chdir: root, out: stdout_file, err: stderr_file)
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

    def qa_playwright(url: nil, task_id: nil, force: false, dry_run: false)
      state, state_error = runtime_state_snapshot
      return qa_playwright_blocked_payload(state, [state_error], dry_run: dry_run, command: qa_playwright_command(nil), target: nil) unless state_error.nil?

      ensure_scaffold_state_defaults!(state) if state
      scaffold = runtime_scaffold_summary(state)
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary
      missing_files = self.class::SCAFFOLD_PROFILE_D_REQUIRED_FILES.reject { |path| File.exist?(File.join(root, path)) }
      blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files)
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
          stdout, stderr, process_status = Open3.capture3({ "PLAYWRIGHT_BASE_URL" => target["url"] }, "pnpm", "exec", "playwright", "test", relative(spec_path), "--reporter=json", chdir: root)
          exit_code = process_status.exitstatus
          status = process_status.success? ? "passed" : "failed"
          blocking_issues << "#{command} failed with exit code #{exit_code}" unless process_status.success?
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

    def browser_qa(dry_run: false)
      qa_playwright(dry_run: dry_run)
    end

    def qa_screenshot(url: nil, task_id: nil, force: false, dry_run: false)
      state, state_error = runtime_state_snapshot
      return qa_screenshot_blocked_payload(state, [state_error], dry_run: dry_run, command: qa_screenshot_command(nil, nil, nil), target: nil) unless state_error.nil?

      ensure_scaffold_state_defaults!(state) if state
      scaffold = runtime_scaffold_summary(state)
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary
      missing_files = self.class::SCAFFOLD_PROFILE_D_REQUIRED_FILES.reject { |path| File.exist?(File.join(root, path)) }
      blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files)
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
            stdout, stderr, process_status = Open3.capture3({ "AIWEB_QA_SCREENSHOT_URL" => target["url"] }, *command_parts, chdir: root)
            stdout_chunks << "$ #{command_parts.join(" ")}\n#{stdout}"
            stderr_chunks << "$ #{command_parts.join(" ")}\n#{stderr}"
            unless process_status.success?
              exit_code = process_status.exitstatus
              status = "failed"
              blocking_issues << "#{command_parts.join(" ")} failed with exit code #{exit_code}"
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

    def setup_blocked_payload(state:, status:, command:, dry_run:, blocking_issues:, next_action:)
      setup_payload(
        state: state,
        metadata: {
          "schema_version" => 1,
          "status" => status,
          "command" => command,
          "dry_run" => dry_run,
          "blocking_issues" => blocking_issues
        },
        changed_files: [],
        action_taken: "setup install #{status}",
        blocking_issues: blocking_issues,
        next_action: next_action
      )
    end

    def setup_payload(state:, metadata:, changed_files:, action_taken:, blocking_issues:, next_action:)
      {
        "schema_version" => 1,
        "current_phase" => state&.dig("phase", "current"),
        "action_taken" => action_taken,
        "changed_files" => changed_files,
        "blocking_issues" => blocking_issues,
        "missing_artifacts" => [],
        "setup" => metadata,
        "next_action" => next_action
      }
    end

    def setup_run_metadata(run_id:, status:, command:, package_manager:, started_at:, finished_at:, exit_code:, stdout_log:, stderr_log:, metadata_path:, lifecycle_script_warnings:, node_modules_present:, blocking_issues:, dry_run:, approved:, requires_approval:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "command" => command,
        "package_manager" => package_manager,
        "cwd" => root,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "exit_code" => exit_code,
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "metadata_path" => metadata_path,
        "lifecycle_script_warnings" => lifecycle_script_warnings,
        "node_modules_present" => node_modules_present,
        "dry_run" => dry_run,
        "approved" => approved,
        "requires_approval" => requires_approval,
        "blocking_issues" => blocking_issues
      }
    end

    def setup_next_action(status)
      case status
      when "passed" then "continue to build/preview/QA only through separately approved roadmap commands"
      when "blocked" then "resolve the blocked local setup precondition, then rerun aiweb setup --install --approved"
      else "inspect .ai-web/runs setup logs, fix the package install issue, then rerun aiweb setup --install --approved"
      end
    end

    def setup_package_manager(scaffold, metadata, package_json)
      [
        scaffold["package_manager"],
        metadata["package_manager"],
        package_json_package_manager_name(package_json)
      ].map { |value| value.to_s.strip }.find { |value| !value.empty? } || "pnpm"
    end

    def package_json_package_manager_name(package_json)
      value = package_json["package_manager"] || package_json["packageManager"]
      value.to_s.split("@").first
    end

    def setup_install_command(package_manager)
      setup_install_argv(package_manager).join(" ")
    end

    def setup_install_argv(package_manager)
      case package_manager
      when "pnpm" then ["pnpm", "install"]
      else [package_manager.to_s, "install"]
      end
    end

    def package_lifecycle_script_warnings
      data = read_package_json_object
      scripts = data["scripts"].is_a?(Hash) ? data["scripts"] : {}
      %w[preinstall install postinstall prepare].each_with_object([]) do |name, warnings|
        next if scripts[name].to_s.strip.empty?

        warnings << {
          "script" => name,
          "warning" => "package.json declares #{name}; approved install may execute package lifecycle code"
        }
      end
    end

    def read_package_json_object
      path = File.join(root, "package.json")
      return {} unless File.file?(path)

      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : {}
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def setup_child_env
      ENV.to_h.reject do |key, _value|
        key.match?(/SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE|CREDENTIAL|API[_-]?KEY|AUTH/i)
      end.merge("AIWEB_SETUP_APPROVED" => "1")
    end

    def redact_setup_output(output)
      output.to_s
        .gsub(/(SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE|CREDENTIAL|API[_-]?KEY)([A-Z0-9_ -]*)(=|:)[^\s]+/i, '\1\2\3[REDACTED]')
        .gsub(/(sk|pk|sb_secret)_[A-Za-z0-9_-]{12,}/, '[REDACTED]')
        .gsub(/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/, '[REDACTED]')
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
      {
        "schema_version" => 1,
        "current_phase" => state&.dig("phase", "current"),
        "action_taken" => action_taken,
        "changed_files" => changed_files,
        "blocking_issues" => blocking_issues,
        "missing_artifacts" => [],
        "build" => metadata,
        "next_action" => next_action
      }
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
      {
        "schema_version" => 1,
        "current_phase" => state&.dig("phase", "current"),
        "action_taken" => action_taken,
        "changed_files" => changed_files,
        "blocking_issues" => blocking_issues,
        "missing_artifacts" => [],
        "preview" => metadata,
        "next_action" => next_action
      }
    end

    def qa_playwright_payload(state:, metadata:, changed_files:, action_taken:, blocking_issues:, next_action:)
      {
        "schema_version" => 1,
        "current_phase" => state&.dig("phase", "current"),
        "action_taken" => action_taken,
        "changed_files" => changed_files,
        "blocking_issues" => blocking_issues,
        "missing_artifacts" => [],
        "playwright_qa" => metadata,
        "next_action" => next_action
      }
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
      File.executable?(path) && !File.directory?(path) ? path : nil
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
      File.executable?(path) && !File.directory?(path) ? path : nil
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

    def git_commit_sha
      stdout, _stderr, status = Open3.capture3("git", "rev-parse", "HEAD", chdir: root)
      status.success? ? stdout.strip : "unknown"
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
        Process.kill("TERM", pid)
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

    def runtime_state_snapshot
      return [nil, "Project is not initialized; run aiweb init --profile D or aiweb start before checking runtime readiness."] unless File.file?(state_path)

      state = YAML.load_file(state_path)
      return [state, nil] if state.is_a?(Hash)

      [nil, ".ai-web/state.yaml must be a YAML mapping; repair state before checking runtime readiness."]
    rescue Psych::Exception => e
      [nil, "Cannot parse .ai-web/state.yaml: #{e.message}"]
    end

    def runtime_scaffold_summary(state)
      implementation = state&.fetch("implementation", {}) || {}
      metadata_path = runtime_scaffold_metadata_path(implementation["scaffold_metadata_path"])
      {
        "scaffold_created" => implementation["scaffold_created"] == true,
        "profile" => implementation["scaffold_profile"] || implementation["stack_profile"],
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

    def runtime_scaffold_metadata_path(state_value)
      raw = state_value.to_s.strip
      return { "path" => self.class::SCAFFOLD_PROFILE_D_METADATA_PATH, "state_value" => nil, "safe" => true, "error" => nil } if raw.empty?

      normalized = raw.tr("\\", "/")
      normalized = normalized.sub(%r{\A(?:\./)+}, "")
      parts = normalized.split("/")
      error = if raw.start_with?("/") || raw.match?(%r{\A[A-Za-z]:[\\/]})
                "scaffold metadata path must be relative to the project .ai-web directory, not absolute"
              elsif parts.any? { |part| part == ".." }
                "scaffold metadata path must not contain traversal"
              elsif parts.any? { |part| part.start_with?(".env") }
                "scaffold metadata path must not reference .env files"
              elsif normalized != self.class::SCAFFOLD_PROFILE_D_METADATA_PATH
                "scaffold metadata path must be #{self.class::SCAFFOLD_PROFILE_D_METADATA_PATH}"
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

    def runtime_package_json_summary
      path = File.join(root, "package.json")
      summary = {
        "path" => "package.json",
        "present" => File.file?(path),
        "valid_json" => false,
        "scripts" => runtime_expected_map(self.class::PROFILE_D_EXPECTED_SCRIPTS),
        "dependencies" => runtime_expected_map(self.class::PROFILE_D_EXPECTED_DEPENDENCIES.to_h { |name| [name, "present"] }),
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
      summary["scripts"] = self.class::PROFILE_D_EXPECTED_SCRIPTS.each_with_object({}) do |(name, expected), memo|
        actual = scripts[name]
        memo[name] = {
          "expected" => expected,
          "actual" => actual,
          "present" => !actual.to_s.empty?,
          "matches" => actual == expected
        }
      end
      summary["dependencies"] = self.class::PROFILE_D_EXPECTED_DEPENDENCIES.each_with_object({}) do |name, memo|
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

    def runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files)
      blockers = []
      blockers << state_error if state_error
      unless scaffold["scaffold_created"]
        blockers << "Scaffold has not been created; run aiweb scaffold --profile D after selecting a design candidate."
      end
      if scaffold["profile"].to_s != "D"
        blockers << "Runtime plan currently expects Profile D; run aiweb scaffold --profile D or repair implementation.scaffold_profile."
      end
      unless scaffold["metadata_path_safe"]
        blockers << "Unsafe scaffold metadata path #{scaffold["metadata_path_state_value"].inspect}: #{scaffold["metadata_path_error"]}. Runtime plan only reads #{self.class::SCAFFOLD_PROFILE_D_METADATA_PATH}."
      end
      blockers << "Scaffold metadata .ai-web/scaffold-profile-D.json is missing; rerun aiweb scaffold --profile D after reviewing existing files." if scaffold["metadata_path_safe"] && !metadata["present"]
      blockers << "Scaffold metadata #{metadata["path"]} is malformed: #{metadata["error"]}" if metadata["present"] && !metadata["valid_json"]
      runtime_expected_metadata_blockers(scaffold, metadata).each { |blocker| blockers << blocker } if metadata["valid_json"]
      runtime_selected_design_drift_blockers(design).each { |blocker| blockers << blocker }
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
      missing_files.each do |path|
        blockers << "Required scaffold file #{path} is missing; rerun aiweb scaffold --profile D to complete safe missing files."
      end
      runtime_package_blockers(package_json).each { |blocker| blockers << blocker }
      blockers.compact.uniq
    end

    def runtime_expected_metadata_blockers(scaffold, metadata)
      expected = {
        "profile" => "D",
        "framework" => "Astro",
        "package_manager" => "pnpm",
        "dev_command" => "pnpm dev",
        "build_command" => "pnpm build"
      }
      expected.each_with_object([]) do |(key, value), blockers|
        actual = metadata[key]
        blockers << "Scaffold metadata #{key} should be #{value.inspect}, found #{actual.inspect}; rerun aiweb scaffold --profile D or repair metadata." unless actual == value
        state_actual = scaffold[key]
        next if state_actual.to_s.empty? || state_actual == actual

        blockers << "State scaffold #{key} (#{state_actual.inspect}) does not match metadata (#{actual.inspect}); repair .ai-web/state.yaml or rerun scaffold with reviewed force."
      end
    end

    def runtime_selected_design_drift_blockers(design)
      blockers = []
      state_selected = design["state_selected_candidate"].to_s.strip
      metadata_selected = design["metadata_selected_candidate"].to_s.strip
      generated = design.fetch("generated_reference", {})
      generated_selected = generated["selected_candidate"].to_s.strip

      if state_selected.empty? && !metadata_selected.empty?
        blockers << "Selected design drift: state design_candidates.selected_candidate is missing but scaffold metadata selected_candidate is #{metadata_selected.inspect}; reselect the intended candidate and rerun aiweb scaffold --profile D, or repair .ai-web/state.yaml."
      elsif !state_selected.empty? && metadata_selected.empty?
        blockers << "Selected design drift: state design_candidates.selected_candidate is #{state_selected.inspect} but scaffold metadata selected_candidate is missing; rerun aiweb scaffold --profile D or repair #{self.class::SCAFFOLD_PROFILE_D_METADATA_PATH}."
      elsif state_selected != metadata_selected
        blockers << "Selected design drift: state design_candidates.selected_candidate (#{state_selected.inspect}) does not match scaffold metadata selected_candidate (#{metadata_selected.inspect}); reselect the intended candidate and rerun aiweb scaffold --profile D, or repair .ai-web/state.yaml and #{self.class::SCAFFOLD_PROFILE_D_METADATA_PATH}."
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

    def runtime_package_blockers(package_json)
      blockers = []
      unless package_json["present"]
        blockers << "package.json is missing; rerun aiweb scaffold --profile D before runtime tools."
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
        blockers << "package.json dependency #{name.inspect} is missing; restore Profile D scaffold dependencies." unless status["present"]
      end
      blockers
    end
  end
end
