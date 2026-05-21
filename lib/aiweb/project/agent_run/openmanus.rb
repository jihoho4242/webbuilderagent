# frozen_string_literal: true

module Aiweb
  module ProjectAgentRun
    private

    def agent_run_openmanus(state:, task_source:, context:, source_paths:, run_id:, run_dir:, stdout_path:, stderr_path:, metadata_path:, diff_path:, context_path:, prompt_path:, validator_path:, result_path:, network_log_path:, browser_log_path:, denied_access_log_path:, tool_broker_log_path:, command:, contract:, approval_hash:, capability:)
      changes = []
      payload = nil
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << relative(run_dir)
        FileUtils.mkdir_p(File.dirname(diff_path))

        started_at = now
        prompt = agent_run_openmanus_prompt(context: context, contract_context: contract.fetch("context"))
        workspace_dir = File.join(root, contract.fetch("workspace_root"))
        workspace_result_path = File.join(workspace_dir, "_aiweb", "openmanus-result.json")
        stdout = +""
        stderr = +""
        exit_code = nil
        status = "blocked"
        blocking_issues = []
        changed_source_files = []
        openmanus_report = nil
        preapply_patch = ""

        changes << write_json(context_path, contract.fetch("context"), false)
        changes << write_file(prompt_path, prompt, false)
        workspace_blockers = agent_run_prepare_openmanus_workspace(workspace_dir, source_paths)
        changes << relative(workspace_dir)
        if workspace_blockers.empty?
          engine_run_prepare_workspace_tool_broker(workspace_dir)
          changes << relative(File.join(workspace_dir, "_aiweb", "tool-broker-bin"))
          changes << write_json(File.join(workspace_dir, "_aiweb", "openmanus-context.json"), contract.fetch("context"), false)
        end
        before_snapshot = agent_run_workspace_snapshot

        if workspace_blockers.empty?
          result = agent_run_capture_openmanus(
            command: command,
            prompt: prompt,
            workspace_dir: workspace_dir,
            timeout_sec: contract.dig("context", "timeout_sec"),
            context_path: context_path,
            result_path: workspace_result_path,
            source_paths: source_paths,
            run_id: run_id,
            metadata_path: metadata_path,
            diff_path: diff_path
          )
          stdout = agent_run_redact_process_output(result.fetch(:stdout))
          stderr = agent_run_redact_process_output(result.fetch(:stderr))
          exit_code = result[:exit_code]
          blocking_issues.concat(result.fetch(:blocking_issues))
          tool_broker_events = engine_run_workspace_tool_broker_events(workspace_dir)
          unless tool_broker_events.empty?
            blocked = tool_broker_events.map { |event| [event["risk_class"], event["tool_name"]].compact.join(":") }.reject(&:empty?).join(", ")
            blocking_issues << "openmanus tool broker blocked prohibited staged action: #{blocked}"
          end
          openmanus_report, report_blockers = agent_run_read_openmanus_report(workspace_result_path, source_paths)
          blocking_issues.concat(report_blockers)
          after_snapshot = agent_run_workspace_snapshot
          unauthorized_changes = agent_run_unauthorized_workspace_changes(before_snapshot, after_snapshot, [])
          unless unauthorized_changes.empty?
            blocking_issues << "openmanus rejected changes outside the isolated workspace: #{unauthorized_changes.join(", ")}"
          end
          changed_source_files, validation_blockers, validator = agent_run_validate_openmanus_workspace(
            workspace_dir: workspace_dir,
            source_paths: source_paths,
            base_hashes: contract.dig("context", "base_hashes")
          )
          blocking_issues.concat(validation_blockers)
          preapply_patch = agent_run_openmanus_workspace_diff(workspace_dir, changed_source_files)
          blocking_issues.concat(agent_run_validate_source_diff(preapply_patch, source_paths))
          if result[:success] && blocking_issues.empty?
            agent_run_apply_openmanus_changes(workspace_dir, changed_source_files)
            status = changed_source_files.empty? ? "no_changes" : "passed"
          else
            status = "failed"
          end
        else
          blocking_issues.concat(workspace_blockers)
          validator = {
            "schema_version" => 1,
            "status" => "blocked",
            "changed_source_files" => [],
            "blocking_issues" => blocking_issues
          }
        end

        changes << write_file(stdout_path, stdout, false)
        changes << write_file(stderr_path, stderr, false)
        changes << write_file(network_log_path, "network_allowed=false\n", false)
        changes << write_file(browser_log_path, "browser_navigation_allowed=localhost-only\n", false)
        changes << write_file(tool_broker_log_path, agent_run_openmanus_tool_broker_log(workspace_dir), false)
        changes << write_file(denied_access_log_path, blocking_issues.join("\n") + (blocking_issues.empty? ? "" : "\n"), false)
        diff_patch, diff_changed_files = if status == "passed" || status == "no_changes"
                                           agent_run_source_diff(source_paths)
                                         else
                                           [preapply_patch.to_s, changed_source_files]
                                         end
        diff_validation_blockers = agent_run_validate_source_diff(diff_patch, source_paths)
        unless diff_validation_blockers.empty?
          blocking_issues.concat(diff_validation_blockers)
          status = "failed"
        end
        changes << write_file(diff_path, diff_patch, false)
        patch_hash = diff_patch.to_s.empty? ? nil : "sha256:#{Digest::SHA256.hexdigest(diff_patch)}"
        validator ||= {}
        validator["status"] = blocking_issues.empty? ? "passed" : status
        validator["changed_source_files"] = changed_source_files
        validator["diff_changed_files"] = diff_changed_files
        validator["patch_hash"] = patch_hash
        validator["blocking_issues"] = blocking_issues
        validator["openmanus_report"] = openmanus_report if openmanus_report
        changes << write_json(validator_path, validator, false)

        result_payload = agent_run_openmanus_result_payload(
          status: status,
          exit_code: exit_code,
          changed_source_files: changed_source_files,
          diff_path: relative(diff_path),
          patch_hash: patch_hash,
          base_hashes: contract.dig("context", "base_hashes"),
          blocking_issues: blocking_issues,
          stdout_path: relative(stdout_path),
          stderr_path: relative(stderr_path),
          context_path: relative(context_path),
          validator_path: relative(validator_path),
          network_log_path: relative(network_log_path),
          browser_log_path: relative(browser_log_path),
          denied_access_log_path: relative(denied_access_log_path),
          tool_broker_log_path: relative(tool_broker_log_path),
          openmanus_report: openmanus_report
        )
        changes << write_json(result_path, result_payload, false)

        metadata = agent_run_run_metadata(
          run_id: run_id,
          agent: "openmanus",
          task_source: task_source,
          context: context,
          command: command.join(" "),
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
          status: status,
          changed_source_files: changed_source_files
        )
        metadata["mode"] = "approved"
        metadata["permission_profile"] = "implementation-local-no-network"
        metadata["openmanus"] = contract.merge(
          "result_path" => relative(result_path),
          "validator_path" => relative(validator_path),
          "patch_hash" => patch_hash,
          "evidence" => result_payload.fetch("evidence")
        )
        changes << write_json(metadata_path, metadata, false)
        changes.concat(changed_source_files)

        state["implementation"]["latest_agent_run"] = relative(metadata_path)
        state["implementation"]["last_diff"] = relative(diff_path)
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)

        payload = agent_run_payload(
          state: state,
          metadata: metadata,
          changed_files: compact_changes(changes),
          planned_changes: [],
          action_taken: status == "passed" ? "ran openmanus patch" : (status == "no_changes" ? "openmanus produced no source diff" : "openmanus agent run failed"),
          blocking_issues: blocking_issues,
          next_action: agent_run_next_action(metadata)
        )
      end
      payload
    end



  end
end
