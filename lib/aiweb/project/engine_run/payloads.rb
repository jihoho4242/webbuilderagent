# frozen_string_literal: true

module Aiweb
  module ProjectEngineRunPayloads
    private

    def engine_run_dry_run_payload(state:, run_id:, normalized_mode:, normalized_agent:, sandbox:, approved:, capability:, expected_hash:, paths:, planned_changes:, resume:, opendesign_contract:, run_graph:, tool_broker:)
      dry_blockers = opendesign_contract.fetch("blocking_issues", [])
      dry_status = dry_blockers.empty? ? "dry_run" : "blocked"
      metadata = engine_run_metadata(
        run_id: run_id,
        status: dry_status,
        mode: normalized_mode,
        agent: normalized_agent,
        sandbox: sandbox,
        approved: approved,
        dry_run: true,
        goal: capability.fetch("goal"),
        capability: capability,
        approval_hash: expected_hash,
        paths: paths,
        events: engine_run_planned_events,
        checkpoint: engine_run_checkpoint(run_id: run_id, status: dry_status, cycle: 0, next_step: dry_status == "blocked" ? "select_design" : "await_approval", workspace_path: paths.fetch(:workspace_dir), goal: capability.fetch("goal"), resume_from: resume, opendesign_contract: opendesign_contract, run_graph: run_graph),
        run_graph: run_graph,
        tool_broker: tool_broker,
        opendesign_contract: opendesign_contract,
        blocking_issues: dry_blockers
      )
      engine_run_payload(
        state: state,
        metadata: metadata,
        changed_files: [],
        planned_changes: planned_changes,
        action_taken: dry_status == "blocked" ? "engine run blocked" : "planned engine run",
        next_action: dry_status == "blocked" ? "select a design candidate before running UI/source engine work" : "rerun aiweb engine-run --agent #{normalized_agent} --mode #{normalized_mode}#{engine_run_sandbox_suffix(normalized_agent, sandbox)} --approval-hash #{expected_hash} --approved to execute inside the staged sandbox"
      )
    end

    def engine_run_initial_blocked_payload(state:, run_id:, normalized_mode:, normalized_agent:, sandbox:, approved:, capability:, expected_hash:, paths:, resume:, opendesign_contract:, run_graph:, tool_broker:, blockers:)
      metadata = engine_run_metadata(
        run_id: run_id,
        status: "blocked",
        mode: normalized_mode,
        agent: normalized_agent,
        sandbox: sandbox,
        approved: approved,
        dry_run: false,
        goal: capability.fetch("goal"),
        capability: capability,
        approval_hash: expected_hash,
        paths: paths,
        events: [],
        checkpoint: engine_run_checkpoint(run_id: run_id, status: "blocked", cycle: 0, next_step: opendesign_contract.fetch("blocking_issues", []).empty? ? "resolve_blockers" : "select_design", workspace_path: paths.fetch(:workspace_dir), goal: capability.fetch("goal"), resume_from: resume, opendesign_contract: opendesign_contract, run_graph: run_graph),
        run_graph: run_graph,
        tool_broker: tool_broker,
        opendesign_contract: opendesign_contract,
        blocking_issues: blockers
      )
      engine_run_payload(
        state: state,
        metadata: metadata,
        changed_files: [],
        planned_changes: [],
        action_taken: "engine run blocked",
        next_action: "resolve engine-run blockers or inspect aiweb engine-run --dry-run"
      )
    end

  end
end
