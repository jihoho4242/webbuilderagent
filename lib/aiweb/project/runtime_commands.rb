# frozen_string_literal: true

require "digest"
require_relative "../profile_policy"
require_relative "../runtime"
require_relative "runtime_commands/qa_artifacts"
require_relative "runtime_commands/browser_qa"
require_relative "runtime_commands/setup"
require_relative "runtime_commands/readiness"
require_relative "runtime_commands/preview"
require_relative "runtime_commands/playwright_qa"
module Aiweb
  module ProjectRuntimeCommands
    include ProjectRuntimeReadiness
    include ProjectRuntimePreview
    include ProjectRuntimePlaywrightQa
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

  end
end
