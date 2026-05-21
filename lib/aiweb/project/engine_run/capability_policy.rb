# frozen_string_literal: true

require "digest"
require_relative "../../authz_contract"

module Aiweb
  module ProjectEngineRunCapabilityPolicy
    private

    def engine_run_capability_envelope(run_id:, goal:, mode:, agent:, sandbox:, max_cycles:, resume:, opendesign_contract:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "goal" => goal,
        "constitution_hash" => Aiweb::Constitution::Loader.new.content_hash,
        "policy_kernel_version" => Aiweb::Tools::DecisionPacket::POLICY_KERNEL_VERSION,
        "mode" => mode,
        "agent" => agent,
        "sandbox" => sandbox,
        "resume_from" => resume,
        "opendesign_contract" => engine_run_capability_opendesign_contract(opendesign_contract),
        "writable_globs" => ProjectEngineRun::ENGINE_RUN_DEFAULT_WRITABLE_GLOBS,
        "allowed_tools" => mode == "agentic_local" ? %w[sandbox_shell build test preview local_qa screenshot] : %w[source_patch],
        "forbidden" => %w[env credentials external_network deploy provider_cli git_push host_root_write],
        "context_refs" => %w[project_index opendesign_contract worker_adapter_registry staged_manifest prior_evidence],
        "limits" => {
          "max_cycles" => max_cycles,
          "timeout_sec" => 600,
          "max_output_bytes" => 200_000
        },
        "worker_adapter" => engine_run_worker_adapter_contract(agent),
        "tool_broker" => engine_run_tool_broker_contract(mode),
        "authz_contract" => engine_run_authz_contract,
        "retention_redaction_policy" => engine_run_retention_redaction_policy,
        "copy_back" => {
          "requires_validation" => true,
          "secret_scan" => true,
          "risk_classifier" => true
        }
      }
    end

    def engine_run_local_backend_route_permissions
      {
        "view_status" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "view_workbench" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "view_console" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "view_runs" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "view_run" => %w[api_token project_path run_id tenant_claim project_claim user_claim role_acl audit_event],
        "view_events" => %w[api_token project_path run_id tenant_claim project_claim user_claim role_acl audit_event],
        "view_approvals" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "view_job_status" => %w[api_token project_path run_id tenant_claim project_claim user_claim role_acl audit_event],
        "view_job_timeline" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "view_job_summary" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "view_artifact" => %w[api_token project_path artifact_path tenant_claim project_claim user_claim role_acl audit_event],
        "command" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "codex_agent_run" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "run_start" => %w[api_token approval_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "approve" => %w[api_token approval_token project_path run_id capability_hash tenant_claim project_claim user_claim role_acl audit_event],
        "resume" => %w[api_token approval_token project_path run_id tenant_claim project_claim user_claim role_acl audit_event],
        "cancel" => %w[api_token approval_token project_path run_id tenant_claim project_claim user_claim role_acl audit_event],
        "copy_back" => %w[capability_hash safe_change_policy approval_record role_acl audit_event]
      }
    end

    def engine_run_local_backend_route_required_roles
      Aiweb::AuthzContract.copy(Aiweb::AuthzContract::AUTHZ_ACTION_REQUIRED_ROLES)
    end

    def engine_run_local_backend_artifact_acl_policy
      Aiweb::AuthzContract.copy(Aiweb::AuthzContract::ARTIFACT_ACL_POLICY)
    end

    def engine_run_authz_contract
      {
        "schema_version" => 1,
        "mode" => "local_project",
        "local_api_token_required" => true,
        "run_id_is_not_authority" => true,
        "saas_required_claims" => Aiweb::AuthzContract.copy(Aiweb::AuthzContract::REQUIRED_CLAIMS),
        "local_backend_claim_enforced_mode" => Aiweb::AuthzContract.local_backend_claim_enforced_mode(route_required_roles: engine_run_local_backend_route_required_roles),
        "permission_checks" => engine_run_local_backend_route_permissions.keys,
        "approval_scope_binds" => %w[approver_identity tenant_id project_id run_id capability_hash expiry single_use exact_capability],
        "tenant_scoped_artifacts" => %w[events artifacts screenshots logs diffs approvals checkpoints],
        "note" => "Local engine-run is project-scoped; a SaaS workbench must add tenant/project/user authz before exposing these APIs remotely."
      }
    end

    def engine_run_authz_enforcement(run_id:, mode:, agent:, sandbox:, approved:, paths:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "recorded_at" => now,
        "mode" => "local_project",
        "run_id_is_not_authority" => true,
        "project_scope" => {
          "project_root" => relative(root),
          "workspace_path" => relative(paths.fetch(:workspace_dir)),
          "run_dir" => relative(paths.fetch(:run_dir)),
          "artifact_scope" => relative(paths.fetch(:run_dir)),
          "diff_scope" => ".ai-web/diffs"
        },
        "local_backend_enforcement" => Aiweb::AuthzContract.local_backend_enforcement(route_required_roles: engine_run_local_backend_route_required_roles, route_permissions: engine_run_local_backend_route_permissions),
        "current_execution" => {
          "agent" => agent,
          "engine_mode" => mode,
          "sandbox" => sandbox,
          "approved_flag" => approved,
          "approval_scope" => "single_run_single_capability"
        },
        "saas_required_claims" => Aiweb::AuthzContract.copy(Aiweb::AuthzContract::REQUIRED_CLAIMS),
        "saas_claims_observed" => [],
        "remote_exposure_status" => "blocked_until_tenant_project_user_claims_are_enforced",
        "blocking_issues" => [
          "remote SaaS exposure requires tenant_id, project_id, and user_id authz enforcement outside local engine-run"
        ]
      }
    end

    def engine_run_retention_redaction_policy
      {
        "schema_version" => 1,
        "events" => {
          "append_only" => true,
          "tamper_evident_hash_chain" => true,
          "redaction_status" => "redacted_at_source"
        },
        "artifact_classes" => {
          "logs" => { "retention" => "project_local_until_user_deletes_run", "redaction" => "secret_patterns_and_env_paths" },
          "prompts" => { "retention" => "project_local_until_user_deletes_run", "redaction" => "no_raw_env_or_provider_credentials" },
          "screenshots" => { "retention" => "project_local_until_user_deletes_run", "redaction" => "local_preview_only_no_external_urls" },
          "dom_snapshots" => { "retention" => "project_local_until_user_deletes_run", "redaction" => "local_preview_only_secret_pattern_scan" },
          "diffs" => { "retention" => "project_local_until_user_deletes_run", "redaction" => "copy_back_secret_scan_before_acceptance" },
          "command_output" => { "retention" => "project_local_until_user_deletes_run", "redaction" => "agent_run_redact_process_output" }
        }
      }
    end

    def engine_run_approval_hash(capability)
      stable = capability.to_h.reject { |key, _value| key == "run_id" }
      Digest::SHA256.hexdigest(json_generate(stable))
    end

    def engine_run_tool_broker_contract(mode)
      {
        "schema_version" => 1,
        "mode" => mode,
        "event_flow" => %w[tool.requested policy.decision tool.started tool.finished tool.blocked],
        "request_fields" => %w[tool_name args working_dir capability_scope risk_class expected_outputs idempotency_key approval_hash],
        "deny_by_default" => %w[external_network package_install deploy provider_cli git_push mcp_connectors env_read host_root_write],
        "pre_guardrail" => true,
        "post_guardrail" => true,
        "side_effect_surface_audit" => side_effect_surface_audit,
        "runtime_broker_enforcement" => engine_run_runtime_broker_enforcement(selected_adapter: nil),
        "mcp_connectors" => {
          "default" => "denied_for_implementation_workers_except_approved_brokered_lazyweb_health_search_and_project_files_metadata_list",
          "known_brokered_design_research_driver" => "aiweb.lazyweb.side_effect_broker",
          "known_brokered_implementation_worker_driver" => "aiweb.implementation_mcp_broker",
          "elevated_approval_requires" => %w[mcp_server tool_names allowed_args_schema credential_source delegated_identity network_destinations output_redaction per_call_audit]
        }
      }
    end

    def engine_run_tool_request(tool_name, command, working_dir, capability, risk_class:, expected_outputs:)
      args = Array(command).map(&:to_s)
      idempotency_key = Digest::SHA256.hexdigest([tool_name, args.join("\0"), relative(working_dir), capability["goal"]].join("\0"))
      {
        "schema_version" => 1,
        "request_id" => "tool-#{idempotency_key[0, 16]}",
        "tool_name" => tool_name,
        "args" => args,
        "working_dir" => relative(working_dir),
        "capability_scope" => capability["mode"],
        "risk_class" => risk_class,
        "expected_outputs" => expected_outputs,
        "idempotency_key" => idempotency_key,
        "trace_span_id" => "span-tool-#{idempotency_key[0, 16]}",
        "approval_hash" => engine_run_approval_hash(capability)
      }
    end

    def engine_run_approval_record(run_id:, capability:, approval_hash:, approved:, scope:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "scope" => scope,
        "status" => approved ? "approved" : "planned",
        "approved_at" => approved ? now : nil,
        "approval_hash" => approval_hash,
        "capability_hash" => approval_hash,
        "single_use" => true,
        "capability" => capability
      }
    end

  end
end
