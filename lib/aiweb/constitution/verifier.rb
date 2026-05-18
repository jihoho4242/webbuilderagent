# frozen_string_literal: true

require_relative "loader"

module Aiweb
  module Constitution
    class Verifier
      REQUIRED_CRITICAL_RULES = %w[
        NO_SELF_PERMISSION_ESCALATION
        NO_POLICY_KERNEL_BYPASS
        NO_HITL_DOWNGRADE
        NO_EVAL_THRESHOLD_DOWNGRADE
        NO_SECRET_READ
      ].freeze

      def initialize(loader = Loader.new)
        @loader = loader
      end

      def verify(expected_hash: nil)
        data = @loader.load
        blockers = []
        blockers << "constitution immutable must be true" unless data["immutable"] == true
        rule_ids = Array(data["rules"]).map { |rule| rule["id"].to_s }
        missing = REQUIRED_CRITICAL_RULES - rule_ids
        blockers << "constitution missing critical rules: #{missing.join(", ")}" unless missing.empty?
        weak = Array(data["rules"]).select { |rule| REQUIRED_CRITICAL_RULES.include?(rule["id"].to_s) && rule["severity"].to_s != "critical" }
        blockers << "constitution critical rules must have severity=critical: #{weak.map { |rule| rule["id"] }.join(", ")}" unless weak.empty?
        hash = @loader.content_hash
        blockers << "constitution hash mismatch: expected #{expected_hash}, got #{hash}" if expected_hash && expected_hash != hash
        change = data.fetch("change_process", {})
        %w[requires_signed_pr requires_security_owner requires_two_person_review_for_l4_l5].each do |key|
          blockers << "constitution change_process.#{key} must be true" unless change[key] == true
        end
        @loader.evidence.merge(
          "status" => blockers.empty? ? "passed" : "blocked",
          "blocking_issues" => blockers
        )
      rescue StandardError => e
        {
          "schema_version" => 1,
          "status" => "blocked",
          "blocking_issues" => ["constitution verification failed: #{e.class}: #{e.message}"]
        }
      end
    end
  end
end
