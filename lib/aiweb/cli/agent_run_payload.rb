# frozen_string_literal: true

module Aiweb
  class CLI
    module AgentRunPayload
      private

    def agent_run_base_payload(status:, task:, agent:, approved:, dry_run:, action_taken:, blocking_issues:, next_action:)
      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      run_id = "agent-run-#{timestamp}"
      run_dir = File.join(@root, ".ai-web", "runs", run_id)
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      metadata_path = File.join(run_dir, "agent-run.json")
      diff_path = File.join(@root, ".ai-web", "diffs", "#{run_id}.patch")
      command = ["aiweb", "agent-run", "--task", task, "--agent", agent]
      command << "--dry-run" if dry_run
      command << "--approval-hash HASH" if approved
      command << "--approved" if approved

      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => action_taken,
        "changed_files" => dry_run ? [relative_path(run_dir), relative_path(stdout_path), relative_path(stderr_path), relative_path(metadata_path), relative_path(diff_path)] : [],
        "blocking_issues" => blocking_issues,
        "missing_artifacts" => [],
        "agent_run" => {
          "schema_version" => 1,
          "status" => status,
          "task" => task,
          "agent" => agent,
          "dry_run" => dry_run,
          "approved" => approved,
          "command" => command.join(" "),
          "planned_run_dir" => relative_path(run_dir),
          "planned_stdout_path" => relative_path(stdout_path),
          "planned_stderr_path" => relative_path(stderr_path),
          "planned_metadata_path" => relative_path(metadata_path),
          "planned_diff_path" => relative_path(diff_path),
          "guardrails" => [
            "--approval-hash from dry-run required for real local agent execution",
            "--approved required with the matching approval hash for real local agent execution",
            "--dry-run writes nothing",
            "no build/preview/QA/deploy/provider CLI",
            "no .env/.env.* reads or output"
          ],
          "blocking_issues" => blocking_issues
        },
        "next_action" => next_action
      }
    end

    def agent_run_approval_blocked_payload(task:, agent:)
      agent_run_base_payload(
        status: "blocked",
        task: task,
        agent: agent,
        approved: false,
        dry_run: false,
        action_taken: "agent run blocked",
        blocking_issues: ["--approved is required for real local agent execution"],
        next_action: "review the agent-run dry-run approval_hash; lower-level agent-run execution is not a friendly web-building runbook, so prefer aiweb agent or aiweb engine-run for user-facing work"
      )
    end
    end
  end
end
