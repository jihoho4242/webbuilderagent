# frozen_string_literal: true

module Aiweb
  module ProjectEngineRunGeneratedSources
    def engine_run_langgraph_worker_source
      <<~'PY'
        import json
        import os
        import sys
        from typing import Any, Dict, List, TypedDict

        try:
            from langgraph.graph import END, START, StateGraph
        except Exception as exc:
            result_path = os.environ.get("AIWEB_LANGGRAPH_RESULT_PATH") or "/workspace/_aiweb/engine-result.json"
            os.makedirs(os.path.dirname(result_path), exist_ok=True)
            with open(result_path, "w", encoding="utf-8") as handle:
                json.dump({
                    "schema_version": 1,
                    "adapter": "langgraph",
                    "status": "blocked",
                    "structured_events": [{"type": "langgraph.import_failed", "error_class": exc.__class__.__name__}],
                    "artifact_refs": ["_aiweb/langgraph-worker.py"],
                    "changed_file_manifest": [],
                    "proposed_tool_requests": [],
                    "risk_notes": ["LangGraph package is unavailable in the prepared sandbox image"],
                    "blocking_issues": ["langgraph package import failed: " + exc.__class__.__name__]
                }, handle, ensure_ascii=False, sort_keys=True)
            sys.exit(2)

        class WorkerState(TypedDict, total=False):
            task_path: str
            contract_path: str
            registry_path: str
            graph_plan_path: str
            events: List[Dict[str, Any]]
            artifact_refs: List[str]
            changed_file_manifest: List[str]
            proposed_tool_requests: List[Dict[str, Any]]
            risk_notes: List[str]
            blocking_issues: List[str]
            status: str

        def read_json(path: str) -> Dict[str, Any]:
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    value = json.load(handle)
                return value if isinstance(value, dict) else {}
            except OSError:
                return {}
            except json.JSONDecodeError as exc:
                return {"_error": exc.__class__.__name__}

        def prepare(state: WorkerState) -> WorkerState:
            events = list(state.get("events", []))
            events.append({"type": "langgraph.prepare", "task_path": state.get("task_path")})
            artifacts = list(state.get("artifact_refs", []))
            artifacts.extend(["_aiweb/langgraph-worker.py", "_aiweb/langgraph-task.md"])
            return {"events": events, "artifact_refs": artifacts}

        def act(state: WorkerState) -> WorkerState:
            events = list(state.get("events", []))
            proposed = list(state.get("proposed_tool_requests", []))
            risks = list(state.get("risk_notes", []))
            contract = read_json(state.get("contract_path", ""))
            registry = read_json(state.get("registry_path", ""))
            graph_plan = read_json(state.get("graph_plan_path", ""))
            events.append({
                "type": "langgraph.act",
                "contract_adapter": contract.get("adapter"),
                "registry_protocol": registry.get("protocol_version"),
                "graph_scheduler_type": graph_plan.get("scheduler_type")
            })
            risks.append("experimental LangGraph bridge observed aiweb artifacts and did not request side effects")
            return {"events": events, "proposed_tool_requests": proposed, "risk_notes": risks}

        def observe(state: WorkerState) -> WorkerState:
            events = list(state.get("events", []))
            events.append({"type": "langgraph.observe", "changed_file_count": len(state.get("changed_file_manifest", []))})
            return {"events": events}

        def finalize(state: WorkerState) -> WorkerState:
            events = list(state.get("events", []))
            blockers = list(state.get("blocking_issues", []))
            events.append({"type": "langgraph.finalize", "blocking_issue_count": len(blockers)})
            return {"events": events, "status": "blocked" if blockers else "no_changes"}

        builder = StateGraph(WorkerState)
        builder.add_node("prepare", prepare)
        builder.add_node("act", act)
        builder.add_node("observe", observe)
        builder.add_node("finalize", finalize)
        builder.add_edge(START, "prepare")
        builder.add_edge("prepare", "act")
        builder.add_edge("act", "observe")
        builder.add_edge("observe", "finalize")
        builder.add_edge("finalize", END)
        graph = builder.compile()

        initial: WorkerState = {
            "task_path": os.environ.get("AIWEB_LANGGRAPH_TASK_PATH", "/workspace/_aiweb/langgraph-task.md"),
            "contract_path": os.environ.get("AIWEB_WORKER_ADAPTER_CONTRACT_PATH", "/workspace/_aiweb/worker-adapter-contract.json"),
            "registry_path": os.environ.get("AIWEB_WORKER_ADAPTER_REGISTRY_PATH", "/workspace/_aiweb/worker-adapter-registry.json"),
            "graph_plan_path": os.environ.get("AIWEB_GRAPH_EXECUTION_PLAN_PATH", "/workspace/_aiweb/graph-execution-plan.json"),
            "events": [],
            "artifact_refs": [],
            "changed_file_manifest": [],
            "proposed_tool_requests": [],
            "risk_notes": [],
            "blocking_issues": []
        }
        final = graph.invoke(initial)
        result = {
            "schema_version": 1,
            "adapter": "langgraph",
            "status": final.get("status", "reported"),
            "structured_events": final.get("events", []),
            "artifact_refs": final.get("artifact_refs", []),
            "changed_file_manifest": final.get("changed_file_manifest", []),
            "proposed_tool_requests": final.get("proposed_tool_requests", []),
            "risk_notes": final.get("risk_notes", []),
            "blocking_issues": final.get("blocking_issues", []),
            "graph_trace": {
                "api": "langgraph.graph.StateGraph",
                "nodes": ["prepare", "act", "observe", "finalize"],
                "edges": [["START", "prepare"], ["prepare", "act"], ["act", "observe"], ["observe", "finalize"], ["finalize", "END"]]
            }
        }
        result_path = os.environ.get("AIWEB_LANGGRAPH_RESULT_PATH") or os.environ.get("AIWEB_ENGINE_RUN_RESULT_PATH") or "/workspace/_aiweb/engine-result.json"
        os.makedirs(os.path.dirname(result_path), exist_ok=True)
        with open(result_path, "w", encoding="utf-8") as handle:
            json.dump(result, handle, ensure_ascii=False, sort_keys=True)
        print(json.dumps({"adapter": "langgraph", "status": result["status"], "event_count": len(result["structured_events"])}, sort_keys=True))
      PY
    end
  end
end
