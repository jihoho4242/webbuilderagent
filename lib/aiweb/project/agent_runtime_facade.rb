# frozen_string_literal: true

require_relative "../agent_runtime"

module Aiweb
  module ProjectAgentRuntimeFacade
    def agent(goal:, mode: "plan-only", profile: nil, max_steps: 20, approved: false, dry_run: false)
      assert_initialized!
      normalized_goal = goal.to_s.strip
      raise UserError.new("agent requires a goal", 1) if normalized_goal.empty?

      normalized_mode = mode.to_s.strip.empty? ? "plan-only" : mode.to_s.strip
      unless %w[plan-only supervised autonomous-local].include?(normalized_mode)
        raise UserError.new("agent --mode must be plan-only, supervised, or autonomous-local", 1)
      end

      canonical_engine_run = agent_engine_run_facade_plan(normalized_goal)
      payload = Aiweb::AgentRuntime::Loop.new(self).run(
        goal: normalized_goal,
        mode: normalized_mode,
        profile: profile,
        max_steps: max_steps.to_i.positive? ? max_steps.to_i : 20,
        approved: approved,
        dry_run: dry_run || normalized_mode == "plan-only",
        canonical_engine_run: canonical_engine_run
      )
      payload["engine_run_facade"] = canonical_engine_run
      payload.dig("agent_runtime", "agent_os")["engine_run_facade"] = payload["engine_run_facade"] if payload.dig("agent_runtime", "agent_os").is_a?(Hash)
      payload
    end

    private

    def agent_engine_run_facade_plan(goal)
      planned = engine_run(goal: goal, agent: "codex", mode: "safe_patch", dry_run: true)
      {
        "schema_version" => 1,
        "canonical_runtime" => "engine-run",
        "status" => "planned",
        "engine_run_id" => planned.dig("engine_run", "run_id"),
        "approval_hash" => planned.dig("engine_run", "approval_hash"),
        "checkpoint_path" => planned.dig("engine_run", "checkpoint_path"),
        "events_path" => planned.dig("engine_run", "events_path"),
        "note" => "aiweb agent is a goal facade; engine-run is the canonical durable runtime"
      }
    rescue StandardError => e
      {
        "schema_version" => 1,
        "canonical_runtime" => "engine-run",
        "status" => "blocked",
        "blocking_issues" => ["engine-run facade dry-run unavailable: #{e.class}: #{e.message}"]
      }
    end
  end
end
