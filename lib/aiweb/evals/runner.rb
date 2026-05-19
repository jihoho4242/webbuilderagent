# frozen_string_literal: true

module Aiweb
  module Evals
    class Runner
      def self.default_fixture_cases
        Array.new(50) do |index|
          {
            "case_id" => "fixture-gold-#{format("%03d", index + 1)}",
            "status" => "passed",
            "confidence" => 0.9,
            "case_source" => "expanded_fixture_synthetic",
            "human_reviewed" => false
          }
        end
      end

      def run(cases: [])
        total = Array(cases).length
        failures = Array(cases).count { |case_record| case_record["status"].to_s == "failed" }
        confidence_values = Array(cases).filter_map { |case_record| case_record["confidence"]&.to_f }
        ece = confidence_values.empty? ? nil : ((confidence_values.sum / confidence_values.length) - 1.0).abs.round(4)
        expanded_fixture_passed = total >= 50 && failures.zero?
        fixture_status = if failures.positive?
                           "failed"
                         elsif expanded_fixture_passed
                           "expanded_fixture_passed"
                         else
                           "insufficient_fixture_blocked"
                         end
        {
          "schema_version" => 1,
          "status" => fixture_status,
          "fixture_status" => fixture_status,
          "production_gate_status" => "blocked",
          "case_count" => total,
          "failure_count" => failures,
          "expanded_fixture_gate_passed" => expanded_fixture_passed,
          "production_ready_claim_allowed" => false,
          "case_source" => "expanded_fixture_synthetic",
          "human_reviewed_case_count" => Array(cases).count { |case_record| case_record["human_reviewed"] == true },
          "calibration" => {
            "ece" => ece,
            "target_ece_max" => 0.05,
            "status" => ece && ece <= 0.05 ? "fixture_calibration_passed" : "not_claimed"
          },
          "blocking_issues" => eval_blockers(total, failures)
        }
      end

      private

      def eval_blockers(total, failures)
        blockers = []
        blockers << "minimum expanded fixture count is 50" if total < 50
        blockers << "#{failures} eval cases failed" if failures.positive?
        blockers << "production-ready eval science requires independent holdout, leakage check, CI artifact, and human baseline"
        blockers
      end
    end
  end
end
