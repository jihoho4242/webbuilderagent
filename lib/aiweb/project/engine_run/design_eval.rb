# frozen_string_literal: true

require_relative "design_eval/human_calibration"
require_relative "design_eval/metrics"
require_relative "design_eval/verdict"
require_relative "design_eval/fixture"
require_relative "design_eval/regression_gate"

module Aiweb
  module ProjectEngineRun
    private

    def engine_run_eval_benchmark(final_status:, result:, policy:, verification:, preview:, screenshot_evidence:, design_verdict:, design_fixture:, opendesign_contract:, paths:, events:)
      design_required = opendesign_contract.to_h["status"] == "ready"
      human_calibration = engine_run_eval_human_calibration(design_fixture)
      metrics = engine_run_eval_metrics(
        final_status: final_status,
        result: result,
        policy: policy,
        verification: verification,
        preview: preview,
        screenshot_evidence: screenshot_evidence,
        design_verdict: design_verdict
      )
      current_scores = {
        "visual_fidelity" => design_verdict.to_h["average_score"],
        "selected_design_fidelity" => design_verdict.to_h.dig("scores", "selected_design_fidelity"),
        "hierarchy" => design_verdict.to_h.dig("scores", "hierarchy"),
        "spacing" => design_verdict.to_h.dig("scores", "spacing"),
        "typography" => design_verdict.to_h.dig("scores", "typography"),
        "color" => design_verdict.to_h.dig("scores", "color"),
        "mobile_polish" => design_verdict.to_h.dig("scores", "mobile_polish")
      }
      regression_gate = engine_run_eval_regression_gate(
        design_required: design_required,
        final_status: final_status,
        metrics: metrics,
        design_verdict: design_verdict,
        screenshot_evidence: screenshot_evidence,
        human_calibration: human_calibration
      )
      status = if regression_gate["status"] == "failed"
                 "failed"
               elsif final_status == "waiting_approval"
                 "blocked"
               elsif design_required
                 "passed"
               else
                 "skipped"
               end
      basis = {
        "run_id" => paths.fetch(:run_id),
        "fixture_id" => design_fixture.to_h["fixture_id"],
        "status" => status,
        "current_scores" => current_scores,
        "regression_gate" => regression_gate
      }
      {
        "schema_version" => 1,
        "status" => status,
        "benchmark_id" => "eval-benchmark-#{Digest::SHA256.hexdigest(json_generate(basis))[0, 16]}",
        "recorded_at" => now,
        "fixture_id" => design_fixture.to_h["fixture_id"],
        "human_calibration_status" => human_calibration.fetch("status"),
        "baseline_source" => human_calibration.fetch("baseline_source"),
        "thresholds" => {
          "task_success_required" => true,
          "build_pass_required_when_script_exists" => true,
          "test_pass_required_when_script_exists" => true,
          "visual_fidelity_min_average" => design_verdict.to_h.dig("thresholds", "minimum_average_score"),
          "visual_fidelity_min_axis" => design_verdict.to_h.dig("thresholds", "minimum_axis_score"),
          "browser_evidence_required_when_design_ready" => true,
          "human_calibration_required_for_claiming_human_grade_eval" => true
        },
        "viewport_matrix" => engine_run_eval_viewport_matrix(design_fixture, screenshot_evidence),
        "metrics" => metrics,
        "current_scores" => current_scores,
        "regression_gate" => regression_gate,
        "repair_cycles" => [result.to_h.fetch(:cycles_completed, 0).to_i - 1, 0].max,
        "approval_count" => Array(policy.to_h["approval_requests"]).length,
        "unsafe_action_blocked" => !Array(policy.to_h["requested_actions"]).empty? || Array(policy.to_h["approval_requests"]).any?,
        "time_to_pass" => engine_run_eval_time_to_pass(final_status, events),
        "token_tool_cost" => engine_run_eval_token_tool_cost(events),
        "evidence_refs" => {
          "verification_path" => relative(paths.fetch(:verification_path)),
          "preview_path" => relative(paths.fetch(:preview_path)),
          "browser_evidence_path" => relative(paths.fetch(:screenshot_evidence_path)),
          "design_verdict_path" => relative(paths.fetch(:design_verdict_path)),
          "design_fixture_path" => relative(paths.fetch(:design_fixture_path)),
          "opendesign_contract_path" => relative(paths.fetch(:opendesign_contract_path))
        },
        "blocking_issues" => regression_gate.fetch("blocking_issues")
      }
    end

    def engine_run_eval_benchmark_blocks?(eval_benchmark)
      eval_benchmark.to_h.dig("regression_gate", "enforced") == true &&
        eval_benchmark.to_h.dig("regression_gate", "status") == "failed"
    end

  end
end
