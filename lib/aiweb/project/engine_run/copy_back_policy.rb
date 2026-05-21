# frozen_string_literal: true

require_relative "copy_back_policy/supply_chain"

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
