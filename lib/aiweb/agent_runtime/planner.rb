# frozen_string_literal: true

require "time"

module Aiweb
  module AgentRuntime
    class Planner
      def plan(goal:, observation:, mode:, max_steps:)
        readiness = observation.dig("runtime_plan", "readiness")
        profile = observation["profile"]
        blockers = Array(observation["blocking_issues"])
        actions = []
        if blockers.any?
          actions << action("finish", "Runtime is blocked; report blockers before acting", requires_approval: false)
        elsif readiness == "ready"
          actions.concat([
            action("build", "Profile #{profile} is runtime-ready; build is the next verification gate", requires_approval: true),
            action("preview", "Preview enables browser QA feedback", requires_approval: true),
            action("browser_qa", "Browser QA verifies rendered output before repair", requires_approval: true)
          ])
        elsif readiness == "local_planning_only"
          actions << action("local_verify", "Profile #{profile} is local-planning-only; run local verification instead of build/preview", requires_approval: false)
        else
          actions << action("finish", "No supported runtime action is available for readiness #{readiness.inspect}", requires_approval: false)
        end

        {
          "schema_version" => 1,
          "goal" => goal,
          "mode" => mode,
          "max_steps" => max_steps,
          "planned_actions" => actions.take(max_steps),
          "planned_at" => Time.now.utc.iso8601
        }
      end

      private

      def action(tool, reason, requires_approval:)
        {
          "tool" => tool,
          "reason" => reason,
          "risk" => risk_for(tool),
          "requires_approval" => requires_approval,
          "expected_artifact" => ToolRegistry::TOOLS.dig(tool, "artifact"),
          "verification" => "#{tool} result must be structured, redacted, and linked from final-report.json"
        }
      end

      def risk_for(tool)
        case tool
        when "finish" then "none"
        when "local_verify" then "local_artifact_write"
        when "build", "preview", "browser_qa" then "approved_local_runtime"
        when "source_patch" then "bounded_source_write"
        else "local_runtime"
        end
      end
    end
  end
end
