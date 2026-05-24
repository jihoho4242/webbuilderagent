# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
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
  end
end
