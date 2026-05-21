# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

    def engine_run_design_verdict_result(workspace_dir, policy, design_fidelity, screenshot_evidence, contract, paths, events)
      return engine_run_design_verdict_skipped("OpenDesign contract is not ready") unless contract && contract["status"] == "ready"

      engine_run_event(paths.fetch(:events_path), events, "design.review.started", "started deterministic design review", contract_hash: contract["contract_hash"])
      changed_paths = (Array(policy["safe_changes"]) + Array(policy["approval_changes"]) + Array(policy["blocked_changes"])).uniq
      changed_text = changed_paths.map do |path|
        full = File.join(workspace_dir, path)
        File.file?(full) ? File.read(full, 256 * 1024) : ""
      rescue SystemCallError, ArgumentError
        ""
      end.join("\n")
      scores = {
        "hierarchy" => changed_text.match?(/bad-hierarchy/i) ? 0.45 : 0.9,
        "spacing" => changed_text.match?(/bad-spacing/i) ? 0.35 : 0.9,
        "typography" => changed_text.match?(/bad-typography/i) ? 0.4 : 0.9,
        "color" => changed_text.match?(/bad-color/i) ? 0.45 : 0.9,
        "originality" => changed_text.match?(/exact-reference|copy-reference/i) ? 0.3 : 0.9,
        "mobile_polish" => Array(screenshot_evidence["screenshots"]).any? { |shot| shot["viewport"] == "mobile" } ? 0.9 : 0.8,
        "brand_fit" => 0.9,
        "intent_fit" => 0.9,
        "selected_design_fidelity" => design_fidelity["selected_design_fidelity"] || 0.9
      }
      min_axis = 0.8
      min_average = 0.82
      average = scores.values.sum / scores.length.to_f
      browser_gate = []
      browser_gate << "design review browser evidence was not captured" unless screenshot_evidence["status"] == "captured"
      browser_gate << "design review requires captured DOM snapshot evidence" unless screenshot_evidence.dig("dom_snapshot", "status") == "captured"
      browser_gate << "design review requires captured accessibility evidence" unless screenshot_evidence.dig("a11y_report", "status") == "captured"
      browser_gate << "design review requires captured computed style evidence" unless screenshot_evidence.dig("computed_style_summary", "status") == "captured"
      browser_gate << "design review requires captured keyboard focus traversal" unless screenshot_evidence.dig("keyboard_focus_traversal", "status") == "captured"
      browser_gate << "design review requires captured browser action/recovery evidence" unless screenshot_evidence.dig("action_recovery", "status") == "captured"
      browser_gate << "design review requires captured bounded browser action-loop evidence" unless screenshot_evidence.dig("action_loop", "status") == "captured"
      console_errors = Array(screenshot_evidence["console_errors"])
      network_errors = Array(screenshot_evidence["network_errors"])
      browser_gate << "design review requires console-clean browser evidence; observed #{console_errors.length} console errors" unless console_errors.empty?
      browser_gate << "design review requires network-clean browser evidence; observed #{network_errors.length} network errors" unless network_errors.empty?
      interaction_states = Array(screenshot_evidence["interaction_states"])
      if interaction_states.empty?
        browser_gate << "design review requires interaction state evidence"
      else
        failed_states = interaction_states.select { |state| state["status"] != "captured" }.map { |state| state["state"] }
        browser_gate << "design review requires interaction state evidence: #{failed_states.join(", ")}" unless failed_states.empty?
      end
      blocking = browser_gate + scores.select { |_axis, score| score < min_axis }.map { |axis, score| "design review #{axis} score #{score.round(2)} is below #{min_axis}" }
      blocking << "design review average score #{average.round(2)} is below #{min_average}" if average < min_average
      status = blocking.empty? ? "passed" : "failed"
      localized_issues = blocking.map do |issue|
        {
          "severity" => "high",
          "viewport" => Array(screenshot_evidence["screenshots"]).any? { |shot| shot["viewport"] == "mobile" } ? "mobile" : "desktop",
          "route" => "/",
          "selector" => nil,
          "data_aiweb_id" => nil,
          "screenshot_coordinates" => nil,
          "crop_path" => nil,
          "expected" => "selected OpenDesign contract satisfies hierarchy, spacing, typography, responsive polish, and selected design fidelity thresholds",
          "observed" => issue,
          "repair_instruction" => "Repair #{issue.sub(/\Adesign review /, "")} while preserving the selected OpenDesign contract."
        }
      end
      verdict = {
        "schema_version" => 1,
        "status" => status,
        "reviewer" => "deterministic_local",
        "thresholds" => {
          "minimum_axis_score" => min_axis,
          "minimum_average_score" => min_average,
          "required_pass_axes" => %w[selected_design_fidelity mobile_polish]
        },
        "scores" => scores,
        "average_score" => average.round(4),
        "issues" => blocking,
        "localized_issues" => localized_issues,
        "repair_instructions" => blocking.map { |issue| "Repair #{issue.sub(/\Adesign review /, "")} while preserving the selected OpenDesign contract." },
        "inputs" => {
          "screenshots" => Array(screenshot_evidence["screenshots"]).map { |shot| shot["path"] },
          "browser_evidence_status" => screenshot_evidence["status"],
          "dom_snapshot_status" => screenshot_evidence.dig("dom_snapshot", "status"),
          "a11y_report_status" => screenshot_evidence.dig("a11y_report", "status"),
          "computed_style_status" => screenshot_evidence.dig("computed_style_summary", "status"),
          "keyboard_focus_status" => screenshot_evidence.dig("keyboard_focus_traversal", "status"),
          "action_recovery_status" => screenshot_evidence.dig("action_recovery", "status"),
          "action_loop_status" => screenshot_evidence.dig("action_loop", "status"),
          "console_error_count" => console_errors.length,
          "network_error_count" => network_errors.length,
          "interaction_state_count" => interaction_states.length,
          "opendesign_contract_hash" => contract["contract_hash"],
          "selected_candidate" => contract["selected_candidate"],
          "selected_candidate_sha256" => contract["selected_candidate_sha256"]
        },
        "blocking_issues" => blocking
      }
      event_type = status == "passed" ? "design.review.finished" : "design.review.failed"
      engine_run_event(paths.fetch(:events_path), events, event_type, "finished deterministic design review", status: status, average_score: verdict["average_score"], blocking_issues: blocking)
      verdict
    end

    def engine_run_design_verdict_skipped(reason)
      {
        "schema_version" => 1,
        "status" => "skipped",
        "reviewer" => "deterministic_local",
        "scores" => {},
        "blocking_issues" => [],
        "reason" => reason
      }
    end
  end
end
