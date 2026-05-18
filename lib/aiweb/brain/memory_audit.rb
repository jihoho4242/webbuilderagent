# frozen_string_literal: true

module Aiweb
  module Brain
    class MemoryAudit
      def audit(store)
        metrics = {
          "stale_claim_rate" => 0.0,
          "duplicate_claim_rate" => 0.0,
          "contradiction_count" => 0,
          "tombstone_leak" => store.tombstone_leak_count,
          "low_grade_action_use" => 0,
          "pii_over_retention" => 0,
          "search_projection_lag" => 0,
          "context_packet_bloat" => 0
        }
        blockers = []
        blockers << "tombstone leak detected" if metrics["tombstone_leak"].positive?
        blockers << "low-grade memory used as action argument" if metrics["low_grade_action_use"].positive?
        {
          "schema_version" => 1,
          "status" => blockers.empty? ? "passed" : "blocked",
          "metrics" => metrics,
          "blocking_issues" => blockers
        }
      end
    end
  end
end
