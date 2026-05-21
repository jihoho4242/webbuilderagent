# frozen_string_literal: true

require "cgi"
require "digest"
require "fileutils"
require "find"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "set"
require "shellwords"
require "timeout"
require "time"
require "uri"
require "yaml"

require_relative "errors"
require_relative "redaction"
require_relative "authz_contract"
require_relative "archetypes"
require_relative "design_brief"
require_relative "design_candidate_generator"
require_relative "design_research"
require_relative "design_system_resolver"
require_relative "intent_router"
require_relative "lazyweb_client"
require_relative "profiles"
require_relative "profile_policy"
require_relative "runtime"
require_relative "constitution"
require_relative "policy"
require_relative "tools"
require_relative "approval"
require_relative "brain"
require_relative "self_improvement"
require_relative "observability"
require_relative "evals"
require_relative "redteam"
require_relative "ops"
require_relative "agent_runtime"
require_relative "project/features"

module Aiweb
  class Project
    include ProjectFeatures
    PHASES = %w[
      phase--1
      phase-0
      phase-0.25
      phase-0.5
      phase-1
      phase-1.5
      phase-2
      phase-2.5
      phase-3
      phase-3.5
      phase-4
      phase-5
      phase-6
      phase-7
      phase-8
      phase-9
      phase-10
      phase-11
      complete
    ].freeze

    ADVANCE_PHASES = (PHASES - ["phase--1", "complete"]).freeze

    REQUIRED_TOP_LEVEL_STATE_KEYS = %w[
      schema_version project phase gates artifacts design_candidates research implementation setup qa deploy budget adapters invalidations decisions snapshots
    ].freeze

    DESIGN_REFERENCE_BRIEF_PATH = ".ai-web/design-reference-brief.md".freeze
    DESIGN_REFERENCE_RESULTS_PATH = ".ai-web/research/lazyweb/results.json".freeze
    DESIGN_PATTERN_MATRIX_PATH = ".ai-web/research/lazyweb/pattern-matrix.md".freeze

    SCAFFOLD_PROFILE_D_METADATA_PATH = ".ai-web/scaffold-profile-D.json".freeze
    SCAFFOLD_PROFILE_S_METADATA_PATH = ".ai-web/scaffold-profile-S.json".freeze
    SCAFFOLD_PROFILE_S_SECRET_QA_PATH = ".ai-web/qa/supabase-secret-qa.json".freeze
    SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH = ".ai-web/qa/supabase-local-verify.json".freeze
    GITHUB_SYNC_PLAN_PATH = ".ai-web/github-sync.json".freeze
    DEPLOY_PLAN_PATH = ".ai-web/deploy-plan.json".freeze
    DEPLOY_PROVIDER_CONFIG_PATHS = {
      "cloudflare-pages" => ".ai-web/deploy/cloudflare-pages.json",
      "vercel" => ".ai-web/deploy/vercel.json"
    }.freeze
    VERIFY_LOOP_MAX_CYCLES = 10
    ACTIVE_RUN_LOCK_PATH = ".ai-web/runs/active-run.json"
    RUN_LIFECYCLE_FILE = "lifecycle.json"
    RUN_CANCEL_REQUEST_FILE = "cancel-request.json"
    RUN_RESUME_PLAN_FILE = "resume-plan.json"
    RUN_METADATA_FILENAMES = %w[
      verify-loop.json
      deploy.json
      workbench-serve.json
      setup.json
      agent-run.json
      engine-run.json
      preview.json
    ].freeze

    REMOVED_DIRECTOR_RUN_ACTIONS = %w[
      interview
      design-prompt
      placeholder-design-candidate
      next-task
      qa-checklist
    ].freeze

    SCAFFOLD_PROFILE_D_REQUIRED_FILES = %w[
      package.json
      astro.config.mjs
      tailwind.config.mjs
      src/styles/global.css
      src/content/site.json
      src/components/Hero.astro
      src/components/SectionCard.astro
      src/pages/index.astro
      public/.gitkeep
      .ai-web/scaffold-profile-D.json
    ].freeze

    PROFILE_D_EXPECTED_SCRIPTS = {
      "dev" => "astro dev",
      "build" => "astro build",
      "preview" => "astro preview"
    }.freeze

    PROFILE_D_EXPECTED_DEPENDENCIES = %w[
      @astrojs/mdx
      @astrojs/sitemap
      astro
      tailwindcss
      @tailwindcss/vite
    ].freeze

    SCAFFOLD_PROFILE_S_REQUIRED_FILES = %w[
      package.json
      next.config.mjs
      tsconfig.json
      src/app/layout.tsx
      src/app/page.tsx
      src/app/globals.css
      src/lib/supabase/client.ts
      src/lib/supabase/server.ts
      supabase/migrations/0001_initial_schema.sql
      supabase/rls-draft.md
      supabase/storage.md
      supabase/env.example.template
      .ai-web/scaffold-profile-S.json
      .ai-web/qa/supabase-secret-qa.json
    ].freeze

    PROFILE_S_SECRET_EXPOSURE_PATTERNS = [
      /SUPABASE_SERVICE_ROLE_KEY/,
      /sb_secret_[A-Za-z0-9_-]+/,
      /eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/
    ].freeze
    attr_reader :root, :templates_dir

    def initialize(root)
      @root = File.expand_path(root)
      @templates_dir = File.expand_path("../../docs/templates", __dir__)
    end

    def aiweb_dir
      File.join(root, ".ai-web")
    end

    def initialized?
      File.exist?(state_path)
    end

    def state_path
      File.join(aiweb_dir, "state.yaml")
    end

    def quality_path
      File.join(aiweb_dir, "quality.yaml")
    end

    def next_task(type: nil, dry_run: false, force: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        phase_guard!(state, "next-task", %w[phase-6 phase-7 phase-8 phase-9 phase-10 phase-11], force)
        task_type = type.to_s.strip.empty? ? recommended_task_type(state) : type.to_s.strip
        task_id = "task-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{slug(task_type)}"
        task_path = File.join(aiweb_dir, "tasks", "#{task_id}.md")
        changes << write_file(task_path, task_packet_markdown(task_id, task_type, state), dry_run)
        state["implementation"]["current_task"] = relative(task_path)
        add_decision!(state, "task_packet", "Generated #{task_type} task packet")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "generated task packet #{task_id}"
      end
      payload
    end

    def qa_checklist(dry_run: false, force: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        phase_guard!(state, "qa-checklist", %w[phase-7 phase-8 phase-9 phase-10 phase-11], force)
        path = File.join(aiweb_dir, "qa", "current-checklist.md")
        changes << write_file(path, qa_checklist_markdown(state), dry_run)
        state["qa"]["current_checklist"] = relative(path)
        add_decision!(state, "qa_checklist", "Generated current QA checklist")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "generated QA checklist"
      end
      payload
    end

    def qa_report(status: "passed", task_id: nil, duration_minutes: nil, timed_out: false, from: nil, dry_run: false, force: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        phase_guard!(state, "qa-report", %w[phase-7 phase-8 phase-9 phase-10 phase-11], force)
        result = from ? load_json_file(from) : default_qa_result(status, task_id, duration_minutes, timed_out)
        normalize_qa_result!(result, state)
        validate_qa_result!(result)
        enforce_qa_timeout_recovery_budget!(state, result)

        result_id = "qa-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{slug(result["task_id"])}"
        path = File.join(aiweb_dir, "qa", "results", "#{result_id}.json")
        changes << write_json(path, result, dry_run)
        state["qa"]["last_result"] = relative(path)

        failures = qa_failures_from_result(result, state, relative(path))
        unless failures.empty?
          state["qa"]["open_failures"] ||= []
          state["qa"]["open_failures"].concat(failures)
          fix_path = File.join(aiweb_dir, "tasks", "fix-#{failures.first["id"]}.md")
          changes << write_file(fix_path, qa_fix_task_markdown(failures, result, state), dry_run)
          result["recommended_action"] = "create_fix_packet"
          result["created_fix_task"] = relative(fix_path)
          changes << write_json(path, result, dry_run)
        end

        if state.dig("phase", "current") == "phase-11"
          final_path = File.join(aiweb_dir, "qa", "final-report.md")
          changes << write_file(final_path, final_qa_report_markdown(state, result, failures), dry_run)
          mark_artifacts_from_files!(state)
        end

        add_decision!(state, "qa_report", "Recorded QA result #{result["status"]} for #{result["task_id"]}")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "recorded QA report"
      end
      payload
    end

    def github_sync(remote: nil, branch: nil, dry_run: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        ensure_pr19_deploy_defaults!(state)
        plan = github_sync_plan_payload(state, remote: remote, branch: branch, dry_run: dry_run)
        planned_changes = [GITHUB_SYNC_PLAN_PATH]

        unless dry_run
          changes << write_json(File.join(root, GITHUB_SYNC_PLAN_PATH), plan, false)
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
        payload["next_action"] = "review #{GITHUB_SYNC_PLAN_PATH}; external GitHub push/PR actions require explicit approval outside this command"
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
        if !target_phase.empty? && !PHASES.include?(target_phase)
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

    def load_state
      assert_initialized!
      YAML.load_file(state_path)
    rescue Psych::SyntaxError => e
      raise UserError.new("cannot parse state.yaml: #{e.message}", 1)
    end




    private

    class BlockedAdvance < StandardError
      attr_reader :payload
      def initialize(payload)
        @payload = payload
        super("advance blocked")
      end
    end
  end
end
