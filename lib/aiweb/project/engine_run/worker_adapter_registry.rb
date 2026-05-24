# frozen_string_literal: true

require_relative "worker_adapter_registry/definitions"

module Aiweb
  module ProjectEngineRun
    def engine_run_worker_adapter_contract(agent)
      {
        "schema_version" => 1,
        "adapter" => agent,
        "api" => %w[prepare act observe cancel resume finalize],
        "input_refs_only" => true,
        "allowed_inputs" => %w[goal staged_workspace_uri run_graph_cursor capability_envelope design_contract prior_evidence_refs],
        "allowed_outputs" => %w[structured_events artifact_refs proposed_tool_requests changed_file_manifest risk_notes],
        "contract_violations" => %w[host_absolute_path raw_secret_value raw_env_value unapproved_network unapproved_provider_cli unapproved_git_push],
        "runtime_broker" => {
          "required" => true,
          "event_flow" => %w[tool.requested policy.decision tool.started tool.finished tool.blocked],
          "fail_closed_on_missing_broker_driver" => true,
          "adapter_must_report_proposed_tool_requests" => true,
          "output_without_broker_evidence_blocks_copy_back" => true
        }
      }
    end

    def engine_run_container_worker_agent?(agent)
      %w[openmanus openhands langgraph openai_agents_sdk].include?(agent.to_s)
    end

    def engine_run_agent_container_image(agent)
      case agent.to_s
      when "openhands" then engine_run_openhands_image
      when "langgraph" then engine_run_langgraph_image
      when "openai_agents_sdk" then engine_run_openai_agents_sdk_image
      else engine_run_openmanus_image
      end
    end

    def engine_run_agent_container_env(agent, provider)
      case agent.to_s
      when "openhands" then engine_run_openhands_container_env(provider)
      when "langgraph" then engine_run_langgraph_container_env(provider)
      when "openai_agents_sdk" then engine_run_openai_agents_sdk_container_env(provider)
      else engine_run_openmanus_container_env(provider)
      end
    end

    def engine_run_worker_adapter_registry(selected_agent:, mode:, sandbox:)
      selected = selected_agent.to_s
      selected_status = engine_run_worker_adapter_status(selected, mode: mode, sandbox: sandbox)
      registry = {
        "schema_version" => 1,
        "protocol_version" => "worker-adapter-v1",
        "selected_adapter" => selected,
        "selected_adapter_status" => selected_status,
        "selected_adapter_executable" => engine_run_worker_adapter_status_executable?(selected_status),
        "selected_adapter_blocking_issues" => engine_run_worker_adapter_status_blocking_issues(selected_status, selected),
        "required_api" => %w[prepare act observe cancel resume finalize],
        "selection_policy" => {
          "agentic_local" => "only sandboxed container workers may execute directly; unsandboxed Codex stays delegated to safe_patch",
          "safe_patch" => "delegated to existing agent-run safe patch flow",
          "external_approval" => "requires explicit external approval before execution"
        },
        "adapters" => engine_run_worker_adapter_registry_entries(mode: mode, sandbox: sandbox),
        "runtime_broker_enforcement" => engine_run_runtime_broker_enforcement(selected_adapter: selected),
        "interchangeability_claim" => "registry exposes adapter readiness; only adapters with implemented/delegated status may execute",
        "blocking_policy" => "planned_contract_only adapters are visible for migration planning but blocked as execution targets"
      }
      blockers = engine_run_worker_adapter_registry_blockers(registry)
      raise UserError.new("engine-run worker adapter registry invalid: #{blockers.join(", ")}", 5) unless blockers.empty?

      registry
    end

    def engine_run_worker_adapter_registry_entries(mode:, sandbox:)
      engine_run_worker_adapter_registry_definitions.map do |definition|
        id = definition.fetch(:id)
        engine_run_worker_adapter_registry_entry(
          id: id,
          status: definition.fetch(:status) { engine_run_worker_adapter_status(id, mode: mode, sandbox: sandbox) },
          modes: Array(definition.fetch(:modes)),
          runtime_boundary: definition.fetch(:runtime_boundary),
          command_driver: definition.fetch(:command_driver),
          sandbox_preflight: definition.fetch(:sandbox_preflight),
          result_schema: definition.fetch(:result_schema),
          broker_id: definition.fetch(:broker_id),
          broker_enforcement_status: definition.fetch(:broker_enforcement_status),
          broker_evidence: Array(definition.fetch(:broker_evidence)),
          evidence: Array(definition.fetch(:evidence)),
          limitations: Array(definition.fetch(:limitations))
        )
      end
    end

    def engine_run_runtime_broker_enforcement(selected_adapter:)
      surfaces = [
        {
          "surface" => "engine_run_worker_adapters",
          "status" => "enforced_for_executable_adapters",
          "broker_id" => "aiweb.engine_run.tool_broker",
          "evidence" => %w[_aiweb/tool-broker-events.jsonl worker-adapter-registry.json worker-adapter-contract.json],
          "policy" => "executable worker adapters must declare broker_contract and report proposed_tool_requests; missing broker evidence blocks copy-back"
        },
        {
          "surface" => "mcp_connectors",
          "status" => "partial_drivers_available_lazyweb_and_project_files",
          "broker_id" => "aiweb.implementation_mcp_broker",
          "evidence" => [".ai-web/runs/lazyweb-research-*/side-effect-broker.jsonl", ".ai-web/runs/mcp-broker-*/side-effect-broker.jsonl"],
          "policy" => "Lazyweb design-research MCP calls, approved implementation-worker Lazyweb health/search calls, approved project_files.project_file_metadata/project_file_list metadata-only calls, approved bounded safe project_files.project_file_excerpt calls, and approved bounded literal project_files.project_file_search calls have concrete per-call brokers with redaction and audit events; all other implementation-worker MCP/connectors remain denied by default until each server has credential source, allowed args schema, network destinations, output redaction, and per-call audit evidence"
        },
        {
          "surface" => "future_adapters",
          "status" => "fail_closed_until_broker_driver",
          "broker_id" => "aiweb.future_adapter.required",
          "evidence" => [],
          "policy" => "OpenHands, LangGraph, and OpenAI Agents SDK each have one experimental sandboxed container driver; production-grade framework parity still requires hardened tool/handoff/session broker coverage"
        },
        {
          "surface" => "elevated_runners",
          "status" => "approval_required_and_brokered",
          "broker_id" => "aiweb.side_effect_broker",
          "evidence" => %w[side-effect-broker.jsonl],
          "policy" => "package install, deploy/provider CLI, backend bridge, Lazyweb HTTP, and OpenManus subprocesses must emit broker events or stay blocked"
        }
      ]
      {
        "schema_version" => 1,
        "status" => "partial_enforcement",
        "selected_adapter" => selected_adapter,
        "deny_by_default_surfaces" => %w[external_network package_install deploy provider_cli git_push mcp_connectors env_read host_root_write future_adapters elevated_runners],
        "executable_without_broker_count" => 0,
        "fail_closed_surface_count" => surfaces.count { |surface| surface["status"].include?("fail_closed") || surface["status"].include?("denied") },
        "universal_broker_claim" => false,
        "known_mcp_broker_drivers" => [
          {
            "server" => "lazyweb",
            "broker_id" => "aiweb.lazyweb.side_effect_broker",
            "scope" => "external_http.lazyweb_mcp",
            "status" => "implemented_for_design_research",
            "evidence" => [".ai-web/runs/lazyweb-research-*/side-effect-broker.jsonl"],
            "limitations" => ["not exposed to implementation agents", "not a generic MCP connector execution surface"]
          },
          {
            "server" => "lazyweb",
            "broker_id" => "aiweb.implementation_mcp_broker",
            "scope" => "implementation_worker.mcp.lazyweb",
            "status" => "implemented_for_approved_health_and_search_calls",
            "evidence" => [".ai-web/runs/mcp-broker-*/mcp-broker.json", ".ai-web/runs/mcp-broker-*/side-effect-broker.jsonl"],
            "limitations" => ["approved Lazyweb health/search only", "not a generic MCP connector runner", "not exposed to default engine-run sandbox without explicit approval"]
          },
          {
            "server" => "project_files",
            "broker_id" => "aiweb.implementation_mcp_broker",
            "scope" => "implementation_worker.mcp.project_files",
            "status" => "implemented_for_approved_project_file_metadata_list_excerpt_search",
            "evidence" => [".ai-web/runs/mcp-broker-*/mcp-broker.json", ".ai-web/runs/mcp-broker-*/side-effect-broker.jsonl"],
            "limitations" => ["approved project_file_metadata, project_file_list, bounded project_file_excerpt, and bounded project_file_search only", "project_file_list returns metadata only; project_file_excerpt returns bounded safe UTF-8 excerpts only; project_file_search returns bounded literal UTF-8 matches only", "no external network or credentials", "not exposed to default engine-run sandbox without explicit approval"]
          }
        ],
        "surfaces" => surfaces,
        "remaining_gaps" => [
          "implementation-worker MCP/connectors beyond Lazyweb health/search and project_files metadata/list/excerpt/search still need concrete per-call broker drivers before use",
          "OpenHands is experimental and still depends on a prepared local container image plus in-sandbox runtime/model configuration",
          "LangGraph is experimental and still depends on a prepared local Python image with langgraph installed; this is not LangGraph Platform or distributed checkpointing",
          "OpenAI Agents SDK is experimental and still depends on a prepared local Python image with openai-agents installed; external model/network calls remain blocked by default",
          "OS/container egress firewall is still separate from broker contract evidence"
        ]
      }
    end

    def engine_run_worker_adapter_registry_blockers(registry)
      adapters = Array(registry["adapters"])
      blockers = []
      adapters.each do |adapter|
        broker = adapter["broker_contract"]
        if !broker.is_a?(Hash) || broker["required"] != true
          blockers << "#{adapter["id"]} adapter is missing required broker_contract"
          next
        end
        blockers << "#{adapter["id"]} adapter broker_id is missing" if broker["broker_id"].to_s.empty?
        unless Array(broker["event_flow"]).include?("policy.decision")
          blockers << "#{adapter["id"]} adapter broker_contract must include policy.decision"
        end
        if adapter["executable"] == true
          status = broker["enforcement_status"].to_s
          unless %w[enforced delegated_safe_patch_bounded].include?(status)
            blockers << "#{adapter["id"]} executable adapter must have enforced broker evidence"
          end
          if Array(broker["evidence_artifacts"]).empty?
            blockers << "#{adapter["id"]} executable adapter must declare broker evidence artifacts"
          end
        elsif adapter["status"] == "planned_contract_only" && adapter["execution_blocked"] != true
          blockers << "#{adapter["id"]} planned adapter must be execution_blocked"
        end
      end
      if registry.dig("runtime_broker_enforcement", "executable_without_broker_count").to_i.positive?
        blockers << "runtime broker enforcement detected executable adapters without broker coverage"
      end
      blockers.uniq
    end

    def engine_run_worker_adapter_status_executable?(status)
      %w[implemented_container_worker experimental_container_worker delegated_safe_patch_only].include?(status.to_s)
    end

    def engine_run_worker_adapter_status_blocking_issues(status, adapter)
      case status.to_s
      when "implemented_container_worker", "experimental_container_worker", "delegated_safe_patch_only"
        []
      when "implemented_requires_docker_or_podman"
        ["#{adapter} requires a validated docker or podman sandbox before agentic_local execution"]
      when "experimental_requires_docker_or_podman"
        ["#{adapter} experimental adapter requires a validated docker or podman sandbox before agentic_local execution"]
      when "blocked_unsandboxed_agentic_local"
        ["#{adapter} agentic_local execution is blocked until a validated sandbox adapter exists; use safe_patch delegation instead"]
      when "planned_contract_only"
        ["#{adapter} is planned contract-only and cannot execute until a command driver, sandbox preflight, result schema, and evidence artifacts are implemented"]
      else
        ["#{adapter} is not supported as an executable engine-run worker adapter"]
      end
    end

    def engine_run_worker_adapter_status(agent, mode:, sandbox:)
      case agent.to_s
      when "openmanus"
        sandbox.to_s.empty? ? "implemented_requires_docker_or_podman" : "implemented_container_worker"
      when "openhands"
        sandbox.to_s.empty? ? "experimental_requires_docker_or_podman" : "experimental_container_worker"
      when "langgraph"
        sandbox.to_s.empty? ? "experimental_requires_docker_or_podman" : "experimental_container_worker"
      when "openai_agents_sdk"
        sandbox.to_s.empty? ? "experimental_requires_docker_or_podman" : "experimental_container_worker"
      when "codex"
        mode.to_s == "safe_patch" ? "delegated_safe_patch_only" : "blocked_unsandboxed_agentic_local"
      else
        "unsupported"
      end
    end

  end
end
