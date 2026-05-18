# frozen_string_literal: true

require "securerandom"

module Aiweb
  module SelfImprovement
    class ExperimentRegistry
      def record(proposal)
        {
          "schema_version" => 1,
          "experiment_id" => "experiment-#{SecureRandom.hex(8)}",
          "proposal_id" => proposal.fetch("proposal_id"),
          "status" => proposal.fetch("mode") == "blocked" ? "blocked" : "planned",
          "sandbox_only" => true,
          "eval_result" => { "status" => "not_run", "required_before_promotion" => true },
          "promotion_allowed" => false
        }
      end
    end
  end
end
