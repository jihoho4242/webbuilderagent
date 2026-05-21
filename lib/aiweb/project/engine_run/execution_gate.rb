# frozen_string_literal: true

module Aiweb
  module ProjectEngineRunExecutionGate
    private

    def engine_run_mode_blockers(mode, agent, sandbox, workspace_dir)
      blockers = []
      if mode == "external_approval"
        blockers << "external_approval mode is a capability escalation record only; package install, network, deploy, provider CLI, and git push require a dedicated approved command"
      end
      if agent == "codex"
        if mode == "agentic_local"
          blockers << "unsandboxed codex is not allowed for real agentic_local engine-run; use --mode safe_patch or run a sandboxed OpenManus worker with --agent openmanus --sandbox docker|podman"
        end
        blockers << "codex executable is missing from PATH" unless executable_path("codex")
      elsif engine_run_container_worker_agent?(agent)
        blockers << "engine-run #{agent} requires --sandbox docker or --sandbox podman" if sandbox.to_s.strip.empty?
        blockers << "engine-run --sandbox must be docker or podman" unless sandbox.to_s.strip.empty? || %w[docker podman].include?(sandbox.to_s)
        blockers << "#{sandbox} executable is missing from PATH" if !sandbox.to_s.strip.empty? && executable_path(sandbox.to_s).nil?
        if !sandbox.to_s.strip.empty? && executable_path(sandbox.to_s)
          command = engine_run_agent_container_command(agent, sandbox.to_s, workspace_dir)
          blockers.concat(engine_run_agent_sandbox_command_blockers(agent, command, sandbox: sandbox.to_s, workspace_dir: workspace_dir))
          blockers.concat(engine_run_agent_image_blockers(agent, sandbox.to_s))
        end
      end
      blockers
    end


    def engine_run_safe_patch(state:, capability:, normalized_agent:, sandbox:, approved:, dry_run:)
      if approved && !dry_run
        preflight = agent_run(task: "latest", agent: normalized_agent, sandbox: sandbox, approved: false, dry_run: true)
        unless preflight.dig("agent_run", "status") == "planned"
          preflight["engine_run"] = {
            "schema_version" => 1,
            "status" => preflight.dig("agent_run", "status"),
            "mode" => "safe_patch",
            "agent" => normalized_agent,
            "capability" => capability,
            "delegated_to" => "agent-run",
            "blocking_issues" => preflight["blocking_issues"] || []
          }
          return preflight
        end
        delegated_hash = preflight.dig("agent_run", "approval_hash")
        return agent_run(task: "latest", agent: normalized_agent, sandbox: sandbox, approved: approved, approval_hash: delegated_hash, dry_run: false).tap do |result|
          result["engine_run"] = {
            "schema_version" => 1,
            "status" => result.dig("agent_run", "status"),
            "mode" => "safe_patch",
            "agent" => normalized_agent,
            "capability" => capability,
            "delegated_to" => "agent-run",
            "delegated_approval_hash" => delegated_hash,
            "blocking_issues" => result["blocking_issues"] || []
          }
        end
      end

      agent_run(task: "latest", agent: normalized_agent, sandbox: sandbox, approved: approved, dry_run: dry_run).tap do |result|
        result["engine_run"] = {
          "schema_version" => 1,
          "status" => result.dig("agent_run", "status"),
          "mode" => "safe_patch",
          "agent" => normalized_agent,
          "capability" => capability,
          "delegated_to" => "agent-run",
          "blocking_issues" => result["blocking_issues"] || []
        }
      end
    end

    def engine_run_initial_execution_blockers(approved:, approval_hash:, expected_hash:, opendesign_contract:, normalized_mode:, normalized_agent:, sandbox:, workspace_dir:, resume:, resume_context:)
      blockers = []
      blockers << "--approved is required for real engine-run execution" unless approved
      if approved && approval_hash.to_s.strip.empty?
        blockers << "--approval-hash is required for real engine-run execution"
      elsif !approval_hash.to_s.strip.empty? && approval_hash.to_s.strip != expected_hash
        blockers << "approval hash does not match the current capability envelope"
      end
      blockers.concat(opendesign_contract.fetch("blocking_issues", []))
      blockers.concat(engine_run_mode_blockers(normalized_mode, normalized_agent, sandbox, workspace_dir))
      if resume && !resume_context
        blockers << "engine-run resume target has no readable checkpoint: #{resume}"
      elsif resume_context
        blockers.concat(engine_run_resume_blockers(resume_context))
      end
      blockers
    end

  end
end
