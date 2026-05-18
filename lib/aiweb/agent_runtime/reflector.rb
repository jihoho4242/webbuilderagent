# frozen_string_literal: true

require "digest"
require "time"

module Aiweb
  module AgentRuntime
    class Reflector
      def reflect(verification)
        blockers = Array(verification["blocking_issues"])
        status = blockers.empty? ? verification.fetch("completion_status", "partial_not_complete") : "blocked"
        {
          "schema_version" => 1,
          "status" => status,
          "stop_reason" => stop_reason_for(status, verification),
          "failure_signature" => blockers.empty? ? nil : Digest::SHA256.hexdigest(blockers.join("\n")),
          "blocking_issues" => blockers,
          "pending_approvals" => Array(verification["pending_approvals"]),
          "repair_hints" => Array(verification["repair_hints"]),
          "recommended_next_actions" => recommended_next_actions(status, verification),
          "reflected_at" => Time.now.utc.iso8601
        }
      end

      private

      def stop_reason_for(status, verification)
        return "runtime_blocked" if status == "blocked"
        return "validation_failed" if status == "failed_validation"
        return "complete" if status == "complete"
        return "approval_required" if Array(verification["pending_approvals"]).any?

        "plan_only_or_partial"
      end

      def recommended_next_actions(status, verification)
        return ["resolve blocking issues, then rerun aiweb agent"] if status == "blocked"
        return Array(verification["repair_hints"]) if status == "failed_validation" && Array(verification["repair_hints"]).any?
        return Array(verification["pending_approvals"]).map { |tool| "rerun with --approved to execute #{tool}" } if Array(verification["pending_approvals"]).any?
        return ["review final-report.json and continue with verify-loop if more runtime evidence is needed"] if status == "partial_not_complete"

        []
      end
    end
  end
end
