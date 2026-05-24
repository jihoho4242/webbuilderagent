# frozen_string_literal: true

require_relative "setup/supply_chain"
require_relative "setup/approval"
require_relative "setup/environment"
require_relative "setup/non_executing_payloads"
require_relative "setup/execution"
require_relative "setup/payloads"

module Aiweb
  module ProjectRuntimeCommands
    include ProjectRuntimeSetupEnvironment
    SETUP_INSTALL_APPROVAL_CACHE_DIR = ".ai-web/runs/<setup-run>/package-cache"

    def setup(install: false, approved: false, approval_hash: nil, dry_run: false, audit_exception_path: nil, allow_lifecycle_scripts: false)
      assert_initialized!

      unless install
        return setup_blocked_payload(
          state: load_state,
          status: "unsupported",
          command: nil,
          dry_run: dry_run,
          blocking_issues: ["setup currently supports --install only"],
          next_action: "rerun aiweb setup --install --dry-run; real install is a lower-level ops action after approval_hash review"
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
      package_cache_dir = setup_paths.fetch(:package_cache_dir)
      side_effect_broker_path = setup_paths.fetch(:side_effect_broker_path)
      supply_chain_gate_path = setup_paths.fetch(:supply_chain_gate_path)
      sbom_path = setup_paths.fetch(:sbom_path)
      cyclonedx_sbom_path = setup_paths.fetch(:cyclonedx_sbom_path)
      spdx_sbom_path = setup_paths.fetch(:spdx_sbom_path)
      package_audit_path = setup_paths.fetch(:package_audit_path)
      command_argv = setup_install_argv(package_manager, cache_dir: relative(package_cache_dir))
      command = setup_install_command(package_manager, cache_dir: relative(package_cache_dir))
      planned_changes = setup_install_planned_changes(setup_paths)
      lifecycle_scripts = package_lifecycle_scripts
      lifecycle_warnings = package_lifecycle_script_warnings(lifecycle_scripts)
      audit_exception_plan = setup_audit_exception_plan(audit_exception_path)
      capability = setup_install_approval_capability(
        package_manager: package_manager,
        lifecycle_scripts: lifecycle_scripts,
        lifecycle_enabled_requested: allow_lifecycle_scripts,
        audit_exception_path: audit_exception_path,
        audit_exception: audit_exception_plan
      )
      expected_hash = setup_install_approval_hash(capability)
      supplied_hash = approval_hash.to_s.strip
      approval_blockers = setup_install_approval_blockers(
        approved: approved,
        supplied_hash: supplied_hash,
        expected_hash: expected_hash
      )
      execution_ready = !dry_run && approved && approval_blockers.empty?
      side_effect_broker_plan = setup_side_effect_broker_plan(
        command_argv: command_argv,
        broker_path: side_effect_broker_path,
        dry_run: dry_run,
        approved: execution_ready,
        blocked: !dry_run && !approval_blockers.empty?,
        blockers: dry_run ? [] : approval_blockers
      )
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
        status: execution_ready ? "ready" : (dry_run ? "planned" : "blocked"),
        blocking_issues: dry_run ? [] : approval_blockers,
        lifecycle_scripts: lifecycle_scripts,
        lifecycle_enabled_requested: allow_lifecycle_scripts
      )

      unless approval_blockers.empty? || dry_run
        return setup_install_approval_blocked_payload(
          state: state,
          run_id: run_id,
          command: command,
          package_manager: package_manager,
          setup_paths: setup_paths,
          lifecycle_warnings: lifecycle_warnings,
          allow_lifecycle_scripts: allow_lifecycle_scripts,
          approval_blockers: approval_blockers,
          approved: approved,
          expected_hash: expected_hash,
          supplied_hash: supplied_hash,
          capability: capability,
          side_effect_broker_plan: side_effect_broker_plan,
          supply_chain_plan: supply_chain_plan,
          audit_exception_plan: audit_exception_plan
        )
      end

      if dry_run
        return setup_install_dry_run_payload(
          state: state,
          run_id: run_id,
          command: command,
          package_manager: package_manager,
          setup_paths: setup_paths,
          lifecycle_warnings: lifecycle_warnings,
          allow_lifecycle_scripts: allow_lifecycle_scripts,
          approved: approved,
          expected_hash: expected_hash,
          supplied_hash: supplied_hash,
          capability: capability,
          side_effect_broker_plan: side_effect_broker_plan,
          supply_chain_plan: supply_chain_plan,
          audit_exception_plan: audit_exception_plan,
          planned_changes: planned_changes
        )
      end

      return setup_install_execute(
        state: state,
        run_id: run_id,
        command: command,
        package_manager: package_manager,
        setup_paths: setup_paths,
        command_argv: command_argv,
        lifecycle_warnings: lifecycle_warnings,
        lifecycle_scripts: lifecycle_scripts,
        allow_lifecycle_scripts: allow_lifecycle_scripts,
        audit_exception_path: audit_exception_path,
        audit_exception_plan: audit_exception_plan,
        expected_hash: expected_hash,
        supplied_hash: supplied_hash,
        capability: capability,
        side_effect_broker_plan: side_effect_broker_plan
      )
    end
  end
end
