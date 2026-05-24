# frozen_string_literal: true

require "fileutils"

module Aiweb
  module ProjectRuntimeCommands
    private

    def setup_install_execute(state:, run_id:, command:, package_manager:, setup_paths:, command_argv:, lifecycle_warnings:, lifecycle_scripts:, allow_lifecycle_scripts:, audit_exception_path:, audit_exception_plan:, expected_hash:, supplied_hash:, capability:, side_effect_broker_plan:)
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
        side_effect_context = setup_side_effect_broker_context(command_argv: command_argv, approved: true).merge("approval_hash" => expected_hash)
        append_side_effect_broker_event(
          side_effect_broker_path,
          side_effect_broker_events,
          "tool.requested",
          side_effect_context.merge("requested_at" => started_at, "dry_run" => false)
        )

        if executable_path("pnpm").nil?
          blocking_issues << "pnpm executable is missing; install pnpm locally, then rerun aiweb setup --install --dry-run for a fresh approval_hash."
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
            side_effect_context.merge("decision" => "allow", "reason" => "explicit hash-bound --approval-hash plus --approved setup install")
          )
          append_side_effect_broker_event(
            side_effect_broker_path,
            side_effect_broker_events,
            "tool.started",
            side_effect_context.merge("started_at" => started_at)
          )
          install_result = runtime_process_runner.capture(
            Aiweb::Runtime::CommandSpec.new(
              argv: command_argv,
              cwd: root,
              env: setup_child_env,
              timeout: 900,
              max_output_bytes: 200_000,
              risk_class: "setup_package_install",
              description: "approved setup package install"
            )
          )
          install_success = install_result.success?
          exit_code = install_result.exit_code
          status = install_success ? "passed" : "failed"
          install_status = status
          append_side_effect_broker_event(
            side_effect_broker_path,
            side_effect_broker_events,
            "tool.finished",
            side_effect_context.merge("finished_at" => now, "status" => status, "exit_code" => exit_code)
          )
          stdout = redact_side_effect_process_output(redact_setup_output(install_result.stdout))
          stderr = redact_side_effect_process_output(redact_setup_output(install_result.stderr))
          blocking_issues << "#{command} failed with exit code #{exit_code || install_result.status}" unless install_success
          if install_success
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
                status = install_success ? "passed" : status
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
          approval_hash: expected_hash,
          supplied_approval_hash: supplied_hash.empty? ? nil : supplied_hash,
          capability: capability,
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
          next_action: setup_next_action(status, approval_hash: expected_hash, audit_exception: audit_exception_plan, lifecycle_enabled_requested: allow_lifecycle_scripts)
        )
      end
    end
  end
end
