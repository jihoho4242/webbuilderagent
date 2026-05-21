# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

    def engine_run_copy_back_policy(workspace_dir, manifest, process_output)
      base_files = manifest.fetch("files")
      workspace_files = engine_run_workspace_files(workspace_dir)
      all_paths = (base_files.keys + workspace_files.keys).uniq.sort
      safe_changes = []
      approval_changes = []
      blocked_changes = []
      blocking_issues = []
      approval_issues = []

      all_paths.each do |path|
        base_hash = base_files.dig(path, "sha256")
        current_hash = workspace_files.dig(path, "sha256")
        next if base_hash == current_hash

        classification = engine_run_classify_copy_back_change(workspace_dir, path, current_hash)
        case classification.fetch("disposition")
        when "safe"
          safe_changes << path
        when "approval"
          approval_changes << path
          approval_issues << classification.fetch("issue")
        else
          blocked_changes << path
          blocking_issues << classification.fetch("issue")
        end
      end

      requested_actions = (engine_run_requested_tool_actions(process_output) + engine_run_requested_tool_actions_from_broker_events(workspace_dir)).uniq { |action| action["type"] }
      broker_actions = requested_actions.select { |action| action["source"] == "tool_broker" }
      approval_issues << "agent output indicates package install, network, deploy, provider CLI, MCP/connectors, env read, or git push may be required" unless requested_actions.empty?
      approval_issues << "tool broker blocked prohibited staged action before execution" unless broker_actions.empty?
      approval_requests = engine_run_approval_requests(approval_issues, approval_changes, requested_actions)

      {
        "schema_version" => 1,
        "status" => if !blocking_issues.empty?
                       "blocked"
                     elsif !approval_issues.empty?
                       "waiting_approval"
                     else
                       "passed"
                     end,
        "safe_changes" => safe_changes,
        "approval_changes" => approval_changes,
        "blocked_changes" => blocked_changes,
        "blocking_issues" => blocking_issues,
        "approval_issues" => approval_issues,
        "approval_requests" => approval_requests,
        "requested_actions" => requested_actions,
        "writable_globs" => ENGINE_RUN_DEFAULT_WRITABLE_GLOBS
      }
    end

    def engine_run_approval_requests(approval_issues, approval_changes, requested_actions)
      requests = Array(requested_actions).map do |action|
        type = action.fetch("type", "elevated_action")
        {
          "schema_version" => 1,
          "id" => "approval-#{Digest::SHA256.hexdigest(json_generate(action))[0, 16]}",
          "type" => type,
          "status" => "pending",
          "why_needed" => action["reason"].to_s,
          "risk" => engine_run_approval_risk(type),
          "capability_unlocked" => engine_run_approval_capability(type),
          "approval_scope" => "single_run_single_capability",
          "affected_paths" => [],
          "requires" => engine_run_elevated_approval_requirements(type),
          "policy_note" => "Default sandbox profile stays no-network/no-install/no-provider/no-git/no-MCP until this exact request is approved."
        }
      end

      unless Array(approval_changes).empty?
        requests << {
          "schema_version" => 1,
          "id" => "approval-#{Digest::SHA256.hexdigest(Array(approval_changes).join("\n"))[0, 16]}",
          "type" => "copy_back_change",
          "status" => "pending",
          "why_needed" => Array(approval_issues).grep(/delete requires approval|high-risk changed path/i).join("; "),
          "risk" => "host_project_mutation",
          "capability_unlocked" => "copy_back_delete_or_high_risk_paths",
          "approval_scope" => "single_run_selected_paths",
          "affected_paths" => Array(approval_changes).sort,
          "requires" => %w[human_reviewed_diff exact_paths rollback_plan validation_result],
          "policy_note" => "Only the listed paths may be copied back after approval; all other host mutations remain blocked."
        }
      end

      requests
    end

    def engine_run_classify_copy_back_change(workspace_dir, path, current_hash)
      return { "disposition" => "approval", "issue" => "delete requires approval: #{path}" } if current_hash.nil?

      full = File.join(workspace_dir, path)
      return { "disposition" => "blocked", "issue" => "unsafe changed path blocked: #{path}" } if engine_run_secret_surface_path?(path) || File.symlink?(full) || path.split("/").include?("..")
      return { "disposition" => "blocked", "issue" => "binary changed file blocked: #{path}" } if engine_run_binary_file?(full)
      return { "disposition" => "blocked", "issue" => "secret-like content blocked in changed file: #{path}" } if engine_run_file_contains_secret?(full)
      return { "disposition" => "blocked", "issue" => "changed path outside engine-run writable envelope: #{path}" } unless engine_run_writable_path?(path)
      return { "disposition" => "approval", "issue" => "high-risk changed path requires approval: #{path}" } if engine_run_high_risk_path?(path)

      { "disposition" => "safe", "issue" => nil }
    end

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

    def engine_run_approval_risk(type)
      {
        "package_install" => "supply_chain_and_network",
        "external_network" => "external_data_exfiltration",
        "deploy" => "external_production_side_effect",
        "git_push" => "remote_repository_mutation",
        "mcp_connectors" => "delegated_identity_and_connector_data_access",
        "env_read" => "secret_environment_exposure",
        "copy_back_change" => "host_project_mutation"
      }.fetch(type.to_s, "elevated_side_effect")
    end

    def engine_run_approval_capability(type)
      {
        "package_install" => "approved_package_manager_install",
        "external_network" => "approved_network_destinations",
        "deploy" => "approved_provider_deploy",
        "git_push" => "approved_git_push",
        "mcp_connectors" => "approved_mcp_connector_calls",
        "env_read" => "approved_environment_read_scope",
        "copy_back_change" => "approved_copy_back_paths"
      }.fetch(type.to_s, "approved_elevated_action")
    end

    def engine_run_elevated_approval_requirements(type)
      case type.to_s
      when "package_install"
        %w[package_manager exact_command registry_allowlist network_allowlist lifecycle_script_policy lockfile_policy expected_changed_files timeout rollback_behavior dependency_diff lockfile_diff package_manager_config audit_sbom_output vulnerability_copy_back_gate]
      when "mcp_connectors"
        %w[mcp_server tool_names allowed_args_schema credential_source delegated_identity network_destinations output_redaction per_call_audit]
      when "external_network"
        %w[exact_command destination_allowlist method timeout output_redaction no_secret_upload audit_log]
      when "deploy"
        %w[provider exact_command target_environment credential_source rollback_plan production_confirmation audit_log]
      when "git_push"
        %w[remote branch commit_range protected_branch_check human_review_confirmation rollback_plan]
      when "env_read"
        %w[exact_command allowed_environment_keys redaction_policy no_secret_values audit_log]
      else
        %w[exact_command capability_scope risk_review audit_log]
      end
    end

    def engine_run_quarantine_record(run_id:, result:, policy:, sandbox_preflight:)
      reasons = []
      text = [result.fetch(:stdout).to_s, result.fetch(:stderr).to_s, Array(result.fetch(:blocking_issues)).join("\n"), Array(policy["blocking_issues"]).join("\n")].join("\n")
      reasons << "agent output contained secret-like content" if text.match?(ENGINE_RUN_SECRET_VALUE_PATTERN)
      reasons << "sandbox reported credential or secret leakage" if text.match?(/secret environment leaked|credential leaked|raw secret|raw env/i)
      reasons << "sandbox boundary or host mutation signal detected" if text.match?(/sandbox boundary|host root|root mutation|outside the workspace/i)
      reasons << "unexpected network or connector guard signal detected" if text.match?(/network guard missing|unexpected network|mcp guard missing|env guard missing/i)
      reasons.concat(Array(policy["blocking_issues"]).grep(/\.env|credential|secret|unsafe changed path/i))
      negative = sandbox_preflight.to_h.fetch("negative_checks", {})
      mounted_forbidden = negative.select { |name, value| value.to_s == "mounted" && name.to_s != "workspace" }
      reasons << "sandbox preflight observed forbidden host mount: #{mounted_forbidden.keys.sort.join(", ")}" unless mounted_forbidden.empty?
      reasons = reasons.compact.map(&:to_s).reject(&:empty?).uniq
      status = reasons.empty? ? "clear" : "quarantined"
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "recorded_at" => now,
        "reasons" => reasons,
        "blocking_issues" => reasons.map { |reason| "quarantine: #{reason}" },
        "copy_back_allowed" => reasons.empty?,
        "worker_cancel_required" => !reasons.empty?,
        "artifact_visibility" => reasons.empty? ? "normal" : "redacted_run_artifacts_plus_quarantine_summary",
        "manual_release_required" => !reasons.empty?
      }
    end

    def engine_run_requested_tool_actions(process_output)
      text = process_output.to_s
      actions = []
      actions << engine_run_tool_action("package_install", "Package installation requires explicit approval") if text.match?(/\b(?:npm|pnpm|yarn|bun)\s+(?:add|install|i|ci|update|upgrade|up)\b/i)
      actions << engine_run_tool_action("external_network", "External network access requires explicit approval") if text.match?(/\b(?:curl|wget)\s+https?:/i)
      actions << engine_run_tool_action("deploy", "Deploy/provider CLI execution requires explicit approval") if text.match?(/\b(?:vercel|netlify|cloudflare|wrangler)\b/i)
      actions << engine_run_tool_action("git_push", "git push requires explicit approval") if text.match?(/\bgit\s+push\b/i)
      actions << engine_run_tool_action("mcp_connectors", "MCP/connectors require explicit allowlist approval") if text.match?(/\b(?:mcp|connector|github\s+app|google\s+drive|gmail)\b/i)
      actions.uniq { |action| action["type"] }
    end

    def engine_run_requested_tool_actions_from_broker_events(workspace_dir)
      engine_run_workspace_tool_broker_events(workspace_dir).map do |event|
        type = event["risk_class"].to_s
        next if type.empty?

        engine_run_tool_action(type, event["reason"].to_s.empty? ? "Tool broker blocked prohibited staged action" : event["reason"].to_s).merge(
          "source" => "tool_broker",
          "tool_name" => event["tool_name"],
          "args_text" => engine_run_redact_event_text(event["args_text"].to_s)
        )
      end.compact.uniq { |action| action["type"] }
    end

    def engine_run_apply_workspace_tool_broker_events_to_policy(policy, workspace_dir)
      actions = engine_run_requested_tool_actions_from_broker_events(workspace_dir)
      return policy if actions.empty?

      policy["requested_actions"] = (Array(policy["requested_actions"]) + actions).uniq { |action| action["type"] }
      policy["approval_issues"] = Array(policy["approval_issues"])
      policy["approval_issues"] << "agent output indicates package install, network, deploy, provider CLI, MCP/connectors, env read, or git push may be required"
      policy["approval_issues"] << "tool broker blocked prohibited staged action before execution"
      policy["approval_issues"].uniq!
      policy["approval_requests"] = engine_run_approval_requests(policy["approval_issues"], Array(policy["approval_changes"]), policy["requested_actions"])
      policy["status"] = "waiting_approval" if policy["status"].to_s.empty? || %w[passed no_changes].include?(policy["status"].to_s)
      policy
    end

    def engine_run_tool_action(type, reason)
      {
        "schema_version" => 1,
        "type" => type,
        "status" => "blocked",
        "source" => "process_output",
        "reason" => reason
      }
    end

    def engine_run_workspace_files(workspace_dir)
      files = {}
      Find.find(workspace_dir) do |path|
        next if File.directory?(path)

        rel = path.sub(/^#{Regexp.escape(workspace_dir)}[\\\/]?/, "").tr("\\", "/")
        next if rel.start_with?("_aiweb/")
        next if engine_run_stage_excluded?(rel)
        next unless File.file?(path)

        files[rel] = {
          "sha256" => Digest::SHA256.file(path).hexdigest,
          "bytes" => File.size(path)
        }
      end
      files
    end

    def engine_run_writable_path?(path)
      normalized = path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
      ENGINE_RUN_DEFAULT_WRITABLE_GLOBS.any? do |glob|
        if glob.end_with?("/**")
          prefix = glob.delete_suffix("/**")
          normalized == prefix || normalized.start_with?("#{prefix}/")
        else
          File.fnmatch?(glob, normalized, File::FNM_PATHNAME | File::FNM_EXTGLOB)
        end
      end
    end

    def engine_run_high_risk_path?(path)
      ENGINE_RUN_HIGH_RISK_PATTERNS.any? { |pattern| path.match?(pattern) }
    end

    def engine_run_binary_file?(path)
      File.open(path, "rb") { |file| file.read(4096).to_s.include?("\x00") }
    rescue SystemCallError
      false
    end

    def engine_run_file_contains_secret?(path)
      return false unless File.file?(path)

      File.read(path, 256 * 1024).match?(ENGINE_RUN_SECRET_VALUE_PATTERN)
    rescue SystemCallError, ArgumentError
      true
    end

    def engine_run_workspace_diff(workspace_dir, changed_files)
      Array(changed_files).map do |path|
        source = File.join(root, path)
        workspace = File.join(workspace_dir, path)
        agent_run_full_file_diff(path, source, workspace)
      end.join
    end

    def engine_run_copy_back_conflicts(manifest, safe_changes)
      base_files = manifest.fetch("files", {})
      Array(safe_changes).each_with_object([]) do |path, conflicts|
        target = File.join(root, path)
        base_hash = base_files.dig(path, "sha256")
        if base_hash
          unless File.file?(target)
            conflicts << "copy-back target changed since staging: #{path}"
            next
          end
          current_hash = Digest::SHA256.file(target).hexdigest
          conflicts << "copy-back target changed since staging: #{path}" unless current_hash == base_hash
        elsif File.exist?(target) || File.symlink?(target)
          conflicts << "copy-back target appeared since staging: #{path}"
        end
      end
    end

    def engine_run_apply_safe_changes(workspace_dir, safe_changes)
      safe_changes.each do |path|
        source = File.join(workspace_dir, path)
        target = File.join(root, path)
        raise UserError.new("engine-run copy-back target is hardlinked and unsafe: #{path}", 5) if File.file?(target) && File.lstat(target).nlink.to_i > 1

        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(source, target)
      end
    end

  end
end
