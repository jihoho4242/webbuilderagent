# frozen_string_literal: true

module Aiweb
  module ProjectTaskQaCommands
    def next_task(type: nil, dry_run: false, force: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        phase_guard!(state, "next-task", %w[phase-6 phase-7 phase-8 phase-9 phase-10 phase-11], force)
        task_type = type.to_s.strip.empty? ? recommended_task_type(state) : type.to_s.strip
        task_id = "task-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{slug(task_type)}"
        task_path = File.join(aiweb_dir, "tasks", "#{task_id}.md")
        changes << write_file(task_path, task_packet_markdown(task_id, task_type, state), dry_run)
        state["implementation"]["current_task"] = relative(task_path)
        add_decision!(state, "task_packet", "Generated #{task_type} task packet")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "generated task packet #{task_id}"
      end
      payload
    end

    def qa_checklist(dry_run: false, force: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        phase_guard!(state, "qa-checklist", %w[phase-7 phase-8 phase-9 phase-10 phase-11], force)
        path = File.join(aiweb_dir, "qa", "current-checklist.md")
        changes << write_file(path, qa_checklist_markdown(state), dry_run)
        state["qa"]["current_checklist"] = relative(path)
        add_decision!(state, "qa_checklist", "Generated current QA checklist")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "generated QA checklist"
      end
      payload
    end

    def qa_report(status: "passed", task_id: nil, duration_minutes: nil, timed_out: false, from: nil, dry_run: false, force: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        phase_guard!(state, "qa-report", %w[phase-7 phase-8 phase-9 phase-10 phase-11], force)
        result = from ? load_json_file(from) : default_qa_result(status, task_id, duration_minutes, timed_out)
        normalize_qa_result!(result, state)
        validate_qa_result!(result)
        enforce_qa_timeout_recovery_budget!(state, result)

        result_id = "qa-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{slug(result["task_id"])}"
        path = File.join(aiweb_dir, "qa", "results", "#{result_id}.json")
        changes << write_json(path, result, dry_run)
        state["qa"]["last_result"] = relative(path)

        failures = qa_failures_from_result(result, state, relative(path))
        unless failures.empty?
          state["qa"]["open_failures"] ||= []
          state["qa"]["open_failures"].concat(failures)
          fix_path = File.join(aiweb_dir, "tasks", "fix-#{failures.first["id"]}.md")
          changes << write_file(fix_path, qa_fix_task_markdown(failures, result, state), dry_run)
          result["recommended_action"] = "create_fix_packet"
          result["created_fix_task"] = relative(fix_path)
          changes << write_json(path, result, dry_run)
        end

        if state.dig("phase", "current") == "phase-11"
          final_path = File.join(aiweb_dir, "qa", "final-report.md")
          changes << write_file(final_path, final_qa_report_markdown(state, result, failures), dry_run)
          mark_artifacts_from_files!(state)
        end

        add_decision!(state, "qa_report", "Recorded QA result #{result["status"]} for #{result["task_id"]}")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "recorded QA report"
      end
      payload
    end

  end
end
