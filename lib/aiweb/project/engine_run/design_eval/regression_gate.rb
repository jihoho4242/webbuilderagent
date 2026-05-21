# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

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
