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

      Aiweb::AgentRuntime::Loop.new(self).run(
        goal: normalized_goal,
        mode: normalized_mode,
        profile: profile,
        max_steps: max_steps.to_i.positive? ? max_steps.to_i : 20,
        approved: approved,
        dry_run: dry_run || normalized_mode == "plan-only"
      )
    end
  end
end
