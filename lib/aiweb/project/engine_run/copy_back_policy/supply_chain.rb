# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

    def engine_run_supply_chain_gate(policy:, workspace_dir:, manifest:, paths:)
      package_actions = Array(policy["requested_actions"]).select { |action| action.is_a?(Hash) && action["type"].to_s == "package_install" }
      package_requests = Array(policy["approval_requests"]).select { |request| request.is_a?(Hash) && request["type"].to_s == "package_install" }
      package_manager = engine_run_supply_chain_package_manager(workspace_dir, package_actions)
      dependency_snapshot = engine_run_dependency_snapshot(workspace_dir)
      lifecycle_scripts = engine_run_package_lifecycle_scripts(workspace_dir)
      package_file_diff = engine_run_package_file_diff(manifest, workspace_dir)
      required = !package_actions.empty? || !package_requests.empty?
      status = if required
                 "waiting_approval"
               elsif package_file_diff.any? { |entry| entry["changed"] }
                 "blocked"
               else
                 "skipped"
               end
      blockers = []
      blockers << "package manifest or lockfile changed without a supply-chain approval request" if status == "blocked"
      {
        "schema_version" => 1,
        "status" => status,
        "recorded_at" => now,
        "required" => required,
        "package_manager" => package_manager,
        "package_install_requests" => {
          "count" => package_requests.length,
          "items" => package_requests
        },
        "requested_actions" => package_actions,
        "clean_cache_install" => {
          "required" => required,
          "status" => required ? "pending_approval" : "skipped",
          "isolated_cache_dir" => "_aiweb/package-cache",
          "network_policy" => "registry_allowlist_required",
          "lifecycle_script_policy" => "disabled_by_default_until_explicitly_approved",
          "command_policy" => "exact package manager command required; install must run inside staged workspace with clean cache and no host package cache mount",
          "default_install_lifecycle_execution" => false,
          "default_command_uses_ignore_scripts" => false
        },
        "dependency_diff" => {
          "status" => required ? "pending_approval" : (package_file_diff.any? { |entry| entry["changed"] } ? "blocked" : "skipped"),
          "baseline" => dependency_snapshot.fetch("dependencies"),
          "package_file_diff" => package_file_diff,
          "required_outputs" => %w[package_json_diff lockfile_diff added_packages removed_packages version_changes]
        },
        "sbom" => {
          "status" => required ? "not_executed_pending_approval" : "skipped",
          "required" => required,
          "accepted_formats" => %w[cyclonedx spdx npm-sbom-json],
          "artifact_path" => relative(paths.fetch(:supply_chain_sbom_path))
        },
        "audit" => {
          "status" => required ? "not_executed_pending_approval" : "skipped",
          "required" => required,
          "commands" => engine_run_supply_chain_audit_commands(package_manager),
          "artifact_path" => relative(paths.fetch(:supply_chain_audit_path))
        },
        "vulnerability_copy_back_gate" => {
          "status" => required ? "pending_approval" : "skipped",
          "policy" => "block copy-back on critical or high vulnerabilities unless the approval explicitly documents an exception and rollback plan",
          "blocked_severities" => %w[critical high]
        },
        "lifecycle_sandbox_gate" => engine_run_lifecycle_sandbox_gate(
          required: required,
          package_manager: package_manager,
          lifecycle_scripts: lifecycle_scripts
        ),
        "execution_evidence" => {
          "status" => required ? "not_executed_pending_approval" : "skipped",
          "artifacts" => required ? [relative(paths.fetch(:supply_chain_sbom_path)), relative(paths.fetch(:supply_chain_audit_path))] : [],
          "reason" => required ? "package install, SBOM, and audit execution require explicit elevated approval and are not executed in the default sandbox profile" : "no package install request or package manifest mutation"
        },
        "evidence_refs" => {
          "supply_chain_gate_path" => relative(paths.fetch(:supply_chain_gate_path)),
          "staged_manifest_path" => relative(paths.fetch(:manifest_path)),
          "approval_path" => relative(paths.fetch(:approval_path))
        },
        "blocking_issues" => blockers
      }
    end

    def engine_run_package_lifecycle_scripts(workspace_dir)
      package_path = File.join(workspace_dir, "package.json")
      return [] unless File.file?(package_path)

      package = JSON.parse(File.read(package_path, 256 * 1024))
      scripts = package["scripts"].is_a?(Hash) ? package["scripts"] : {}
      %w[preinstall install postinstall prepare].filter_map do |name|
        command = scripts[name].to_s.strip
        next if command.empty?

        {
          "script" => name,
          "command" => redact_side_effect_process_output(command),
          "command_sha256" => Digest::SHA256.hexdigest(command)
        }
      end
    rescue JSON::ParserError, SystemCallError
      []
    end

    def engine_run_lifecycle_sandbox_gate(required:, package_manager:, lifecycle_scripts:)
      lifecycle_present = !Array(lifecycle_scripts).empty?
      lifecycle_enabled_status = lifecycle_present || required ? "blocked_until_sandbox_and_egress_firewall" : "not_required"
      {
        "schema_version" => 1,
        "policy" => "aiweb.engine_run.lifecycle_sandbox_gate.v1",
        "status" => lifecycle_enabled_status,
        "package_manager" => package_manager,
        "lifecycle_scripts_present" => lifecycle_present,
        "lifecycle_scripts" => Array(lifecycle_scripts),
        "default_install_lifecycle_execution" => false,
        "default_command_uses_ignore_scripts" => false,
        "lifecycle_enabled_install_status" => lifecycle_enabled_status,
        "egress_firewall" => {
          "default_sandbox_network" => "none",
          "lifecycle_enabled_network_policy" => "blocked_until_network_none_or_recorded_egress_firewall",
          "external_network_allowed" => false
        },
        "required_sandbox_evidence" => {
          "container_or_vm_isolation" => "required_for_lifecycle_enabled_install",
          "network_mode" => "none_or_explicit_registry_allowlist_with_egress_audit",
          "egress_firewall_default_deny" => true,
          "environment_allowlist_only" => true,
          "secret_environment_stripped" => true,
          "dot_env_reads_allowed" => false,
          "workspace_escape_allowed" => false,
          "required_artifacts" => %w[lifecycle-sandbox-attestation.json egress-firewall-log.json package-file-diff sbom package-audit]
        },
        "limitations" => [
          "engine-run default sandbox does not execute package installs",
          "lifecycle-enabled package install remains blocked until sandbox and egress evidence exists"
        ]
      }
    end

    def engine_run_supply_chain_pending_artifacts(gate, paths)
      return {} unless gate.to_h["required"]

      request_ids = Array(gate.dig("package_install_requests", "items")).filter_map { |request| request["id"] if request.is_a?(Hash) }
      {
        paths.fetch(:supply_chain_sbom_path) => {
          "schema_version" => 1,
          "artifact_kind" => "sbom",
          "status" => "not_executed_pending_approval",
          "recorded_at" => now,
          "package_manager" => gate["package_manager"],
          "accepted_formats" => gate.dig("sbom", "accepted_formats"),
          "approval_request_ids" => request_ids,
          "execution_boundary" => "blocked_until_elevated_supply_chain_approval",
          "reason" => "SBOM generation must run only after explicit package-install approval in an isolated staged cache"
        },
        paths.fetch(:supply_chain_audit_path) => {
          "schema_version" => 1,
          "artifact_kind" => "package_audit",
          "status" => "not_executed_pending_approval",
          "recorded_at" => now,
          "package_manager" => gate["package_manager"],
          "commands" => gate.dig("audit", "commands"),
          "approval_request_ids" => request_ids,
          "execution_boundary" => "blocked_until_elevated_supply_chain_approval",
          "blocked_severities" => gate.dig("vulnerability_copy_back_gate", "blocked_severities"),
          "reason" => "Package audit must run only after explicit package-install approval; copy-back remains blocked for critical/high findings without an exception and rollback plan"
        }
      }
    end

    def engine_run_supply_chain_package_manager(workspace_dir, package_actions)
      action_tool = Array(package_actions).map { |action| action["tool_name"].to_s }.find { |tool| %w[npm pnpm yarn bun].include?(tool) }
      return action_tool if action_tool
      return "pnpm" if File.file?(File.join(workspace_dir, "pnpm-lock.yaml"))
      return "yarn" if File.file?(File.join(workspace_dir, "yarn.lock"))
      return "bun" if File.file?(File.join(workspace_dir, "bun.lockb"))

      "npm"
    end

    def engine_run_dependency_snapshot(workspace_dir)
      package_path = File.join(workspace_dir, "package.json")
      package = File.file?(package_path) ? JSON.parse(File.read(package_path, 256 * 1024)) : {}
      dependencies = %w[dependencies devDependencies optionalDependencies peerDependencies].each_with_object({}) do |key, memo|
        memo[key] = package[key].is_a?(Hash) ? package[key].sort.to_h : {}
      end
      {
        "status" => File.file?(package_path) ? "captured" : "missing",
        "dependencies" => dependencies
      }
    rescue JSON::ParserError => e
      {
        "status" => "failed",
        "dependencies" => {},
        "blocking_issues" => ["package.json dependency snapshot failed: #{e.message}"]
      }
    end

    def engine_run_package_file_diff(manifest, workspace_dir)
      package_files = %w[package.json package-lock.json npm-shrinkwrap.json pnpm-lock.yaml yarn.lock bun.lockb]
      workspace_files = engine_run_workspace_files(workspace_dir)
      package_files.map do |path|
        base_hash = manifest.fetch("files", {}).dig(path, "sha256")
        current_hash = workspace_files.dig(path, "sha256")
        {
          "path" => path,
          "baseline_sha256" => base_hash,
          "current_sha256" => current_hash,
          "changed" => !base_hash.nil? && base_hash != current_hash || (base_hash.nil? && !current_hash.nil?)
        }
      end
    end

    def engine_run_supply_chain_audit_commands(package_manager)
      case package_manager.to_s
      when "pnpm"
        ["pnpm audit --json"]
      when "yarn"
        ["yarn npm audit --json"]
      when "bun"
        ["bun audit --json"]
      else
        ["npm audit --json", "npm sbom --json"]
      end
    end
  end
end
