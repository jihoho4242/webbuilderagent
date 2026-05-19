# frozen_string_literal: true

require_relative "setup/supply_chain"
module Aiweb
  module ProjectRuntimeCommands
    def setup(install: false, approved: false, dry_run: false, audit_exception_path: nil, allow_lifecycle_scripts: false)
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
      contract = runtime_profile_contract(scaffold)
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary(contract)
      missing_files = runtime_missing_required_files(contract)
      blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files, contract)
      blockers.concat(runtime_capability_blockers(contract, :setup))
      package_manager = setup_package_manager(scaffold, metadata, package_json)
      command = setup_install_command(package_manager)
      blockers << "setup install currently supports pnpm only; detected #{package_manager.inspect}" unless package_manager == "pnpm"
      return setup_blocked_payload(state: state, status: "blocked", command: command, dry_run: dry_run, blocking_issues: blockers, next_action: "resolve runtime-plan blockers, then rerun aiweb setup --install") unless blockers.empty?

      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%S%6NZ")
      run_id = "setup-#{timestamp}-#{SecureRandom.hex(4)}"
      setup_paths = setup_install_run_paths(run_id)
      run_dir = setup_paths.fetch(:run_dir)
      artifacts_dir = setup_paths.fetch(:artifacts_dir)
      package_cache_dir = setup_paths.fetch(:package_cache_dir)
      stdout_path = setup_paths.fetch(:stdout_path)
      stderr_path = setup_paths.fetch(:stderr_path)
      metadata_path = setup_paths.fetch(:metadata_path)
      side_effect_broker_path = setup_paths.fetch(:side_effect_broker_path)
      supply_chain_gate_path = setup_paths.fetch(:supply_chain_gate_path)
      sbom_path = setup_paths.fetch(:sbom_path)
      cyclonedx_sbom_path = setup_paths.fetch(:cyclonedx_sbom_path)
      spdx_sbom_path = setup_paths.fetch(:spdx_sbom_path)
      package_audit_path = setup_paths.fetch(:package_audit_path)
      command_argv = setup_install_argv(package_manager, cache_dir: relative(package_cache_dir))
      command = setup_install_command(package_manager, cache_dir: relative(package_cache_dir))
      side_effect_broker_plan = setup_side_effect_broker_plan(
        command_argv: command_argv,
        broker_path: side_effect_broker_path,
        dry_run: dry_run,
        approved: approved,
        blocked: false,
        blockers: []
      )
      planned_changes = setup_install_planned_changes(setup_paths)
      lifecycle_scripts = package_lifecycle_scripts
      lifecycle_warnings = package_lifecycle_script_warnings(lifecycle_scripts)
      audit_exception_plan = setup_audit_exception_plan(audit_exception_path)
      supply_chain_plan = setup_supply_chain_plan(
        package_manager: package_manager,
        command_argv: command_argv,
        package_cache_dir: package_cache_dir,
        supply_chain_gate_path: supply_chain_gate_path,
        sbom_path: sbom_path,
        cyclonedx_sbom_path: cyclonedx_sbom_path,
        spdx_sbom_path: spdx_sbom_path,
        package_audit_path: package_audit_path,
        audit_exception: audit_exception_plan,
        status: approved ? "ready" : (dry_run ? "planned" : "blocked"),
        blocking_issues: approved || dry_run ? [] : ["--approved is required for real package install"],
        lifecycle_scripts: lifecycle_scripts,
        lifecycle_enabled_requested: allow_lifecycle_scripts
      )

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
            lifecycle_enabled_requested: allow_lifecycle_scripts,
            node_modules_present: File.directory?(File.join(root, "node_modules")),
            blocking_issues: ["--approved is required for real package install"],
            dry_run: false,
            approved: false,
            requires_approval: true,
            side_effect_broker_path: relative(side_effect_broker_path),
            side_effect_broker: side_effect_broker_plan.merge(
              "status" => "blocked",
              "policy" => side_effect_broker_plan.fetch("policy").merge(
                "decision" => "deny",
                "blocking_issues" => ["--approved is required for real package install"]
              )
            ),
            side_effect_broker_events: [],
            supply_chain_gate_path: relative(supply_chain_gate_path),
            supply_chain_gate: supply_chain_plan,
            sbom_path: relative(sbom_path),
            cyclonedx_sbom_path: relative(cyclonedx_sbom_path),
            spdx_sbom_path: relative(spdx_sbom_path),
            package_audit_path: relative(package_audit_path),
            audit_exception: audit_exception_plan
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
            lifecycle_enabled_requested: allow_lifecycle_scripts,
            node_modules_present: File.directory?(File.join(root, "node_modules")),
            blocking_issues: [],
            dry_run: true,
            approved: approved,
            requires_approval: false,
            side_effect_broker_path: relative(side_effect_broker_path),
            side_effect_broker: side_effect_broker_plan,
            side_effect_broker_events: [],
            supply_chain_gate_path: relative(supply_chain_gate_path),
            supply_chain_gate: supply_chain_plan,
            sbom_path: relative(sbom_path),
            cyclonedx_sbom_path: relative(cyclonedx_sbom_path),
            spdx_sbom_path: relative(spdx_sbom_path),
            package_audit_path: relative(package_audit_path),
            audit_exception: audit_exception_plan
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
        FileUtils.mkdir_p(artifacts_dir)
        FileUtils.mkdir_p(package_cache_dir)
        changes << relative(run_dir)
        changes << relative(artifacts_dir)
        changes << relative(package_cache_dir)
        started_at = now
        stdout = ""
        stderr = ""
        status = "blocked"
        install_status = "blocked"
        exit_code = nil
        blocking_issues = []
        side_effect_broker_events = []
        dependency_snapshot_before = setup_supply_chain_file_snapshot
        dependency_semantic_before = setup_supply_chain_dependency_snapshot
        lockfile_semantic_before = setup_supply_chain_lockfile_snapshot
        pre_install_network_blockers = setup_supply_chain_network_allowlist_blockers(
          dependency_semantic_before,
          lockfile_semantic_before,
          phase: "pre-install"
        )
        pre_install_lifecycle_blockers = setup_lifecycle_sandbox_blockers(
          command_argv,
          lifecycle_scripts,
          lifecycle_enabled_requested: allow_lifecycle_scripts
        )
        not_executed_artifacts = setup_not_executed_supply_chain_artifacts(package_manager)
        sbom_artifact = not_executed_artifacts.fetch(:sbom)
        cyclonedx_sbom_artifact = not_executed_artifacts.fetch(:cyclonedx_sbom)
        spdx_sbom_artifact = not_executed_artifacts.fetch(:spdx_sbom)
        audit_artifact = not_executed_artifacts.fetch(:package_audit)
        audit_exception = audit_exception_plan
        side_effect_context = setup_side_effect_broker_context(command_argv: command_argv, approved: true)
        append_side_effect_broker_event(
          side_effect_broker_path,
          side_effect_broker_events,
          "tool.requested",
          side_effect_context.merge("requested_at" => started_at, "dry_run" => false)
        )

        if executable_path("pnpm").nil?
          blocking_issues << "pnpm executable is missing; install pnpm locally, then rerun aiweb setup --install --approved."
          stderr = blocking_issues.join("\n") + "\n"
          append_side_effect_broker_event(
            side_effect_broker_path,
            side_effect_broker_events,
            "policy.decision",
            side_effect_context.merge("decision" => "deny", "reason" => "pnpm executable is missing", "blocking_issues" => blocking_issues)
          )
          append_side_effect_broker_event(
            side_effect_broker_path,
            side_effect_broker_events,
            "tool.blocked",
            side_effect_context.merge("status" => "blocked", "reason" => blocking_issues.join("\n"))
          )
        elsif !pre_install_network_blockers.empty? || !pre_install_lifecycle_blockers.empty?
          blocking_issues.concat(pre_install_network_blockers)
          blocking_issues.concat(pre_install_lifecycle_blockers)
          stderr = blocking_issues.join("\n") + "\n"
          append_side_effect_broker_event(
            side_effect_broker_path,
            side_effect_broker_events,
            "policy.decision",
            side_effect_context.merge("decision" => "deny", "reason" => "setup dependency network or lifecycle sandbox allowlist violation", "blocking_issues" => blocking_issues)
          )
          append_side_effect_broker_event(
            side_effect_broker_path,
            side_effect_broker_events,
            "tool.blocked",
            side_effect_context.merge("status" => "blocked", "reason" => blocking_issues.join("\n"))
          )
        else
          append_side_effect_broker_event(
            side_effect_broker_path,
            side_effect_broker_events,
            "policy.decision",
            side_effect_context.merge("decision" => "allow", "reason" => "explicit --approved setup install")
          )
          append_side_effect_broker_event(
            side_effect_broker_path,
            side_effect_broker_events,
            "tool.started",
            side_effect_context.merge("started_at" => started_at)
          )
          stdout, stderr, process_status = Open3.capture3(setup_child_env, *command_argv, chdir: root, unsetenv_others: true)
          exit_code = process_status.exitstatus
          status = process_status.success? ? "passed" : "failed"
          install_status = status
          append_side_effect_broker_event(
            side_effect_broker_path,
            side_effect_broker_events,
            "tool.finished",
            side_effect_context.merge("finished_at" => now, "status" => status, "exit_code" => exit_code)
          )
          stdout = redact_side_effect_process_output(redact_setup_output(stdout))
          stderr = redact_side_effect_process_output(redact_setup_output(stderr))
          blocking_issues << "#{command} failed with exit code #{exit_code}" unless process_status.success?
          if process_status.success?
            sbom_result = setup_run_brokered_supply_chain_command(
              side_effect_broker_path,
              side_effect_broker_events,
              setup_supply_chain_sbom_argv(package_manager),
              scope: "setup.sbom",
              target: "installed_dependency_inventory",
              network_call_status: "local_inventory"
            )
            sbom_artifact = setup_supply_chain_sbom_artifact(
              package_manager: package_manager,
              command_result: sbom_result,
              dependency_snapshot: setup_supply_chain_file_snapshot
            )
            cyclonedx_sbom_artifact = setup_supply_chain_cyclonedx_sbom_artifact(
              package_manager: package_manager,
              sbom_artifact: sbom_artifact
            )
            spdx_sbom_artifact = setup_supply_chain_spdx_sbom_artifact(
              package_manager: package_manager,
              sbom_artifact: sbom_artifact
            )
            audit_result = setup_run_brokered_supply_chain_command(
              side_effect_broker_path,
              side_effect_broker_events,
              setup_supply_chain_audit_argv(package_manager),
              scope: "setup.package_audit",
              target: "installed_dependency_vulnerabilities",
              network_call_status: "attempted_unknown_result"
            )
            audit_artifact = setup_supply_chain_audit_artifact(package_manager: package_manager, command_result: audit_result)
            if sbom_artifact["status"] == "failed"
              blocking_issues << "setup supply-chain SBOM generation failed"
              status = "blocked"
            end
            if audit_artifact["status"] == "failed"
              blocking_issues << "setup package audit failed"
              status = "blocked"
            elsif audit_artifact["vulnerability_gate"] == "blocked"
              audit_exception = setup_audit_exception_evidence(
                audit_exception_path,
                audit_artifact: audit_artifact,
                package_manager: package_manager
              )
              if audit_exception["status"] == "accepted"
                status = process_status.success? ? "passed" : status
              else
                blocked_counts = audit_artifact.fetch("severity_counts").slice("critical", "high")
                blocking_issues << "setup package audit blocked by critical/high vulnerabilities: #{blocked_counts.inspect}"
                blocking_issues.concat(Array(audit_exception["blocking_issues"]))
                status = "blocked"
              end
            end
          end
        end

        dependency_semantic_after = setup_supply_chain_dependency_snapshot
        lockfile_semantic_after = setup_supply_chain_lockfile_snapshot
        if install_status == "passed"
          post_install_manifest_blockers = setup_post_install_package_manifest_blockers(dependency_semantic_after)
          post_install_lockfile_blockers = setup_post_install_lockfile_blockers(package_manager, lockfile_semantic_after)
          post_install_network_blockers = setup_supply_chain_network_allowlist_blockers(
            dependency_semantic_after,
            lockfile_semantic_after,
            phase: "post-install"
          )
          unless post_install_manifest_blockers.empty?
            blocking_issues.concat(post_install_manifest_blockers)
            status = "blocked"
          end
          unless post_install_lockfile_blockers.empty?
            blocking_issues.concat(post_install_lockfile_blockers)
            status = "blocked"
          end
          unless post_install_network_blockers.empty?
            blocking_issues.concat(post_install_network_blockers)
            status = "blocked"
          end
        end
        dependency_snapshot_after = setup_supply_chain_file_snapshot
        supply_chain_gate = setup_supply_chain_gate(
          package_manager: package_manager,
          command_argv: command_argv,
          package_cache_dir: package_cache_dir,
          supply_chain_gate_path: supply_chain_gate_path,
          sbom_path: sbom_path,
          cyclonedx_sbom_path: cyclonedx_sbom_path,
          spdx_sbom_path: spdx_sbom_path,
          package_audit_path: package_audit_path,
          audit_exception: audit_exception,
          install_status: install_status,
          install_exit_code: exit_code,
          dependency_snapshot_before: dependency_snapshot_before,
          dependency_snapshot_after: dependency_snapshot_after,
          dependency_semantic_before: dependency_semantic_before,
          dependency_semantic_after: dependency_semantic_after,
          lockfile_semantic_before: lockfile_semantic_before,
          lockfile_semantic_after: lockfile_semantic_after,
          sbom_artifact: sbom_artifact,
          cyclonedx_sbom_artifact: cyclonedx_sbom_artifact,
          spdx_sbom_artifact: spdx_sbom_artifact,
          audit_artifact: audit_artifact,
          blocking_issues: blocking_issues,
          lifecycle_scripts: lifecycle_scripts,
          lifecycle_enabled_requested: allow_lifecycle_scripts
        )
        changes << write_file(stdout_path, stdout, false)
        changes << write_file(stderr_path, stderr, false)
        changes << relative(side_effect_broker_path) if File.file?(side_effect_broker_path)
        changes << write_json(sbom_path, sbom_artifact, false)
        changes << write_json(cyclonedx_sbom_path, cyclonedx_sbom_artifact, false)
        changes << write_json(spdx_sbom_path, spdx_sbom_artifact, false)
        changes << write_json(package_audit_path, audit_artifact, false)
        changes << write_json(supply_chain_gate_path, supply_chain_gate, false)
        broker_policy_event = side_effect_broker_events.find { |event| event["event"] == "policy.decision" }
        broker_policy_decision = broker_policy_event&.fetch("decision", nil) || (side_effect_broker_events.empty? && !blocking_issues.empty? ? "deny" : "allow")
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
          lifecycle_enabled_requested: allow_lifecycle_scripts,
          node_modules_present: File.directory?(File.join(root, "node_modules")),
          blocking_issues: blocking_issues,
          dry_run: false,
          approved: true,
          requires_approval: false,
          side_effect_broker_path: relative(side_effect_broker_path),
          side_effect_broker: side_effect_broker_plan.merge(
            "status" => status,
            "events_recorded" => !side_effect_broker_events.empty?,
            "events_path" => relative(side_effect_broker_path),
            "event_count" => side_effect_broker_events.length,
            "policy" => side_effect_broker_plan.fetch("policy").merge(
              "decision" => broker_policy_decision,
              "blocking_issues" => broker_policy_decision == "deny" ? blocking_issues : []
            )
          ),
          side_effect_broker_events: side_effect_broker_events,
          supply_chain_gate_path: relative(supply_chain_gate_path),
          supply_chain_gate: supply_chain_gate,
          sbom_path: relative(sbom_path),
          cyclonedx_sbom_path: relative(cyclonedx_sbom_path),
          spdx_sbom_path: relative(spdx_sbom_path),
          package_audit_path: relative(package_audit_path),
          audit_exception: audit_exception
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
          action_taken: status == "passed" ? "ran setup install" : (status == "blocked" ? "setup install blocked" : "setup install failed"),
          blocking_issues: blocking_issues,
          next_action: setup_next_action(status)
        )
      end
    end


    private

    def setup_install_run_paths(run_id)
      run_dir = File.join(aiweb_dir, "runs", run_id)
      artifacts_dir = File.join(run_dir, "artifacts")
      {
        run_dir: run_dir,
        artifacts_dir: artifacts_dir,
        package_cache_dir: File.join(run_dir, "package-cache"),
        stdout_path: File.join(run_dir, "stdout.log"),
        stderr_path: File.join(run_dir, "stderr.log"),
        metadata_path: File.join(run_dir, "setup.json"),
        side_effect_broker_path: File.join(run_dir, "side-effect-broker.jsonl"),
        supply_chain_gate_path: File.join(artifacts_dir, "supply-chain-gate.json"),
        sbom_path: File.join(artifacts_dir, "sbom.json"),
        cyclonedx_sbom_path: File.join(artifacts_dir, "sbom.cyclonedx.json"),
        spdx_sbom_path: File.join(artifacts_dir, "sbom.spdx.json"),
        package_audit_path: File.join(artifacts_dir, "package-audit.json")
      }
    end

    def setup_install_planned_changes(paths)
      %i[
        run_dir
        artifacts_dir
        package_cache_dir
        stdout_path
        stderr_path
        metadata_path
        side_effect_broker_path
        supply_chain_gate_path
        sbom_path
        cyclonedx_sbom_path
        spdx_sbom_path
        package_audit_path
      ].map { |key| relative(paths.fetch(key)) }
    end

    def setup_not_executed_supply_chain_artifacts(package_manager)
      reason = "package install did not complete"
      sbom_argv = setup_supply_chain_sbom_argv(package_manager)
      {
        sbom: setup_supply_chain_not_executed_artifact(kind: "sbom", status: "not_executed", package_manager: package_manager, command_argv: sbom_argv, reason: reason),
        cyclonedx_sbom: setup_supply_chain_not_executed_artifact(kind: "cyclonedx_sbom", status: "not_executed", package_manager: package_manager, command_argv: sbom_argv, reason: reason),
        spdx_sbom: setup_supply_chain_not_executed_artifact(kind: "spdx_sbom", status: "not_executed", package_manager: package_manager, command_argv: sbom_argv, reason: reason),
        package_audit: setup_supply_chain_not_executed_artifact(kind: "package_audit", status: "not_executed", package_manager: package_manager, command_argv: setup_supply_chain_audit_argv(package_manager), reason: reason)
      }
    end

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
      runtime_command_payload(key: "setup", state: state, metadata: metadata, changed_files: changed_files, action_taken: action_taken, blocking_issues: blocking_issues, next_action: next_action)
    end

    def setup_run_metadata(run_id:, status:, command:, package_manager:, started_at:, finished_at:, exit_code:, stdout_log:, stderr_log:, metadata_path:, lifecycle_script_warnings:, lifecycle_enabled_requested: false, node_modules_present:, blocking_issues:, dry_run:, approved:, requires_approval:, side_effect_broker_path: nil, side_effect_broker: nil, side_effect_broker_events: [], supply_chain_gate_path: nil, supply_chain_gate: nil, sbom_path: nil, cyclonedx_sbom_path: nil, spdx_sbom_path: nil, package_audit_path: nil, audit_exception: nil)
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
        "lifecycle_enabled_requested" => lifecycle_enabled_requested,
        "node_modules_present" => node_modules_present,
        "dry_run" => dry_run,
        "approved" => approved,
        "requires_approval" => requires_approval,
        "blocking_issues" => blocking_issues
      }.tap do |metadata|
        metadata["side_effect_broker_path"] = side_effect_broker_path if side_effect_broker_path
        metadata["side_effect_broker"] = side_effect_broker if side_effect_broker
        metadata["side_effect_broker_events"] = side_effect_broker_events
        metadata["supply_chain_gate_path"] = supply_chain_gate_path if supply_chain_gate_path
        metadata["supply_chain_gate"] = supply_chain_gate if supply_chain_gate
        metadata["sbom_path"] = sbom_path if sbom_path
        metadata["cyclonedx_sbom_path"] = cyclonedx_sbom_path if cyclonedx_sbom_path
        metadata["spdx_sbom_path"] = spdx_sbom_path if spdx_sbom_path
        metadata["package_audit_path"] = package_audit_path if package_audit_path
        metadata["audit_exception"] = audit_exception if audit_exception
      end
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

    def setup_install_command(package_manager, cache_dir: nil)
      setup_install_argv(package_manager, cache_dir: cache_dir).join(" ")
    end

    def setup_install_argv(package_manager, cache_dir: nil)
      case package_manager
      when "pnpm"
        ["pnpm", "install", "--ignore-scripts", "--registry", setup_supply_chain_registry_url].tap do |argv|
          argv.concat(["--store-dir", cache_dir]) if cache_dir
        end
      else [package_manager.to_s, "install"]
      end
    end

    def package_lifecycle_scripts
      data = read_package_json_object
      scripts = data["scripts"].is_a?(Hash) ? data["scripts"] : {}
      %w[preinstall install postinstall prepare].filter_map do |name|
        command = scripts[name].to_s.strip
        next if command.empty?

        redacted_command = redact_side_effect_process_output(redact_setup_output(command))
        {
          "script" => name,
          "command" => redacted_command,
          "command_sha256" => Digest::SHA256.hexdigest(command)
        }
      end
    end

    def package_lifecycle_script_warnings(lifecycle_scripts = package_lifecycle_scripts)
      lifecycle_scripts.map do |entry|
        {
          "script" => entry.fetch("script"),
          "warning" => "package.json declares #{entry.fetch("script")}; approved setup install uses --ignore-scripts, so this lifecycle script is not run by default"
        }
      end
    end

    def setup_command_uses_ignore_scripts?(command_argv)
      Array(command_argv).any? { |arg| arg.to_s == "--ignore-scripts" || arg.to_s == "--ignore-scripts=true" }
    end

    def setup_lifecycle_sandbox_blockers(command_argv, lifecycle_scripts, lifecycle_enabled_requested: false)
      scripts = Array(lifecycle_scripts)
      if lifecycle_enabled_requested && !scripts.empty?
        return ["setup lifecycle-enabled install requested but blocked until container/VM isolation and OS/container egress firewall evidence exists"]
      end
      return [] if scripts.empty? || setup_command_uses_ignore_scripts?(command_argv)

      ["package.json lifecycle scripts require --ignore-scripts unless lifecycle-enabled install sandbox and egress-firewall evidence is present"]
    end

    def setup_lifecycle_sandbox_gate(command_argv:, package_cache_dir:, lifecycle_scripts:, install_status:, execution_evidence_status:, lifecycle_enabled_requested: false)
      lifecycle_present = !Array(lifecycle_scripts).empty?
      lifecycle_enabled_status = lifecycle_present ? "blocked_until_sandbox_and_egress_firewall" : "not_required"
      lifecycle_enabled_block_reason =
        if lifecycle_enabled_requested && lifecycle_present
          "lifecycle-enabled install was explicitly requested but is fail-closed until container/VM filesystem isolation and OS/container egress firewall evidence exist"
        elsif lifecycle_present
          "lifecycle scripts are present; default install disables them and lifecycle-enabled install remains unavailable until sandbox and egress evidence exist"
        end
      {
        "schema_version" => 1,
        "policy" => "aiweb.setup.lifecycle_sandbox_gate.v1",
        "status" => lifecycle_enabled_status,
        "install_status" => install_status,
        "lifecycle_scripts_present" => lifecycle_present,
        "lifecycle_scripts" => Array(lifecycle_scripts),
        "lifecycle_enabled_requested" => lifecycle_enabled_requested,
        "lifecycle_enabled_execution_available" => false,
        "default_install_lifecycle_execution" => false,
        "default_command_uses_ignore_scripts" => setup_command_uses_ignore_scripts?(command_argv),
        "default_install_command" => redact_side_effect_command(command_argv),
        "lifecycle_enabled_install_status" => lifecycle_enabled_status,
        "lifecycle_enabled_block_reason" => lifecycle_enabled_block_reason,
        "requested_command_policy" => "fail_closed_until_lifecycle_sandbox_driver_and_egress_firewall_exist",
        "execution_evidence_status" => execution_evidence_status,
        "egress_firewall" => {
          "default_install_network_policy" => "registry_allowlist_metadata_gate",
          "lifecycle_enabled_network_policy" => "blocked_until_network_none_or_recorded_egress_firewall",
          "external_network_allowed" => false,
          "registry_allowlist" => [setup_supply_chain_registry_host],
          "network_refs_static_allowlist_enforced" => true,
          "default_install_os_egress_firewall_status" => "not_installed",
          "default_install_egress_probe_status" => "not_run_for_host_package_manager",
          "lifecycle_enabled_egress_firewall_required" => true
        },
        "default_install_sandbox_attestation" => {
          "status" => setup_command_uses_ignore_scripts?(command_argv) ? "passed" : "blocked",
          "mode" => "host_package_manager_with_lifecycle_scripts_disabled",
          "filesystem_isolation" => "not_claimed_for_default_install",
          "working_directory" => ".",
          "lifecycle_scripts_executed" => false,
          "dot_env_access_by_lifecycle_scripts" => false,
          "package_manager_process_uses_unsetenv_others" => true,
          "child_env_policy" => setup_child_env_policy,
          "limitations" => [
            "default setup install still runs the package manager in the project root",
            "lifecycle scripts are disabled with --ignore-scripts, so lifecycle script filesystem/network access is not exercised",
            "this is environment and static allowlist evidence, not an OS/container egress firewall"
          ]
        },
        "required_sandbox_evidence" => {
          "container_or_vm_isolation" => "required_for_lifecycle_enabled_install",
          "network_mode" => "none_or_explicit_registry_allowlist_with_egress_audit",
          "egress_firewall_default_deny" => true,
          "environment_allowlist_only" => true,
          "secret_environment_stripped" => true,
          "dot_env_reads_allowed" => false,
          "workspace_escape_allowed" => false,
          "isolated_cache_dir" => relative(package_cache_dir),
          "required_artifacts" => %w[lifecycle-sandbox-attestation.json egress-firewall-log.json package-file-diff sbom package-audit]
        },
        "limitations" => [
          "default setup install intentionally does not run lifecycle scripts",
          "aiweb setup records lifecycle-enabled requirements but does not install an OS/container egress firewall",
          "lifecycle-enabled install remains unavailable until sandbox and egress evidence is implemented"
        ]
      }
    end

    def setup_supply_chain_registry_url
      "https://registry.npmjs.org/"
    end

    def setup_supply_chain_registry_host
      "registry.npmjs.org"
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
      %w[
        PATH
        PATHEXT
        SYSTEMROOT
        SystemRoot
        WINDIR
        COMSPEC
        HOME
        USERPROFILE
        TMP
        TEMP
      ].each_with_object({}) do |key, env|
        env[key] = ENV[key] if ENV[key]
      end.merge("AIWEB_SETUP_APPROVED" => "1")
    end

    def setup_child_env_policy
      child_env = setup_child_env
      secret_keys = %w[
        SECRET
        NPM_TOKEN
        NODE_AUTH_TOKEN
        YARN_NPM_AUTH_TOKEN
        PNPM_HOME_TOKEN
        OPENAI_API_KEY
        ANTHROPIC_API_KEY
        AWS_SECRET_ACCESS_KEY
        GOOGLE_APPLICATION_CREDENTIALS
      ]
      {
        "unsetenv_others" => true,
        "allowed_env_keys" => child_env.keys.sort,
        "secret_parent_env_keys_stripped" => secret_keys.select { |key| ENV.key?(key) },
        "secret_values_recorded" => false,
        "aiweb_setup_approved" => child_env["AIWEB_SETUP_APPROVED"] == "1"
      }
    end

    def redact_setup_output(output)
      output.to_s
        .gsub(/(SECRET|TOKEN|PASSWORD|PASSWD|PRIVATE|CREDENTIAL|API[_-]?KEY)([A-Z0-9_ -]*)(=|:)[^\s]+/i, '\1\2\3[REDACTED]')
        .gsub(/(sk|pk|sb_secret)_[A-Za-z0-9_-]{12,}/, '[REDACTED]')
        .gsub(/eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/, '[REDACTED]')
    end

  end
end
