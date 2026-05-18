# frozen_string_literal: true

module Aiweb
  module ProjectVerifyLoop
    private

    def verify_loop_step_status(result)
      key = VERIFY_LOOP_RESULT_STATUS_KEYS.find { |candidate| result[candidate].is_a?(Hash) }
      key ? result.dig(key, "status") : result["status"]
    end

    def verify_loop_step_passed?(result, step_name)
      status = verify_loop_step_status(result).to_s
      return true if step_name == "visual-critique" && result.dig("visual_critique", "approval").to_s == "pass"

      VERIFY_LOOP_PASSING_STATUSES.fetch(step_name, %w[passed]).include?(status)
    end

    def verify_loop_step_blocker(step_name, result)
      issues = []
      issues.concat(result["blocking_issues"]) if result["blocking_issues"].is_a?(Array)
      VERIFY_LOOP_RESULT_STATUS_KEYS.each do |key|
        issues.concat(result.dig(key, "blocking_issues")) if result.dig(key, "blocking_issues").is_a?(Array)
      end
      issues << "#{step_name} status #{verify_loop_step_status(result)}"
      issues.compact.map(&:to_s).reject(&:empty?).uniq.join("; ")
    end

    def verify_loop_preview_url(preview_result)
      preview_result.dig("preview", "url").to_s.empty? ? preview_result.dig("preview", "preview_url") : preview_result.dig("preview", "url")
    end

    def verify_loop_qa_result_path(result)
      VERIFY_LOOP_QA_RESULT_PATH_KEYS.lazy.map { |key| result.dig(key, "result_path") }.find { |value| !value.to_s.empty? } ||
        result.dig("qa_result", "artifact_path") ||
        "latest"
    end

    def verify_loop_ensure_component_map(cycle)
      return if File.file?(File.join(aiweb_dir, "component-map.json"))

      result = verify_loop_record_step(cycle, "component-map") { component_map(force: false, dry_run: false) }
      return if verify_loop_step_passed?(result, "component-map")

      raise UserError.new(verify_loop_step_blocker("component-map", result), 1)
    end

    def verify_loop_payload(state:, metadata:, changed_files:, planned_changes:, action_taken:, next_action:)
      payload = status_hash(state: state, changed_files: changed_files)
      payload["action_taken"] = action_taken
      payload["blocking_issues"] = metadata["blocking_issues"] || []
      payload["planned_changes"] = planned_changes unless planned_changes.empty?
      payload["verify_loop"] = metadata
      payload["next_action"] = next_action
      payload
    end

    def verify_loop_cancel_blocker(run_id)
      return nil unless run_cancel_requested?(run_id)

      "verify-loop cancellation requested for #{run_id}"
    end

    def verify_loop_action_taken(status)
      case status
      when "passed" then "verify loop passed"
      when "max_cycles" then "verify loop reached max cycles"
      when "cancelled" then "verify loop cancelled"
      when "agent_run_failed" then "verify loop stopped after agent-run failure"
      else "verify loop blocked"
      end
    end

    def verify_loop_next_action(metadata)
      case metadata["status"]
      when "passed"
        "review #{metadata["metadata_path"]} and continue toward deploy planning only after approval gates are satisfied"
      when "max_cycles"
        "inspect #{metadata["metadata_path"]}, review latest blocker, then rerun with a higher --max-cycles and --agent #{metadata["agent"]} only after reviewing the generated task/diff evidence"
      when "agent_run_failed"
        "inspect the cycle agent-run logs in #{metadata["run_dir"]}, then repair the task packet or source allowlist"
      when "cancelled"
        "inspect #{metadata["metadata_path"]}, then record a resume descriptor with aiweb run-resume --run-id #{metadata["run_id"]} if you want to continue"
      else
        "resolve #{metadata["latest_blocker"] || "verify-loop blockers"}, then rerun aiweb verify-loop --max-cycles #{metadata["max_cycles"]} --agent #{metadata["agent"]} --approved"
      end
    end
  end
end
