# frozen_string_literal: true

module Aiweb
  module ProjectFlowHelpers
    private

    def phase_lock_blockers(state)
      return [] unless state.dig("phase", "blocked") == true

      reason = state.dig("phase", "block_reason").to_s
      return [] unless reason.start_with?("rollback:") || reason.start_with?("phase is blocked by rollback:")

      detail = reason.sub(/^rollback:\s*/, "").sub(/^phase is blocked by rollback:\s*/, "")
      detail = detail.sub(/; run aiweb resolve-blocker .*$/, "")
      ["phase is blocked by rollback: #{detail}; run aiweb resolve-blocker --reason \"...\" after recovery evidence is recorded"]
    end

    def missing_artifacts(artifacts, keys)
      keys.each_with_object([]) do |key, out|
        meta = artifacts[key]
        if meta.nil? || %w[missing stub].include?(meta["status"])
          out << "artifact #{key} is #{meta ? meta["status"] : "missing"}"
        end
      end
    end

    def next_phase_after(current)
      idx = self.class::ADVANCE_PHASES.index(current)
      return current if idx.nil?
      return "complete" if idx >= self.class::ADVANCE_PHASES.length - 1
      self.class::ADVANCE_PHASES[idx + 1]
    end

    def status_hash(state:, changed_files:)
      refresh_state!(state)
      blockers = phase_blockers(state)
      missing = (state["artifacts"] || {}).select { |_k, v| v.is_a?(Hash) && v["status"] == "missing" }.keys
      {
        "schema_version" => 1,
        "current_phase" => state.dig("phase", "current"),
        "action_taken" => "status",
        "changed_files" => changed_files,
        "blocking_issues" => blockers,
        "missing_artifacts" => missing,
        "gates" => summarize_gates(state),
        "design_candidates" => {
          "count" => state.dig("artifacts", "design_candidates", "count").to_i,
          "min_required" => state.dig("design_candidates", "min_required"),
          "max_allowed" => state.dig("design_candidates", "max_allowed"),
          "selected_candidate" => state.dig("design_candidates", "selected_candidate")
        },
        "design_research" => design_research_summary(state),
        "current_task" => state.dig("implementation", "current_task"),
        "open_failures" => state.dig("qa", "open_failures") || [],
        "budget" => summarize_budget(state),
        "next_action" => next_action_for(state, blockers)
      }
    end

    def removed_director_run_metadata(state, dry_run:)
      requested_execution = !dry_run
      blocking_issues = []
      if requested_execution
        blocking_issues << "aiweb run has been removed as a phase-script execution engine; use aiweb agent --dry-run or aiweb engine-run --dry-run directly"
      end

      {
        "schema_version" => 1,
        "status" => requested_execution ? "blocked" : "dry_run",
        "current_phase" => state.dig("phase", "current"),
        "canonical_runtime" => "engine-run",
        "compatibility_role" => "removed_legacy_phase_runner_tombstone",
        "removed_command" => true,
        "legacy_execution_removed" => true,
        "script_executor_neutralized" => true,
        "execution_allowed" => false,
        "fixed_phase_action_present" => false,
        "engine_run_delegation_present" => false,
        "direct_phase_mutation_present" => false,
        "placeholder_artifact_generation_present" => false,
        "removed_actions" => self.class::REMOVED_DIRECTOR_RUN_ACTIONS,
        "dry_run" => dry_run,
        "requires_approval" => false,
        "blocking_issues" => blocking_issues,
        "guardrails" => [
          "aiweb run no longer dispatches phase-canned interview/design/task/QA actions",
          "aiweb run no longer creates placeholder design candidates",
          "local source work must enter through aiweb agent or engine-run",
          "dry-run writes nothing and launches nothing",
          "no deploy or provider CLI",
          "no .env or .env.* reads, writes, or output"
        ]
      }
    end

    def removed_director_run_action_taken(metadata)
      return "aiweb run removed command tombstone" if metadata["dry_run"]

      "aiweb run removed before phase-script execution"
    end

    def removed_director_run_next_action
      "use aiweb agent \"improve this website\" --mode supervised --dry-run or aiweb engine-run --agent codex --mode agentic_local --max-cycles 3 --dry-run; aiweb run has been removed as a phase-script runner"
    end

    def summarize_gates(state)
      (state["gates"] || {}).each_with_object({}) do |(key, value), memo|
        memo[key] = {
          "status" => value["status"],
          "artifact" => value["artifact"],
          "approved_at" => value["approved_at"]
        }
      end
    end

    def summarize_budget(state)
      budget = state["budget"] || {}
      {
        "cost_mode" => budget["cost_mode"],
        "meter_model_cost" => budget["meter_model_cost"],
        "max_design_generations_total" => budget["max_design_generations_total"],
        "max_design_candidates" => budget["max_design_candidates"],
        "max_qa_runtime_minutes" => budget["max_qa_runtime_minutes"],
        "qa_timeout_action" => budget["qa_timeout_action"],
        "max_qa_timeout_recovery_cycles" => budget["max_qa_timeout_recovery_cycles"]
      }
    end

    def next_action_for(state, blockers)
      return "resolve blockers then run aiweb advance" unless blockers.empty?
      case state.dig("phase", "current")
      when "phase-0" then "aiweb interview --idea '<website idea>'"
      when "phase-0.5" then "aiweb init --profile D"
      when "phase-3" then "aiweb design-prompt"
      when "phase-3.5" then "aiweb ingest-design --title '<candidate>'"
      when "phase-8", "phase-9" then "aiweb next-task"
      when "phase-10" then "aiweb qa-checklist"
      else "aiweb advance"
      end
    end

    def start_steps(profile, advance)
      steps = [
        "create #{root}",
        "aiweb init --profile #{profile}",
        "aiweb interview --idea '<provided idea>'",
      ]
      steps << "aiweb advance" if advance
      steps
    end

    def start_next_action(advance, final_payload)
      blockers = final_payload["blocking_issues"] || []
      return final_payload["next_action"] unless blockers.empty?
      return "review .ai-web/project.md and .ai-web/product.md, then run aiweb advance" unless advance

      "review .ai-web/quality.yaml, set quality.approved: true when accepted, then run aiweb advance"
    end



    def github_sync_plan_payload(state, remote:, branch:, dry_run:)
      selected_remote = remote.to_s.strip.empty? ? "origin" : remote.to_s.strip
      selected_branch = branch.to_s.strip.empty? ? "current" : branch.to_s.strip
      command_line = ["git", "push", selected_remote]
      command_line << selected_branch unless selected_branch == "current"
      {
        "schema_version" => 1,
        "status" => "planned",
        "dry_run" => dry_run,
        "created_at" => now,
        "project_id" => state.dig("project", "id"),
        "project_name" => state.dig("project", "name"),
        "mode" => "local_plan_only",
        "remote" => selected_remote,
        "branch" => selected_branch,
        "planned_command" => command_line.join(" "),
        "planned_artifact_path" => ".ai-web/github/github-sync.json",
        "planned_config_path" => self.class::GITHUB_SYNC_PLAN_PATH,
        "artifact_path" => dry_run ? nil : self.class::GITHUB_SYNC_PLAN_PATH,
        "planned_steps" => [
          "inspect local git status manually",
          "review remote and branch policy manually",
          "prepare commit/PR only after explicit human approval"
        ],
        "external_actions_allowed" => false,
        "external_push_performed" => false,
        "external_deploy_performed" => false,
        "pushed" => false,
        "requires_approval" => true,
        "guardrails" => ["no external push", "no network", "no provider CLI", "no build/preview/install", "no .env/.env.* access"],
        "blocked_external_actions" => ["git push", "GitHub API calls", "pull request creation", "remote mutation"]
      }
    end
  end
end
