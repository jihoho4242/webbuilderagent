# frozen_string_literal: true

require "digest"

module Aiweb
  module ProjectEngineRunCheckpoint
    private

    def engine_run_checkpoint(run_id:, status:, cycle:, next_step:, workspace_path:, safe_changes: [], goal: nil, resume_from: nil, opendesign_contract: nil, run_graph: nil, artifact_hashes: nil)
      record = {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "cycle" => cycle,
        "next_step" => next_step,
        "workspace_path" => relative(workspace_path),
        "safe_changes" => safe_changes,
        "saved_at" => now
      }
      record["goal"] = goal unless goal.to_s.strip.empty?
      record["resume_from"] = resume_from unless resume_from.to_s.strip.empty?
      record["opendesign_contract"] = engine_run_checkpoint_opendesign_contract(opendesign_contract) if opendesign_contract
      record["artifact_hashes"] = artifact_hashes.is_a?(Hash) ? artifact_hashes : {}
      if run_graph
        record["run_graph_cursor"] = run_graph["cursor"]
        record["run_graph"] = run_graph.slice("schema_version", "run_id", "constitution_hash", "agent_os_goal_runtime_nodes", "nodes", "executor_contract", "resume_policy", "side_effects_must_use_tool_broker")
      end
      record
    end

    def engine_run_checkpoint_artifact_hashes(paths)
      {
        "staged_manifest" => paths.fetch(:manifest_path),
        "graph_execution_plan" => paths.fetch(:graph_execution_plan_path),
        "graph_scheduler_state" => paths.fetch(:graph_scheduler_state_path),
        "opendesign_contract" => paths.fetch(:opendesign_contract_path),
        "project_index" => paths.fetch(:project_index_path),
        "run_memory" => paths.fetch(:run_memory_path),
        "authz_enforcement" => paths.fetch(:authz_enforcement_path),
        "worker_adapter_registry" => paths.fetch(:worker_adapter_registry_path),
        "sandbox_preflight" => paths.fetch(:sandbox_preflight_path),
        "supply_chain_gate" => paths.fetch(:supply_chain_gate_path),
        "supply_chain_sbom" => paths.fetch(:supply_chain_sbom_path),
        "supply_chain_audit" => paths.fetch(:supply_chain_audit_path),
        "verification" => paths.fetch(:verification_path),
        "preview" => paths.fetch(:preview_path),
        "browser_evidence" => paths.fetch(:screenshot_evidence_path),
        "design_verdict" => paths.fetch(:design_verdict_path),
        "design_fidelity" => paths.fetch(:design_fidelity_path),
        "design_fixture" => paths.fetch(:design_fixture_path),
        "eval_benchmark" => paths.fetch(:eval_benchmark_path),
        "quarantine" => paths.fetch(:quarantine_path),
        "diff" => paths.fetch(:diff_path)
      }.each_with_object({}) do |(name, path), memo|
        next unless File.file?(path)

        memo[name] = {
          "path" => relative(path),
          "sha256" => "sha256:#{Digest::SHA256.file(path).hexdigest}",
          "bytes" => File.size(path)
        }
      end
    end

  end
end
