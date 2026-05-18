# frozen_string_literal: true

require "shellwords"

module Aiweb
  module ProjectEngineRunGeneratedSources
    def engine_run_tool_broker_shim_source(tool_name, config)
      <<~SH
        #!/bin/sh
        set -eu
        TOOL_NAME=#{Shellwords.escape(tool_name)}
        RISK_CLASS=#{Shellwords.escape(config.fetch("risk"))}
        BLOCK_MODE=#{Shellwords.escape(config.fetch("mode"))}
        BLOCK_REASON=#{Shellwords.escape(config.fetch("reason"))}
        EVENT_PATH="${AIWEB_TOOL_BROKER_EVENTS_PATH:-/workspace/_aiweb/tool-broker-events.jsonl}"
        REAL_PATH="${AIWEB_TOOL_BROKER_REAL_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
        SHIM_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

        aiweb_block() {
          mkdir -p "$(dirname -- "$EVENT_PATH")"
          ARG_COUNT=$#
          printf '{"schema_version":1,"type":"tool.blocked","tool_name":"%s","risk_class":"%s","reason":"%s","args_redacted":true,"arg_count":%s}\\n' "$TOOL_NAME" "$RISK_CLASS" "$BLOCK_REASON" "$ARG_COUNT" >> "$EVENT_PATH"
          printf 'AIWEB_TOOL_BROKER_BLOCKED %s: %s\\n' "$RISK_CLASS" "$BLOCK_REASON" >&2
          exit 126
        }

        aiweb_delegate() {
          OLD_IFS=$IFS
          IFS=:
          for dir in $REAL_PATH; do
            IFS=$OLD_IFS
            [ -n "$dir" ] || continue
            [ "$dir" = "$SHIM_DIR" ] && continue
            if [ -x "$dir/$TOOL_NAME" ]; then
              exec "$dir/$TOOL_NAME" "$@"
            fi
            IFS=:
          done
          IFS=$OLD_IFS
          printf 'AIWEB_TOOL_BROKER_REAL_COMMAND_MISSING %s\\n' "$TOOL_NAME" >&2
          exit 127
        }

        aiweb_first_subcommand() {
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --)
                shift
                break
                ;;
              --prefix|--workspace|--filter|--cwd|--cache|--userconfig|--registry|-C|-w)
                shift
                [ "$#" -gt 0 ] && shift
                continue
                ;;
              --prefix=*|--workspace=*|--filter=*|--cwd=*|--cache=*|--userconfig=*|--registry=*|-C=*|-w=*)
                shift
                continue
                ;;
              -c)
                shift
                if [ "$TOOL_NAME" = "git" ]; then
                  [ "$#" -gt 0 ] && shift
                fi
                continue
                ;;
              -*)
                shift
                continue
                ;;
              *)
                printf '%s' "$1"
                return 0
                ;;
            esac
          done
          [ "$#" -gt 0 ] && printf '%s' "$1"
        }

        aiweb_contains_package_install() {
          for arg in "$@"; do
            case "$arg" in
              add|install|i|ci|update|upgrade|up) return 0 ;;
            esac
          done
          return 1
        }

        aiweb_contains_git_push() {
          for arg in "$@"; do
            [ "$arg" = "push" ] && return 0
          done
          return 1
        }

        case "$BLOCK_MODE" in
          always_block)
            aiweb_block "$@"
            ;;
          package_manager)
            if aiweb_contains_package_install "$@"; then
              aiweb_block "$@"
            fi
            aiweb_delegate "$@"
            ;;
          git)
            if aiweb_contains_git_push "$@"; then
              aiweb_block "$@"
            fi
            aiweb_delegate "$@"
            ;;
          *)
            aiweb_block "$@"
            ;;
        esac
      SH
    end

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
