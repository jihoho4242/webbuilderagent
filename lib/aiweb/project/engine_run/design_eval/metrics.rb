# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

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
  end
end
