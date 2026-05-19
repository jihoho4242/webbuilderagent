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

    def init(profile: nil, dry_run: false)
      changes = []
      payload = nil
      selected_profile = nil
      selected_profile_data = nil
      if profile
        selected_profile, selected_profile_data = Profiles.fetch!(profile)
      end
      mutation(dry_run: dry_run) do
        timestamp = now
        planned_dirs.each do |dir|
          changes << create_dir(dir, dry_run)
        end

        copy_core_templates(dry_run, changes)

        state = load_state_if_present || load_template_yaml("state.yaml")
        state["project"]["id"] = default_project_id if blank?(state.dig("project", "id"))
        state["project"]["name"] = File.basename(root) if blank?(state.dig("project", "name"))
        state["project"]["created_at"] = timestamp if blank?(state.dig("project", "created_at"))
        state["project"]["updated_at"] = timestamp
        ensure_defaults!(state)

        if selected_profile
          state["implementation"]["stack_profile"] = selected_profile
          state["implementation"]["scaffold_target"] = selected_profile_data[:scaffold_target]
          changes << write_file(File.join(aiweb_dir, "stack.md"), stack_markdown(selected_profile, selected_profile_data), dry_run)
          changes << write_file(File.join(aiweb_dir, "deploy.md"), deploy_markdown(selected_profile, selected_profile_data), dry_run)
        end

        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = selected_profile ? "initialized profile #{selected_profile}" : "initialized director workspace"
      end
      payload
    end

    def status
      assert_initialized!
      state = load_state
      refreshed = refresh_state!(state)
      payload = status_hash(state: refreshed, changed_files: [])
      validation_errors = validate_state_shape(refreshed)
      unless validation_errors.empty?
        payload["validation_errors"] = validation_errors
        payload["blocking_issues"] = (payload["blocking_issues"] + validation_errors.map { |error| "state validation failed: #{error}" }).uniq
        payload["next_action"] = "repair .ai-web/state.yaml then rerun aiweb status"
      end
      payload
    end

    def start(idea:, profile: nil, advance: true, dry_run: false)
      idea = idea.to_s.strip
      raise UserError.new("start requires --idea", 1) if idea.empty?

      route = IntentRouter.route(idea)
      selected_profile = profile.to_s.strip.empty? ? route.fetch("recommended_profile") : profile.to_s.strip
      Profiles.fetch!(selected_profile)

      if dry_run
        return {
          "schema_version" => 1,
          "current_phase" => nil,
          "action_taken" => "planned director start",
          "changed_files" => [],
          "blocking_issues" => [],
          "missing_artifacts" => [],
          "start_steps" => start_steps(selected_profile, advance),
          "next_action" => "would create #{root}, initialize profile #{selected_profile}, draft interview artifacts#{advance ? ", then advance to phase-0.25" : ""}",
        }
      end

      FileUtils.mkdir_p(root)
      init_payload = init(profile: selected_profile, dry_run: false)
      interview_payload = interview(idea: idea, dry_run: false)
      final_payload = advance ? self.advance(dry_run: false) : status
      final_payload = final_payload.merge(
        "action_taken" => advance ? "started director workspace and advanced to quality gate" : "started director workspace",
        "changed_files" => compact_changes([
          init_payload["changed_files"],
          interview_payload["changed_files"],
          final_payload["changed_files"],
        ]),
        "start_steps" => start_steps(selected_profile, advance),
        "next_action" => start_next_action(advance, final_payload)
      )
      final_payload
    end

    def interview(idea:, dry_run: false)
      assert_initialized!
      idea = idea.to_s.strip
      idea = "TODO: describe the website idea" if idea.empty?
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        intent = classify_intent(idea)
        changes << write_yaml(File.join(aiweb_dir, "intent.yaml"), intent, dry_run)
        changes << write_file(File.join(aiweb_dir, "first-view-contract.md"), first_view_contract_markdown(intent, idea), dry_run)
        changes << write_file(File.join(aiweb_dir, "project.md"), project_markdown(idea, state, intent), dry_run)
        changes << write_file(File.join(aiweb_dir, "product.md"), product_markdown(idea, intent), dry_run)
        changes << write_file(File.join(aiweb_dir, "brand.md"), brand_markdown(idea), dry_run)
        changes << write_file(File.join(aiweb_dir, "content.md"), content_markdown(idea, intent), dry_run)
        changes << write_design_brief_if_needed(intent: intent, dry_run: dry_run, force: false)
        changes << write_design_system_if_needed(intent: intent, dry_run: dry_run, force: false)
        mark_artifacts_from_files!(state)
        add_decision!(state, "interview_draft", "Generated #{intent["archetype"]} interview artifacts from idea: #{idea}")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "generated interview drafts"
      end
      payload
    end

    def design_brief(dry_run: false, force: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        changes << write_design_brief_if_needed(intent: load_intent_artifact, dry_run: dry_run, force: force)
        mark_artifacts_from_files!(state)
        add_decision!(state, "design_brief", "#{force ? "Regenerated" : "Generated"} deterministic design brief")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = force ? "regenerated design brief" : "generated design brief"
      end
      payload
    end

    def design_system_resolve(dry_run: false, force: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        intent = load_intent_artifact
        changes << write_design_brief_if_needed(intent: intent, dry_run: dry_run, force: false)
        changes << write_design_system_if_needed(intent: intent, dry_run: dry_run, force: force)
        mark_artifacts_from_files!(state)
        add_decision!(state, "design_system_resolve", "#{force ? "Regenerated" : "Resolved"} deterministic design source of truth")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = force ? "regenerated design source of truth" : "resolved design source of truth"
      end
      payload
    end


    def design_research(provider: "lazyweb", policy: nil, limit: 8, dry_run: false, force: false)
      assert_initialized!
      provider = provider.to_s.strip.empty? ? "lazyweb" : provider.to_s.strip
      unless provider == "lazyweb"
        raise UserError.new("design-research only supports provider lazyweb; received #{provider.inspect}", 1)
      end

      policy = policy.to_s.strip.empty? ? nil : policy.to_s.strip
      unless policy.nil? || %w[off opportunistic required].include?(policy)
        raise UserError.new("design-research --policy must be off, opportunistic, or required", 1)
      end

      limit = Integer(limit)
      raise UserError.new("design-research --limit must be between 1 and 50", 1) unless limit.between?(1, 50)

      state = load_state
      ensure_design_research_state_defaults!(state)
      phase_guard!(state, "design-research", %w[phase-3 phase-3.5], force)
      research = state.dig("research", "design_research")
      effective_policy = policy || research["policy"] || "opportunistic"
      paths = design_research_paths(state)
      planned_queries = design_research_planned_queries
      token_configured = lazyweb_token_configured?

      if dry_run
        payload = status_hash(state: state, changed_files: [])
        payload.merge!(
          "action_taken" => "planned design research",
          "design_research" => design_research_summary(state).merge(
            "provider" => provider,
            "policy" => effective_policy,
            "limit" => limit,
            "token_configured" => token_configured,
            "planned_queries" => planned_queries,
            "planned_artifact_paths" => paths.values
          ),
          "next_action" => "rerun aiweb design-research without --dry-run to write reference artifacts when Lazyweb is configured"
        )
        return payload
      end

      if effective_policy == "off"
        return record_design_research_skip!(state, provider, effective_policy, "policy off", paths, planned_queries, dry_run: false)
      end

      unless token_configured
        if effective_policy == "required"
          raise UserError.new("Lazyweb design research is required but no token is configured; set LAZYWEB_MCP_TOKEN or ~/.lazyweb/lazyweb_mcp_token", 2)
        end
        return record_design_research_skip!(state, provider, effective_policy, "Lazyweb token not configured", paths, planned_queries, dry_run: false)
      end

      helper_result = run_design_research_helper(state: state, provider: provider, policy: effective_policy, limit: limit)
      return helper_result if helper_result

      if effective_policy == "required"
        raise UserError.new("Lazyweb design research adapter is unavailable; expected Aiweb::DesignResearch integration", 4)
      end
      record_design_research_skip!(state, provider, effective_policy, "Lazyweb design research adapter unavailable", paths, planned_queries, dry_run: false)
    end

    def design_prompt(dry_run: false, force: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        phase_guard!(state, "design-prompt", %w[phase-3 phase-3.5], force)
        intent = load_intent_artifact
        changes << write_design_brief_if_needed(intent: intent, dry_run: dry_run, force: false)
        changes << write_design_system_if_needed(intent: intent, dry_run: dry_run, force: false)
        output = design_prompt_markdown
        path = File.join(aiweb_dir, "design-prompt.md")
        changes << write_file(path, output, dry_run)
        add_decision!(state, "design_prompt", "Generated GPT Image 2 / Claude Design prompt handoff")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "generated design prompt"
      end
      payload
    end

    def design(candidates: 3, dry_run: false, force: false)
      assert_initialized!
      count = candidates.to_i
      unless count == DesignCandidateGenerator::CANDIDATE_IDS.length
        raise UserError.new("design candidate generation supports exactly 3 candidates; received #{candidates.inspect}", 1)
      end

      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        if !force && complete_design_candidate_artifacts?
          refresh_state!(state)
          payload = status_hash(state: state, changed_files: [])
          payload["action_taken"] = "preserved existing design candidates"
          payload["next_action"] = "review .ai-web/design-candidates/comparison.md or rerun aiweb design --candidates 3 --force to regenerate"
        else
          intent = load_intent_artifact
          changes << write_design_brief_if_needed(intent: intent, dry_run: dry_run, force: false)
          changes << write_design_system_if_needed(intent: intent, dry_run: dry_run, force: false)
          generator = design_candidate_generator(intent)
          generator.candidates.each do |candidate|
            path = File.join(aiweb_dir, "design-candidates", "#{candidate.id}.html")
            changes << write_file(path, candidate.html, dry_run)
          end
          changes << write_file(File.join(aiweb_dir, "design-candidates", "comparison.md"), generator.comparison_markdown, dry_run)
          state["design_candidates"]["candidates"] = generator.candidates.map do |candidate|
            {
              "id" => candidate.id,
              "path" => ".ai-web/design-candidates/#{candidate.id}.html",
              "strategy_id" => candidate.strategy_id,
              "score" => candidate.score,
              "rubric_scores" => candidate.rubric_scores,
              "first_view" => candidate.first_view,
              "proof_pattern" => candidate.proof_pattern,
              "cta_flow" => candidate.cta_flow,
              "mobile_behavior" => candidate.mobile_behavior,
              "risks" => candidate.risks,
              "status" => "draft"
            }
          end
          state["design_candidates"]["regeneration_requested"] = false
          state["design_candidates"]["regeneration_rounds"] = state["design_candidates"]["regeneration_rounds"].to_i + (force ? 1 : 0)
          update_design_counts!(state)
          mark_artifacts_from_files!(state)
          add_decision!(state, "design_candidates_generated", "#{force ? "Regenerated" : "Generated"} 3 deterministic HTML design candidates from .ai-web/DESIGN.md")
          state["project"]["updated_at"] = now
          changes << write_yaml(state_path, state, dry_run)
          payload = status_hash(state: state, changed_files: compact_changes(changes))
          payload["action_taken"] = force ? "regenerated design candidates" : "generated design candidates"
          payload["next_action"] = "review .ai-web/design-candidates/comparison.md then run aiweb select-design candidate-01|candidate-02|candidate-03"
        end
      end
      payload
    end

    def select_design(id, dry_run: false)
      assert_initialized!
      selected_id = slug(id)
      unless DesignCandidateGenerator::CANDIDATE_IDS.include?(selected_id)
        raise UserError.new("select-design requires one of #{DesignCandidateGenerator::CANDIDATE_IDS.join(', ')}", 1)
      end
      candidate_path = File.join(aiweb_dir, "design-candidates", "#{selected_id}.html")
      raise UserError.new("design candidate #{selected_id} is missing; run aiweb design --candidates 3 first", 1) unless File.exist?(candidate_path) || dry_run

      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        refresh_state!(state)
        refs = state.dig("design_candidates", "candidates") || []
        refs = DesignCandidateGenerator::CANDIDATE_IDS.map do |candidate_id|
          ref = refs.find { |candidate| candidate["id"] == candidate_id } || { "id" => candidate_id, "path" => ".ai-web/design-candidates/#{candidate_id}.html" }
          ref.merge("status" => candidate_id == selected_id ? "approved" : "draft")
        end
        state["design_candidates"]["candidates"] = refs
        state["design_candidates"]["selected_candidate"] = selected_id
        selected_ref = refs.find { |candidate| candidate["id"] == selected_id } || { "id" => selected_id, "path" => ".ai-web/design-candidates/#{selected_id}.html" }
        changes << write_file(File.join(aiweb_dir, "design-candidates", "selected.md"), selected_design_markdown(selected_id, selected_ref: selected_ref, refs: refs), dry_run)
        changes << write_file(File.join(aiweb_dir, "gates", "gate-2-design.md"), gate_markdown("Gate 2 — Design", ["Selected design candidate: #{selected_id}", "Source of truth remains .ai-web/DESIGN.md", "Candidate HTML: .ai-web/design-candidates/#{selected_id}.html"], "pending"), dry_run)
        mark_artifacts_from_files!(state)
        add_decision!(state, "design_candidate_selected", "Selected #{selected_id}; .ai-web/DESIGN.md remains source of truth")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "selected design candidate #{selected_id}"
        payload["next_action"] = "keep .ai-web/DESIGN.md as source of truth; use selected candidate notes for design-prompt or next-task handoff"
      end
      payload
    end

    def ingest_design(id: nil, title: nil, source: nil, notes: nil, selected: false, dry_run: false, force: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        phase_guard!(state, "ingest-design", %w[phase-3.5], force)
        refresh_state!(state)
        max_allowed = state.dig("design_candidates", "max_allowed") || state.dig("budget", "max_design_candidates") || 10
        current = state.dig("design_candidates", "candidates") || []
        requested_id = (id && !id.empty?) ? slug(id) : nil
        adding_new_candidate = requested_id.nil? || current.none? { |candidate| candidate["id"] == requested_id }
        if current.length >= max_allowed.to_i && adding_new_candidate
          raise UserError.new("design candidate cap reached (#{max_allowed})", 3)
        end

        candidate_id = requested_id || format("candidate-%02d", current.length + 1)
        candidate_title = title.to_s.strip.empty? ? "Design candidate #{candidate_id}" : title.to_s.strip
        candidate_path = File.join(aiweb_dir, "design-candidates", "#{candidate_id}.md")
        changes << write_file(candidate_path, design_candidate_markdown(candidate_id, candidate_title, source, notes), dry_run)

        candidate_ref = {
          "id" => candidate_id,
          "path" => relative(candidate_path),
          "status" => selected ? "approved" : "draft"
        }
        state["design_candidates"]["candidates"] = upsert_candidate(current, candidate_ref)
        state["design_candidates"]["selected_candidate"] = candidate_id if selected
        state["design_candidates"]["regeneration_rounds"] ||= 0
        update_design_counts!(state)

        if state["design_candidates"]["candidates"].length >= 2
          changes << write_file(File.join(aiweb_dir, "design-candidates", "comparison.md"), design_comparison_markdown(state), dry_run)
        end
        if selected || state["design_candidates"]["selected_candidate"]
          selected_id = state["design_candidates"]["selected_candidate"] || candidate_id
          state["design_candidates"]["selected_candidate"] = selected_id
          changes << write_file(File.join(aiweb_dir, "design-candidates", "selected.md"), selected_design_markdown(selected_id), dry_run)
          changes << write_file(File.join(aiweb_dir, "gates", "gate-2-design.md"), gate_markdown("Gate 2 — Design", ["Selected design candidate: #{selected_id}"], "pending"), dry_run)
        end

        mark_artifacts_from_files!(state)
        add_decision!(state, "design_candidate", "Recorded design candidate #{candidate_id}")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "ingested design candidate #{candidate_id}"
      end
      payload
    end

    def ingest_reference(type: nil, title: nil, source: nil, notes: nil, dry_run: false, force: false)
      assert_initialized!
      reference_type = normalize_reference_type(type)
      reference_title = title.to_s.strip.empty? ? default_reference_title(reference_type) : title.to_s.strip
      reference_source = source.to_s.strip
      reference_notes = notes.to_s.strip
      if reference_source.empty? && reference_notes.empty?
        raise UserError.new("ingest-reference requires --source or --notes", 1)
      end
      reject_reference_secret_path!(reference_source, "reference source") unless reference_source.empty?

      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        phase_guard!(state, "ingest-reference", %w[phase-3 phase-3.5], force)
        ensure_design_research_state_defaults!(state)
        paths = design_research_paths(state)
        brief_relative_path = paths["reference_brief"]
        brief_path = File.join(root, brief_relative_path)
        existing_brief = File.file?(brief_path) && !stub_file?(brief_path) ? File.read(brief_path) : nil
        changes << write_file(
          brief_path,
          reference_ingestion_brief(existing_brief: existing_brief, type: reference_type, title: reference_title, source: reference_source, notes: reference_notes),
          dry_run
        )

        research = state["research"]["design_research"]
        research["status"] = "ready"
        research["latest_run"] = now
        research["skipped_reason"] = nil
        research["last_error"] = nil
        research["reference_brief_path"] = brief_relative_path

        mark_artifacts_from_files!(state)
        add_decision!(state, "design_reference_ingested", "Recorded #{reference_type} reference as pattern-only constraints")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "ingested #{reference_type} reference"
        payload["reference_ingestion"] = {
          "type" => reference_type,
          "title" => reference_title,
          "source" => reference_source.empty? ? nil : reference_source,
          "reference_brief_path" => brief_relative_path,
          "pattern_constraints_only" => true,
          "no_copy_guardrails" => reference_no_copy_guardrails
        }
        payload["next_action"] = "review .ai-web/design-reference-brief.md as pattern evidence only, then continue with aiweb design-system resolve or aiweb design"
      end
      payload
    end


    def component_map(force: false, dry_run: false)
      assert_initialized!

      state = load_state
      artifact_path = File.join(aiweb_dir, "component-map.json")
      components = discover_component_map_components
      blockers = component_map_blockers(components, force: force)
      status = blockers.empty? ? (dry_run ? "planned" : "ready") : "blocked"
      component_map = component_map_record(
        status: status,
        artifact_path: artifact_path,
        components: components,
        blockers: blockers,
        dry_run: dry_run
      )
      planned_changes = [relative(artifact_path)]

      if dry_run || !blockers.empty?
        return component_map_payload(
          state: state,
          component_map: component_map,
          changed_files: [],
          planned_changes: blockers.empty? ? planned_changes : [],
          action_taken: blockers.empty? ? "planned component map" : "component map blocked",
          blocking_issues: blockers,
          next_action: blockers.empty? ? "rerun aiweb component-map without --dry-run to write #{relative(artifact_path)}" : "run aiweb scaffold --profile D or restore source files with stable data-aiweb-id hooks, then rerun aiweb component-map"
        )
      end

      changes = []
      payload = nil
      mutation(dry_run: false) do
        changes << write_json(artifact_path, component_map, false)
        payload = component_map_payload(
          state: state,
          component_map: component_map,
          changed_files: compact_changes(changes),
          planned_changes: [],
          action_taken: "created component map",
          blocking_issues: [],
          next_action: "select a data-aiweb-id target, then run aiweb visual-edit --target DATA_AIWEB_ID --prompt TEXT"
        )
      end
      payload
    end

    def visual_edit(target:, prompt:, from_map: "latest", force: false, dry_run: false)
      assert_initialized!

      target = target.to_s.strip
      prompt = prompt.to_s.strip
      raise UserError.new("visual-edit requires --target DATA_AIWEB_ID", 1) if target.empty?
      raise UserError.new("visual-edit requires --prompt TEXT", 1) if prompt.empty?

      state = load_state
      source = resolve_component_map_source(from_map)
      component_map = source["path"] ? load_component_map_for_visual_edit(source["path"]) : nil
      components = component_map ? component_map_components(component_map, target) : []
      component = components.length == 1 ? components.first : nil
      blockers = visual_edit_blockers(source, component_map, component, target, components: components, force: force)

      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      edit_id = "visual-edit-#{timestamp}-#{slug(target)}"
      task_path = File.join(aiweb_dir, "tasks", "#{edit_id}.md")
      record_path = File.join(aiweb_dir, "visual", "#{edit_id}.json")
      record = visual_edit_record(
        edit_id: edit_id,
        target: target,
        prompt: prompt,
        source_map: source["relative"],
        component: component,
        task_path: task_path,
        record_path: record_path,
        status: blockers.empty? ? (dry_run ? "planned" : "created") : "blocked",
        blockers: blockers,
        dry_run: dry_run
      )
      planned_changes = [relative(task_path), relative(record_path)]

      if dry_run || !blockers.empty?
        return visual_edit_payload(
          state: state,
          record: record,
          changed_files: [],
          planned_changes: blockers.empty? ? planned_changes : [],
          action_taken: blockers.empty? ? "planned visual edit" : "visual edit blocked",
          blocking_issues: blockers,
          next_action: blockers.empty? ? "rerun aiweb visual-edit without --dry-run to create the local handoff artifacts" : "create a component map and choose an editable data-aiweb-id target, then rerun aiweb visual-edit"
        )
      end

      changes = []
      payload = nil
      mutation(dry_run: false) do
        changes << write_file(task_path, visual_edit_task_markdown(record), false)
        changes << write_json(record_path, record, false)
        payload = visual_edit_payload(
          state: state,
          record: record,
          changed_files: compact_changes(changes),
          planned_changes: [],
          action_taken: "created visual edit handoff",
          blocking_issues: [],
          next_action: "review #{relative(task_path)}; source patching and smoke QA are intentionally outside this command"
        )
      end
      payload
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
      case state.dig("phase", "current")
      when "phase-0", "phase-1", "phase-1.5"
        interview(idea: state.dig("project", "name"), dry_run: dry_run)
      when "phase-3"
        design_prompt(dry_run: dry_run)
      when "phase-3.5"
        ingest_design(title: "Draft design candidate", source: "aiweb run", notes: "Generated placeholder candidate. Replace with image/design analysis.", dry_run: dry_run)
      when "phase-8", "phase-9", "phase-11"
        next_task(dry_run: dry_run)
      when "phase-10"
        qa_checklist(dry_run: dry_run)
      else
        status_hash(state: state, changed_files: []).merge("action_taken" => "no automatic run action for #{state.dig("phase", "current")}")
      end
    end

    def load_state
      assert_initialized!
      YAML.load_file(state_path)
    rescue Psych::SyntaxError => e
      raise UserError.new("cannot parse state.yaml: #{e.message}", 1)
    end


    def visual_critique(paths: nil, evidence_paths: nil, screenshot: nil, screenshots: nil, from_screenshots: nil, metadata: nil, task_id: nil, dry_run: false, **_options)
      assert_initialized!
      evidence = visual_critique_evidence_paths(paths, evidence_paths, screenshot, [screenshots, from_screenshots], metadata)
      raise UserError.new("visual-critique requires at least one local evidence path", 1) if evidence.empty?

      evidence.each { |path| validate_visual_critique_input_path!(path) }

      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      critique_slug = slug(task_id)
      critique_id = ["visual-critique", timestamp, critique_slug].reject { |part| part.to_s.empty? }.join("-")
      artifact_path = File.join(aiweb_dir, "visual", "#{critique_id}.json")
      planned_changes = [relative(File.dirname(artifact_path)), relative(artifact_path), relative(state_path)]

      if dry_run
        state = load_state
        payload = visual_critique_payload(
          state: state,
          critique: visual_critique_record(
            critique_id: critique_id,
            task_id: task_id,
            evidence_paths: evidence,
            artifact_path: artifact_path,
            dry_run: true
          ),
          changed_files: [],
          planned_changes: planned_changes,
          action_taken: "planned visual critique",
          next_action: "rerun aiweb visual-critique without --dry-run to write #{relative(artifact_path)} and update project state"
        )
        return payload
      end

      changes = []
      payload = nil
      mutation(dry_run: false) do
        state = load_state
        critique = visual_critique_record(
          critique_id: critique_id,
          task_id: task_id,
          evidence_paths: evidence,
          artifact_path: artifact_path,
          dry_run: false
        )
        changes << write_json(artifact_path, critique, false)
        state["qa"] ||= {}
        state["qa"]["latest_visual_critique"] = relative(artifact_path)
        state["visual"] ||= {}
        state["visual"]["latest_critique"] = relative(artifact_path)
        add_decision!(state, "visual_critique", "Recorded visual critique #{critique["approval"]} at #{relative(artifact_path)}")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)
        payload = visual_critique_payload(
          state: state,
          critique: critique,
          changed_files: compact_changes(changes),
          planned_changes: [],
          action_taken: "recorded visual critique",
          next_action: visual_critique_next_action(critique)
        )
      end
      payload
    end

    private

    class BlockedAdvance < StandardError
      attr_reader :payload
      def initialize(payload)
        @payload = payload
        super("advance blocked")
      end
    end

    def planned_dirs
      [
        aiweb_dir,
        File.join(aiweb_dir, "gates"),
        File.join(aiweb_dir, "design-candidates"),
        File.join(aiweb_dir, "qa"),
        File.join(aiweb_dir, "qa", "results"),
        File.join(aiweb_dir, "tasks"),
        File.join(aiweb_dir, "snapshots")
      ]
    end

    def copy_core_templates(dry_run, changes)
      template_map = {
        "quality.yaml" => File.join(aiweb_dir, "quality.yaml"),
        "state.schema.json" => File.join(aiweb_dir, "state.schema.json"),
        "quality.schema.json" => File.join(aiweb_dir, "quality.schema.json"),
        "qa-result.schema.json" => File.join(aiweb_dir, "qa", "qa-result.schema.json"),
        "intent.schema.json" => File.join(aiweb_dir, "intent.schema.json"),
        "intent.yaml" => File.join(aiweb_dir, "intent.yaml"),
        "first-view-contract.md" => File.join(aiweb_dir, "first-view-contract.md"),
        "project.md" => File.join(aiweb_dir, "project.md"),
        "product.md" => File.join(aiweb_dir, "product.md"),
        "brand.md" => File.join(aiweb_dir, "brand.md"),
        "content.md" => File.join(aiweb_dir, "content.md"),
        "ia.md" => File.join(aiweb_dir, "ia.md"),
        "data.md" => File.join(aiweb_dir, "data.md"),
        "security.md" => File.join(aiweb_dir, "security.md"),
        "design-brief.md" => File.join(aiweb_dir, "design-brief.md"),
        "deploy.md" => File.join(aiweb_dir, "deploy.md"),
        "post-launch-backlog.md" => File.join(aiweb_dir, "post-launch-backlog.md"),
        "final-qa-report.md" => File.join(aiweb_dir, "qa", "final-report.md"),
        "DESIGN.md" => File.join(aiweb_dir, "DESIGN.md"),
        "AGENTS.md" => File.join(root, "AGENTS.md")
      }
      template_map.each do |src, dest|
        changes << copy_template(src, dest, dry_run) unless File.exist?(dest)
      end
      root_design = File.join(root, "DESIGN.md")
      changes << copy_template("DESIGN.md", root_design, dry_run) unless File.exist?(root_design)
      changes << write_file(File.join(aiweb_dir, "gates", "gate-1a-scope-quality-stack.md"), gate_markdown("Gate 1A — Scope / Quality / Stack", ["Release scope", "Quality contract", "Stack profile"], "pending"), dry_run) unless File.exist?(File.join(aiweb_dir, "gates", "gate-1a-scope-quality-stack.md"))
      changes << write_file(File.join(aiweb_dir, "gates", "gate-1b-product-content-ia-data-security.md"), gate_markdown("Gate 1B — Product / Content / IA / Data / Security", ["Product", "Brand/content", "IA", "Data/security"], "pending"), dry_run) unless File.exist?(File.join(aiweb_dir, "gates", "gate-1b-product-content-ia-data-security.md"))
      changes << write_file(File.join(aiweb_dir, "gates", "gate-2-design.md"), gate_markdown("Gate 2 — Design", ["Design candidates", "Comparison", "Selected design"], "pending"), dry_run) unless File.exist?(File.join(aiweb_dir, "gates", "gate-2-design.md"))
      changes << write_file(File.join(aiweb_dir, "gates", "gate-3-golden-flow.md"), gate_markdown("Gate 3 — Golden Flow", ["Golden page", "Golden flow QA"], "pending"), dry_run) unless File.exist?(File.join(aiweb_dir, "gates", "gate-3-golden-flow.md"))
      changes << copy_template("gate-4-predeploy.md", File.join(aiweb_dir, "gates", "gate-4-predeploy.md"), dry_run) unless File.exist?(File.join(aiweb_dir, "gates", "gate-4-predeploy.md"))
    end

    def copy_template(name, dest, dry_run)
      src = File.join(templates_dir, name)
      raise UserError.new("missing template #{src}", 10) unless File.exist?(src)
      write_file(dest, File.read(src), dry_run)
    end

    def load_template_yaml(name)
      YAML.load_file(File.join(templates_dir, name))
    end

    def load_state_if_present
      File.exist?(state_path) ? YAML.load_file(state_path) : nil
    end

    def assert_initialized!
      raise UserError.new("not initialized; run aiweb init first", 1) unless initialized?
    end

    def phase_guard!(state, command, allowed_phases, force)
      return if force
      current = state.dig("phase", "current")
      return if allowed_phases.include?(current)

      raise UserError.new(
        "#{command} requires current phase #{allowed_phases.join(" or ")}; current phase is #{current.inspect}. Use --force only for manual repair/override.",
        2
      )
    end

    def mutation(dry_run:)
      if dry_run
        yield
        return
      end
      FileUtils.mkdir_p(aiweb_dir)
      lock = File.join(aiweb_dir, ".lock")
      lock_acquired = false
      begin
        File.open(lock, File::WRONLY | File::CREAT | File::EXCL) do |file|
          lock_acquired = true
          file.write("pid=#{Process.pid}\ncreated_at=#{now}\n")
        end
        yield
      rescue Errno::EEXIST
        raise UserError.new("state lock exists: #{lock}. If this is stale, remove it only after confirming no aiweb command is running.", 1)
      ensure
        FileUtils.rm_f(lock) if lock_acquired
      end
    end

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
      idx = ADVANCE_PHASES.index(current)
      return current if idx.nil?
      return "complete" if idx >= ADVANCE_PHASES.length - 1
      ADVANCE_PHASES[idx + 1]
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

    def write_file(path, content, dry_run)
      rel = relative(path)
      return rel if dry_run
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      rel
    end

    def write_yaml(path, data, dry_run)
      write_file(path, YAML.dump(data), dry_run)
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
        "planned_config_path" => GITHUB_SYNC_PLAN_PATH,
        "artifact_path" => dry_run ? nil : GITHUB_SYNC_PLAN_PATH,
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

    def executable_path(name)
      suffixes = [""]
      if windows? && File.extname(name.to_s).empty?
        suffixes.concat(ENV.fetch("PATHEXT", ".COM;.EXE;.BAT;.CMD").split(";"))
      end
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).flat_map do |dir|
        suffixes.map { |suffix| File.join(dir, "#{name}#{suffix}") }
      end.find { |path| File.executable?(path) && !File.directory?(path) }
    end

    def subprocess_path_env
      %w[PATH PATHEXT SYSTEMROOT WINDIR COMSPEC].each_with_object({}) do |key, env|
        env[key] = ENV[key] if ENV[key]
      end
    end

    def local_executable_path(path)
      suffixes = [""]
      if windows? && File.extname(path.to_s).empty?
        suffixes.concat(ENV.fetch("PATHEXT", ".COM;.EXE;.BAT;.CMD").split(";"))
      end
      suffixes.map { |suffix| "#{path}#{suffix}" }.find { |candidate| File.executable?(candidate) && !File.directory?(candidate) }
    end

    def write_json(path, data, dry_run)
      write_file(path, JSON.pretty_generate(data) + "\n", dry_run)
    end

    def create_dir(path, dry_run)
      rel = relative(path)
      FileUtils.mkdir_p(path) unless dry_run
      rel
    end

    def compact_changes(changes)
      changes.flatten.compact.uniq.reject(&:empty?)
    end

    def relative(path)
      path = File.expand_path(path)
      path.sub(/^#{Regexp.escape(root)}\/?/, "")
    end

    def now
      Time.now.utc.iso8601
    end

    def default_project_id
      slug(File.basename(root))
    end

    def slug(value)
      value.to_s.downcase.gsub(/[^a-z0-9가-힣._-]+/i, "-").gsub(/^-|-$/, "")
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def qa_failures_block_phase?(current)
      phase_index = PHASES.index(current)
      threshold = PHASES.index("phase-7")
      !phase_index.nil? && !threshold.nil? && phase_index >= threshold
    end

    def quality_contract_blockers
      return ["quality.yaml is missing"] unless File.exist?(quality_path)

      quality = YAML.load_file(quality_path)
      errors = validate_json_schema(quality, load_schema("quality.schema.json"))
      return errors.map { |error| "quality.schema: #{error}" } unless errors.empty?

      design_blockers = quality_design_phase0_gate_blockers(quality)
      return design_blockers unless design_blockers.empty?

      approved = quality.dig("quality", "approved")
      approved == true ? [] : ["quality contract must be explicitly approved in .ai-web/quality.yaml (quality.approved: true)"]
    rescue Psych::SyntaxError => e
      ["cannot parse quality.yaml: #{e.message}"]
    end

    def quality_design_phase0_gate_blockers(quality)
      gate = quality.dig("quality", "design", "phase_0_gate")
      return ["quality.design.phase_0_gate is required for human-grade design gating"] unless gate.is_a?(Hash)

      blockers = []
      missing_craft = %w[anti-ai-slop color typography spacing-responsive] - Array(gate["craft_rules_required"]).map(&:to_s)
      blockers << "quality.design.phase_0_gate missing craft rules: #{missing_craft.join(", ")}" unless missing_craft.empty?

      missing_strategies = %w[editorial-premium conversion-focused trust-minimal] - Array(gate["candidate_strategies"]).map(&:to_s)
      blockers << "quality.design.phase_0_gate must require differentiated candidate strategies: #{missing_strategies.join(", ")}" unless missing_strategies.empty?
      blockers << "quality.design.phase_0_gate candidate_strategy_count must be at least 3" if gate["candidate_strategy_count"].to_i < 3

      missing_scores = visual_critique_score_categories - Array(gate["required_score_categories"]).map(&:to_s)
      blockers << "quality.design.phase_0_gate missing visual score categories: #{missing_scores.join(", ")}" unless missing_scores.empty?
      blockers << "quality.design.phase_0_gate min_visual_score_axis must be at least 70" if gate["min_visual_score_axis"].to_f < 70
      blockers << "quality.design.phase_0_gate min_visual_score_average must be at least 78" if gate["min_visual_score_average"].to_f < 78

      missing_widths = [375, 390, 768, 1440] - Array(gate["responsive_first_fold_widths"]).map(&:to_i)
      blockers << "quality.design.phase_0_gate missing responsive widths: #{missing_widths.join(", ")}" unless missing_widths.empty?
      blockers << "quality.design.phase_0_gate first_view_alignment_required must be true" unless gate["first_view_alignment_required"] == true
      blockers << "quality.design.phase_0_gate no_copy_provenance_required must be true" unless gate["no_copy_provenance_required"] == true

      blockers
    end

    def completed_task_evidence_blockers(state, requirements)
      evidence = Array(state.dig("implementation", "completed_tasks")).map(&:to_s)
      requirements.each_with_object([]) do |(label, patterns), blockers|
        matched = evidence.any? { |value| patterns.any? { |pattern| value.match?(pattern) } }
        blockers << "#{label} completed task evidence is required" unless matched
      end
    end

    def stub_file?(path)
      body = File.read(path)
      return true if body.strip.empty?

      substantive = body.lines.map(&:strip).reject do |line|
        line.empty? ||
          line.start_with?("#") ||
          line =~ /^-?\s*TODO\b/i ||
          line =~ /^-?\s*TBD\b/i ||
          line =~ /^-?\s*[A-Za-z0-9가-힣 \/]+:\s*$/ ||
          line =~ /^\|?[-:\s|]+\|?$/ ||
          line =~ /^\|.*\|$/ ||
          line =~ /^Status:\s*(pending)?$/i ||
          line =~ /^Approved (at|by):\s*$/i
      end
      substantive.empty?
    rescue Errno::ENOENT
      true
    end

    def gate_approved?(state, gate_key)
      state.dig("gates", gate_key, "status") == "approved"
    end

    def approved_hash_drift_blockers(state)
      blockers = []
      (state["gates"] || {}).each do |gate_key, gate|
        next unless gate.is_a?(Hash)
        next unless gate["status"] == "approved"
        (gate["approved_artifact_hashes"] || {}).each do |path, expected_hash|
          full_path = File.join(root, path.to_s)
          if !File.exist?(full_path)
            blockers << "#{gate_key} approved artifact missing: #{path}"
          else
            actual_hash = Digest::SHA256.file(full_path).hexdigest
            blockers << "#{gate_key} approved artifact hash drift: #{path}" unless actual_hash == expected_hash
          end
        end
      end
      blockers
    end

    def validate_accepted_risks(state, errors)
      (state["gates"] || {}).each do |gate_key, gate|
        next unless gate.is_a?(Hash)
        (gate["accepted_risks"] || []).each_with_index do |risk, index|
          unless risk.is_a?(Hash)
            errors << "#{gate_key}.accepted_risks[#{index}] must be an object"
            next
          end
          %w[id severity owner mitigation expires_at release_blocker].each do |key|
            errors << "#{gate_key}.accepted_risks[#{index}].#{key} missing" if blank?(risk[key])
          end
        end
      end
    end


    def ensure_setup_state_defaults!(state)
      state["setup"] ||= {}
      state["setup"]["latest_run"] = nil unless state["setup"].key?("latest_run")
      state["setup"]["package_manager"] = nil unless state["setup"].key?("package_manager")
      state["setup"]["node_modules_present"] = false if state["setup"]["node_modules_present"].nil?
      state["setup"]["last_installed_at"] = nil unless state["setup"].key?("last_installed_at")
      state
    end

    def ensure_implementation_state_defaults!(state)
      state["implementation"] ||= {}
      state["implementation"]["latest_agent_run"] = nil unless state["implementation"].key?("latest_agent_run")
      state["implementation"]["last_diff"] = nil unless state["implementation"].key?("last_diff")
      state
    end

    def upsert_candidate(current, ref)
      replaced = false
      updated = current.map do |item|
        if item["id"] == ref["id"]
          replaced = true
          item.merge(ref)
        else
          item
        end
      end
      updated << ref unless replaced
      updated
    end

    def recommended_task_type(state)
      case state.dig("phase", "current")
      when "phase-6" then "bootstrap"
      when "phase-7" then "design-tokens"
      when "phase-8" then "golden-page"
      when "phase-9" then "remaining-pages-features"
      when "phase-11" then "deploy-preparation"
      else "phase-#{state.dig("phase", "current")}-work"
      end
    end

    def add_decision!(state, type, summary)
      state["decisions"] ||= []
      state["decisions"] << {
        "id" => "decision-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}",
        "type" => type,
        "summary" => summary,
        "created_at" => now
      }
    end

    def copy_snapshot_contents(snapshot_dir)
      Dir.children(aiweb_dir).each do |entry|
        next if entry == "snapshots" || entry == ".lock"
        src = File.join(aiweb_dir, entry)
        dest = File.join(snapshot_dir, entry)
        if File.directory?(src)
          FileUtils.cp_r(src, dest)
        else
          FileUtils.cp(src, dest)
        end
      end
    end
  end
end
