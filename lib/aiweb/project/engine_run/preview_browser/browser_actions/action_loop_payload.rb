# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    def engine_run_browser_action_loop_probes(captures)
      captures.map do |capture|
        viewport = capture["viewport"].to_s
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        actions = Array(recovery["actions"]).select { |action| action.is_a?(Hash) }
        direct_recovery_steps = Array(recovery["recovery_steps"])
        blocking_issues = Array(recovery["blocking_issues"]).compact.map(&:to_s)
        step_count = actions.sum { |action| Array(action["actions"]).length }
        recovery_step_count = direct_recovery_steps.length + actions.sum { |action| Array(action["recovery"]).length }
        blocked_step_count = Array(recovery["external_requests_blocked"]).length
        steps = actions.first(5).map do |action|
          {
            "target_index" => action["index"],
            "selector" => action["selector"],
            "text_role" => action["text_role"],
            "data_aiweb_id" => action["data_aiweb_id"],
            "planned_actions" => Array(action["actions"]).map do |step|
              step = step.is_a?(Hash) ? step : { "name" => step.to_s }
              step.slice("name", "status", "reason")
            end,
            "recovery_actions" => Array(action["recovery"]).map do |step|
              step = step.is_a?(Hash) ? step : { "name" => step.to_s }
              step.slice("name", "action", "status", "reason")
            end
          }.compact
        end
        status = recovery["status"] == "captured" &&
          blocking_issues.empty? &&
          step_count >= 2 &&
          recovery_step_count.positive? ? "captured" : "failed"
        {
          "probe_id" => "safe-local-ui-probe-#{viewport}",
          "viewport" => viewport,
          "goal" => "probe reversible local UI interactions and recover preview state",
          "policy" => {
            "network" => "localhost-only",
            "reversible_only" => true,
            "external_navigation_blocked" => true,
            "form_submission_allowed" => false
          },
          "target_count" => actions.length,
          "steps" => steps,
          "status" => status,
          "step_count" => step_count,
          "recovery_step_count" => recovery_step_count,
          "blocked_step_count" => blocked_step_count,
          "blocking_issues" => blocking_issues
        }
      end
    end

    def engine_run_browser_action_loop_multi_step_evidence(probe_results:, executed_steps:, recovery_steps:, blocked_steps:)
      results = Array(probe_results)
      {
        "probe_count" => results.length,
        "multi_step_sequences_observed" => results.any? { |probe| probe["step_count"].to_i >= 2 } || Array(executed_steps).length >= 2,
        "all_probes_recovered" => results.any? && results.all? { |probe| probe["status"] == "captured" && probe["recovery_step_count"].to_i.positive? },
        "total_executed_step_count" => Array(executed_steps).length,
        "total_recovery_step_count" => Array(recovery_steps).length,
        "total_blocked_step_count" => Array(blocked_steps).length,
        "policy" => {
          "network" => "localhost-only",
          "reversible_only" => true,
          "external_navigation_blocked" => true,
          "form_submission_allowed" => false
        }
      }
    end

    def engine_run_browser_action_loop_envelope(status:, viewports:, planned_steps:, executed_steps:, recovery_steps:, blocked_steps:, blocking_issues:, reason: nil, probe_plan: [], probe_results: [], multi_step_evidence: nil)
      probe_results = Array(probe_results)
      multi_step_evidence ||= engine_run_browser_action_loop_multi_step_evidence(
        probe_results: probe_results,
        executed_steps: executed_steps,
        recovery_steps: recovery_steps,
        blocked_steps: blocked_steps
      )
      {
        "schema_version" => 1,
        "status" => status,
        "required" => true,
        "loop_type" => "bounded_safe_local_browser_probe",
        "goal_source" => "selected_design_fixture_and_browser_evidence",
        "autonomy_level" => "deterministic_probe_not_autonomous_planning",
        "probe_generator" => "deterministic_local_browser_probe",
        "policy" => {
          "network" => "localhost-only",
          "allowed_actions" => %w[scroll_into_view hover focus fill_text_probe restore_input_value click_same_origin_anchor click_toggle_button escape restore_preview_url],
          "blocked_actions" => %w[external_navigation form_submit destructive_click credential_entry file_upload payment deploy],
          "reversible_only" => true,
          "external_navigation_blocked" => true,
          "form_submission_allowed" => false
        },
        "limits" => {
          "expected_viewports" => %w[desktop tablet mobile],
          "observed_viewports" => Array(viewports).length,
          "max_targets_per_viewport" => 5,
          "max_steps_per_target" => 4,
          "timeout_seconds_per_viewport" => 90
        },
        "stop_condition" => "all_viewports_observed_and_recovered_or_policy_blocked",
        "viewports" => Array(viewports),
        "planned_steps" => Array(planned_steps),
        "executed_steps" => Array(executed_steps),
        "recovery_steps" => Array(recovery_steps),
        "blocked_steps" => Array(blocked_steps),
        "probe_plan" => Array(probe_plan),
        "probe_results" => probe_results,
        "multi_step_evidence" => multi_step_evidence,
        "limitations" => [
          "not a production open-ended browser agent",
          "does not submit forms or perform irreversible clicks",
          "does not navigate beyond the local preview origin"
        ],
        "blocking_issues" => Array(blocking_issues).compact.map(&:to_s)
      }.tap do |payload|
        payload["reason"] = reason.to_s if reason
      end
    end
  end
end
