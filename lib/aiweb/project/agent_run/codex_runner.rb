# frozen_string_literal: true

module Aiweb
  module ProjectAgentRun
    private

    def agent_run_codex(state:, agent_name:, task_source:, context:, source_paths:, run_id:, run_dir:, stdout_path:, stderr_path:, context_path:, metadata_path:, diff_path:)
      changes = []
      payload = nil
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << relative(run_dir)
        started_at = now
        prompt = agent_run_prompt(context: context)
        changes << write_json(context_path, context, false)
        before_snapshot = agent_run_workspace_snapshot
        stdout = ""
        stderr = ""
        exit_code = nil
        status = "blocked"

        stdout, stderr, process_status = Open3.capture3(
          agent_run_process_env(context_path: context_path, source_paths: source_paths, task_source: task_source, run_id: run_id, diff_path: diff_path, metadata_path: metadata_path),
          agent_name,
          stdin_data: prompt,
          chdir: root,
          unsetenv_others: true
        )
        after_snapshot = agent_run_workspace_snapshot
        unauthorized_changes = agent_run_unauthorized_workspace_changes(before_snapshot, after_snapshot, source_paths)
        stdout = agent_run_redact_process_output(stdout)
        stderr = agent_run_redact_process_output(stderr)
        exit_code = process_status.exitstatus
        status = process_status.success? && unauthorized_changes.empty? ? "passed" : "failed"
        blocking_issues = []
        blocking_issues << "#{agent_name} exited with status #{exit_code}" unless process_status.success?
        unless unauthorized_changes.empty?
          blocking_issues << "agent-run rejected changes outside allowed source paths: #{unauthorized_changes.join(", ")}"
        end

        changes << write_file(stdout_path, stdout, false)
        changes << write_file(stderr_path, stderr, false)
        diff_patch, changed_source_files = agent_run_source_diff(source_paths)
        blocking_issues.concat(agent_run_validate_source_diff(diff_patch, source_paths))
        changes << write_file(diff_path, diff_patch, false)

        metadata = agent_run_run_metadata(
          run_id: run_id,
          agent: agent_name,
          task_source: task_source,
          context: context,
          command: agent_name,
          context_path: relative(context_path),
          started_at: started_at,
          finished_at: now,
          exit_code: exit_code,
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          metadata_path: relative(metadata_path),
          diff_path: relative(diff_path),
          source_paths: source_paths,
          dry_run: false,
          approved: true,
          blocking_issues: blocking_issues,
          status: if status == "failed" || !blocking_issues.empty?
                    "failed"
                  elsif changed_source_files.empty? || diff_patch.to_s.strip.empty?
                    "no_changes"
                  else
                    "passed"
                  end,
          changed_source_files: changed_source_files
        )
        changes.concat(changed_source_files)
        changes << write_json(metadata_path, metadata, false)
        state["implementation"]["latest_agent_run"] = relative(metadata_path)
        state["implementation"]["last_diff"] = relative(diff_path)
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)

        payload = agent_run_payload(
          state: state,
          metadata: metadata,
          changed_files: compact_changes(changes),
          planned_changes: [],
          action_taken: metadata["status"] == "passed" ? "ran agent patch" : (metadata["status"] == "no_changes" ? "agent run produced no source diff" : "agent run failed"),
          blocking_issues: metadata["blocking_issues"],
          next_action: agent_run_next_action(metadata)
        )
      end
      payload
    end
  end
end
