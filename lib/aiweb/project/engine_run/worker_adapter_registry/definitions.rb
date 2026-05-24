# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    def engine_run_worker_adapter_registry_definitions
      [
        {
          id: "openmanus",
          modes: %w[agentic_local],
          runtime_boundary: "aiweb_validated_docker_or_podman_no_network_staged_workspace",
          command_driver: "engine_run_openmanus_command",
          sandbox_preflight: "required_before_execution",
          result_schema: "worker-adapter-v1 engine-result.json",
          broker_id: "aiweb.engine_run.tool_broker",
          broker_enforcement_status: "enforced",
          broker_evidence: %w[_aiweb/tool-broker-events.jsonl worker-adapter-contract.json worker-adapter-registry.json sandbox-preflight.json agent-result.json],
          evidence: %w[worker-adapter-contract.json worker-adapter-registry.json sandbox-preflight.json agent-result.json],
          limitations: []
        },
        {
          id: "codex",
          status: "delegated_safe_patch_only",
          modes: %w[safe_patch],
          runtime_boundary: "agent_run_clean_environment_bounded_copy_back",
          command_driver: "agent_run",
          sandbox_preflight: "not_applicable_safe_patch_delegation",
          result_schema: "agent-run.json diff.patch",
          broker_id: "aiweb.agent_run.safe_patch_boundary",
          broker_enforcement_status: "delegated_safe_patch_bounded",
          broker_evidence: %w[agent-run.json stdout.log stderr.log diff.patch],
          evidence: %w[agent-run.json stdout.log stderr.log diff.patch],
          limitations: ["real agentic_local Codex execution is blocked until a sandbox adapter exists"]
        },
        {
          id: "openhands",
          modes: %w[agentic_local],
          runtime_boundary: "experimental_aiweb_validated_docker_or_podman_no_network_staged_workspace_with_openhands_headless",
          command_driver: "engine_run_openhands_command",
          sandbox_preflight: "required_before_execution",
          result_schema: "engine-run-openhands-result.schema.json",
          broker_id: "aiweb.engine_run.tool_broker",
          broker_enforcement_status: "enforced",
          broker_evidence: %w[_aiweb/tool-broker-events.jsonl worker-adapter-contract.json worker-adapter-registry.json sandbox-preflight.json agent-result.json _aiweb/openhands-task.md],
          evidence: %w[worker-adapter-contract.json worker-adapter-registry.json sandbox-preflight.json agent-result.json openhands-task.md],
          limitations: ["experimental OpenHands headless CLI container adapter only", "requires a prepared local OpenHands-compatible image and model/runtime configuration inside the approved sandbox", "does not imply LangGraph or OpenAI Agents SDK worker parity"]
        },
        {
          id: "langgraph",
          modes: %w[agentic_local],
          runtime_boundary: "experimental_aiweb_validated_docker_or_podman_no_network_staged_workspace_with_langgraph_stategraph_bridge",
          command_driver: "engine_run_langgraph_command",
          sandbox_preflight: "required_before_execution",
          result_schema: "engine-run-langgraph-result.schema.json",
          broker_id: "aiweb.engine_run.tool_broker",
          broker_enforcement_status: "enforced",
          broker_evidence: %w[_aiweb/tool-broker-events.jsonl worker-adapter-contract.json worker-adapter-registry.json sandbox-preflight.json agent-result.json _aiweb/langgraph-worker.py _aiweb/langgraph-task.md],
          evidence: %w[worker-adapter-contract.json worker-adapter-registry.json sandbox-preflight.json agent-result.json langgraph-worker.py langgraph-task.md],
          limitations: ["experimental LangGraph StateGraph bridge only", "requires a prepared local LangGraph-compatible Python image", "does not provide a LangGraph Platform deployment or distributed checkpoint store", "does not imply OpenAI Agents SDK worker parity"]
        },
        {
          id: "openai_agents_sdk",
          modes: %w[agentic_local],
          runtime_boundary: "experimental_aiweb_validated_docker_or_podman_no_network_staged_workspace_with_openai_agents_sdk_bridge",
          command_driver: "engine_run_openai_agents_sdk_command",
          sandbox_preflight: "required_before_execution",
          result_schema: "engine-run-openai-agents-sdk-result.schema.json",
          broker_id: "aiweb.engine_run.tool_broker",
          broker_enforcement_status: "enforced",
          broker_evidence: %w[_aiweb/tool-broker-events.jsonl worker-adapter-contract.json worker-adapter-registry.json sandbox-preflight.json agent-result.json _aiweb/openai-agents-worker.py _aiweb/openai-agents-task.md],
          evidence: %w[worker-adapter-contract.json worker-adapter-registry.json sandbox-preflight.json agent-result.json openai-agents-worker.py openai-agents-task.md],
          limitations: ["experimental OpenAI Agents SDK bridge only", "requires a prepared local Python image with openai-agents installed", "default bridge records SDK orchestration readiness without enabling external OpenAI network calls", "does not provide production handoff/tool parity"]
        }
      ]
    end

    def engine_run_worker_adapter_registry_entry(id:, status:, modes:, runtime_boundary:, command_driver:, broker_id:, broker_enforcement_status:, broker_evidence:, evidence:, limitations:, sandbox_preflight: nil, result_schema: nil)
      blocking_issues = engine_run_worker_adapter_status_blocking_issues(status, id)
      {
        "id" => id,
        "status" => status,
        "executable" => engine_run_worker_adapter_status_executable?(status),
        "execution_blocked" => !engine_run_worker_adapter_status_executable?(status),
        "blocking_issues" => blocking_issues,
        "api" => %w[prepare act observe cancel resume finalize],
        "modes" => modes,
        "runtime_boundary" => runtime_boundary,
        "command_driver" => command_driver,
        "sandbox_preflight" => sandbox_preflight,
        "result_schema" => result_schema,
        "driver_readiness" => engine_run_worker_adapter_driver_readiness(
          id: id,
          status: status,
          command_driver: command_driver,
          sandbox_preflight: sandbox_preflight,
          result_schema: result_schema,
          broker_evidence: broker_evidence,
          evidence: evidence,
          limitations: limitations
        ),
        "broker_contract" => {
          "required" => true,
          "broker_id" => broker_id,
          "event_flow" => %w[tool.requested policy.decision tool.started tool.finished tool.blocked],
          "enforcement_status" => broker_enforcement_status,
          "evidence_artifacts" => broker_evidence,
          "fail_closed_on_missing_broker_driver" => true
        },
        "input_refs_only" => true,
        "output_contract" => %w[structured_events artifact_refs proposed_tool_requests changed_file_manifest risk_notes],
        "evidence_artifacts" => evidence,
        "limitations" => limitations
      }
    end

    def engine_run_worker_adapter_driver_readiness(id:, status:, command_driver:, sandbox_preflight:, result_schema:, broker_evidence:, evidence:, limitations:)
      required = %w[command_driver sandbox_preflight result_schema broker_evidence result_evidence limitations]
      missing = []
      missing << "command_driver" if command_driver.to_s.empty?
      missing << "sandbox_preflight" if sandbox_preflight.to_s.empty? || sandbox_preflight.to_s == "missing"
      missing << "result_schema" if result_schema.to_s.empty?
      missing << "broker_evidence" if Array(broker_evidence).empty?
      missing << "result_evidence" if Array(evidence).empty?
      missing << "limitations" if Array(limitations).empty? && !engine_run_worker_adapter_status_executable?(status)
      state = if engine_run_worker_adapter_status_executable?(status) && missing.empty?
                %w[openhands langgraph openai_agents_sdk].include?(id.to_s) ? "experimental_ready" : "ready"
              elsif engine_run_worker_adapter_status_executable?(status)
                "executable_but_incomplete"
              else
                "blocked_missing_driver_artifacts"
              end
      {
        "schema_version" => 1,
        "state" => state,
        "required_artifacts" => required,
        "missing_artifacts" => missing,
        "executable_now" => engine_run_worker_adapter_status_executable?(status) && missing.empty?,
        "transition_gate" => missing.empty? ? "driver_may_execute_under_adapter_status_policy" : "fail_closed_until_missing_artifacts_exist",
        "next_required_evidence" => missing.map { |item| engine_run_worker_adapter_readiness_requirement(id, item) },
        "limitations" => limitations
      }
    end

    def engine_run_worker_adapter_readiness_requirement(id, item)
      case item
      when "command_driver"
        "#{id} needs a concrete command driver wired from engine_run_agent_command"
      when "sandbox_preflight"
        "#{id} needs sandbox or runtime preflight evidence before execution"
      when "result_schema"
        "#{id} needs a schema-locked worker-adapter-v1 result contract"
      when "broker_evidence"
        "#{id} needs tool broker event evidence artifacts before copy-back"
      when "result_evidence"
        "#{id} needs durable result/evidence artifacts in the run directory and staged workspace"
      when "limitations"
        "#{id} needs explicit limitations so adapter readiness cannot be overclaimed"
      else
        "#{id} needs #{item}"
      end
    end
  end
end
