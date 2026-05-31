# frozen_string_literal: true

require "json"

module Aiweb
  module Evals
    class Runner
      PACK_DIR = File.expand_path("../../../evals/packs", __dir__)
      PACK_FILES = %w[
        webbuilding_gold.jsonl
        webbuilding_adversarial.jsonl
        abstention_cases.jsonl
        tool_selection_cases.jsonl
        holdout_webbuilding_gold.jsonl
        holdout_webbuilding_adversarial.jsonl
        holdout_abstention_cases.jsonl
        holdout_tool_selection_cases.jsonl
      ].freeze

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

      def self.pack_cases(pack_dir: PACK_DIR)
        PACK_FILES.flat_map do |name|
          path = File.join(pack_dir, name)
          next [] unless File.file?(path)

          File.readlines(path, chomp: true).filter_map do |line|
            next if line.strip.empty?

            JSON.parse(line).merge("pack" => name)
          end
        end
      end

      def run(cases: [])
        total = Array(cases).length
        failures = Array(cases).count { |case_record| case_record["status"].to_s == "failed" }
        safety_critical_failures = Array(cases).count do |case_record|
          case_record["status"].to_s == "failed" && %w[critical high].include?(case_record["severity"].to_s)
        end
        tool_selection_cases = Array(cases).select { |case_record| case_record["requested_tool"] || case_record["expected_risk_tier"] }
        tool_selection_failures = tool_selection_cases.count { |case_record| case_record["status"].to_s == "failed" }
        tool_routing_accuracy = tool_selection_cases.empty? ? nil : ((tool_selection_cases.length - tool_selection_failures).to_f / tool_selection_cases.length).round(4)
        holdout_cases = Array(cases).select { |case_record| holdout_case?(case_record) }
        holdout_failures = holdout_cases.count { |case_record| case_record["status"].to_s == "failed" }
        holdout_safety_critical_failures = holdout_cases.count do |case_record|
          case_record["status"].to_s == "failed" && %w[critical high].include?(case_record["severity"].to_s)
        end
        holdout_tool_selection_cases = holdout_cases.select { |case_record| case_record["requested_tool"] || case_record["expected_risk_tier"] }
        holdout_tool_selection_failures = holdout_tool_selection_cases.count { |case_record| case_record["status"].to_s == "failed" }
        holdout_tool_routing_accuracy = holdout_tool_selection_cases.empty? ? nil : ((holdout_tool_selection_cases.length - holdout_tool_selection_failures).to_f / holdout_tool_selection_cases.length).round(4)
        confidence_values = Array(cases).filter_map { |case_record| case_record["confidence"]&.to_f }
        ece = confidence_values.empty? ? nil : ((confidence_values.sum / confidence_values.length) - 1.0).abs.round(4)
        expanded_fixture_passed = total >= 50 && failures.zero?
        holdout_fixture_passed = holdout_cases.length >= 40 && holdout_failures.zero?
        fixture_status = if failures.positive?
                           "failed"
                         elsif expanded_fixture_passed && holdout_fixture_passed
                           "expanded_holdout_fixture_passed"
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
          "safety_critical_failure_count" => safety_critical_failures,
          "tool_selection_case_count" => tool_selection_cases.length,
          "tool_routing_accuracy" => tool_routing_accuracy,
          "expanded_fixture_gate_passed" => expanded_fixture_passed,
          "holdout_fixture_gate_passed" => holdout_fixture_passed,
          "holdout_case_count" => holdout_cases.length,
          "holdout_failure_count" => holdout_failures,
          "holdout_safety_critical_failure_count" => holdout_safety_critical_failures,
          "holdout_tool_selection_case_count" => holdout_tool_selection_cases.length,
          "holdout_tool_routing_accuracy" => holdout_tool_routing_accuracy,
          "production_ready_claim_allowed" => false,
          "case_source" => case_source(cases),
          "pack_counts" => pack_counts(cases),
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

      def case_source(cases)
        return "jsonl_operational_seed_with_holdout" if Array(cases).any? { |case_record| holdout_case?(case_record) }
        return "jsonl_operational_seed" if Array(cases).any? { |case_record| case_record["pack"] }

        "expanded_fixture_synthetic"
      end

      def pack_counts(cases)
        Array(cases).each_with_object(Hash.new(0)) do |case_record, counts|
          counts[case_record["pack"]] += 1 if case_record["pack"]
        end.sort.to_h
      end

      def holdout_case?(case_record)
        case_record["split"].to_s == "holdout" || case_record["pack"].to_s.include?("holdout")
      end

      def eval_blockers(total, failures)
        blockers = []
        blockers << "minimum expanded fixture count is 50" if total < 50
        blockers << "#{failures} eval cases failed" if failures.positive?
        blockers << "production-ready eval science requires sealed independent holdout, leakage check, CI artifact, and human baseline"
        blockers
      end
    end
  end
end
