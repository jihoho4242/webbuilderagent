# frozen_string_literal: true

module Aiweb
  module ProjectEngineRunGeneratedSources
    def engine_run_openai_agents_sdk_worker_source
      <<~'PY'
        import json
        import os
        import sys
        from typing import Any, Dict

        RESULT_PATH = os.environ.get("AIWEB_OPENAI_AGENTS_RESULT_PATH") or os.environ.get("AIWEB_ENGINE_RUN_RESULT_PATH") or "/workspace/_aiweb/engine-result.json"
        TASK_PATH = os.environ.get("AIWEB_OPENAI_AGENTS_TASK_PATH", "/workspace/_aiweb/openai-agents-task.md")
        CONTRACT_PATH = os.environ.get("AIWEB_WORKER_ADAPTER_CONTRACT_PATH", "/workspace/_aiweb/worker-adapter-contract.json")
        REGISTRY_PATH = os.environ.get("AIWEB_WORKER_ADAPTER_REGISTRY_PATH", "/workspace/_aiweb/worker-adapter-registry.json")
        GRAPH_PLAN_PATH = os.environ.get("AIWEB_GRAPH_EXECUTION_PLAN_PATH", "/workspace/_aiweb/graph-execution-plan.json")

        def read_json(path: str) -> Dict[str, Any]:
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    value = json.load(handle)
                return value if isinstance(value, dict) else {}
            except OSError:
                return {}
            except json.JSONDecodeError as exc:
                return {"_error": exc.__class__.__name__}

        def read_text(path: str) -> str:
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    return handle.read()
            except OSError:
                return ""

        def write_result(payload: Dict[str, Any], exit_code: int = 0) -> None:
            os.makedirs(os.path.dirname(RESULT_PATH), exist_ok=True)
            with open(RESULT_PATH, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, ensure_ascii=False, sort_keys=True)
            print(json.dumps({
                "adapter": payload.get("adapter"),
                "status": payload.get("status"),
                "event_count": len(payload.get("structured_events", []))
            }, sort_keys=True))
            sys.exit(exit_code)

        try:
            from agents import Agent, Runner
        except Exception as exc:
            write_result({
                "schema_version": 1,
                "adapter": "openai_agents_sdk",
                "status": "blocked",
                "structured_events": [{"type": "openai_agents_sdk.import_failed", "error_class": exc.__class__.__name__}],
                "artifact_refs": ["_aiweb/openai-agents-worker.py"],
                "changed_file_manifest": [],
                "proposed_tool_requests": [],
                "risk_notes": ["OpenAI Agents SDK package is unavailable in the prepared sandbox image"],
                "blocking_issues": ["agents package import failed: " + exc.__class__.__name__],
                "sdk_trace": {
                    "api": "agents.Agent/Runner",
                    "model_call_attempted": False,
                    "model_call_allowed": False
                }
            }, 2)

        task = read_text(TASK_PATH)
        contract = read_json(CONTRACT_PATH)
        registry = read_json(REGISTRY_PATH)
        graph_plan = read_json(GRAPH_PLAN_PATH)
        model_call_allowed = os.environ.get("AIWEB_OPENAI_AGENTS_ALLOW_MODEL_CALL") == "1" and os.environ.get("AIWEB_NETWORK_ALLOWED") == "1"
        events = [
            {"type": "openai_agents_sdk.prepare", "task_path": TASK_PATH, "task_bytes": len(task.encode("utf-8"))},
            {"type": "openai_agents_sdk.agent_configured", "agent_name": "AiwebSandboxWorker"},
            {
                "type": "openai_agents_sdk.observe_contract",
                "contract_adapter": contract.get("adapter"),
                "registry_protocol": registry.get("protocol_version"),
                "graph_scheduler_type": graph_plan.get("scheduler_type")
            }
        ]
        blockers = []
        risks = [
            "experimental OpenAI Agents SDK bridge configured an Agent/Runner boundary without requesting side effects",
            "external model/network calls are disabled unless a future broker explicitly allows them"
        ]
        final_output = None
        model_call_attempted = False
        agent = Agent(
            name="AiwebSandboxWorker",
            instructions=(
                "You are the WebBuilderAgent sandbox worker. Respect aiweb broker boundaries, "
                "do not request external network, package install, MCP, deploy, git push, or raw env access."
            )
        )
        if model_call_allowed:
            model_call_attempted = True
            try:
                result = Runner.run_sync(agent, task, max_turns=1)
                final_output = str(getattr(result, "final_output", ""))
                events.append({"type": "openai_agents_sdk.runner_finished", "final_output_bytes": len(final_output.encode("utf-8"))})
            except Exception as exc:
                blockers.append("OpenAI Agents SDK Runner failed: " + exc.__class__.__name__)
                events.append({"type": "openai_agents_sdk.runner_failed", "error_class": exc.__class__.__name__})
        else:
            events.append({"type": "openai_agents_sdk.runner_not_invoked_network_blocked", "reason": "AIWEB_OPENAI_AGENTS_ALLOW_MODEL_CALL=0 or AIWEB_NETWORK_ALLOWED=0"})

        write_result({
            "schema_version": 1,
            "adapter": "openai_agents_sdk",
            "status": "blocked" if blockers else "no_changes",
            "structured_events": events,
            "artifact_refs": ["_aiweb/openai-agents-worker.py", "_aiweb/openai-agents-task.md"],
            "changed_file_manifest": [],
            "proposed_tool_requests": [],
            "risk_notes": risks,
            "blocking_issues": blockers,
            "sdk_trace": {
                "api": "agents.Agent/Runner",
                "agent_class": Agent.__name__,
                "runner_has_run_sync": hasattr(Runner, "run_sync"),
                "model_call_attempted": model_call_attempted,
                "model_call_allowed": model_call_allowed,
                "final_output_present": bool(final_output)
            }
        })
      PY
    end
  end
end
