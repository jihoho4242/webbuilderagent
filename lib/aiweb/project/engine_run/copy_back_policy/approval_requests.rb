# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

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
  end
end
