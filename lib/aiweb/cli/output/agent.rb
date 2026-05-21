# frozen_string_literal: true

module Aiweb
  class CLI
    module Output
      private

    def human_agent_run_result(result)
      agent_run = result.fetch("agent_run")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = agent_run["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[run_dir stdout_path stderr_path metadata_path diff_path planned_run_dir planned_stdout_path planned_stderr_path planned_metadata_path planned_diff_path].each do |key|
        value = agent_run[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Agent run: #{agent_run["status"] || "n/a"}",
        "Task: #{agent_run["task"] || "n/a"}",
        "Agent: #{agent_run["agent"] || "n/a"}",
        "Dry run: #{agent_run.key?("dry_run") ? agent_run["dry_run"] : "n/a"}",
        "Approved: #{agent_run.key?("approved") ? agent_run["approved"] : "n/a"}",
        "Command: #{agent_run["command"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Agent run paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_agent_runtime_result(result)
      runtime = result.fetch("agent_runtime")
      session = runtime["agent_session"] || result["agent_session"] || {}
      artifacts = runtime["artifacts"] || {}
      blockers = runtime["blocking_issues"] || result["blocking_issues"] || []
      steps = Array(runtime["steps"]).map { |step| step["tool"] || step["name"] }.compact
      tool_statuses = Array(runtime["toolResults"]).map { |tool| "#{tool["tool"]}=#{tool["status"]}" }
      [
        "Agent runtime: #{runtime["status"] || "n/a"}",
        "Goal: #{session["goal"] || "n/a"}",
        "Mode/profile/approved: #{runtime["mode"] || session["mode"] || "n/a"}/#{runtime["profile"] || session["profile"] || "n/a"}/#{session.key?("approved") ? session["approved"] : "n/a"}",
        "Planned tools: #{steps.empty? ? "none" : steps.join(", ")}",
        "Tool results: #{tool_statuses.empty? ? "none" : tool_statuses.join(", ")}",
        "Browser QA: #{runtime.dig("browserQa", "status") || "n/a"}",
        "Patch manifest: #{runtime.dig("patchManifest", "verifier_decision") || "n/a"}",
        "Run dir: #{artifacts["run_dir"] || session.dig("artifact_paths", "run_dir") || "n/a"}",
        "Final report: #{artifacts["final_report"] || session.dig("artifact_paths", "final_report") || "n/a"}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_eval_baseline_result(result)
      baseline = result.fetch("eval_baseline")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = baseline["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[source_path target_path validation_path review_pack_path planned_target_path planned_validation_path planned_review_pack_path candidate_path].each do |key|
        value = baseline[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Eval baseline: #{baseline["status"] || "n/a"}",
        "Action: #{baseline["action"] || "n/a"}",
        "Dry run: #{baseline.key?("dry_run") ? baseline["dry_run"] : "n/a"}",
        "Approved: #{baseline.key?("approved") ? baseline["approved"] : "n/a"}",
        "Fixtures checked: #{baseline["fixture_count"] || 0}",
        "Calibrated fixtures: #{baseline["calibrated_fixture_count"] || 0}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_verify_loop_result(result)
      loop = result.fetch("verify_loop")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = loop["blocking_issues"] || result["blocking_issues"] || []
      steps = Array(loop["planned_steps"]).empty? ? Array(loop["cycles"]).flat_map { |cycle| Array(cycle["steps"]).map { |step| step["name"] } }.uniq : Array(loop["planned_steps"]).flat_map { |cycle| cycle["steps"] }.uniq
      [
        "Verify loop: #{loop["status"] || "n/a"}",
        "Max cycles: #{loop["max_cycles"] || "n/a"}",
        "Cycles run: #{loop["cycle_count"] || 0}",
        "Dry run: #{loop.key?("dry_run") ? loop["dry_run"] : "n/a"}",
        "Approved: #{loop.key?("approved") ? loop["approved"] : "n/a"}",
        "Metadata: #{loop["metadata_path"] || "n/a"}",
        "Run dir: #{loop["run_dir"] || "n/a"}",
        "Steps: #{steps.empty? ? "none" : steps.join(", ")}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end
    end
  end
end
