# frozen_string_literal: true

module Aiweb
  module ProjectAgentRuntimeFacade
    def agent(goal:, mode: "plan-only", profile: nil, max_steps: 20, approved: false, approval_hash: nil, dry_run: false)
      assert_initialized!
      normalized_goal = goal.to_s.strip
      raise UserError.new("agent requires a goal", 1) if normalized_goal.empty?

      normalized_mode = mode.to_s.strip.empty? ? "plan-only" : mode.to_s.strip
      unless %w[plan-only supervised autonomous-local].include?(normalized_mode)
        raise UserError.new("agent --mode must be plan-only, supervised, or autonomous-local", 1)
      end

      engine_payload = engine_run(
        goal: normalized_goal,
        agent: "codex",
        mode: "agentic_local",
        max_cycles: agent_cycle_limit(max_steps),
        approved: !!approved,
        approval_hash: approval_hash,
        dry_run: dry_run || normalized_mode == "plan-only" || !approved
      )
      agent_goal_facade_payload(engine_payload, goal: normalized_goal, mode: normalized_mode, profile: profile, max_steps: max_steps, approved: approved, dry_run: dry_run)
    end

    private

    def agent_cycle_limit(max_steps)
      value = max_steps.to_i
      value.positive? ? value : 20
    end

    def agent_goal_facade_payload(engine_payload, goal:, mode:, profile:, max_steps:, approved:, dry_run:)
      engine = engine_payload["engine_run"].is_a?(Hash) ? engine_payload["engine_run"] : {}
      status = engine["status"] || engine_payload["status"] || "unknown"
      blocking_issues = (Array(engine_payload["blocking_issues"]) + Array(engine["blocking_issues"])).uniq
      approval_hash = engine["approval_hash"] || engine.dig("capability", "approval_hash")
      summary = {
        "schema_version" => 2,
        "status" => status,
        "goal" => goal,
        "mode" => mode,
        "profile" => profile,
        "max_steps" => agent_cycle_limit(max_steps),
        "canonical_runtime" => "engine-run",
        "agent_runtime_execution_role" => "removed_script_runner",
        "script_executor_neutralized" => true,
        "fixed_action_planner_present" => false,
        "direct_tool_executor_present" => false,
        "approved" => !!approved,
        "dry_run" => dry_run || mode == "plan-only" || !approved,
        "engine_run" => {
          "run_id" => engine["run_id"],
          "status" => status,
          "mode" => engine["mode"],
          "agent" => engine["agent"],
          "approval_hash" => approval_hash,
          "metadata_path" => engine["metadata_path"],
          "checkpoint_path" => engine["checkpoint_path"],
          "events_path" => engine["events_path"]
        }.compact,
        "blocking_issues" => blocking_issues
      }
      engine_payload.merge(
        "action_taken" => "delegated natural-language goal to engine-run",
        "agent_runtime" => summary,
        "next_action" => agent_goal_facade_next_action(engine_payload, approval_hash: approval_hash, approved: approved, dry_run: dry_run, mode: mode)
      )
    end

    def agent_goal_facade_next_action(engine_payload, approval_hash:, approved:, dry_run:, mode:)
      return engine_payload["next_action"] if engine_payload["next_action"].to_s.match?(/select a design candidate|resolve/i)
      return "review engine-run evidence and continue with aiweb engine-scheduler or run-resume if needed" if approved && !dry_run && mode != "plan-only"

      return "review the engine-run plan, then rerun aiweb agent --mode supervised --dry-run to obtain an approval_hash before any --approved execution" if approval_hash.to_s.empty?

      "review the engine-run plan, then rerun aiweb agent --mode supervised --approval-hash #{approval_hash} --approved only when the capability envelope is acceptable"
    end
  end
end
