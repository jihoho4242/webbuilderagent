# frozen_string_literal: true

require "time"

require_relative "artifact"

module Aiweb
  module Approval
    class Verifier
      def verify(artifact:, decision_packet:, action_diff:, args:, evidence:, now: Time.now.utc)
        blockers = []
        blockers << "approval schema_version must be 2" unless artifact["schema_version"] == 2
        blockers << "approval is expired" if Time.parse(artifact.fetch("expires_at")) <= now
        blockers << "approval is single-use and already consumed" if artifact["single_use"] == true && !artifact["consumed_at"].nil?
        blockers << "approval does not include decision packet" unless Array(artifact["decision_packet_ids"]).include?(decision_packet.fetch("packet_id"))
        blockers << "approval action_diff_hash mismatch" unless artifact["action_diff_hash"] == Artifact.sha(action_diff)
        blockers << "approval args_hash mismatch" unless artifact["args_hash"] == Artifact.sha(args)
        blockers << "approval evidence_hash mismatch" unless artifact["evidence_hash"] == Artifact.sha(evidence)
        if %w[L4 L5].include?(artifact["risk_tier"].to_s) && artifact["second_reviewer_id"].to_s.strip.empty?
          blockers << "L4/L5 approval requires second_reviewer_id"
        end
        {
          "schema_version" => 1,
          "status" => blockers.empty? ? "passed" : "blocked",
          "approval_id" => artifact["approval_id"],
          "approval_hash" => artifact["approval_hash"],
          "second_reviewer_id" => artifact["second_reviewer_id"],
          "blocking_issues" => blockers
        }
      rescue StandardError => e
        { "schema_version" => 1, "status" => "blocked", "blocking_issues" => ["approval verification failed: #{e.class}: #{e.message}"] }
      end
    end
  end
end
