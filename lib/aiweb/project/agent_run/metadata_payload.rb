# frozen_string_literal: true

module Aiweb
  module ProjectAgentRun
    private

    def agent_run_run_metadata(run_id:, agent:, task_source:, context:, command:, context_path:, started_at:, finished_at:, exit_code:, stdout_log:, stderr_log:, metadata_path:, diff_path:, source_paths:, dry_run:, approved:, blocking_issues:, status:, changed_source_files: [], approval_hash: nil, capability: nil)
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
        "approval_hash" => approval_hash,
        "capability" => capability,
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
        "inspect #{metadata["stdout_log"]} and #{metadata["stderr_log"]}, rerun aiweb agent-run --task latest --agent #{agent} --dry-run for a fresh approval_hash, then execute with --approval-hash HASH --approved"
      else
        "add a safe source target to the task packet or component map, rerun aiweb agent-run --task latest --agent #{agent} --dry-run for an approval_hash, then execute with --approval-hash HASH --approved"
      end
    end

    def agent_run_capability_envelope(run_id:, agent:, sandbox:, task_source:, context:, source_paths:, target_allowlist:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "command" => "agent-run",
        "agent" => agent,
        "sandbox" => sandbox,
        "task_path" => task_source["relative"],
        "task_sha256" => task_source["path"] && File.file?(task_source["path"]) ? Digest::SHA256.file(task_source["path"]).hexdigest : nil,
        "source_paths" => Array(source_paths).sort,
        "source_base_hashes" => agent_run_source_base_hashes(source_paths),
        "selected_candidate" => context["selected_candidate"],
        "target_allowlist" => target_allowlist,
        "allowed_tools" => %w[source_patch],
        "forbidden" => %w[env credentials external_network package_install build preview qa deploy provider_cli git_push],
        "limits" => {
          "max_source_files" => 10,
          "timeout_sec" => 600,
          "max_output_bytes" => 200_000
        },
        "copy_back" => {
          "requires_validation" => true,
          "secret_scan" => true,
          "allowed_source_paths_only" => true
        }
      }
    end

    def agent_run_approval_hash(capability)
      stable = capability.to_h.reject { |key, _value| key == "run_id" }
      Digest::SHA256.hexdigest(JSON.generate(stable))
    end

    def agent_run_source_base_hashes(source_paths)
      Array(source_paths).sort.each_with_object({}) do |path, memo|
        full = File.join(root, path)
        memo[path] = File.file?(full) ? Digest::SHA256.file(full).hexdigest : nil
      end
    end
  end
end
