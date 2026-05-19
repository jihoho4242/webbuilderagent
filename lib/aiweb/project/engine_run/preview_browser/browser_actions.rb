# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    def engine_run_browser_action_recovery_skipped(reason)
      {
        "schema_version" => 1,
        "status" => "skipped",
        "required" => true,
        "policy" => "localhost-only reversible UI actions; external navigation is blocked and recorded",
        "reason" => reason.to_s,
        "viewports" => [],
        "action_sequences" => [],
        "recovery_attempts" => [],
        "external_requests_blocked" => [],
        "blocking_issues" => []
      }
    end

    def engine_run_browser_action_recovery_failed(blockers)
      {
        "schema_version" => 1,
        "status" => "failed",
        "required" => true,
        "policy" => "localhost-only reversible UI actions; external navigation is blocked and recorded",
        "viewports" => [],
        "action_sequences" => [],
        "recovery_attempts" => [],
        "external_requests_blocked" => [],
        "blocking_issues" => Array(blockers).compact.map(&:to_s)
      }
    end

    def engine_run_browser_action_loop_skipped(reason)
      engine_run_browser_action_loop_envelope(
        status: "skipped",
        viewports: [],
        planned_steps: [],
        executed_steps: [],
        recovery_steps: [],
        blocked_steps: [],
        blocking_issues: [],
        reason: reason.to_s
      )
    end

    def engine_run_browser_action_loop_failed(blockers)
      engine_run_browser_action_loop_envelope(
        status: "failed",
        viewports: [],
        planned_steps: [],
        executed_steps: [],
        recovery_steps: [],
        blocked_steps: [],
        blocking_issues: Array(blockers).compact.map(&:to_s)
      )
    end

    def engine_run_browser_evidence_unavailable(reason, status: "skipped")
      {
        "schema_version" => 1,
        "status" => status,
        "reason" => reason.to_s,
        "capture_mode" => nil,
        "viewports" => [],
        "items" => [],
        "blocking_issues" => status == "failed" ? [reason.to_s] : []
      }
    end

    def engine_run_browser_focus_unavailable(reason, status: "skipped")
      {
        "schema_version" => 1,
        "status" => status,
        "required" => true,
        "reason" => reason.to_s,
        "viewports" => []
      }
    end

    def engine_run_merge_browser_observations(captures, key)
      captures.flat_map do |capture|
        Array(capture[key]).map do |entry|
          if entry.is_a?(Hash)
            entry.merge("viewport" => entry["viewport"] || capture["viewport"])
          else
            { "viewport" => capture["viewport"], "message" => entry.to_s }
          end
        end
      end
    end

    def engine_run_merge_browser_evidence(captures, key)
      items = captures.map { |capture| capture[key] }.compact
      status = captures.any? && items.all? { |item| item["status"] == "captured" } && items.length == captures.length ? "captured" : "failed"
      {
        "schema_version" => 1,
        "status" => status,
        "capture_mode" => "playwright_browser",
        "viewports" => captures.map { |capture| capture["viewport"] },
        "items" => items,
        "required_fields" => %w[route viewport selector data_aiweb_id text_role computed_styles bounding_box]
      }
    end

    def engine_run_merge_interaction_states(captures)
      names = %w[default hover focus-visible active disabled loading empty error success]
      names.map do |name|
        per_viewport = captures.map do |capture|
          state = Array(capture["interaction_states"]).find { |item| item["state"] == name } || {}
          { "viewport" => capture["viewport"], "status" => state["status"], "evidence" => Array(state["evidence"]) }
        end
        {
          "state" => name,
          "status" => captures.any? && per_viewport.all? { |item| %w[captured not_applicable].include?(item["status"]) } ? "captured" : "failed",
          "viewports" => per_viewport
        }
      end
    end

    def engine_run_merge_focus_traversal(captures)
      {
        "schema_version" => 1,
        "status" => captures.any? && captures.all? { |capture| capture.dig("keyboard_focus_traversal", "status") == "captured" } ? "captured" : "failed",
        "required" => true,
        "viewports" => captures.map do |capture|
          {
            "viewport" => capture["viewport"],
            "steps" => Array(capture.dig("keyboard_focus_traversal", "steps"))
          }
        end
      }
    end

    def engine_run_merge_action_recovery(captures)
      per_viewport = captures.map do |capture|
        evidence = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        {
          "viewport" => capture["viewport"],
          "status" => evidence["status"] || "failed",
          "action_count" => Array(evidence["actions"]).length,
          "recovery_count" => Array(evidence["recovery_steps"]).length,
          "actionable_target_count" => evidence["actionable_target_count"].to_i,
          "unsafe_navigation_policy_enforced" => evidence["unsafe_navigation_policy_enforced"] == true,
          "unsafe_navigation_blocked" => evidence["unsafe_navigation_blocked"] == true,
          "external_request_block_count" => Array(evidence["external_requests_blocked"]).length,
          "blocking_issues" => Array(evidence["blocking_issues"])
        }
      end
      blockers = per_viewport.flat_map { |entry| Array(entry["blocking_issues"]).map { |issue| "#{entry["viewport"]}: #{issue}" } }
      action_sequences = captures.flat_map do |capture|
        evidence = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(evidence["actions"]).map do |action|
          action.is_a?(Hash) ? action.merge("viewport" => capture["viewport"]) : { "viewport" => capture["viewport"], "action" => action.to_s }
        end
      end
      recovery_attempts = captures.flat_map do |capture|
        evidence = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(evidence["recovery_steps"]).map do |step|
          step.is_a?(Hash) ? step.merge("viewport" => capture["viewport"]) : { "viewport" => capture["viewport"], "action" => step.to_s }
        end
      end
      external_requests_blocked = captures.flat_map do |capture|
        evidence = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(evidence["external_requests_blocked"]).map do |entry|
          entry.is_a?(Hash) ? entry.merge("viewport" => entry["viewport"] || capture["viewport"]) : { "viewport" => capture["viewport"], "url" => entry.to_s }
        end
      end
      {
        "schema_version" => 1,
        "status" => captures.any? && per_viewport.all? { |entry| entry["status"] == "captured" } && blockers.empty? ? "captured" : "failed",
        "required" => true,
        "policy" => "localhost-only reversible UI actions; external navigation is blocked and recorded",
        "viewports" => per_viewport,
        "action_sequences" => action_sequences,
        "recovery_attempts" => recovery_attempts,
        "external_requests_blocked" => external_requests_blocked,
        "blocking_issues" => blockers
      }
    end

    def engine_run_browser_action_loop(captures)
      viewports = captures.map do |capture|
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        actions = Array(recovery["actions"])
        recovery_steps = Array(recovery["recovery_steps"])
        blocked_requests = Array(recovery["external_requests_blocked"])
        blocking_issues = Array(recovery["blocking_issues"])
        {
          "viewport" => capture["viewport"],
          "status" => recovery["status"] == "captured" && blocking_issues.empty? ? "captured" : "failed",
          "planned_step_count" => actions.length,
          "executed_step_count" => actions.count { |action| action.is_a?(Hash) && %w[captured passed not_applicable].include?(action["status"].to_s) },
          "recovery_step_count" => recovery_steps.length + actions.sum { |action| action.is_a?(Hash) ? Array(action["recovery"]).length : 0 },
          "blocked_step_count" => blocked_requests.length,
          "unsafe_navigation_policy_enforced" => recovery["unsafe_navigation_policy_enforced"] == true,
          "unsafe_navigation_blocked" => recovery["unsafe_navigation_blocked"] == true,
          "blocking_issues" => blocking_issues
        }
      end
      planned_steps = captures.flat_map do |capture|
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(recovery["actions"]).map do |action|
          descriptor = action.is_a?(Hash) ? action : { "action" => action.to_s }
          descriptor.slice("index", "selector", "text_role", "data_aiweb_id", "bounding_box", "reason").merge(
            "viewport" => capture["viewport"],
            "planned_actions" => Array(descriptor["actions"]).map { |step| step.is_a?(Hash) ? step.slice("name", "status", "reason") : { "name" => step.to_s } }
          )
        end
      end
      executed_steps = captures.flat_map do |capture|
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(recovery["actions"]).flat_map do |action|
          next [] unless action.is_a?(Hash)

          Array(action["actions"]).map do |step|
            step = step.is_a?(Hash) ? step : { "name" => step.to_s }
            {
              "viewport" => capture["viewport"],
              "target_index" => action["index"],
              "selector" => action["selector"],
              "name" => step["name"],
              "status" => step["status"] || "recorded",
              "reason" => step["reason"]
            }.compact
          end
        end
      end
      recovery_steps = captures.flat_map do |capture|
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        direct_steps = Array(recovery["recovery_steps"]).map do |step|
          step = step.is_a?(Hash) ? step : { "action" => step.to_s }
          step.merge("viewport" => capture["viewport"])
        end
        nested_steps = Array(recovery["actions"]).flat_map do |action|
          next [] unless action.is_a?(Hash)

          Array(action["recovery"]).map do |step|
            step = step.is_a?(Hash) ? step : { "name" => step.to_s }
            step.merge(
              "viewport" => capture["viewport"],
              "target_index" => action["index"],
              "selector" => action["selector"]
            )
          end
        end
        direct_steps + nested_steps
      end
      blocked_steps = captures.flat_map do |capture|
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(recovery["external_requests_blocked"]).map do |entry|
          entry = entry.is_a?(Hash) ? entry : { "url" => entry.to_s }
          entry.merge("viewport" => capture["viewport"], "policy" => "non_local_request_blocked")
        end
      end
      probes = engine_run_browser_action_loop_probes(captures)
      probe_plan = probes.map do |probe|
        probe.slice("probe_id", "viewport", "goal", "policy", "target_count", "steps")
      end
      probe_results = probes.map do |probe|
        probe.slice("probe_id", "viewport", "status", "step_count", "recovery_step_count", "blocked_step_count", "blocking_issues")
      end
      multi_step_evidence = engine_run_browser_action_loop_multi_step_evidence(
        probe_results: probe_results,
        executed_steps: executed_steps,
        recovery_steps: recovery_steps,
        blocked_steps: blocked_steps
      )
      blockers = viewports.flat_map { |entry| Array(entry["blocking_issues"]).map { |issue| "#{entry["viewport"]}: #{issue}" } }
      status = captures.length == 3 &&
        viewports.all? { |entry| entry["status"] == "captured" && entry["unsafe_navigation_policy_enforced"] == true } &&
        probe_results.length == captures.length &&
        probe_results.all? { |probe| probe["status"] == "captured" } &&
        multi_step_evidence["multi_step_sequences_observed"] == true &&
        multi_step_evidence["all_probes_recovered"] == true &&
        executed_steps.any? &&
        recovery_steps.any? &&
        blockers.empty? ? "captured" : "failed"
      envelope = engine_run_browser_action_loop_envelope(
        status: status,
        viewports: viewports,
        planned_steps: planned_steps,
        executed_steps: executed_steps,
        recovery_steps: recovery_steps,
        blocked_steps: blocked_steps,
        probe_plan: probe_plan,
        probe_results: probe_results,
        multi_step_evidence: multi_step_evidence,
        blocking_issues: blockers
      )
      envelope["limits"]["observed_viewports"] = captures.length
      envelope
    end

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
