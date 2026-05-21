# frozen_string_literal: true

require_relative "design_eval/human_calibration"
require_relative "design_eval/metrics"
require_relative "design_eval/verdict"

module Aiweb
  module ProjectEngineRun
    private

    def engine_run_design_fixture(contract, design_verdict, screenshot_evidence, paths)
      selected = contract.to_h
      target_brief_path = selected.dig("artifacts", "selected_design", "path") || ".ai-web/design-candidates/selected.md"
      golden_path = selected["selected_candidate_path"]
      baseline = {
        "status" => design_verdict["status"],
        "scores" => design_verdict["scores"],
        "average_score" => design_verdict["average_score"],
        "blocking_issues" => Array(design_verdict["blocking_issues"])
      }
      basis = {
        "contract_hash" => selected["contract_hash"],
        "selected_candidate_sha256" => selected["selected_candidate_sha256"],
        "baseline" => baseline
      }
      {
        "schema_version" => 1,
        "status" => selected["status"] == "ready" ? "ready" : "missing",
        "fixture_id" => "design-fixture-#{Digest::SHA256.hexdigest(json_generate(basis))[0, 16]}",
        "recorded_at" => now,
        "human_approved_target_brief" => {
          "path" => target_brief_path,
          "excerpt" => engine_run_fixture_excerpt(target_brief_path)
        },
        "golden_reference" => {
          "selected_candidate" => selected["selected_candidate"],
          "path" => golden_path,
          "sha256" => selected["selected_candidate_sha256"],
          "excerpt" => engine_run_fixture_excerpt(golden_path)
        },
        "viewport_expected_outcomes" => %w[desktop tablet mobile].map do |viewport|
          {
            "viewport" => viewport,
            "expected" => "match selected OpenDesign first-view hierarchy, typography, spacing, contrast, component state, and route intent",
            "evidence_required" => %w[screenshot dom_snapshot a11y_report computed_style interaction_states keyboard_focus action_recovery action_loop]
          }
        end,
        "allowed_variance_thresholds" => design_verdict.fetch("thresholds", {}),
        "stored_baseline_verdict" => baseline,
        "evidence_refs" => {
          "browser_evidence_path" => relative(paths.fetch(:screenshot_evidence_path)),
          "design_verdict_path" => relative(paths.fetch(:design_verdict_path)),
          "opendesign_contract_path" => relative(paths.fetch(:opendesign_contract_path)),
          "screenshot_count" => Array(screenshot_evidence["screenshots"]).length
        }
      }
    end

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

    def engine_run_eval_regression_gate(design_required:, final_status:, metrics:, design_verdict:, screenshot_evidence:, human_calibration:)
      blockers = []
      if design_required
        blockers << "eval benchmark requires task success before copy-back" unless %w[passed no_changes waiting_approval].include?(final_status)
        blockers << "eval benchmark requires captured browser evidence" unless screenshot_evidence.to_h["status"] == "captured"
        blockers << "eval benchmark requires passing deterministic design verdict" unless design_verdict.to_h["status"] == "passed"
        blockers << "eval benchmark requires passing interaction evidence" unless metrics.dig("interaction_pass", "status") == "passed"
        blockers << "eval benchmark requires passing browser action/recovery evidence" unless metrics.dig("action_recovery_pass", "status") == "passed"
        blockers << "eval benchmark requires passing bounded browser action-loop evidence" unless metrics.dig("browser_action_loop_pass", "status") == "passed"
        blockers << "eval benchmark requires passing accessibility evidence" unless metrics.dig("a11y_pass", "status") == "passed"
        blockers << "eval benchmark requires console-clean browser evidence" unless metrics.dig("browser_console_clean", "status") == "passed"
        blockers << "eval benchmark requires network-clean browser evidence" unless metrics.dig("browser_network_clean", "status") == "passed"
      end
      %w[build_pass test_pass].each do |metric|
        blockers << "eval benchmark #{metric} failed" if metrics.dig(metric, "status") == "failed"
      end
      baseline_average = human_calibration.dig("baseline_source", "average_score")
      current_average = design_verdict.to_h["average_score"]
      if human_calibration.fetch("status") == "calibrated" && baseline_average.is_a?(Numeric) && current_average.is_a?(Numeric) && current_average < baseline_average
        blockers << "eval benchmark current average score #{current_average} is below calibrated human baseline #{baseline_average}"
      end

      {
        "status" => if blockers.empty?
                       design_required ? "passed" : "skipped"
                     else
                       "failed"
                     end,
        "enforced" => design_required,
        "mode" => human_calibration.fetch("status") == "calibrated" ? "human_calibrated_thresholds" : "evidence_gate_only_no_human_baseline",
        "human_calibration_status" => human_calibration.fetch("status"),
        "checked_metrics" => %w[task_success build_pass test_pass visual_fidelity interaction_pass action_recovery_pass browser_action_loop_pass a11y_pass browser_console_clean browser_network_clean approval_count unsafe_action_blocked],
        "baseline_average_score" => baseline_average || current_average,
        "current_average_score" => current_average,
        "blocking_issues" => blockers.uniq
      }
    end

  end
end
