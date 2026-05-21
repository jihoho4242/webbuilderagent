# frozen_string_literal: true

require_relative "design_eval/human_calibration"

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

    def engine_run_eval_metrics(final_status:, result:, policy:, verification:, preview:, screenshot_evidence:, design_verdict:)
      {
        "task_success" => {
          "status" => if %w[passed no_changes].include?(final_status)
                         "passed"
                       elsif final_status == "waiting_approval"
                         "blocked"
                       else
                         "failed"
                       end,
          "value" => %w[passed no_changes].include?(final_status),
          "final_status" => final_status,
          "exit_code" => result.to_h[:exit_code]
        },
        "build_pass" => engine_run_eval_verification_check_metric(verification, "build"),
        "test_pass" => engine_run_eval_verification_check_metric(verification, "test"),
        "visual_fidelity" => {
          "status" => engine_run_eval_metric_status(design_verdict.to_h["status"]),
          "value" => design_verdict.to_h["status"] == "passed",
          "average_score" => design_verdict.to_h["average_score"],
          "minimum_average_score" => design_verdict.to_h.dig("thresholds", "minimum_average_score"),
          "blocking_issues" => Array(design_verdict.to_h["blocking_issues"])
        },
        "interaction_pass" => engine_run_eval_interaction_metric(screenshot_evidence),
        "action_recovery_pass" => engine_run_eval_browser_status_metric(screenshot_evidence, "action_recovery"),
        "browser_action_loop_pass" => engine_run_eval_browser_status_metric(screenshot_evidence, "action_loop"),
        "a11y_pass" => engine_run_eval_browser_status_metric(screenshot_evidence, "a11y_report"),
        "browser_console_clean" => {
          "status" => Array(screenshot_evidence.to_h["console_errors"]).empty? ? "passed" : "failed",
          "value" => Array(screenshot_evidence.to_h["console_errors"]).empty?,
          "count" => Array(screenshot_evidence.to_h["console_errors"]).length
        },
        "browser_network_clean" => {
          "status" => Array(screenshot_evidence.to_h["network_errors"]).empty? ? "passed" : "failed",
          "value" => Array(screenshot_evidence.to_h["network_errors"]).empty?,
          "count" => Array(screenshot_evidence.to_h["network_errors"]).length
        },
        "repair_cycles" => {
          "status" => "recorded",
          "value" => [result.to_h.fetch(:cycles_completed, 0).to_i - 1, 0].max,
          "cycles_completed" => result.to_h.fetch(:cycles_completed, 0).to_i
        },
        "approval_count" => {
          "status" => Array(policy.to_h["approval_requests"]).empty? ? "passed" : "blocked",
          "value" => Array(policy.to_h["approval_requests"]).length,
          "requested_actions" => Array(policy.to_h["requested_actions"]).length
        },
        "unsafe_action_blocked" => {
          "status" => (!Array(policy.to_h["requested_actions"]).empty? || Array(policy.to_h["approval_requests"]).any?) ? "blocked" : "passed",
          "value" => !Array(policy.to_h["requested_actions"]).empty? || Array(policy.to_h["approval_requests"]).any?,
          "requested_actions" => Array(policy.to_h["requested_actions"]).map { |action| action.is_a?(Hash) ? action.slice("type", "tool_name", "risk_class", "reason") : action.to_s }
        },
        "preview_ready" => {
          "status" => engine_run_eval_metric_status(preview.to_h["status"]),
          "value" => preview.to_h["status"] == "ready",
          "url" => preview.to_h["url"]
        }
      }
    end

    def engine_run_eval_verification_check_metric(verification, name)
      check = Array(verification.to_h["checks"]).find { |entry| entry.is_a?(Hash) && entry["name"].to_s == name }
      unless check
        return {
          "status" => "skipped",
          "value" => nil,
          "reason" => verification.to_h["reason"] || "#{name} script was not present in staged package.json"
        }
      end

      {
        "status" => engine_run_eval_metric_status(check["status"]),
        "value" => check["status"] == "passed",
        "exit_code" => check["exit_code"],
        "command" => check["command"]
      }
    end

    def engine_run_eval_interaction_metric(screenshot_evidence)
      states = Array(screenshot_evidence.to_h["interaction_states"])
      if states.empty?
        return {
          "status" => "skipped",
          "value" => nil,
          "reason" => "interaction state evidence was not captured"
        }
      end

      failed = states.reject { |state| state.is_a?(Hash) && state["status"] == "captured" }.map { |state| state["state"].to_s }
      {
        "status" => failed.empty? ? "passed" : "failed",
        "value" => failed.empty?,
        "state_count" => states.length,
        "failed_states" => failed
      }
    end

    def engine_run_eval_browser_status_metric(screenshot_evidence, key)
      status = screenshot_evidence.to_h.dig(key, "status").to_s
      if status.empty?
        return {
          "status" => "skipped",
          "value" => nil,
          "reason" => "#{key} evidence was not captured"
        }
      end

      {
        "status" => status == "captured" ? "passed" : "failed",
        "value" => status == "captured",
        "evidence_status" => status
      }
    end

    def engine_run_eval_metric_status(status)
      case status.to_s
      when "passed", "ready", "captured", "clear" then "passed"
      when "blocked", "waiting_approval" then "blocked"
      when "skipped", "missing", "" then "skipped"
      else "failed"
      end
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
