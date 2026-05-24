# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    def engine_run_openmanus_container_env(provider)
      {
        "AIWEB_ENGINE_RUN_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_OPENMANUS_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_GRAPH_EXECUTION_PLAN_PATH" => "/workspace/_aiweb/graph-execution-plan.json",
        "AIWEB_WORKER_ADAPTER_CONTRACT_PATH" => "/workspace/_aiweb/worker-adapter-contract.json",
        "AIWEB_WORKER_ADAPTER_REGISTRY_PATH" => "/workspace/_aiweb/worker-adapter-registry.json",
        "AIWEB_OPENMANUS_SANDBOX" => provider,
        "AIWEB_NETWORK_ALLOWED" => "0",
        "AIWEB_MCP_ALLOWED" => "0",
        "AIWEB_ENV_ACCESS_ALLOWED" => "0",
        "AIWEB_TOOL_BROKER_EVENTS_PATH" => "/workspace/_aiweb/tool-broker-events.jsonl",
        "AIWEB_TOOL_BROKER_REAL_PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "PATH" => "/workspace/_aiweb/tool-broker-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME" => "/workspace/_aiweb/home",
        "USERPROFILE" => "/workspace/_aiweb/home",
        "TMPDIR" => "/workspace/_aiweb/tmp",
        "TMP" => "/workspace/_aiweb/tmp",
        "TEMP" => "/workspace/_aiweb/tmp"
      }
    end

    def engine_run_openhands_container_env(provider)
      {
        "AIWEB_ENGINE_RUN_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_OPENHANDS_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_OPENHANDS_TASK_PATH" => "/workspace/_aiweb/openhands-task.md",
        "AIWEB_GRAPH_EXECUTION_PLAN_PATH" => "/workspace/_aiweb/graph-execution-plan.json",
        "AIWEB_WORKER_ADAPTER_CONTRACT_PATH" => "/workspace/_aiweb/worker-adapter-contract.json",
        "AIWEB_WORKER_ADAPTER_REGISTRY_PATH" => "/workspace/_aiweb/worker-adapter-registry.json",
        "AIWEB_OPENHANDS_SANDBOX" => provider,
        "AIWEB_NETWORK_ALLOWED" => "0",
        "AIWEB_MCP_ALLOWED" => "0",
        "AIWEB_ENV_ACCESS_ALLOWED" => "0",
        "AIWEB_TOOL_BROKER_EVENTS_PATH" => "/workspace/_aiweb/tool-broker-events.jsonl",
        "AIWEB_TOOL_BROKER_REAL_PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "RUNTIME" => "process",
        "SANDBOX_VOLUMES" => "/workspace:/workspace:rw",
        "PATH" => "/workspace/_aiweb/tool-broker-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME" => "/workspace/_aiweb/home",
        "USERPROFILE" => "/workspace/_aiweb/home",
        "TMPDIR" => "/workspace/_aiweb/tmp",
        "TMP" => "/workspace/_aiweb/tmp",
        "TEMP" => "/workspace/_aiweb/tmp"
      }
    end

    def engine_run_langgraph_container_env(provider)
      {
        "AIWEB_ENGINE_RUN_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_LANGGRAPH_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_LANGGRAPH_TASK_PATH" => "/workspace/_aiweb/langgraph-task.md",
        "AIWEB_LANGGRAPH_WORKER_PATH" => "/workspace/_aiweb/langgraph-worker.py",
        "AIWEB_GRAPH_EXECUTION_PLAN_PATH" => "/workspace/_aiweb/graph-execution-plan.json",
        "AIWEB_WORKER_ADAPTER_CONTRACT_PATH" => "/workspace/_aiweb/worker-adapter-contract.json",
        "AIWEB_WORKER_ADAPTER_REGISTRY_PATH" => "/workspace/_aiweb/worker-adapter-registry.json",
        "AIWEB_LANGGRAPH_SANDBOX" => provider,
        "AIWEB_NETWORK_ALLOWED" => "0",
        "AIWEB_MCP_ALLOWED" => "0",
        "AIWEB_ENV_ACCESS_ALLOWED" => "0",
        "AIWEB_TOOL_BROKER_EVENTS_PATH" => "/workspace/_aiweb/tool-broker-events.jsonl",
        "AIWEB_TOOL_BROKER_REAL_PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "PATH" => "/workspace/_aiweb/tool-broker-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME" => "/workspace/_aiweb/home",
        "USERPROFILE" => "/workspace/_aiweb/home",
        "TMPDIR" => "/workspace/_aiweb/tmp",
        "TMP" => "/workspace/_aiweb/tmp",
        "TEMP" => "/workspace/_aiweb/tmp"
      }
    end

    def engine_run_openai_agents_sdk_container_env(provider)
      {
        "AIWEB_ENGINE_RUN_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_OPENAI_AGENTS_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_OPENAI_AGENTS_TASK_PATH" => "/workspace/_aiweb/openai-agents-task.md",
        "AIWEB_OPENAI_AGENTS_WORKER_PATH" => "/workspace/_aiweb/openai-agents-worker.py",
        "AIWEB_OPENAI_AGENTS_ALLOW_MODEL_CALL" => "0",
        "AIWEB_GRAPH_EXECUTION_PLAN_PATH" => "/workspace/_aiweb/graph-execution-plan.json",
        "AIWEB_WORKER_ADAPTER_CONTRACT_PATH" => "/workspace/_aiweb/worker-adapter-contract.json",
        "AIWEB_WORKER_ADAPTER_REGISTRY_PATH" => "/workspace/_aiweb/worker-adapter-registry.json",
        "AIWEB_OPENAI_AGENTS_SANDBOX" => provider,
        "AIWEB_NETWORK_ALLOWED" => "0",
        "AIWEB_MCP_ALLOWED" => "0",
        "AIWEB_ENV_ACCESS_ALLOWED" => "0",
        "AIWEB_TOOL_BROKER_EVENTS_PATH" => "/workspace/_aiweb/tool-broker-events.jsonl",
        "AIWEB_TOOL_BROKER_REAL_PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "PATH" => "/workspace/_aiweb/tool-broker-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME" => "/workspace/_aiweb/home",
        "USERPROFILE" => "/workspace/_aiweb/home",
        "TMPDIR" => "/workspace/_aiweb/tmp",
        "TMP" => "/workspace/_aiweb/tmp",
        "TEMP" => "/workspace/_aiweb/tmp"
      }
    end

  end
end
