# frozen_string_literal: true

module Aiweb
  module ProjectAgentRun
    private

    def agent_run_run_metadata(run_id:, agent:, task_source:, context:, command:, context_path:, started_at:, finished_at:, exit_code:, stdout_log:, stderr_log:, metadata_path:, diff_path:, source_paths:, dry_run:, approved:, blocking_issues:, status:, changed_source_files: [])
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "agent" => agent,
        "command" => command,
        "cwd" => root,
        "task_path" => task_source["relative"],
        "task_sha256" => task_source["path"] ? Digest::SHA256.file(task_source["path"]).hexdigest : nil,
        "context" => {
          "safe_context_only" => context["safe_context_only"] == true,
          "context_files" => context["context_files"],
          "selected_candidate" => context["selected_candidate"],
          "selected_design_files" => context["selected_design_files"],
          "source_paths" => source_paths,
          "targeted_edit" => context["targeted_edit"] == true,
          "target_allowlist" => context["target_allowlist"]
        },
        "source_paths" => source_paths,
        "changed_source_files" => changed_source_files,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "exit_code" => exit_code,
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "context_path" => context_path,
        "metadata_path" => metadata_path,
        "diff_path" => diff_path,
        "dry_run" => dry_run,
        "approved" => approved,
        "requires_approval" => !approved && !dry_run,
        "blocking_issues" => blocking_issues
      }
    end

    def agent_run_payload(state:, metadata:, changed_files:, planned_changes:, action_taken:, blocking_issues:, next_action:)
      payload = status_hash(state: state, changed_files: changed_files)
      payload["action_taken"] = action_taken
      payload["blocking_issues"] = blocking_issues
      payload["planned_changes"] = planned_changes unless planned_changes.empty?
      payload["agent_run"] = metadata
      payload["next_action"] = next_action
      payload
    end

    def agent_run_next_action(metadata)
      agent = metadata["agent"].to_s.empty? ? "codex" : metadata["agent"]
      case metadata["status"]
      when "passed"
        "review #{metadata["metadata_path"]} and #{metadata["diff_path"]} before accepting the patch"
      when "no_changes"
        "inspect #{metadata["stdout_log"]} and #{metadata["stderr_log"]}; rerun with better source hints if the patch should have changed files"
      when "failed"
        "inspect #{metadata["stdout_log"]} and #{metadata["stderr_log"]}, then repair the source task and rerun aiweb agent-run --task latest --agent #{agent} --approved"
      else
        "add a safe source target to the task packet or component map, then rerun aiweb agent-run --task latest --agent #{agent} --approved"
      end
    end
  end
end
