# frozen_string_literal: true

module Aiweb
  module SelfImprovement
    class CanaryPromoter
      def self.status
        { "schema_version" => 1, "status" => "blocked_without_eval_and_hitl", "auto_promote" => false }
      end
    end
  end
end
