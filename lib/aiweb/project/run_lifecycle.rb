# frozen_string_literal: true

require "fileutils"
require "json"
require "shellwords"
require_relative "run_lifecycle/resume_plan"
require_relative "run_lifecycle/records"

module Aiweb
  module ProjectRunLifecycle
    def run_status(run_id: nil)
      assert_initialized!
      state = load_state
      lifecycle = run_lifecycle_status(run_id: run_id)
      payload = status_hash(state: state, changed_files: [])
      payload["action_taken"] = "reported run lifecycle"
      payload["run_lifecycle"] = lifecycle
      payload["next_action"] = lifecycle["active_run"] ? "inspect the active run or request cancellation with aiweb run-cancel --run-id active" : 'start a natural-language local run such as aiweb agent "improve this website" --mode supervised --dry-run'
      payload
    end

    def run_timeline(limit: 20)
      assert_initialized!
      state = load_state
      bounded_limit = bounded_observability_limit(limit)
      timeline = workbench_run_timeline(bounded_limit)
      payload = status_hash(state: state, changed_files: [])
      payload["action_taken"] = "reported run timeline"
      payload["run_timeline"] = {
        "schema_version" => 1,
        "status" => timeline.empty? ? "empty" : "ready",
        "generated_at" => now,
        "limit" => bounded_limit,
        "active_run" => read_active_run_lock,
        "active_run_live" => active_run_live?(read_active_run_lock),
        "runs" => timeline,
        "blocking_issues" => []
      }
      payload["next_action"] = timeline.empty? ? "run a local command that records .ai-web/runs evidence, then rerun aiweb run-timeline" : "inspect the timeline entries or run aiweb observability-summary for a compact status rollup"
      payload
    end

    def observability_summary(limit: 20)
      assert_initialized!
      state = load_state
      bounded_limit = bounded_observability_limit(limit)
      timeline = workbench_run_timeline(bounded_limit)
      active = read_active_run_lock
      latest_deploy_path = state.dig("deploy", "latest_deploy")
      latest_deploy = latest_deploy_path && !unsafe_env_path?(latest_deploy_path) ? workbench_json_summary(latest_deploy_path, allow_runs: true) : nil
      statuses = timeline.map { |entry| entry["status"].to_s.empty? ? "unknown" : entry["status"].to_s }
      recent_blockers = timeline.flat_map { |entry| Array(entry["blocking_issues"]) }.compact.map(&:to_s).reject(&:empty?).first(10)
      summary = {
        "schema_version" => 1,
        "status" => active_run_live?(active) ? "running" : (timeline.empty? ? "empty" : "ready"),
        "generated_at" => now,
        "limit" => bounded_limit,
        "active_run" => active,
        "active_run_live" => active_run_live?(active),
        "latest_verify_loop" => workbench_verify_loop_status(state),
        "latest_deploy" => latest_deploy,
        "recent_run_count" => timeline.length,
        "recent_status_counts" => statuses.each_with_object(Hash.new(0)) { |status, memo| memo[status] += 1 },
        "recent_blockers" => recent_blockers,
        "recent_runs" => timeline,
        "blocking_issues" => []
      }
      payload = status_hash(state: state, changed_files: [])
      payload["action_taken"] = "reported observability summary"
      payload["observability_summary"] = summary
      payload["next_action"] = active ? "inspect active run with aiweb run-status --run-id active or request cancellation with aiweb run-cancel --run-id active" : 'continue with aiweb agent "improve this website" --mode supervised --dry-run or inspect aiweb run-timeline'
      payload
    end

    def run_cancel(run_id: "active", dry_run: false, force: false)
      assert_initialized!
      state = load_state
      target = resolve_run_lifecycle_target(run_id)
      blockers = []
      blockers << "no active or matching run found for #{run_id.to_s.empty? ? "active" : run_id}" unless target
      run_dir = target && run_lifecycle_run_dir(target.fetch("run_id"))
      request_path = run_dir && File.join(run_dir, self.class::RUN_CANCEL_REQUEST_FILE)
      metadata = run_cancel_request_metadata(target, request_path, dry_run: dry_run, force: force, blocking_issues: blockers)

      if dry_run || !blockers.empty?
        payload = status_hash(state: state, changed_files: [])
        payload["action_taken"] = blockers.empty? ? "planned run cancellation" : "run cancellation blocked"
        payload["run_lifecycle"] = {
          "status" => blockers.empty? ? "cancel_planned" : "blocked",
          "selected_run" => target,
          "cancel_request" => metadata,
          "blocking_issues" => blockers
        }
        payload["planned_changes"] = blockers.empty? ? [relative(request_path), relative(run_lifecycle_path(target.fetch("run_id")))] : []
        payload["blocking_issues"] = (payload["blocking_issues"] + blockers).uniq
        payload["next_action"] = blockers.empty? ? "rerun aiweb run-cancel --run-id #{target.fetch("run_id")} without --dry-run to request cancellation" : "inspect aiweb run-status before requesting cancellation"
        return payload
      end

      changes = []
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << write_json(request_path, metadata, false)
        changes << write_json(run_lifecycle_path(target.fetch("run_id")), run_lifecycle_record(target).merge(
          "status" => "cancel_requested",
          "cancel_requested_at" => metadata["requested_at"],
          "cancel_request_path" => relative(request_path)
        ), false)
        if active_run_matches?(target.fetch("run_id"))
          active = read_active_run_lock || {}
          active = active.merge(
            "status" => "cancel_requested",
            "cancel_requested_at" => metadata["requested_at"],
            "cancel_request_path" => relative(request_path)
          )
          changes << write_json(active_run_lock_path, active, false)
        end
        if target["kind"] == "workbench-serve" && live_process?(target["pid"].to_i)
          Process.kill("TERM", target["pid"].to_i)
          metadata["process_signal"] = "TERM"
          changes << write_json(request_path, metadata, false)
          workbench_metadata_path = run_main_metadata_path(target.fetch("run_id"))
          workbench_metadata = workbench_metadata_path && read_json_file(workbench_metadata_path)
          if workbench_metadata
            workbench_metadata = workbench_metadata.merge(
              "status" => "cancelled",
              "finished_at" => now,
              "blocking_issues" => []
            )
            changes << write_json(workbench_metadata_path, workbench_metadata, false)
          end
          changes << write_json(run_lifecycle_path(target.fetch("run_id")), run_lifecycle_record(target).merge(
            "status" => "cancelled",
            "finished_at" => now,
            "cancel_requested_at" => metadata["requested_at"],
            "cancel_request_path" => relative(request_path)
          ), false)
          FileUtils.rm_f(active_run_lock_path) if active_run_matches?(target.fetch("run_id"))
        end
      end

      payload = status_hash(state: load_state, changed_files: compact_changes(changes))
      payload["action_taken"] = "requested run cancellation"
      payload["run_lifecycle"] = {
        "status" => "cancel_requested",
        "selected_run" => target,
        "cancel_request" => metadata,
        "blocking_issues" => []
      }
      payload["next_action"] = "poll aiweb run-status; long-running commands stop at their next lifecycle checkpoint"
      payload
    end

    def run_resume(run_id: "latest", dry_run: false)
      assert_initialized!
      state = load_state
      target = resolve_run_lifecycle_target(run_id.to_s.strip.empty? ? "latest" : run_id)
      metadata = target && run_main_metadata(target.fetch("run_id"))
      plan = metadata ? run_resume_plan(target, metadata) : nil
      blockers = []
      blockers << "no matching run found for #{run_id}" unless target
      blockers << "run type is not resumable by descriptor" if target && plan.nil?
      plan_path = target && File.join(run_lifecycle_run_dir(target.fetch("run_id")), self.class::RUN_RESUME_PLAN_FILE)

      if dry_run || !blockers.empty?
        payload = status_hash(state: state, changed_files: [])
        payload["action_taken"] = blockers.empty? ? "planned run resume" : "run resume blocked"
        payload["run_lifecycle"] = {
          "status" => blockers.empty? ? "resume_planned" : "blocked",
          "selected_run" => target,
          "resume_plan" => plan,
          "blocking_issues" => blockers
        }
        payload["planned_changes"] = blockers.empty? ? [relative(plan_path)] : []
        payload["blocking_issues"] = (payload["blocking_issues"] + blockers).uniq
        payload["next_action"] = blockers.empty? ? "rerun aiweb run-resume --run-id #{target.fetch("run_id")} to record the resume descriptor; any lower-level approved execution must remain approval_hash-gated" : "inspect aiweb run-status and choose a resumable run"
        return payload
      end

      changes = []
      mutation(dry_run: false) do
        FileUtils.mkdir_p(File.dirname(plan_path))
        changes << write_json(plan_path, plan, false)
        changes << write_json(run_lifecycle_path(target.fetch("run_id")), run_lifecycle_record(target).merge(
          "status" => "resume_planned",
          "resume_planned_at" => plan["created_at"],
          "resume_plan_path" => relative(plan_path)
        ), false)
      end

      payload = status_hash(state: load_state, changed_files: compact_changes(changes))
      payload["action_taken"] = "recorded run resume descriptor"
      payload["run_lifecycle"] = {
        "status" => "resume_planned",
        "selected_run" => target,
        "resume_plan" => plan,
        "blocking_issues" => []
      }
      payload["next_action"] = plan.fetch("next_command")
      payload
    end

  private

  end
end
