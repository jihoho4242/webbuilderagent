# frozen_string_literal: true

module Aiweb
  module SelfImprovement
    class PatchSandbox
      def self.status
        {
          "schema_version" => 1,
          "status" => "sandbox_only",
          "production_gate_status" => "blocked",
          "production_patch_allowed" => false,
          "production_ready_claim_allowed" => false
        }
      end
    end
  end
end
