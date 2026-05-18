# frozen_string_literal: true

module Aiweb
  module ProjectRuntimeCommands
    private

    def setup_supply_chain_plan(package_manager:, command_argv:, package_cache_dir:, supply_chain_gate_path:, sbom_path:, cyclonedx_sbom_path:, spdx_sbom_path:, package_audit_path:, audit_exception:, status:, blocking_issues:, lifecycle_scripts:, lifecycle_enabled_requested: false)
      {
        "schema_version" => 1,
        "status" => status,
        "recorded_at" => now,
        "package_manager" => package_manager,
        "exact_command" => redact_side_effect_command(command_argv),
        "clean_cache_install" => {
          "status" => status == "planned" ? "planned" : status,
          "isolated_cache_dir" => relative(package_cache_dir),
          "registry_allowlist" => [setup_supply_chain_registry_url],
          "network_allowlist" => [setup_supply_chain_registry_host],
          "network_policy" => "package.json direct network specs and pnpm-lock.yaml network refs must resolve only to the approved registry host",
          "command_policy" => "exact command must include --ignore-scripts, approved registry, and run-local --store-dir",
          "lifecycle_script_policy" => "disabled_by_default_with_ignore_scripts",
          "default_install_lifecycle_execution" => false,
          "default_command_uses_ignore_scripts" => setup_command_uses_ignore_scripts?(command_argv)
        },
        "dependency_diff" => {
          "status" => status == "planned" ? "planned" : status,
          "tracked_files" => setup_supply_chain_tracked_files,
          "semantic_sections" => setup_supply_chain_dependency_sections,
          "required_outputs" => %w[package_file_diff semantic_dependency_diff lockfile_diff lockfile_semantic_diff network_allowlist_enforcement added_packages removed_packages version_changes]
        },
        "sbom" => {
          "status" => status == "planned" ? "planned" : status,
          "artifact_path" => relative(sbom_path),
          "standard_artifact_path" => relative(cyclonedx_sbom_path),
          "spdx_artifact_path" => relative(spdx_sbom_path),
          "accepted_formats" => ["CycloneDX 1.5 JSON", "SPDX 2.3 JSON"],
          "command" => setup_supply_chain_sbom_argv(package_manager)
        },
        "audit" => {
          "status" => status == "planned" ? "planned" : status,
          "artifact_path" => relative(package_audit_path),
          "command" => setup_supply_chain_audit_argv(package_manager)
        },
        "vulnerability_copy_back_gate" => {
          "status" => status == "blocked" ? "blocked" : "planned",
          "blocked_severities" => %w[critical high],
          "audit_exception" => audit_exception
        },
        "network_allowlist_enforcement" => setup_supply_chain_network_allowlist_evidence(
          dependency_snapshot: nil,
          dependency_semantic_before: setup_supply_chain_dependency_snapshot,
          dependency_semantic_after: nil,
          lockfile_semantic_before: setup_supply_chain_lockfile_snapshot,
          lockfile_semantic_after: nil
        ),
        "lifecycle_sandbox_gate" => setup_lifecycle_sandbox_gate(
          command_argv: command_argv,
          package_cache_dir: package_cache_dir,
          lifecycle_scripts: lifecycle_scripts,
          install_status: status,
          execution_evidence_status: status == "planned" ? "planned" : "not_executed",
          lifecycle_enabled_requested: lifecycle_enabled_requested
        ),
        "evidence_refs" => {
          "supply_chain_gate_path" => relative(supply_chain_gate_path),
          "sbom_path" => relative(sbom_path),
          "cyclonedx_sbom_path" => relative(cyclonedx_sbom_path),
          "spdx_sbom_path" => relative(spdx_sbom_path),
          "package_audit_path" => relative(package_audit_path)
        },
        "blocking_issues" => blocking_issues
      }
    end

    def setup_supply_chain_gate(package_manager:, command_argv:, package_cache_dir:, supply_chain_gate_path:, sbom_path:, cyclonedx_sbom_path:, spdx_sbom_path:, package_audit_path:, audit_exception:, install_status:, install_exit_code:, dependency_snapshot_before:, dependency_snapshot_after:, dependency_semantic_before:, dependency_semantic_after:, lockfile_semantic_before:, lockfile_semantic_after:, sbom_artifact:, cyclonedx_sbom_artifact:, spdx_sbom_artifact:, audit_artifact:, blocking_issues:, lifecycle_scripts:, lifecycle_enabled_requested: false)
      file_diff = setup_supply_chain_file_diff(dependency_snapshot_before, dependency_snapshot_after)
      semantic_diff = setup_supply_chain_dependency_semantic_diff(dependency_semantic_before, dependency_semantic_after)
      lockfile_semantic_diff = setup_supply_chain_lockfile_semantic_diff(lockfile_semantic_before, lockfile_semantic_after)
      lockfile_diff = file_diff.select { |entry| entry.fetch("path", "").end_with?("-lock.yaml", "-lock.json", ".lock", "lockfile") || setup_supply_chain_lockfile_paths.include?(entry.fetch("path", "")) }
      cyclonedx_status = setup_supply_chain_cyclonedx_status(cyclonedx_sbom_artifact)
      spdx_status = setup_supply_chain_spdx_status(spdx_sbom_artifact)
      {
        "schema_version" => 1,
        "status" => blocking_issues.empty? && install_status == "passed" ? "passed" : "blocked",
        "recorded_at" => now,
        "package_manager" => package_manager,
        "exact_command" => redact_side_effect_command(command_argv),
        "install_status" => install_status,
        "install_exit_code" => install_exit_code,
        "clean_cache_install" => {
          "status" => install_status == "passed" ? "executed" : install_status,
          "isolated_cache_dir" => relative(package_cache_dir),
          "cache_dir_present" => File.directory?(package_cache_dir),
          "registry_allowlist" => [setup_supply_chain_registry_url],
          "network_allowlist" => [setup_supply_chain_registry_host],
          "network_policy" => "package.json direct network specs and pnpm-lock.yaml network refs must resolve only to the approved registry host",
          "command_policy" => "exact pnpm install command includes --ignore-scripts, approved registry, and run-local --store-dir",
          "lifecycle_script_policy" => "disabled_by_default_with_ignore_scripts; future lifecycle-enabled installs require sandboxed elevated approval",
          "default_install_lifecycle_execution" => false,
          "default_command_uses_ignore_scripts" => setup_command_uses_ignore_scripts?(command_argv)
        },
        "dependency_diff" => {
          "status" => file_diff.empty? && semantic_diff["status"] == "unchanged" && lockfile_semantic_diff["status"] == "unchanged" ? "unchanged" : "changed",
          "before" => dependency_snapshot_before,
          "after" => dependency_snapshot_after,
          "semantic_before" => dependency_semantic_before,
          "semantic_after" => dependency_semantic_after,
          "semantic_dependency_diff" => semantic_diff,
          "lockfile_semantic_before" => lockfile_semantic_before,
          "lockfile_semantic_after" => lockfile_semantic_after,
          "lockfile_semantic_diff" => lockfile_semantic_diff,
          "lockfile_diff" => lockfile_diff,
          "package_file_diff" => file_diff,
          "required_outputs" => %w[package_file_diff semantic_dependency_diff lockfile_diff lockfile_semantic_diff network_allowlist_enforcement added_packages removed_packages version_changes]
        },
        "sbom" => {
          "status" => sbom_artifact["status"],
          "artifact_path" => relative(sbom_path),
          "standard_status" => cyclonedx_status,
          "standard_format" => "CycloneDX 1.5 JSON",
          "standard_artifact_path" => relative(cyclonedx_sbom_path),
          "spdx_status" => spdx_status,
          "spdx_format" => "SPDX 2.3 JSON",
          "spdx_artifact_path" => relative(spdx_sbom_path),
          "component_count" => sbom_artifact["component_count"].to_i,
          "command" => sbom_artifact["command"]
        },
        "audit" => {
          "status" => audit_artifact["status"],
          "artifact_path" => relative(package_audit_path),
          "severity_counts" => audit_artifact["severity_counts"] || {},
          "active_findings" => audit_artifact["active_findings"] || [],
          "audit_artifact_sha256" => audit_artifact["audit_artifact_sha256"],
          "audit_exception" => audit_exception,
          "command" => audit_artifact["command"]
        },
        "vulnerability_copy_back_gate" => {
          "status" => audit_exception["status"] == "accepted" ? "accepted_risk" : (audit_artifact["vulnerability_gate"] || "not_executed"),
          "blocked_severities" => %w[critical high],
          "policy" => "block setup completion on critical/high vulnerabilities unless an approved, unexpired audit exception with rollback plan is supplied",
          "audit_exception" => audit_exception
        },
        "network_allowlist_enforcement" => setup_supply_chain_network_allowlist_evidence(
          dependency_snapshot: dependency_snapshot_after,
          dependency_semantic_before: dependency_semantic_before,
          dependency_semantic_after: dependency_semantic_after,
          lockfile_semantic_before: lockfile_semantic_before,
          lockfile_semantic_after: lockfile_semantic_after
        ),
        "lifecycle_sandbox_gate" => setup_lifecycle_sandbox_gate(
          command_argv: command_argv,
          package_cache_dir: package_cache_dir,
          lifecycle_scripts: lifecycle_scripts,
          install_status: install_status,
          execution_evidence_status: blocking_issues.empty? && install_status == "passed" ? "default_install_executed_without_lifecycle_scripts" : "blocked",
          lifecycle_enabled_requested: lifecycle_enabled_requested
        ),
        "execution_evidence" => {
          "status" => blocking_issues.empty? && install_status == "passed" ? "executed" : "blocked",
          "artifacts" => [relative(sbom_path), relative(cyclonedx_sbom_path), relative(spdx_sbom_path), relative(package_audit_path)]
        },
        "evidence_refs" => {
          "supply_chain_gate_path" => relative(supply_chain_gate_path),
          "sbom_path" => relative(sbom_path),
          "cyclonedx_sbom_path" => relative(cyclonedx_sbom_path),
          "spdx_sbom_path" => relative(spdx_sbom_path),
          "package_audit_path" => relative(package_audit_path)
        },
        "blocking_issues" => blocking_issues
      }
    end
  end
end
