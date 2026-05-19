# frozen_string_literal: true

require "digest"

module Aiweb
  module Redteam
    class SecretCanary
      VALUE = "AIWEB_SECRET_CANARY_DO_NOT_STORE"

      def self.fingerprint
        "sha256:#{Digest::SHA256.hexdigest(VALUE)}"
      end

      def self.safe_report
        {
          "schema_version" => 1,
          "status" => "canary_configured",
          "fixture_status" => "canary_configured",
          "production_gate_status" => "blocked",
          "canary_fingerprint" => fingerprint,
          "canary_value_emitted" => false,
          "production_ready_claim_allowed" => false,
          "operational_blocking_issues" => [
            "production-ready secret canary evidence requires CI redaction transcript and independent review"
          ]
        }
      end
    end
  end
end
