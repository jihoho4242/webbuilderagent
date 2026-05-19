# frozen_string_literal: true

module Aiweb
  module SelfImprovement
    class CanaryPromoter
      def self.status
        {
          "schema_version" => 1,
          "status" => "blocked_without_eval_and_hitl",
          "production_gate_status" => "blocked",
          "auto_promote" => false,
          "production_ready_claim_allowed" => false
        }
      end
    end
  end
end
