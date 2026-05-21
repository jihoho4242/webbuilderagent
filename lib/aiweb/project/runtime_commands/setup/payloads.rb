# frozen_string_literal: true

module Aiweb
  module ProjectRuntimeCommands
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

    def setup_run_metadata(run_id:, status:, command:, package_manager:, started_at:, finished_at:, exit_code:, stdout_log:, stderr_log:, metadata_path:, lifecycle_script_warnings:, lifecycle_enabled_requested: false, node_modules_present:, blocking_issues:, dry_run:, approved:, requires_approval:, approval_hash: nil, supplied_approval_hash: nil, capability: nil, side_effect_broker_path: nil, side_effect_broker: nil, side_effect_broker_events: [], supply_chain_gate_path: nil, supply_chain_gate: nil, sbom_path: nil, cyclonedx_sbom_path: nil, spdx_sbom_path: nil, package_audit_path: nil, audit_exception: nil)
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
        "approval_hash" => approval_hash,
        "supplied_approval_hash" => supplied_approval_hash,
        "capability" => capability,
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

    def setup_next_action(status, approval_hash:, audit_exception:, lifecycle_enabled_requested:)
      case status
      when "passed" then "continue to build/preview/QA only through separately approved roadmap commands"
      when "blocked" then "resolve the blocked local setup precondition, then rerun aiweb setup --install --dry-run for a fresh approval_hash"
      else "inspect .ai-web/runs setup logs, fix the package install issue, then rerun aiweb setup --install --dry-run for a fresh approval_hash"
      end
    end
  end
end
