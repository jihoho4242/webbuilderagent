# frozen_string_literal: true

module Aiweb
  module ProjectAgentRun
    private

    def agent_run_codex(state:, agent_name:, task_source:, context:, source_paths:, run_id:, run_dir:, stdout_path:, stderr_path:, context_path:, metadata_path:, diff_path:, side_effect_broker_path:, approval_hash:, capability:)
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
        side_effect_broker_events = []
        side_effect_context = side_effect_broker_context(
          broker: "aiweb.agent_run.codex.side_effect_broker",
          scope: "agent_run.codex_worker",
          target: "approved_local_source_patch_worker",
          command: [agent_name],
          risk_class: "local_source_patch_worker",
          approved: true,
          extra: {
            "run_id" => run_id,
            "context_path" => relative(context_path),
            "task_path" => task_source["relative"].to_s,
            "source_paths" => source_paths,
            "stdout_log" => relative(stdout_path),
            "stderr_log" => relative(stderr_path),
            "diff_path" => relative(diff_path)
          }
        )
        append_side_effect_broker_event(side_effect_broker_path, side_effect_broker_events, "tool.requested", side_effect_context)
        append_side_effect_broker_event(side_effect_broker_path, side_effect_broker_events, "policy.decision", side_effect_context.merge("decision" => "allow", "reason" => "explicit --approved bounded agent-run source patch"))
        append_side_effect_broker_event(side_effect_broker_path, side_effect_broker_events, "tool.started", side_effect_context.merge("status" => "running"))

        result = runtime_process_runner.capture(
          Aiweb::Runtime::CommandSpec.new(
            argv: [agent_name],
            cwd: root,
            env: agent_run_process_env(context_path: context_path, source_paths: source_paths, task_source: task_source, run_id: run_id, diff_path: diff_path, metadata_path: metadata_path, side_effect_broker_path: side_effect_broker_path),
            stdin_data: prompt,
            timeout: 600,
            max_output_bytes: 200_000,
            risk_class: "agent_run_codex_local_source_patch_worker",
            description: "agent-run Codex local source patch worker"
          )
        )
        after_snapshot = agent_run_workspace_snapshot
        unauthorized_changes = agent_run_unauthorized_workspace_changes(before_snapshot, after_snapshot, source_paths)
        stdout = agent_run_redact_process_output(result.stdout)
        stderr = agent_run_redact_process_output(result.stderr)
        exit_code = result.exit_code
        status = result.success? && unauthorized_changes.empty? ? "passed" : "failed"
        blocking_issues = []
        blocking_issues << "#{agent_name} exited with status #{exit_code || result.status}" unless result.success?
        unless unauthorized_changes.empty?
          blocking_issues << "agent-run rejected changes outside allowed source paths: #{unauthorized_changes.join(", ")}"
        end

        changes << write_file(stdout_path, stdout, false)
        changes << write_file(stderr_path, stderr, false)
        diff_patch, changed_source_files = agent_run_source_diff(source_paths)
        blocking_issues.concat(agent_run_validate_source_diff(diff_patch, source_paths))
        changes << write_file(diff_path, diff_patch, false)

        metadata_status = if status == "failed" || !blocking_issues.empty?
                            "failed"
                          elsif changed_source_files.empty? || diff_patch.to_s.strip.empty?
                            "no_changes"
                          else
                            "passed"
                          end
        broker_terminal_event = metadata_status == "failed" ? "tool.failed" : "tool.finished"
        append_side_effect_broker_event(
          side_effect_broker_path,
          side_effect_broker_events,
          broker_terminal_event,
          side_effect_context.merge("status" => metadata_status, "exit_code" => exit_code, "blocking_issues" => blocking_issues.uniq)
        )
        changes << relative(side_effect_broker_path)

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
          approval_hash: approval_hash,
          capability: capability,
          blocking_issues: blocking_issues,
          status: metadata_status,
          changed_source_files: changed_source_files
        )
        metadata["side_effect_broker_path"] = relative(side_effect_broker_path)
        metadata["side_effect_broker"] = {
          "schema_version" => 1,
          "broker" => "aiweb.agent_run.codex.side_effect_broker",
          "scope" => "agent_run.codex_worker",
          "status" => metadata_status,
          "events_recorded" => true,
          "events_path" => relative(side_effect_broker_path),
          "event_count" => side_effect_broker_events.length,
          "target" => "approved_local_source_patch_worker",
          "tool" => agent_name,
          "command" => redact_side_effect_command([agent_name]),
          "risk_class" => "local_source_patch_worker",
          "requires_approval" => true,
          "approved" => true,
          "policy" => {
            "decision" => "allow",
            "blocking_issues" => []
          }
        }
        metadata["side_effect_broker_events"] = side_effect_broker_events
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
