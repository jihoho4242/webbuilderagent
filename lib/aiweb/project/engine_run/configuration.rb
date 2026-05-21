# frozen_string_literal: true

module Aiweb
  module ProjectEngineRunConfiguration
    private

    def engine_run_agent(value)
      text = value.to_s.strip.empty? ? "codex" : value.to_s.strip
      raise UserError.new("engine-run --agent must be codex, openmanus, openhands, langgraph, or openai_agents_sdk", 1) unless self.class::ENGINE_RUN_AGENTS.include?(text)

      text
    end

    def engine_run_mode(value)
      text = value.to_s.strip.empty? ? "agentic_local" : value.to_s.strip.tr("-", "_")
      raise UserError.new("engine-run --mode must be safe_patch, agentic_local, or external_approval", 1) unless self.class::ENGINE_RUN_MODES.include?(text)

      text
    end

    def engine_run_cycle_limit(value)
      number = value.to_i
      number = 3 unless number.positive?
      [number, 10].min
    end

    def engine_run_requested_run_id(value, resume:, timestamp:)
      text = value.to_s.strip
      unless text.empty?
        safe = validate_run_id!(text)
        unless safe.match?(/\Aengine-run-[A-Za-z0-9_.-]+\z/)
          raise UserError.new("engine-run --run-id must start with engine-run- and contain only letters, numbers, dot, underscore, or dash", 1)
        end
        return safe
      end

      resume.to_s.strip.empty? ? "engine-run-#{timestamp}" : "engine-run-resume-#{timestamp}"
    end

    def engine_run_goal(goal, state, resume, resume_context = nil)
      text = goal.to_s.strip
      return text unless text.empty?
      if resume
        checkpoint = resume_context ? resume_context.fetch(:checkpoint) : engine_run_resume_checkpoint(resume)
        return checkpoint["goal"].to_s unless checkpoint.to_h["goal"].to_s.empty?
        metadata = resume_context && resume_context[:metadata]
        return metadata["goal"].to_s unless metadata.to_h["goal"].to_s.empty?
      end
      state.dig("project", "idea").to_s.strip.empty? ? "complete the current web-building task autonomously inside the sandbox" : state.dig("project", "idea").to_s
    end

    def engine_run_paths(run_id, run_dir)
      {
        run_id: run_id,
        run_dir: run_dir,
        metadata_path: File.join(run_dir, "engine-run.json"),
        job_path: File.join(run_dir, "job.json"),
        events_path: File.join(run_dir, "events.jsonl"),
        approval_path: File.join(run_dir, "approvals.jsonl"),
        checkpoint_path: File.join(run_dir, "checkpoint.json"),
        stdout_path: File.join(run_dir, "logs", "stdout.log"),
        stderr_path: File.join(run_dir, "logs", "stderr.log"),
        diff_path: File.join(aiweb_dir, "diffs", "#{run_id}.patch"),
        manifest_path: File.join(run_dir, "artifacts", "staged-manifest.json"),
        graph_execution_plan_path: File.join(run_dir, "artifacts", "graph-execution-plan.json"),
        graph_scheduler_state_path: File.join(run_dir, "artifacts", "graph-scheduler-state.json"),
        opendesign_contract_path: File.join(run_dir, "artifacts", "opendesign-contract.json"),
        project_index_path: File.join(run_dir, "artifacts", "project-index.json"),
        run_memory_path: File.join(run_dir, "artifacts", "run-memory.json"),
        authz_enforcement_path: File.join(run_dir, "artifacts", "authz-enforcement.json"),
        worker_adapter_registry_path: File.join(run_dir, "artifacts", "worker-adapter-registry.json"),
        worker_adapter_contract_path: File.join(run_dir, "artifacts", "worker-adapter-contract.json"),
        agent_result_path: File.join(run_dir, "artifacts", "agent-result.json"),
        sandbox_preflight_path: File.join(run_dir, "artifacts", "sandbox-preflight.json"),
        supply_chain_gate_path: File.join(run_dir, "artifacts", "supply-chain-gate.json"),
        supply_chain_sbom_path: File.join(run_dir, "artifacts", "sbom.json"),
        supply_chain_audit_path: File.join(run_dir, "artifacts", "package-audit.json"),
        quarantine_path: File.join(run_dir, "artifacts", "quarantine.json"),
        verification_path: File.join(run_dir, "qa", "verification.json"),
        preview_path: File.join(run_dir, "qa", "preview.json"),
        screenshot_evidence_path: File.join(run_dir, "qa", "screenshots.json"),
        design_verdict_path: File.join(run_dir, "qa", "design-verdict.json"),
        design_fidelity_path: File.join(run_dir, "qa", "design-fidelity.json"),
        design_fixture_path: File.join(run_dir, "qa", "design-fixture.json"),
        eval_benchmark_path: File.join(run_dir, "qa", "eval-benchmark.json"),
        workspace_dir: File.join(aiweb_dir, "tmp", "agentic", run_id, "workspace"),
        artifacts_dir: File.join(run_dir, "artifacts"),
        logs_dir: File.join(run_dir, "logs"),
        qa_dir: File.join(run_dir, "qa"),
        screenshots_dir: File.join(run_dir, "screenshots")
      }
    end

    def engine_run_artifact_dirs(paths)
      [paths.fetch(:artifacts_dir), paths.fetch(:logs_dir), paths.fetch(:qa_dir), paths.fetch(:screenshots_dir), File.dirname(paths.fetch(:diff_path))]
    end

    def engine_run_planned_changes(paths)
      [
        relative(paths.fetch(:run_dir)),
        relative(paths.fetch(:metadata_path)),
        relative(paths.fetch(:job_path)),
        relative(paths.fetch(:events_path)),
        relative(paths.fetch(:approval_path)),
        relative(paths.fetch(:checkpoint_path)),
        relative(paths.fetch(:manifest_path)),
        relative(paths.fetch(:graph_execution_plan_path)),
        relative(paths.fetch(:graph_scheduler_state_path)),
        relative(paths.fetch(:opendesign_contract_path)),
        relative(paths.fetch(:project_index_path)),
        relative(paths.fetch(:run_memory_path)),
        relative(paths.fetch(:authz_enforcement_path)),
        relative(paths.fetch(:worker_adapter_registry_path)),
        relative(paths.fetch(:worker_adapter_contract_path)),
        relative(paths.fetch(:agent_result_path)),
        relative(paths.fetch(:sandbox_preflight_path)),
        relative(paths.fetch(:supply_chain_gate_path)),
        relative(paths.fetch(:supply_chain_sbom_path)),
        relative(paths.fetch(:supply_chain_audit_path)),
        relative(paths.fetch(:quarantine_path)),
        relative(paths.fetch(:verification_path)),
        relative(paths.fetch(:preview_path)),
        relative(paths.fetch(:screenshot_evidence_path)),
        relative(paths.fetch(:design_verdict_path)),
        relative(paths.fetch(:design_fidelity_path)),
        relative(paths.fetch(:design_fixture_path)),
        relative(paths.fetch(:eval_benchmark_path)),
        relative(paths.fetch(:diff_path)),
        relative(paths.fetch(:workspace_dir))
      ]
    end
  end
end
