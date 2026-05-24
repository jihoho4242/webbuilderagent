# frozen_string_literal: true

require_relative "adapter_commands/container_env"

module Aiweb
  module ProjectEngineRun
    def engine_run_agent_command(agent, sandbox, workspace_dir)
      if engine_run_container_worker_agent?(agent)
        return engine_run_agent_container_command(agent, sandbox, workspace_dir)
      end
      path = executable_path(agent)
      raise UserError.new("#{agent} executable is missing from PATH", 1) unless path

      [agent]
    end

    def engine_run_agent_container_command(agent, sandbox, workspace_dir)
      case agent.to_s
      when "openhands" then engine_run_openhands_command(sandbox, workspace_dir)
      when "langgraph" then engine_run_langgraph_command(sandbox, workspace_dir)
      when "openai_agents_sdk" then engine_run_openai_agents_sdk_command(sandbox, workspace_dir)
      else engine_run_openmanus_command(sandbox, workspace_dir)
      end
    end

    def engine_run_agent_sandbox_command_blockers(agent, command, sandbox:, workspace_dir:)
      case agent.to_s
      when "openhands" then engine_run_openhands_sandbox_command_blockers(command, sandbox: sandbox, workspace_dir: workspace_dir)
      when "langgraph" then engine_run_langgraph_sandbox_command_blockers(command, sandbox: sandbox, workspace_dir: workspace_dir)
      when "openai_agents_sdk" then engine_run_openai_agents_sdk_sandbox_command_blockers(command, sandbox: sandbox, workspace_dir: workspace_dir)
      else engine_run_openmanus_sandbox_command_blockers(command, sandbox: sandbox, workspace_dir: workspace_dir)
      end
    end

    def engine_run_agent_image_blockers(agent, sandbox)
      case agent.to_s
      when "openhands" then engine_run_openhands_image_blockers(sandbox)
      when "langgraph" then engine_run_langgraph_image_blockers(sandbox)
      when "openai_agents_sdk" then engine_run_openai_agents_sdk_image_blockers(sandbox)
      else engine_run_openmanus_image_blockers(sandbox)
      end
    end

    def engine_run_openmanus_command(sandbox, workspace_dir)
      provider = sandbox.to_s
      image = engine_run_openmanus_image
      sandbox_runtime_container_command(
        provider: provider,
        workspace_dir: workspace_dir,
        image: image,
        env: engine_run_openmanus_container_env(provider),
        pids_limit: 512,
        memory: "2g",
        cpus: "2",
        tmpfs_size: "128m",
        command: ["openmanus"]
      )
    end

    def engine_run_openhands_command(sandbox, workspace_dir)
      provider = sandbox.to_s
      image = engine_run_openhands_image
      sandbox_runtime_container_command(
        provider: provider,
        workspace_dir: workspace_dir,
        image: image,
        env: engine_run_openhands_container_env(provider),
        pids_limit: 512,
        memory: "2g",
        cpus: "2",
        tmpfs_size: "128m",
        command: ["openhands", "--headless", "--json", "--file", "/workspace/_aiweb/openhands-task.md"]
      )
    end

    def engine_run_langgraph_command(sandbox, workspace_dir)
      provider = sandbox.to_s
      image = engine_run_langgraph_image
      sandbox_runtime_container_command(
        provider: provider,
        workspace_dir: workspace_dir,
        image: image,
        env: engine_run_langgraph_container_env(provider),
        pids_limit: 512,
        memory: "2g",
        cpus: "2",
        tmpfs_size: "128m",
        command: ["python3", "/workspace/_aiweb/langgraph-worker.py"]
      )
    end

    def engine_run_openai_agents_sdk_command(sandbox, workspace_dir)
      provider = sandbox.to_s
      image = engine_run_openai_agents_sdk_image
      sandbox_runtime_container_command(
        provider: provider,
        workspace_dir: workspace_dir,
        image: image,
        env: engine_run_openai_agents_sdk_container_env(provider),
        pids_limit: 512,
        memory: "2g",
        cpus: "2",
        tmpfs_size: "128m",
        command: ["python3", "/workspace/_aiweb/openai-agents-worker.py"]
      )
    end

    def engine_run_openmanus_sandbox_command_blockers(command, sandbox:, workspace_dir:)
      sandbox_runtime_container_command_blockers(
        command,
        sandbox: sandbox,
        workspace_dir: workspace_dir,
        required_env: {
          "AIWEB_ENGINE_RUN_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
          "AIWEB_OPENMANUS_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
          "AIWEB_GRAPH_EXECUTION_PLAN_PATH" => "/workspace/_aiweb/graph-execution-plan.json",
          "AIWEB_WORKER_ADAPTER_CONTRACT_PATH" => "/workspace/_aiweb/worker-adapter-contract.json",
          "AIWEB_WORKER_ADAPTER_REGISTRY_PATH" => "/workspace/_aiweb/worker-adapter-registry.json",
          "AIWEB_OPENMANUS_SANDBOX" => sandbox,
          "AIWEB_NETWORK_ALLOWED" => "0",
          "AIWEB_MCP_ALLOWED" => "0",
          "AIWEB_ENV_ACCESS_ALLOWED" => "0"
        },
        label: "engine-run openmanus sandbox"
      )
    end

    def engine_run_openhands_sandbox_command_blockers(command, sandbox:, workspace_dir:)
      sandbox_runtime_container_command_blockers(
        command,
        sandbox: sandbox,
        workspace_dir: workspace_dir,
        required_env: {
          "AIWEB_ENGINE_RUN_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
          "AIWEB_OPENHANDS_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
          "AIWEB_OPENHANDS_TASK_PATH" => "/workspace/_aiweb/openhands-task.md",
          "AIWEB_GRAPH_EXECUTION_PLAN_PATH" => "/workspace/_aiweb/graph-execution-plan.json",
          "AIWEB_WORKER_ADAPTER_CONTRACT_PATH" => "/workspace/_aiweb/worker-adapter-contract.json",
          "AIWEB_WORKER_ADAPTER_REGISTRY_PATH" => "/workspace/_aiweb/worker-adapter-registry.json",
          "AIWEB_OPENHANDS_SANDBOX" => sandbox,
          "AIWEB_NETWORK_ALLOWED" => "0",
          "AIWEB_MCP_ALLOWED" => "0",
          "AIWEB_ENV_ACCESS_ALLOWED" => "0",
          "RUNTIME" => "process"
        },
        label: "engine-run OpenHands sandbox"
      )
    end

    def engine_run_langgraph_sandbox_command_blockers(command, sandbox:, workspace_dir:)
      sandbox_runtime_container_command_blockers(
        command,
        sandbox: sandbox,
        workspace_dir: workspace_dir,
        required_env: {
          "AIWEB_ENGINE_RUN_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
          "AIWEB_LANGGRAPH_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
          "AIWEB_LANGGRAPH_TASK_PATH" => "/workspace/_aiweb/langgraph-task.md",
          "AIWEB_LANGGRAPH_WORKER_PATH" => "/workspace/_aiweb/langgraph-worker.py",
          "AIWEB_GRAPH_EXECUTION_PLAN_PATH" => "/workspace/_aiweb/graph-execution-plan.json",
          "AIWEB_WORKER_ADAPTER_CONTRACT_PATH" => "/workspace/_aiweb/worker-adapter-contract.json",
          "AIWEB_WORKER_ADAPTER_REGISTRY_PATH" => "/workspace/_aiweb/worker-adapter-registry.json",
          "AIWEB_LANGGRAPH_SANDBOX" => sandbox,
          "AIWEB_NETWORK_ALLOWED" => "0",
          "AIWEB_MCP_ALLOWED" => "0",
          "AIWEB_ENV_ACCESS_ALLOWED" => "0"
        },
        label: "engine-run LangGraph sandbox"
      )
    end

    def engine_run_openai_agents_sdk_sandbox_command_blockers(command, sandbox:, workspace_dir:)
      sandbox_runtime_container_command_blockers(
        command,
        sandbox: sandbox,
        workspace_dir: workspace_dir,
        required_env: {
          "AIWEB_ENGINE_RUN_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
          "AIWEB_OPENAI_AGENTS_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
          "AIWEB_OPENAI_AGENTS_TASK_PATH" => "/workspace/_aiweb/openai-agents-task.md",
          "AIWEB_OPENAI_AGENTS_WORKER_PATH" => "/workspace/_aiweb/openai-agents-worker.py",
          "AIWEB_OPENAI_AGENTS_ALLOW_MODEL_CALL" => "0",
          "AIWEB_GRAPH_EXECUTION_PLAN_PATH" => "/workspace/_aiweb/graph-execution-plan.json",
          "AIWEB_WORKER_ADAPTER_CONTRACT_PATH" => "/workspace/_aiweb/worker-adapter-contract.json",
          "AIWEB_WORKER_ADAPTER_REGISTRY_PATH" => "/workspace/_aiweb/worker-adapter-registry.json",
          "AIWEB_OPENAI_AGENTS_SANDBOX" => sandbox,
          "AIWEB_NETWORK_ALLOWED" => "0",
          "AIWEB_MCP_ALLOWED" => "0",
          "AIWEB_ENV_ACCESS_ALLOWED" => "0"
        },
        label: "engine-run OpenAI Agents SDK sandbox"
      )
    end

    def engine_run_openmanus_image
      image = ENV["AIWEB_OPENMANUS_IMAGE"].to_s.strip
      image.empty? ? "openmanus:latest" : image
    end

    def engine_run_openhands_image
      image = ENV["AIWEB_OPENHANDS_IMAGE"].to_s.strip
      image.empty? ? "openhands:latest" : image
    end

    def engine_run_langgraph_image
      image = ENV["AIWEB_LANGGRAPH_IMAGE"].to_s.strip
      image.empty? ? "langgraph:latest" : image
    end

    def engine_run_openai_agents_sdk_image
      image = ENV["AIWEB_OPENAI_AGENTS_IMAGE"].to_s.strip
      image.empty? ? "openai-agents:latest" : image
    end

    def engine_run_openmanus_image_blockers(sandbox)
      image = engine_run_openmanus_image
      blockers = []
      image_inspect = engine_run_container_image_inspect(sandbox, image)
      unless image_inspect.fetch("status", "failed") == "passed"
        reason = image_inspect.fetch("reason", image_inspect.fetch("error", "image inspect failed")).to_s
        blockers << "OpenManus container image is not available as validated local inspect evidence: #{image}. Build or pull it first, or set AIWEB_OPENMANUS_IMAGE to a prepared local image. #{agent_run_redact_process_output(reason)[0, 300]}".strip
      end
      if engine_run_require_digest_pinned_openmanus_image? && !engine_run_digest_pinned_image?(image)
        sources = engine_run_digest_pinned_openmanus_policy_sources.join(", ")
        blockers << "OpenManus container image must be digest-pinned when strict or production sandbox policy is enabled (#{sources}): set AIWEB_OPENMANUS_IMAGE=openmanus@sha256:<digest>"
      end
      return blockers

    rescue SystemCallError => e
      ["OpenManus image preflight failed for #{image}: #{e.message}"]
    end

    def engine_run_openhands_image_blockers(sandbox)
      image = engine_run_openhands_image
      image_inspect = engine_run_container_image_inspect(sandbox, image)
      return [] if image_inspect.fetch("status", "failed") == "passed"

      reason = image_inspect.fetch("reason", image_inspect.fetch("error", "image inspect failed")).to_s
      ["OpenHands container image is not available as validated local inspect evidence: #{image}. Build or pull it first, or set AIWEB_OPENHANDS_IMAGE to a prepared local image. #{agent_run_redact_process_output(reason)[0, 300]}".strip]
    rescue SystemCallError => e
      ["OpenHands image preflight failed for #{image}: #{e.message}"]
    end

    def engine_run_langgraph_image_blockers(sandbox)
      image = engine_run_langgraph_image
      image_inspect = engine_run_container_image_inspect(sandbox, image)
      return [] if image_inspect.fetch("status", "failed") == "passed"

      reason = image_inspect.fetch("reason", image_inspect.fetch("error", "image inspect failed")).to_s
      ["LangGraph container image is not available as validated local inspect evidence: #{image}. Build or pull it first, or set AIWEB_LANGGRAPH_IMAGE to a prepared local image. #{agent_run_redact_process_output(reason)[0, 300]}".strip]
    rescue SystemCallError => e
      ["LangGraph image preflight failed for #{image}: #{e.message}"]
    end

    def engine_run_openai_agents_sdk_image_blockers(sandbox)
      image = engine_run_openai_agents_sdk_image
      image_inspect = engine_run_container_image_inspect(sandbox, image)
      return [] if image_inspect.fetch("status", "failed") == "passed"

      reason = image_inspect.fetch("reason", image_inspect.fetch("error", "image inspect failed")).to_s
      ["OpenAI Agents SDK container image is not available as validated local inspect evidence: #{image}. Build or pull it first, or set AIWEB_OPENAI_AGENTS_IMAGE to a prepared local image. #{agent_run_redact_process_output(reason)[0, 300]}".strip]
    rescue SystemCallError => e
      ["OpenAI Agents SDK image preflight failed for #{image}: #{e.message}"]
    end

  end
end
