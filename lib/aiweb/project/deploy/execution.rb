# frozen_string_literal: true

module Aiweb
  class Project
    module Deploy
      private

      def deploy_execute_approved(state:, run_id:, run_dir:, stdout_path:, stderr_path:, metadata_path:, side_effect_broker_path:, deploy_payload:, planned_changes:, normalized_target:, force:)
        active_record = active_run_begin!(
          kind: "deploy",
          run_id: run_id,
          run_dir: run_dir,
          metadata_path: metadata_path,
          command: deploy_payload.fetch("command"),
          force: force
        )
        begin
          payload = nil
          changes = []
          mutation(dry_run: false) do
            FileUtils.mkdir_p(run_dir)
            changes << relative(run_dir)
            started_at = now
            command = deploy_payload.fetch("command")
            side_effect_broker_events = []
            side_effect_context = deploy_side_effect_broker_context(
              target: normalized_target,
              command: command,
              deploy_payload: deploy_payload
            )
            append_side_effect_broker_event(
              side_effect_broker_path,
              side_effect_broker_events,
              "tool.requested",
              side_effect_context.merge(
                "requested_at" => started_at,
                "dry_run" => false
              )
            )
            append_side_effect_broker_event(
              side_effect_broker_path,
              side_effect_broker_events,
              "policy.decision",
              side_effect_context.merge(
                "decision" => "allow",
                "reason" => "explicit --approved deploy with passing verify-loop evidence and ready provider CLI"
              )
            )
            append_side_effect_broker_event(
              side_effect_broker_path,
              side_effect_broker_events,
              "tool.started",
              side_effect_context.merge("started_at" => started_at)
            )
            stdout, stderr, process_status = begin
              Open3.capture3(*command, chdir: root)
            rescue StandardError => error
              append_side_effect_broker_event(
                side_effect_broker_path,
                side_effect_broker_events,
                "tool.failed",
                side_effect_context.merge(
                  "finished_at" => now,
                  "error_class" => error.class.name,
                  "error_message" => error.message.to_s[0, 240]
                )
              )
              raise
            end
            status = process_status.success? ? "passed" : "failed"
            append_side_effect_broker_event(
              side_effect_broker_path,
              side_effect_broker_events,
              "tool.finished",
              side_effect_context.merge(
                "finished_at" => now,
                "status" => status,
                "exit_code" => process_status.exitstatus
              )
            )
            blocking_issues = process_status.success? ? [] : ["#{command.first} exited with status #{process_status.exitstatus}"]
            stdout = redact_side_effect_process_output(stdout)
            stderr = redact_side_effect_process_output(stderr)
            changes << write_file(stdout_path, stdout, false)
            changes << write_file(stderr_path, stderr, false)
            changes << relative(side_effect_broker_path)
            deploy_payload = deploy_payload.merge(
              "status" => status,
              "started_at" => started_at,
              "finished_at" => now,
              "exit_code" => process_status.exitstatus,
              "stdout_log" => relative(stdout_path),
              "stderr_log" => relative(stderr_path),
              "metadata_path" => relative(metadata_path),
              "side_effect_broker_path" => relative(side_effect_broker_path),
              "side_effect_broker_events" => side_effect_broker_events,
              "side_effect_broker" => deploy_payload.fetch("side_effect_broker").merge(
                "status" => status,
                "events_recorded" => true,
                "events_path" => relative(side_effect_broker_path),
                "event_count" => side_effect_broker_events.length
              ),
              "blocking_issues" => blocking_issues,
              "provider_executed" => true,
              "provider_cli_invoked" => true,
              "external_deploy_performed" => process_status.success?,
              "network_calls_performed" => true,
              "network_call_status" => process_status.success? ? "performed" : "attempted_unknown_result",
              "writes_performed" => true
            )
            changes << write_json(metadata_path, deploy_payload, false)
            state["deploy"]["latest_deploy"] = relative(metadata_path)
            state["deploy"]["latest_deploy_target"] = normalized_target
            state["deploy"]["latest_deploy_status"] = status
            state["deploy"]["latest_deploy_at"] = deploy_payload["finished_at"]
            state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
            add_decision!(state, "deploy_adapter", "Ran approved #{normalized_target} deploy adapter after passing verify-loop gate")
            changes << write_yaml(state_path, state, false)
            payload = status_hash(state: state, changed_files: compact_changes(changes))
            payload["action_taken"] = status == "passed" ? "ran approved deploy adapter" : "approved deploy adapter failed"
            payload["deploy"] = deploy_payload
            payload.merge!(pr19_safety_payload(planned_changes))
            payload["external_deploy_performed"] = deploy_payload["external_deploy_performed"]
            payload["requires_approval"] = false
            payload["blocking_issues"] = blocking_issues
            payload["next_action"] = status == "passed" ? "review #{relative(metadata_path)} before treating the provider deployment as accepted" : "inspect #{relative(stderr_path)} and provider readiness, then rerun deploy after fixing the blocker"
          end
          active_run_finish!(active_record, payload.dig("deploy", "status") || "completed")
          active_record = nil
          payload
        ensure
          active_run_finish!(active_record, "failed") if active_record
        end
      end
    end
  end
end
