# frozen_string_literal: true

require "time"

module Aiweb
  module AgentRuntime
    class Verifier
      def verify(observation:, plan:, tool_results:)
        blockers = Array(observation["blocking_issues"])
        result_blockers = tool_results.flat_map { |result| Array(result["blocking_issues"]) }
        statuses = tool_results.map { |result| result["status"].to_s }
        status = verification_status(blockers, result_blockers, statuses)
        completion_status = completion_status_for(status, observation, plan, tool_results)
        {
          "schema_version" => 1,
          "status" => status,
          "completion_status" => completion_status,
          "blocking_issues" => (blockers + result_blockers).uniq,
          "tool_statuses" => tool_results.map { |result| { "tool" => result["tool"], "status" => result["status"] } },
          "pending_approvals" => tool_results.select { |result| result["status"] == "pending_approval" }.map { |result| result["tool"] },
          "repair_hints" => repair_hints(tool_results),
          "planned_action_count" => Array(plan["planned_actions"]).length,
          "verified_at" => Time.now.utc.iso8601
        }
      end

      private

      def verification_status(blockers, result_blockers, statuses)
        return "blocked" if blockers.any? || result_blockers.any? || statuses.include?("blocked")
        return "failed" if statuses.any? { |status| %w[failed timeout error].include?(status) }
        return "pending_approval" if statuses.include?("pending_approval")
        return "planned" if statuses.include?("planned")
        return "passed" if statuses.any? && statuses.all? { |status| %w[passed running already_running created reused].include?(status) }

        "planned"
      end

      def completion_status_for(status, observation, plan, tool_results)
        case status
        when "blocked" then "blocked"
        when "failed" then "failed_validation"
        when "pending_approval", "planned" then "partial_not_complete"
        when "passed"
          required_tools = required_tools_for(observation, plan)
          passed_tools = tool_results.select { |result| %w[passed running already_running created reused].include?(result["status"].to_s) }.map { |result| result["tool"] }
          (required_tools - passed_tools).empty? ? "complete" : "partial_not_complete"
        else
          "partial_not_complete"
        end
      end

      def required_tools_for(observation, plan)
        readiness = observation.dig("runtime_plan", "readiness")
        planned = Array(plan["planned_actions"]).map { |action| action["tool"] }
        return planned & %w[build preview browser_qa] if readiness == "ready"
        return planned & %w[local_verify] if readiness == "local_planning_only"

        []
      end

      def repair_hints(tool_results)
        tool_results.flat_map do |result|
          case result["tool"]
          when "browser_qa"
            next [] if %w[passed planned pending_approval].include?(result["status"].to_s)

            Array(result["blocking_issues"]).map { |issue| "Create a bounded repair/source_patch task from browser QA failure: #{issue}" }
          when "build"
            next [] if %w[passed planned pending_approval].include?(result["status"].to_s)

            Array(result["blocking_issues"]).map { |issue| "Inspect build logs and repair source through manifest-gated source_patch: #{issue}" }
          else
            []
          end
        end.compact
      end
    end
  end
end
