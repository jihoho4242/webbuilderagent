# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
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
  end
end
