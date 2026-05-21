# frozen_string_literal: true

require "digest"
require "json"
require "shellwords"

module Aiweb
  module ProjectRuntimeCommands
    def setup_install_approval_capability(package_manager:, lifecycle_scripts:, lifecycle_enabled_requested:, audit_exception_path:, audit_exception:)
      {
        "schema_version" => 1,
        "capability" => "aiweb.setup.install.v1",
        "constitution_hash" => Aiweb::Constitution::Loader.new.content_hash,
        "policy_kernel_version" => Aiweb::Tools::DecisionPacket::POLICY_KERNEL_VERSION,
        "risk_class" => "setup_package_install",
        "tool_name" => "setup.install",
        "package_manager" => package_manager,
        "command_argv" => setup_install_argv(package_manager, cache_dir: SETUP_INSTALL_APPROVAL_CACHE_DIR),
        "cwd" => ".",
        "registry" => {
          "url" => setup_supply_chain_registry_url,
          "host" => setup_supply_chain_registry_host
        },
        "package_cache_dir_template" => SETUP_INSTALL_APPROVAL_CACHE_DIR,
        "tracked_file_snapshot" => setup_supply_chain_file_snapshot,
        "dependency_semantics" => setup_supply_chain_dependency_snapshot,
        "lockfile_semantics" => setup_supply_chain_lockfile_snapshot,
        "lifecycle_scripts" => Array(lifecycle_scripts),
        "lifecycle_enabled_requested" => lifecycle_enabled_requested,
        "lifecycle_policy" => "default install requires --ignore-scripts; lifecycle-enabled install is fail-closed until sandbox and egress evidence exists",
        "audit_exception" => setup_audit_exception_approval_snapshot(audit_exception_path, audit_exception),
        "child_env_policy" => setup_child_env_policy,
        "network_policy" => {
          "external_network_allowed" => false,
          "registry_allowlist" => [setup_supply_chain_registry_host],
          "network_refs_static_allowlist_enforced" => true
        },
        "side_effect_boundary" => {
          "requires_dry_run_review" => true,
          "requires_matching_approval_hash" => true,
          "writes_under" => %w[.ai-web/runs node_modules package-locks],
          "forbidden" => %w[build preview qa deploy provider_cli env_read git_push lifecycle_scripts_by_default]
        }
      }
    end

    def setup_audit_exception_approval_snapshot(audit_exception_path, audit_exception)
      raw_path = audit_exception_path.to_s.strip
      base = {
        "status" => audit_exception["status"],
        "path" => audit_exception["path"],
        "blocking_issues" => Array(audit_exception["blocking_issues"])
      }
      return base if raw_path.empty? || audit_exception["path"].to_s.empty?

      path_info = setup_audit_exception_path_info(raw_path)
      return base.merge("path_status" => path_info["status"], "blocking_issues" => (base["blocking_issues"] + Array(path_info["blocking_issues"])).uniq) unless path_info["status"] == "provided"

      if File.file?(path_info.fetch("full_path"))
        raw = File.read(path_info.fetch("full_path"))
        base.merge(
          "path_status" => "provided",
          "file_present" => true,
          "bytes" => raw.bytesize,
          "sha256" => Digest::SHA256.hexdigest(raw),
          "secret_scan_status" => redact_side_effect_process_output(raw) == raw ? "passed" : "blocked"
        )
      else
        base.merge("path_status" => "provided", "file_present" => false)
      end
    rescue SystemCallError => e
      base.merge("path_status" => "unreadable", "blocking_issues" => (base["blocking_issues"] + ["setup audit exception could not be fingerprinted: #{e.message}"]).uniq)
    end

    def setup_install_approval_hash(capability)
      Digest::SHA256.hexdigest(JSON.generate(capability))
    end

    def setup_install_approval_blockers(approved:, supplied_hash:, expected_hash:)
      return ["--approved and --approval-hash HASH are required for real package install"] unless approved
      return ["--approval-hash is required for real setup install"] if supplied_hash.to_s.empty?
      return ["setup approval hash does not match the current install capability envelope"] unless supplied_hash == expected_hash

      []
    end

    def setup_install_approved_command(approval_hash, audit_exception:, lifecycle_enabled_requested:)
      parts = ["aiweb", "setup", "--install", "--approval-hash", approval_hash.to_s, "--approved"]
      parts << "--allow-lifecycle-scripts" if lifecycle_enabled_requested
      parts.concat(["--audit-exception", audit_exception["path"].to_s]) if audit_exception.is_a?(Hash) && !audit_exception["path"].to_s.empty?
      Shellwords.join(parts)
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
  end
end
