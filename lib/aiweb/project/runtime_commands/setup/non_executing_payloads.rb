# frozen_string_literal: true

module Aiweb
  module ProjectRuntimeCommands
    private

    def setup_install_approval_blocked_payload(state:, run_id:, command:, package_manager:, setup_paths:, lifecycle_warnings:, allow_lifecycle_scripts:, approval_blockers:, approved:, expected_hash:, supplied_hash:, capability:, side_effect_broker_plan:, supply_chain_plan:, audit_exception_plan:)
      setup_payload(
        state: state,
        metadata: setup_non_executing_metadata(
          run_id: run_id,
          status: "blocked",
          command: command,
          package_manager: package_manager,
          setup_paths: setup_paths,
          lifecycle_warnings: lifecycle_warnings,
          allow_lifecycle_scripts: allow_lifecycle_scripts,
          blocking_issues: approval_blockers,
          dry_run: false,
          approved: approved,
          expected_hash: expected_hash,
          supplied_hash: supplied_hash,
          capability: capability,
          requires_approval: true,
          side_effect_broker: side_effect_broker_plan.merge(
            "status" => "blocked",
            "policy" => side_effect_broker_plan.fetch("policy").merge(
              "decision" => "deny",
              "blocking_issues" => approval_blockers
            )
          ),
          supply_chain_gate: supply_chain_plan,
          audit_exception: audit_exception_plan
        ),
        changed_files: [],
        action_taken: "setup install blocked",
        blocking_issues: approval_blockers,
        next_action: "rerun aiweb setup --install --dry-run and review approval_hash #{expected_hash}; real install remains a lower-level ops action"
      )
    end

    def setup_install_dry_run_payload(state:, run_id:, command:, package_manager:, setup_paths:, lifecycle_warnings:, allow_lifecycle_scripts:, approved:, expected_hash:, supplied_hash:, capability:, side_effect_broker_plan:, supply_chain_plan:, audit_exception_plan:, planned_changes:)
      setup_payload(
        state: state,
        metadata: setup_non_executing_metadata(
          run_id: run_id,
          status: "dry_run",
          command: command,
          package_manager: package_manager,
          setup_paths: setup_paths,
          lifecycle_warnings: lifecycle_warnings,
          allow_lifecycle_scripts: allow_lifecycle_scripts,
          blocking_issues: [],
          dry_run: true,
          approved: approved,
          expected_hash: expected_hash,
          supplied_hash: supplied_hash,
          capability: capability,
          requires_approval: false,
          side_effect_broker: side_effect_broker_plan,
          supply_chain_gate: supply_chain_plan,
          audit_exception: audit_exception_plan
        ),
        changed_files: planned_changes,
        action_taken: "planned setup install",
        blocking_issues: [],
        next_action: "review setup approval_hash #{expected_hash}; executing #{command.inspect} is a lower-level ops action, not a friendly web-building runbook"
      )
    end

    def setup_non_executing_metadata(run_id:, status:, command:, package_manager:, setup_paths:, lifecycle_warnings:, allow_lifecycle_scripts:, blocking_issues:, dry_run:, approved:, expected_hash:, supplied_hash:, capability:, requires_approval:, side_effect_broker:, supply_chain_gate:, audit_exception:)
      setup_run_metadata(
        run_id: run_id,
        status: status,
        command: command,
        package_manager: package_manager,
        started_at: nil,
        finished_at: nil,
        exit_code: nil,
        stdout_log: relative(setup_paths.fetch(:stdout_path)),
        stderr_log: relative(setup_paths.fetch(:stderr_path)),
        metadata_path: relative(setup_paths.fetch(:metadata_path)),
        lifecycle_script_warnings: lifecycle_warnings,
        lifecycle_enabled_requested: allow_lifecycle_scripts,
        node_modules_present: File.directory?(File.join(root, "node_modules")),
        blocking_issues: blocking_issues,
        dry_run: dry_run,
        approved: approved,
        approval_hash: expected_hash,
        supplied_approval_hash: supplied_hash.empty? ? nil : supplied_hash,
        capability: capability,
        requires_approval: requires_approval,
        side_effect_broker_path: relative(setup_paths.fetch(:side_effect_broker_path)),
        side_effect_broker: side_effect_broker,
        side_effect_broker_events: [],
        supply_chain_gate_path: relative(setup_paths.fetch(:supply_chain_gate_path)),
        supply_chain_gate: supply_chain_gate,
        sbom_path: relative(setup_paths.fetch(:sbom_path)),
        cyclonedx_sbom_path: relative(setup_paths.fetch(:cyclonedx_sbom_path)),
        spdx_sbom_path: relative(setup_paths.fetch(:spdx_sbom_path)),
        package_audit_path: relative(setup_paths.fetch(:package_audit_path)),
        audit_exception: audit_exception
      )
    end
  end
end
