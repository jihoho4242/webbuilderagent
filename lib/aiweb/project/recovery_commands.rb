# frozen_string_literal: true

require "digest"

module Aiweb
  module ProjectRecoveryCommands
    class BlockedAdvance < StandardError
      attr_reader :payload

      def initialize(payload)
        @payload = payload
        super("advance blocked")
      end
    end

    def github_sync(remote: nil, branch: nil, dry_run: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        ensure_pr19_deploy_defaults!(state)
        plan = github_sync_plan_payload(state, remote: remote, branch: branch, dry_run: dry_run)
        planned_changes = [Aiweb::Project::GITHUB_SYNC_PLAN_PATH]

        unless dry_run
          changes << write_json(File.join(root, Aiweb::Project::GITHUB_SYNC_PLAN_PATH), plan, false)
          mark_artifacts_from_files!(state)
          state["deploy"]["github_sync_last_planned_at"] = plan["created_at"]
          add_decision!(state, "github_sync_plan", "Recorded local-only GitHub sync plan; no remotes were mutated")
          state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
          changes << write_yaml(state_path, state, false)
        end

        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = dry_run ? "planned local-only GitHub sync" : "recorded local-only GitHub sync plan"
        payload["github_sync"] = plan
        payload.merge!(pr19_safety_payload(planned_changes))
        payload["planned_changes"] = planned_changes
        payload["next_action"] = "review #{Aiweb::Project::GITHUB_SYNC_PLAN_PATH}; external GitHub push/PR actions require explicit approval outside this command"
      end
      payload
    end

    def rollback(to: nil, failure: nil, reason: nil, dry_run: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        target_phase = to.to_s.strip
        if !target_phase.empty? && !Aiweb::Project::PHASES.include?(target_phase)
          raise UserError.new("unknown target phase #{target_phase.inspect}", 1)
        end
        invalidation = {
          "id" => "rollback-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}",
          "failure" => failure.to_s.empty? ? nil : failure.to_s,
          "from_phase" => state.dig("phase", "current"),
          "to_phase" => target_phase.empty? ? state.dig("phase", "current") : target_phase,
          "reason" => reason.to_s.empty? ? "manual rollback decision" : reason.to_s,
          "created_at" => now,
          "affected_tasks" => [state.dig("implementation", "current_task")].compact
        }
        state["phase"]["current"] = invalidation["to_phase"]
        state["phase"]["blocked"] = true
        state["phase"]["block_reason"] = "rollback: #{invalidation["reason"]}"
        state["invalidations"] ||= []
        state["invalidations"] << invalidation
        path = File.join(aiweb_dir, "rollback-#{invalidation["id"]}.md")
        changes << write_file(path, rollback_markdown(invalidation), dry_run)
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "recorded rollback decision"
      end
      payload
    end

    def resolve_blocker(reason: nil, dry_run: false)
      assert_initialized!
      reason = reason.to_s.strip
      raise UserError.new("resolve-blocker requires --reason", 1) if reason.empty?

      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        state["phase"]["blocked"] = false
        state["phase"]["block_reason"] = ""
        add_decision!(state, "blocker_resolved", reason)
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "resolved phase blocker"
      end
      payload
    end

    def snapshot(reason: nil, dry_run: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        id = "snapshot-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}"
        snapshot_dir = File.join(aiweb_dir, "snapshots", id)
        changes << create_dir(snapshot_dir, dry_run)
        unless dry_run
          copy_snapshot_contents(snapshot_dir)
        end
        manifest = {
          "id" => id,
          "created_at" => now,
          "reason" => reason.to_s.empty? ? "manual snapshot" : reason.to_s,
          "phase" => state.dig("phase", "current"),
          "state_sha256" => File.exist?(state_path) ? Digest::SHA256.file(state_path).hexdigest : nil
        }
        changes << write_json(File.join(snapshot_dir, "manifest.json"), manifest, dry_run)
        state["snapshots"] ||= []
        state["snapshots"] << manifest.merge("path" => relative(snapshot_dir))
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "created snapshot #{id}"
      end
      payload
    end

    def advance(dry_run: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        refresh_state!(state)
        validation_errors = validate_state_shape(state)
        raise UserError.new("state validation failed: #{validation_errors.join("; ")}", 1) unless validation_errors.empty?

        blockers = phase_blockers(state)
        unless blockers.empty?
          state["phase"]["blocked"] = true
          state["phase"]["block_reason"] = blockers.join("; ")
          changes << write_yaml(state_path, state, dry_run)
          payload = status_hash(state: state, changed_files: compact_changes(changes))
          payload["action_taken"] = "advance blocked"
          payload["blocking_issues"] = blockers
          raise BlockedAdvance.new(payload)
        end

        current = state.dig("phase", "current")
        next_phase = next_phase_after(current)
        if next_phase == current
          action = "already at final phase"
        else
          state["phase"]["completed"] ||= []
          state["phase"]["completed"] << current unless state["phase"]["completed"].include?(current)
          state["phase"]["current"] = next_phase
          state["phase"]["blocked"] = false
          state["phase"]["block_reason"] = ""
          action = "advanced #{current} -> #{next_phase}"
        end
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = action
        payload["blocking_issues"] = []
        payload["next_action"] = next_action_for(state, [])
      end
      payload
    rescue BlockedAdvance => e
      e.payload
    end

    def run(dry_run: false)
      assert_initialized!
      state = load_state
      metadata = removed_director_run_metadata(state, dry_run: dry_run)
      status_hash(state: state, changed_files: []).merge(
        "action_taken" => removed_director_run_action_taken(metadata),
        "director_run" => metadata,
        "planned_changes" => [],
        "blocking_issues" => Array(metadata["blocking_issues"]).uniq,
        "next_action" => removed_director_run_next_action
      )
    end

  end
end
