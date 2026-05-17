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
require_relative "project/runtime_commands"
require_relative "project/verify_loop"
require_relative "project/sandbox_runtime"
require_relative "project/side_effect_broker"
require_relative "project/mcp_broker"
require_relative "project/graph_scheduler"
require_relative "project/engine_scheduler_service"
require_relative "project/design_fidelity"
require_relative "project/agent_run"
require_relative "project/engine_run"
require_relative "project/state"
require_relative "project/workbench"

module Aiweb
  class Project
    include ProjectRuntimeCommands
    include ProjectVerifyLoop
    include ProjectSandboxRuntime
    include ProjectSideEffectBroker
    include ProjectMcpBroker
    include ProjectDesignFidelity
    include ProjectAgentRun
    include ProjectEngineRun
    include ProjectEngineSchedulerService
    include ProjectStateBoundary
    include ProjectWorkbench
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

    WORKBENCH_PANELS = %w[
      chat
      plan_artifacts
      design_candidates
      selected_design
      preview
      file_tree
      qa_results
      visual_critique
      run_timeline
      verify_loop_status
    ].freeze

    WORKBENCH_CONTROLS = [
      ["run", "Run director", "aiweb run"],
      ["design", "Generate design candidates", "aiweb design"],
      ["build", "Plan or run scaffold build", "aiweb build"],
      ["preview", "Start local preview", "aiweb preview"],
      ["qa_playwright", "Run Playwright QA", "aiweb qa-playwright"],
      ["visual_critique", "Record visual critique", "aiweb visual-critique"],
      ["repair", "Create repair packet", "aiweb repair"],
      ["visual_polish", "Plan visual polish loop", "aiweb visual-polish"],
      ["verify_loop", "Run verify loop", "aiweb verify-loop --max-cycles 3"]
    ].freeze

    WORKBENCH_FILE_TREE_EXCLUDES = %w[
      .git
      .ai-web/workbench
      .ai-web/snapshots
      .ai-web/runs
      node_modules
      dist
      build
      coverage
      tmp
      vendor/bundle
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
    SECRET_LOOKING_PATH_PATTERN = %r{
      (?:
        (?:\A|/)\.ssh(?:/|\z)|
        (?:\A|/)(?:secret|secrets|private|credentials?)(?:[._-][^/\s`"'<>]+)?(?:/|\z)|
        (?:\A|/)[^/\s`"'<>]*(?:private[_-]?key|id_rsa|id_dsa|id_ed25519|credential|secret)[^/\s`"'<>]*\.(?:txt|json|ya?ml|pem|key|env)\z|
        (?:\A|/)[^/\s`"'<>]*\.(?:pem|key)\z
      )
    }ix.freeze
    AGENT_RUN_SHELL_REQUEST_PATTERN = /
      \b(?:
        rm\s+-[A-Za-z]*r|
        cat\s+\.env|
        printenv|
        curl|
        wget|
        ssh|
        scp|
        sudo|
        chmod|
        pnpm|
        npm|
        yarn|
        bun|
        vercel|
        netlify
      )\b
    /ix.freeze
    AGENT_RUN_SECRET_VALUE_PATTERN = /
      (?:\b[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PRIVATE[_-]?KEY|API[_-]?KEY)[A-Z0-9_]*=[^\s]+)|
      (?:-----BEGIN\ [A-Z ]*PRIVATE\ KEY-----)|
      (?:\bAKIA[0-9A-Z]{16}\b)|
      (?:\b(?:ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{10,}\b)|
      (?:\bxox[baprs]-[A-Za-z0-9-]{10,}\b)|
      (?:\b(?:sk|rk)_(?:live|test|proj)_[A-Za-z0-9_-]{10,}\b)
    /ix.freeze
    AGENT_RUN_SNAPSHOT_PRUNE_DIRS = %w[
      .git
      node_modules
      dist
      build
      coverage
      tmp
      vendor
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


    def scaffold(profile: "D", dry_run: false, force: false)
      assert_initialized!
      selected_profile, profile_data = Profiles.fetch!(profile)
      return scaffold_profile_s(profile_data, dry_run: dry_run, force: force) if selected_profile == "S"

      unless selected_profile == "D"
        raise UserError.new("scaffold currently supports --profile D or --profile S; received #{profile.inspect}", 1)
      end

      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        ensure_scaffold_state_defaults!(state)
        validate_scaffold_design_gate!(state)
        files = scaffold_profile_d_files(state)
        scaffold_metadata_path = File.join(aiweb_dir, "scaffold-profile-D.json")
        conflicts = scaffold_conflicts(files, force: force)
        preflight_scaffold_targets!(files, metadata_path: scaffold_metadata_path, force: force, profile: "D")

        unless conflicts.empty?
          raise UserError.new(
            "scaffold profile D found existing files that differ and were preserved: #{conflicts.join(", ")}. No scaffold files were written. Rerun aiweb scaffold --profile D --force to overwrite regular scaffold files after reviewing those files.",
            1
          )
        end

        files.each do |relative_path, content|
          path = File.join(root, relative_path)
          next if File.exist?(path) && File.read(path) == content

          changes << write_file(path, content, dry_run)
        end

        metadata = scaffold_profile_d_metadata(files, state, profile_data)
        changes << write_json(scaffold_metadata_path, metadata, dry_run)
        apply_scaffold_state!(state, metadata)
        add_decision!(state, "scaffold_profile_d", "Generated Profile D Astro-style static app skeleton from .ai-web/DESIGN.md and selected candidate context")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)

        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = force ? "regenerated scaffold profile D" : "generated scaffold profile D"
        payload["scaffold"] = metadata.reject { |key, _| key == "files" }
        payload["next_action"] = "review generated Astro-style files; do not run package install until implementation approval"
      end
      payload
    end


    def scaffold_profile_s(profile_data, dry_run:, force:)
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        ensure_scaffold_state_defaults!(state)
        files = scaffold_profile_s_files(state)
        scaffold_metadata_path = File.join(aiweb_dir, "scaffold-profile-S.json")
        secret_qa_path = File.join(aiweb_dir, "qa", "supabase-secret-qa.json")
        local_verify_path = File.join(aiweb_dir, "qa", "supabase-local-verify.json")
        conflicts = scaffold_conflicts(files, force: force)
        preflight_scaffold_targets!(files, metadata_path: scaffold_metadata_path, force: force, profile: "S")
        preflight_scaffold_targets!({}, metadata_path: secret_qa_path, force: force, profile: "S")
        preflight_scaffold_targets!({}, metadata_path: local_verify_path, force: force, profile: "S")

        unless conflicts.empty?
          raise UserError.new(
            "scaffold profile S found existing files that differ and were preserved: #{conflicts.join(", ")}. No scaffold files were written. Rerun aiweb scaffold --profile S --force to overwrite regular scaffold files after reviewing those files.",
            1
          )
        end

        files.each do |relative_path, content|
          path = File.join(root, relative_path)
          next if File.exist?(path) && File.read(path) == content

          changes << write_file(path, content, dry_run)
        end

        metadata = scaffold_profile_s_metadata(files, profile_data)
        changes << write_json(scaffold_metadata_path, metadata, dry_run)
        scaffold_files_with_metadata = files.merge(SCAFFOLD_PROFILE_S_METADATA_PATH => JSON.pretty_generate(metadata) + "\n")
        secret_qa = scaffold_profile_s_secret_qa(scaffold_files_with_metadata)
        changes << write_json(secret_qa_path, secret_qa, dry_run)
        local_verify = scaffold_profile_s_local_verify(scaffold_files_with_metadata.merge(SCAFFOLD_PROFILE_S_SECRET_QA_PATH => JSON.pretty_generate(secret_qa) + "\n"))
        changes << write_json(local_verify_path, local_verify, dry_run)
        apply_scaffold_state!(state, metadata)
        state["qa"] ||= {}
        state["qa"]["supabase_secret_qa"] = SCAFFOLD_PROFILE_S_SECRET_QA_PATH
        state["qa"]["supabase_local_verify"] = SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH
        add_decision!(state, "scaffold_profile_s", "Generated local-only Profile S Next.js + Supabase scaffold with safe non-dot env template, secret QA artifact, and local Supabase verification")
        state["project"]["updated_at"] = now
        changes << write_yaml(state_path, state, dry_run)

        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = force ? "regenerated scaffold profile S" : "generated scaffold profile S"
        payload["scaffold"] = metadata.reject { |key, _| key == "files" }
        payload["secret_qa"] = secret_qa.reject { |key, _| key == "files" }
        payload["supabase_local_verify"] = local_verify.reject { |key, _| key == "files" }
        payload["next_action"] = "review generated local-only Next.js/Supabase files and .ai-web/qa/supabase-local-verify.json; copy supabase/env.example.template manually into an untracked local env file only when ready"
      end
      payload
    end

    def supabase_secret_qa(dry_run: false, force: false)
      assert_initialized!
      state = load_state
      files = supabase_secret_qa_scan_files
      artifact_path = File.join(root, SCAFFOLD_PROFILE_S_SECRET_QA_PATH)
      qa = scaffold_profile_s_secret_qa(files)
      qa["artifact_path"] = SCAFFOLD_PROFILE_S_SECRET_QA_PATH
      qa["profile"] = "S"
      planned_changes = [SCAFFOLD_PROFILE_S_SECRET_QA_PATH]

      if dry_run
        payload = status_hash(state: state, changed_files: [])
        payload["action_taken"] = "planned Supabase secret QA"
        payload["planned_changes"] = planned_changes
        payload["supabase_secret_qa"] = qa.merge("dry_run" => true)
        payload["next_action"] = "rerun supabase_secret_qa without dry_run to write #{SCAFFOLD_PROFILE_S_SECRET_QA_PATH}"
        return payload
      end

      changes = []
      payload = nil
      mutation(dry_run: false) do
        existing_conflict = File.file?(artifact_path) && !force && JSON.parse(File.read(artifact_path)).is_a?(Hash) == false
        raise UserError.new("Supabase secret QA artifact is malformed; review #{SCAFFOLD_PROFILE_S_SECRET_QA_PATH} or rerun with force", 1) if existing_conflict

        changes << write_json(artifact_path, qa, false)
        state["qa"] ||= {}
        state["qa"]["supabase_secret_qa"] = SCAFFOLD_PROFILE_S_SECRET_QA_PATH
        add_decision!(state, "supabase_secret_qa", "Scanned generated Profile S safe files without reading dot-env paths")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "recorded Supabase secret QA"
        payload["supabase_secret_qa"] = qa
        payload["next_action"] = qa["status"] == "passed" ? "keep dot-env files local and untracked" : "review Profile S generated safe files for credential exposure patterns"
      end
      payload
    rescue JSON::ParserError
      raise UserError.new("Supabase secret QA artifact is malformed; review #{SCAFFOLD_PROFILE_S_SECRET_QA_PATH} or rerun with force", 1)
    end

    def supabase_local_verify(dry_run: false, force: false)
      assert_initialized!
      state = load_state
      files = supabase_local_verify_scan_files
      artifact_path = File.join(root, SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH)
      verify = scaffold_profile_s_local_verify(files)
      verify["artifact_path"] = SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH
      verify["profile"] = "S"
      planned_changes = [SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH]

      if dry_run
        payload = status_hash(state: state, changed_files: [])
        payload["action_taken"] = "planned Supabase local verification"
        payload["planned_changes"] = planned_changes
        payload["supabase_local_verify"] = verify.merge("dry_run" => true)
        payload["next_action"] = "rerun supabase-local-verify without --dry-run to write #{SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH}"
        return payload
      end

      changes = []
      payload = nil
      mutation(dry_run: false) do
        existing_conflict = File.file?(artifact_path) && !force && JSON.parse(File.read(artifact_path)).is_a?(Hash) == false
        raise UserError.new("Supabase local verification artifact is malformed; review #{SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH} or rerun with force", 1) if existing_conflict

        changes << write_json(artifact_path, verify, false)
        state["qa"] ||= {}
        state["qa"]["supabase_local_verify"] = SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH
        add_decision!(state, "supabase_local_verify", "Verified generated Profile S files locally without reading dot-env paths or contacting Supabase")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "recorded Supabase local verification"
        payload["supabase_local_verify"] = verify
        payload["next_action"] = verify["status"] == "passed" ? "run aiweb setup --install --dry-run only after reviewing generated Profile S files" : "repair generated Profile S safe files, then rerun aiweb supabase-local-verify"
      end
      payload
    rescue JSON::ParserError
      raise UserError.new("Supabase local verification artifact is malformed; review #{SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH} or rerun with force", 1)
    end


    def run_status(run_id: nil)
      assert_initialized!
      state = load_state
      lifecycle = run_lifecycle_status(run_id: run_id)
      payload = status_hash(state: state, changed_files: [])
      payload["action_taken"] = "reported run lifecycle"
      payload["run_lifecycle"] = lifecycle
      payload["next_action"] = lifecycle["active_run"] ? "inspect the active run or request cancellation with aiweb run-cancel --run-id active" : "start a local run such as aiweb verify-loop --max-cycles 3 --dry-run"
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
      payload["next_action"] = active ? "inspect active run with aiweb run-status --run-id active or request cancellation with aiweb run-cancel --run-id active" : "continue with aiweb verify-loop --max-cycles 3 --dry-run or inspect aiweb run-timeline"
      payload
    end

    def run_cancel(run_id: "active", dry_run: false, force: false)
      assert_initialized!
      state = load_state
      target = resolve_run_lifecycle_target(run_id)
      blockers = []
      blockers << "no active or matching run found for #{run_id.to_s.empty? ? "active" : run_id}" unless target
      run_dir = target && run_lifecycle_run_dir(target.fetch("run_id"))
      request_path = run_dir && File.join(run_dir, RUN_CANCEL_REQUEST_FILE)
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
      plan_path = target && File.join(run_lifecycle_run_dir(target.fetch("run_id")), RUN_RESUME_PLAN_FILE)

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
        payload["next_action"] = blockers.empty? ? "rerun aiweb run-resume --run-id #{target.fetch("run_id")} to record the resume descriptor, then execute next_command manually if desired" : "inspect aiweb run-status and choose a resumable run"
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

    def repair(from_qa: "latest", max_cycles: nil, force: false, dry_run: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        phase_guard!(state, "repair", %w[phase-7 phase-8 phase-9 phase-10 phase-11], force)
        source_result = resolve_repair_qa_source(from_qa, state)
        result = source_result["path"] ? load_repair_qa_result(source_result["path"]) : nil

        unless result
          payload = repair_blocked_payload(
            state: state,
            source_result: source_result["relative"],
            reason: source_result["reason"] || "no QA result available for repair",
            dry_run: dry_run
          )
          next
        end

        normalize_qa_result!(result, state)
        validate_qa_result!(result)
        failures = qa_failures_from_result(result, state, source_result["relative"])
        if failures.empty?
          payload = repair_blocked_payload(
            state: state,
            source_result: source_result["relative"],
            reason: "QA result has no blocking failed, blocked, or timed-out condition",
            dry_run: dry_run,
            qa_result: result
          )
          next
        end

        cycle_limit = repair_cycle_limit(max_cycles, state)
        cycles_used = repair_cycles_used(result["task_id"], source_result["relative"])
        if cycles_used >= cycle_limit
          payload = repair_blocked_payload(
            state: state,
            source_result: source_result["relative"],
            reason: "repair cycle budget cap reached for QA task #{result["task_id"].inspect}: #{cycles_used}/#{cycle_limit}",
            dry_run: dry_run,
            qa_result: result,
            cycles_used: cycles_used,
            max_cycles: cycle_limit,
            block_type: "budget"
          )
          next
        end

        timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
        primary_failure = failures.first
        repair_id = "repair-#{timestamp}-#{slug(result["task_id"])}-cycle-#{cycles_used + 1}"
        snapshot_id = "pre-#{repair_id}"
        snapshot_dir = File.join(aiweb_dir, "snapshots", snapshot_id)
        repair_record_path = File.join(aiweb_dir, "repairs", "#{repair_id}.json")
        fix_path = repair_fix_task_path(result, primary_failure)
        planned_changes = [relative(snapshot_dir), relative(File.join(snapshot_dir, "manifest.json")), relative(fix_path), relative(repair_record_path), relative(state_path)]

        record = repair_record(
          repair_id: repair_id,
          result: result,
          source_result: source_result["relative"],
          failures: failures,
          snapshot_dir: snapshot_dir,
          fix_path: fix_path,
          cycles_used: cycles_used,
          max_cycles: cycle_limit,
          dry_run: dry_run,
          repair_record_path: repair_record_path
        )

        if dry_run
          payload = repair_payload(
            state: state,
            record: record,
            changed_files: [],
            planned_changes: planned_changes,
            action_taken: "planned repair loop",
            next_action: "rerun aiweb repair without --dry-run to create the pre-repair snapshot, fix task, and repair record"
          )
          next
        end

        changes << create_dir(snapshot_dir, false)
        copy_repair_snapshot_contents(snapshot_dir)
        snapshot_manifest = repair_snapshot_manifest(snapshot_id, result, source_result["relative"], state)
        changes << write_json(File.join(snapshot_dir, "manifest.json"), snapshot_manifest, false)
        state["snapshots"] ||= []
        state["snapshots"] << snapshot_manifest.merge("path" => relative(snapshot_dir))

        state["qa"] ||= {}
        state["qa"]["open_failures"] ||= []
        merge_open_failures!(state, failures)

        unless File.exist?(fix_path)
          changes << write_file(fix_path, qa_fix_task_markdown(failures, result, state), false)
        end
        state["implementation"] ||= {}
        state["implementation"]["current_task"] = relative(fix_path)
        result["recommended_action"] = "repair_loop"
        result["created_fix_task"] ||= relative(fix_path)

        changes << create_dir(File.dirname(repair_record_path), false)
        changes << write_json(repair_record_path, record, false)
        add_decision!(state, "repair_loop", "Created bounded repair loop #{repair_id} for QA task #{result["task_id"]}")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)

        payload = repair_payload(
          state: state,
          record: record,
          changed_files: compact_changes(changes),
          planned_changes: [],
          action_taken: "created repair loop #{repair_id}",
          next_action: "complete the fix task in #{relative(fix_path)}, then rerun the relevant local QA command manually"
        )
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

    def deploy_plan(target: nil, dry_run: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        ensure_pr19_deploy_defaults!(state)
        plan = deploy_plan_payload(state, target: target, dry_run: dry_run)
        selected_target = plan["target"]
        descriptor_targets = selected_target ? [selected_target] : DEPLOY_PROVIDER_CONFIG_PATHS.keys
        provider_descriptors = descriptor_targets.each_with_object({}) do |descriptor_target, memo|
          path = DEPLOY_PROVIDER_CONFIG_PATHS.fetch(descriptor_target)
          memo[path] = deploy_provider_descriptor(descriptor_target, state)
        end
        planned_changes = [DEPLOY_PLAN_PATH, *provider_descriptors.keys]

        unless dry_run
          changes << write_json(File.join(root, DEPLOY_PLAN_PATH), plan, false)
          provider_descriptors.each do |relative_path, descriptor|
            changes << write_json(File.join(root, relative_path), descriptor, false)
          end
          mark_artifacts_from_files!(state)
          state["deploy"]["latest_plan"] = DEPLOY_PLAN_PATH
          state["deploy"]["deploy_plan_last_planned_at"] = plan["created_at"]
          add_decision!(state, "deploy_plan", "Recorded local-only Cloudflare Pages/Vercel dry-run descriptors; no provider deploy was run")
          state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
          changes << write_yaml(state_path, state, false)
        end

        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = dry_run ? "planned local-only deploy plan" : "recorded local-only deploy plan"
        payload["deploy_plan"] = plan
        payload["provider_config_descriptors"] = provider_descriptors
        payload.merge!(pr19_safety_payload(planned_changes))
        payload["planned_changes"] = planned_changes
        payload["next_action"] = "review #{DEPLOY_PLAN_PATH}; run aiweb deploy --target cloudflare-pages --dry-run or --target vercel --dry-run for a non-writing deployment preview"
      end
      payload
    end

    def deploy(target:, approved: false, dry_run: false, force: false)
      assert_initialized!
      normalized_target = normalize_deploy_target(target)
      state = load_state
      ensure_pr19_deploy_defaults!(state)
      descriptor_path = DEPLOY_PROVIDER_CONFIG_PATHS.fetch(normalized_target)
      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%S%6NZ")
      run_id = "deploy-#{timestamp}-#{SecureRandom.hex(4)}-#{normalized_target}"
      run_dir = File.join(aiweb_dir, "runs", run_id)
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      metadata_path = File.join(run_dir, "deploy.json")
      side_effect_broker_path = File.join(run_dir, "side-effect-broker.jsonl")
      planned_changes = [DEPLOY_PLAN_PATH, descriptor_path, relative(run_dir), relative(stdout_path), relative(stderr_path), relative(metadata_path), relative(side_effect_broker_path)]
      deploy_payload = deploy_local_payload(
        normalized_target,
        state,
        dry_run: dry_run,
        force: force,
        approved: approved,
        run_id: run_id,
        run_dir: run_dir,
        stdout_path: stdout_path,
        stderr_path: stderr_path,
        metadata_path: metadata_path,
        side_effect_broker_path: side_effect_broker_path
      )
      payload = status_hash(state: state, changed_files: [])
      payload["action_taken"] = dry_run ? "deploy dry-run planned" : "deploy blocked"
      payload["deploy"] = deploy_payload
      payload["deploy_dry_run"] = deploy_payload if dry_run
      payload.merge!(pr19_safety_payload(planned_changes))
      payload["planned_changes"] = planned_changes
      if dry_run
        payload["next_action"] = "obtain explicit approval and passing verify-loop evidence before any provider deployment; this dry-run wrote nothing and ran no provider CLI"
      elsif deploy_payload["status"] == "blocked"
        payload["blocking_issues"] = (payload["blocking_issues"] + deploy_payload["blocking_issues"]).uniq
        payload["next_action"] = "resolve deploy gates, then rerun aiweb deploy --target #{normalized_target} --approved"
      else
        active_record = active_run_begin!(
          kind: "deploy",
          run_id: run_id,
          run_dir: run_dir,
          metadata_path: metadata_path,
          command: deploy_payload.fetch("command"),
          force: force
        )
        begin
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
        ensure
          active_run_finish!(active_record, "failed") if active_record
        end
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

    def visual_polish(from_critique: "latest", max_cycles: nil, dry_run: false, **_options)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        source_critique = resolve_visual_polish_critique_source(from_critique, state)
        critique = source_critique["path"] ? load_visual_polish_critique(source_critique["path"]) : nil
        validate_visual_polish_critique!(critique) if critique

        unless critique
          payload = visual_polish_blocked_payload(
            state: state,
            source_critique: source_critique["relative"],
            reason: source_critique["reason"] || "no visual critique available for visual polish",
            dry_run: dry_run
          )
          next
        end

        if visual_polish_critique_passed?(critique)
          payload = visual_polish_blocked_payload(
            state: state,
            source_critique: source_critique["relative"],
            reason: "visual critique already passed; visual-polish --repair only accepts repair, redesign, failed, or non-pass critique results",
            dry_run: dry_run,
            critique: critique,
            block_type: "pass"
          )
          next
        end

        cycle_limit = visual_polish_cycle_limit(max_cycles, state)
        cycles_used = visual_polish_cycles_used(source_critique["relative"])
        if cycles_used >= cycle_limit
          payload = visual_polish_blocked_payload(
            state: state,
            source_critique: source_critique["relative"],
            reason: "visual polish cycle budget cap reached for #{source_critique["relative"].inspect}: #{cycles_used}/#{cycle_limit}",
            dry_run: dry_run,
            critique: critique,
            cycles_used: cycles_used,
            max_cycles: cycle_limit,
            block_type: "budget"
          )
          next
        end

        timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
        polish_id = "polish-#{timestamp}-#{slug(critique["task_id"] || critique["id"] || "visual")}-cycle-#{cycles_used + 1}"
        snapshot_id = "pre-#{polish_id}"
        snapshot_dir = File.join(aiweb_dir, "snapshots", snapshot_id)
        task_path = visual_polish_task_path(critique)
        polish_record_path = File.join(aiweb_dir, "visual", "#{polish_id}.json")
        planned_changes = [relative(snapshot_dir), relative(File.join(snapshot_dir, "manifest.json")), relative(task_path), relative(polish_record_path), relative(state_path)]

        record = visual_polish_record(
          polish_id: polish_id,
          critique: critique,
          source_critique: source_critique["relative"],
          snapshot_dir: snapshot_dir,
          task_path: task_path,
          cycles_used: cycles_used,
          max_cycles: cycle_limit,
          dry_run: dry_run,
          polish_record_path: polish_record_path
        )

        if dry_run
          payload = visual_polish_payload(
            state: state,
            record: record,
            changed_files: [],
            planned_changes: planned_changes,
            action_taken: "planned visual polish repair loop",
            next_action: "rerun aiweb visual-polish --repair without --dry-run to create the pre-polish snapshot, task, and polish record"
          )
          next
        end

        changes << create_dir(snapshot_dir, false)
        copy_repair_snapshot_contents(snapshot_dir)
        snapshot_manifest = visual_polish_snapshot_manifest(snapshot_id, critique, source_critique["relative"], state)
        changes << write_json(File.join(snapshot_dir, "manifest.json"), snapshot_manifest, false)
        state["snapshots"] ||= []
        state["snapshots"] << snapshot_manifest.merge("path" => relative(snapshot_dir))

        unless File.exist?(task_path)
          changes << write_file(task_path, visual_polish_task_markdown(record, critique), false)
        end
        state["implementation"] ||= {}
        state["implementation"]["current_task"] = relative(task_path)

        changes << create_dir(File.dirname(polish_record_path), false)
        changes << write_json(polish_record_path, record, false)
        state["visual"] ||= {}
        state["visual"]["latest_polish"] = relative(polish_record_path)
        add_decision!(state, "visual_polish", "Created bounded visual polish repair loop #{polish_id} for #{source_critique["relative"]}")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)

        payload = visual_polish_payload(
          state: state,
          record: record,
          changed_files: compact_changes(changes),
          planned_changes: [],
          action_taken: "created visual polish repair loop #{polish_id}",
          next_action: "complete the local visual polish task in #{relative(task_path)}, then rerun visual critique manually"
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

    def active_run_lock_path
      File.join(root, ACTIVE_RUN_LOCK_PATH)
    end

    def runs_dir
      File.join(aiweb_dir, "runs")
    end

    def run_lifecycle_run_dir(run_id)
      safe_run_id = validate_run_id!(run_id)
      File.join(runs_dir, safe_run_id)
    end

    def run_lifecycle_path(run_id)
      File.join(run_lifecycle_run_dir(run_id), RUN_LIFECYCLE_FILE)
    end

    def run_cancel_request_path(run_id)
      File.join(run_lifecycle_run_dir(run_id), RUN_CANCEL_REQUEST_FILE)
    end

    def validate_run_id!(run_id)
      value = run_id.to_s.strip
      raise UserError.new("run id is required", 1) if value.empty?
      raise UserError.new("unsafe run id blocked", 5) if value.include?("/") || value.include?("\\") || value.include?("..") || value.start_with?(".") || unsafe_env_path?(value)

      value
    end

    def read_json_file(path)
      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def read_active_run_lock
      read_json_file(active_run_lock_path)
    end

    def active_run_matches?(run_id)
      active = read_active_run_lock
      active && active["run_id"] == run_id
    end

    def active_run_live?(record)
      return false unless record.is_a?(Hash)
      return false unless %w[running cancel_requested].include?(record["status"].to_s)

      live_process?(record["pid"].to_i)
    end

    def with_active_run(kind:, run_id:, run_dir:, metadata_path:, command:, force: false)
      record = active_run_begin!(kind: kind, run_id: run_id, run_dir: run_dir, metadata_path: metadata_path, command: command, force: force)
      final_status = "completed"
      result = yield
      final_status = run_lifecycle_result_status(result) || final_status
      result
    rescue StandardError
      final_status = "failed"
      raise
    ensure
      active_run_finish!(record, final_status) if record
    end

    def active_run_begin!(kind:, run_id:, run_dir:, metadata_path:, command:, force: false, keep_active: false)
      FileUtils.mkdir_p(runs_dir)
      existing = read_active_run_lock
      if existing && active_run_live?(existing) && !force
        raise UserError.new("active run exists: #{existing["run_id"]} (#{existing["kind"]}); inspect aiweb run-status or request cancellation with aiweb run-cancel --run-id active", 1)
      end

      FileUtils.rm_f(active_run_lock_path) if existing && (!active_run_live?(existing) || force)
      record = {
        "schema_version" => 1,
        "run_id" => run_id,
        "kind" => kind,
        "status" => "running",
        "pid" => Process.pid,
        "started_at" => now,
        "heartbeat_at" => now,
        "run_dir" => relative(run_dir),
        "metadata_path" => relative(metadata_path),
        "command" => command,
        "lock_path" => ACTIVE_RUN_LOCK_PATH,
        "cancel_request_path" => relative(run_cancel_request_path(run_id)),
        "keep_active" => keep_active
      }
      File.open(active_run_lock_path, File::WRONLY | File::CREAT | File::EXCL) do |file|
        file.write(JSON.pretty_generate(record) + "\n")
      end
      write_json(run_lifecycle_path(run_id), record, false)
      record
    rescue Errno::EEXIST
      raise UserError.new("active run lock exists at #{ACTIVE_RUN_LOCK_PATH}; inspect aiweb run-status before starting another run", 1)
    end

    def active_run_finish!(record, status)
      return unless record

      final = record.merge(
        "status" => status,
        "finished_at" => now,
        "heartbeat_at" => now
      )
      write_json(run_lifecycle_path(record.fetch("run_id")), final, false)
      if read_active_run_lock&.fetch("run_id", nil) == record.fetch("run_id") && !record["keep_active"]
        FileUtils.rm_f(active_run_lock_path)
      end
    rescue SystemCallError, JSON::ParserError
      nil
    end

    def run_lifecycle_result_status(result)
      return nil unless result.is_a?(Hash)

      result.dig("verify_loop", "status") ||
        result.dig("engine_run", "status") ||
        result.dig("deploy", "status") ||
        result.dig("workbench", "serve", "status") ||
        result.dig("workbench", "status") ||
        result.dig("setup", "status") ||
        result.dig("agent_run", "status")
    end

    def run_lifecycle_status(run_id: nil)
      active = read_active_run_lock
      active_live = active_run_live?(active)
      selected = resolve_run_lifecycle_target(run_id) if run_id && !run_id.to_s.strip.empty?
      {
        "status" => active_live ? "running" : "idle",
        "active_lock_path" => ACTIVE_RUN_LOCK_PATH,
        "active_run" => active,
        "active_run_live" => active_live,
        "selected_run" => selected,
        "recent_runs" => recent_run_lifecycle_entries(10),
        "blocking_issues" => []
      }
    end

    def resolve_run_lifecycle_target(run_id)
      selector = run_id.to_s.strip
      selector = "active" if selector.empty?
      if selector == "active"
        active = read_active_run_lock
        return active if active

        return nil
      end

      selector = latest_run_id if selector == "latest"
      return nil if selector.to_s.empty?

      safe_run_id = validate_run_id!(selector)
      run_lifecycle_record("run_id" => safe_run_id)
    end

    def latest_run_id
      Dir.glob(File.join(runs_dir, "*")).select { |path| File.directory?(path) }.map { |path| File.basename(path) }.sort.last
    end

    def recent_run_lifecycle_entries(limit)
      Dir.glob(File.join(runs_dir, "*")).select { |path| File.directory?(path) }.sort.last(limit).reverse.map do |dir|
        run_lifecycle_record("run_id" => File.basename(dir))
      end.compact
    end

    def run_lifecycle_record(target)
      run_id = validate_run_id!(target.fetch("run_id"))
      lifecycle = read_json_file(run_lifecycle_path(run_id)) || {}
      metadata_path = run_main_metadata_path(run_id)
      metadata = metadata_path ? (read_json_file(metadata_path) || {}) : {}
      lifecycle.merge(
        "run_id" => run_id,
        "kind" => lifecycle["kind"] || run_kind_from_id(run_id, metadata),
        "status" => lifecycle["status"] || metadata["status"] || "unknown",
        "run_dir" => lifecycle["run_dir"] || relative(run_lifecycle_run_dir(run_id)),
        "metadata_path" => lifecycle["metadata_path"] || metadata["metadata_path"] || (metadata_path ? relative(metadata_path) : nil),
        "pid" => lifecycle["pid"] || metadata["pid"],
        "blocking_issues" => lifecycle["blocking_issues"] || metadata["blocking_issues"] || []
      )
    rescue UserError
      nil
    end

    def run_main_metadata(run_id)
      path = run_main_metadata_path(run_id)
      path ? read_json_file(path) : nil
    end

    def run_main_metadata_path(run_id)
      dir = run_lifecycle_run_dir(run_id)
      RUN_METADATA_FILENAMES.map { |name| File.join(dir, name) }.find { |path| File.file?(path) } ||
        Dir.glob(File.join(dir, "*.json")).reject { |path| [RUN_LIFECYCLE_FILE, RUN_CANCEL_REQUEST_FILE, RUN_RESUME_PLAN_FILE].include?(File.basename(path)) }.sort.first
    rescue UserError
      nil
    end

    def run_kind_from_id(run_id, metadata)
      return "verify-loop" if run_id.start_with?("verify-loop-")
      return "engine-run" if run_id.start_with?("engine-run-")
      return "deploy" if run_id.start_with?("deploy-")
      return "workbench-serve" if run_id.start_with?("workbench-serve-")
      return "setup" if run_id.start_with?("setup-")
      return "agent-run" if run_id.start_with?("agent-run-")
      return "preview" if run_id.start_with?("preview-")

      metadata["kind"] || metadata["command"]&.first || "unknown"
    end

    def run_cancel_request_metadata(target, request_path, dry_run:, force:, blocking_issues:)
      {
        "schema_version" => 1,
        "run_id" => target && target["run_id"],
        "kind" => target && target["kind"],
        "status" => blocking_issues.empty? ? (dry_run ? "planned" : "cancel_requested") : "blocked",
        "requested_at" => now,
        "requested_by_pid" => Process.pid,
        "dry_run" => dry_run,
        "force" => force,
        "request_path" => request_path ? relative(request_path) : nil,
        "blocking_issues" => blocking_issues
      }
    end

    def run_cancel_requested?(run_id)
      File.file?(run_cancel_request_path(run_id))
    rescue UserError
      false
    end

    def run_resume_plan(target, metadata)
      kind = target["kind"].to_s
      command = case kind
                when "verify-loop"
                  ["aiweb", "verify-loop", "--max-cycles", metadata.fetch("max_cycles", 3).to_s, "--approved"]
                when "deploy"
                  target_name = metadata["target"].to_s
                  target_name.empty? ? nil : ["aiweb", "deploy", "--target", target_name, "--approved"]
                when "workbench-serve"
                  command = ["aiweb", "workbench", "--serve", "--approved"]
                  command += ["--host", metadata["host"].to_s] unless metadata["host"].to_s.empty?
                  command += ["--port", metadata["port"].to_s] unless metadata["port"].to_s.empty?
                  command
                when "setup"
                  ["aiweb", "setup", "--install", "--approved"]
                when "agent-run"
                  ["aiweb", "agent-run", "--task", "latest", "--agent", metadata["agent"].to_s.empty? ? "codex" : metadata["agent"].to_s, "--approved"]
                when "engine-run"
                  command = ["aiweb", "engine-run", "--resume", target.fetch("run_id"), "--agent", metadata["agent"].to_s.empty? ? "codex" : metadata["agent"].to_s, "--mode", metadata["mode"].to_s.empty? ? "agentic_local" : metadata["mode"].to_s, "--approved"]
                  command += ["--sandbox", metadata["sandbox"].to_s] unless metadata["sandbox"].to_s.empty?
                  command
                end
      return nil unless command

      {
        "schema_version" => 1,
        "status" => "planned",
        "run_id" => target.fetch("run_id"),
        "kind" => kind,
        "created_at" => now,
        "source_metadata_path" => target["metadata_path"],
        "command" => command,
        "next_command" => command.shelljoin,
        "executes_process" => false,
        "writes_only_descriptor" => true,
        "guardrails" => ["resume records a descriptor only", "no provider CLI or agent process is launched by run-resume", "no .env/.env.* access"]
      }
    end

    def design_research_paths(state)
      research = state.dig("research", "design_research") || {}
      {
        "reference_brief" => research["reference_brief_path"] || ".ai-web/design-reference-brief.md",
        "normalized_results" => research["normalized_results_path"] || ".ai-web/research/lazyweb/results.json",
        "pattern_matrix" => research["pattern_matrix_path"] || ".ai-web/research/lazyweb/pattern-matrix.md",
        "latest" => ".ai-web/research/lazyweb/latest.json"
      }
    end

    def lazyweb_token_configured?
      return true unless ENV["LAZYWEB_MCP_TOKEN"].to_s.strip.empty?
      ["~/.lazyweb/lazyweb_mcp_token", "~/.codex/lazyweb_mcp_token"].any? do |source|
        path = File.expand_path(source)
        File.file?(path) && !File.read(path).to_s.strip.empty?
      rescue SystemCallError
        false
      end
    end

    def design_research_planned_queries
      intent = load_intent_artifact rescue {}
      text = [intent["archetype"], intent["market"], intent["primary_interaction"], intent["idea"]].compact.join(" ").downcase
      if text.match?(/ecommerce|commerce|shop|checkout|product|store|cart/)
        ["mobile product detail page", "checkout flow", "cart upsell", "subscription paywall"]
      elsif text.match?(/service|booking|appointment|local/)
        ["local service booking page", "trust section", "contact booking CTA"]
      elsif text.match?(/premium|luxury|editorial/)
        ["luxury editorial landing page", "premium product page", "high trust hero"]
      elsif text.match?(/chat|assistant|ai assistant/)
        ["AI assistant onboarding", "chat app first screen", "dashboard empty state"]
      else
        ["B2B SaaS landing page", "developer tools pricing page", "team settings billing", "dashboard onboarding"]
      end
    end

    def run_design_research_helper(state:, provider:, policy:, limit:)
      klass = Aiweb.const_get(:DesignResearch) if Aiweb.const_defined?(:DesignResearch)
      return nil unless klass

      ensure_design_research_state_defaults!(state)
      adapter = state.dig("adapters", "design_research") || {}
      client = Aiweb::LazywebClient.new(
        endpoint: adapter["endpoint"] || "https://www.lazyweb.com/mcp",
        timeout_seconds: adapter["command_timeout_seconds"] || 45,
        token_sources: adapter["token_sources"] || ["LAZYWEB_MCP_TOKEN", "~/.lazyweb/lazyweb_mcp_token", "~/.codex/lazyweb_mcp_token"]
      )
      researcher = klass.new(root: root, client: client)
      return nil unless researcher.respond_to?(:run)

      intent = load_intent_artifact
      design_brief = read_design_research_brief_source
      result = researcher.run(intent: intent, design_brief: design_brief, policy: policy, limit: limit)
      return nil unless result.is_a?(Hash)

      changes = Array(result["changed_files"])
      payload = nil
      mutation(dry_run: false) do
        state = load_state
        ensure_design_research_state_defaults!(state)
        research = state["research"]["design_research"]
        paths = design_research_paths(state)
        research["provider"] = provider
        research["policy"] = policy
        research["status"] = "ready"
        research["latest_run"] = now
        research["skipped_reason"] = nil
        research["last_error"] = nil
        research["reference_brief_path"] = paths["reference_brief"]
        research["pattern_matrix_path"] = paths["pattern_matrix"]
        research["normalized_results_path"] = paths["normalized_results"]
        mark_artifacts_from_files!(state)
        add_decision!(state, "design_research_completed", "Completed Lazyweb design research and wrote reference artifacts")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "completed design research"
        payload["design_research"] = design_research_summary(state).merge(
          "planned_queries" => Array(result.dig("latest", "queries")),
          "planned_artifact_paths" => paths.values,
          "token_configured" => true,
          "side_effect_broker" => result["side_effect_broker"],
          "side_effect_broker_events" => result["side_effect_broker_events"]
        )
        payload["next_action"] = "review .ai-web/design-reference-brief.md, then continue with aiweb design-system resolve"
      end
      payload
    rescue StandardError => e
      raise UserError.new("Lazyweb design research adapter failed: #{redact_lazyweb_secret(e.message)}", 4)
    end

    def read_design_research_brief_source
      path = File.join(aiweb_dir, "design-brief.md")
      return nil unless File.file?(path)
      return nil if stub_file?(path)

      File.read(path)
    rescue SystemCallError
      nil
    end

    def record_design_research_skip!(state, provider, policy, reason, paths, planned_queries, dry_run:)
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        ensure_design_research_state_defaults!(state)
        research = state["research"]["design_research"]
        research["provider"] = provider
        research["policy"] = policy
        research["status"] = policy == "off" ? "skipped" : "skipped"
        research["latest_run"] = now
        research["skipped_reason"] = reason
        research["last_error"] = nil
        add_decision!(state, "design_research_skipped", "Skipped Lazyweb design research: #{reason}")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        mark_artifacts_from_files!(state)
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "skipped design research"
        payload["design_research"] = design_research_summary(state).merge(
          "planned_queries" => planned_queries,
          "planned_artifact_paths" => paths.values,
          "token_configured" => lazyweb_token_configured?
        )
        payload["next_action"] = "continue deterministic design flow with aiweb design-system resolve"
      end
      payload
    end

    def design_research_summary(state)
      ensure_design_research_state_defaults!(state)
      research = state.dig("research", "design_research") || {}
      counts = design_research_reference_counts(state)
      {
        "provider" => research["provider"],
        "policy" => research["policy"],
        "status" => research["status"],
        "latest_run" => research["latest_run"],
        "reference_brief_path" => research["reference_brief_path"],
        "pattern_matrix_path" => research["pattern_matrix_path"],
        "normalized_results_path" => research["normalized_results_path"],
        "min_references" => research["min_references"],
        "min_companies" => research["min_companies"],
        "accepted_references" => counts["accepted_references"],
        "unique_companies" => counts["unique_companies"],
        "skipped_reason" => research["skipped_reason"],
        "last_error" => redact_lazyweb_secret(research["last_error"].to_s)
      }
    end

    def design_research_required_blockers(state)
      ensure_design_research_state_defaults!(state)
      research = state.dig("research", "design_research") || {}
      return [] unless research["policy"] == "required"

      blockers = []
      brief_path = File.join(root, research["reference_brief_path"].to_s)
      matrix_path = File.join(root, research["pattern_matrix_path"].to_s)
      counts = design_research_reference_counts(state)
      min_refs = research["min_references"].to_i
      min_companies = research["min_companies"].to_i

      blockers << "Lazyweb design reference brief is required but missing" unless substantive_design_research_file?(brief_path)
      if counts["accepted_references"] < min_refs
        blockers << "Lazyweb references must include >= #{min_refs} accepted references; currently #{counts["accepted_references"]}"
      end
      if counts["unique_companies"] < min_companies
        blockers << "Lazyweb references must include >= #{min_companies} unique companies; currently #{counts["unique_companies"]}"
      end
      missing_sections = missing_design_research_matrix_sections(matrix_path)
      unless missing_sections.empty?
        blockers << "Lazyweb pattern matrix is missing sections: #{missing_sections.join(", ")}"
      end
      blockers
    end

    def design_research_reference_counts(state)
      research = state.dig("research", "design_research") || {}
      path = File.join(root, research["normalized_results_path"].to_s)
      rows = design_research_result_rows(path)
      companies = rows.map { |row| row["company"].to_s.strip.downcase }.reject(&:empty?).uniq
      { "accepted_references" => rows.length, "unique_companies" => companies.length }
    end

    def design_research_result_rows(path)
      return [] unless File.file?(path)
      data = JSON.parse(File.read(path))
      rows = if data.is_a?(Array)
               data
             elsif data.is_a?(Hash)
               data["references"] || data["results"] || data["items"] || []
             else
               []
             end
      rows.select { |row| row.is_a?(Hash) }
    rescue JSON::ParserError, SystemCallError
      []
    end

    def substantive_design_research_file?(path)
      File.file?(path) && !stub_file?(path) && File.read(path).to_s.strip.length >= 80
    rescue SystemCallError
      false
    end

    def missing_design_research_matrix_sections(path)
      required = {
        "hierarchy" => /hierarchy|information hierarchy/i,
        "cta" => /cta|call[- ]?to[- ]?action/i,
        "layout" => /layout/i,
        "visual style" => /visual (style|language)|style/i,
        "mobile/responsive" => /mobile|responsive/i,
        "no-copy" => /no[- ]?copy|copy risk|do not copy/i
      }
      return required.keys unless File.file?(path)
      content = File.read(path)
      required.select { |_name, pattern| !content.match?(pattern) }.keys
    rescue SystemCallError
      required.keys
    end

    def redact_lazyweb_secret(value)
      value.to_s
        .gsub(/Bearer\s+[^\s"']+/i, "Bearer [REDACTED]")
        .gsub(/(LAZYWEB_MCP_TOKEN=)[^\s"']+/i, "\\1[REDACTED]")
        .gsub(/([?&](?:token|access_token|signature|X-Amz-Signature)=)[^&\s"']+/i, "\\1[REDACTED]")
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


    def ensure_pr19_deploy_defaults!(state)
      state["artifacts"] ||= {}
      {
        "github_sync" => GITHUB_SYNC_PLAN_PATH,
        "deploy_plan" => DEPLOY_PLAN_PATH,
        "deploy_cloudflare_pages" => DEPLOY_PROVIDER_CONFIG_PATHS.fetch("cloudflare-pages"),
        "deploy_vercel" => DEPLOY_PROVIDER_CONFIG_PATHS.fetch("vercel")
      }.each do |key, path|
        state["artifacts"][key] ||= { "path" => path, "status" => "missing" }
      end

      state["deploy"] ||= {}
      state["deploy"]["github_sync_plan"] ||= GITHUB_SYNC_PLAN_PATH
      state["deploy"]["deploy_plan"] ||= DEPLOY_PLAN_PATH
      state["deploy"]["latest_plan"] = nil unless state["deploy"].key?("latest_plan")
      state["deploy"]["provider_config_paths"] ||= DEPLOY_PROVIDER_CONFIG_PATHS.dup
      state["deploy"]["github_last_known_url"] = nil unless state["deploy"].key?("github_last_known_url")
      state["deploy"]["preview_url"] = nil unless state["deploy"].key?("preview_url")
      state["deploy"]["production_url"] = nil unless state["deploy"].key?("production_url")
      state["deploy"]["cloudflare_preview_url"] = nil unless state["deploy"].key?("cloudflare_preview_url")
      state["deploy"]["vercel_preview_url"] = nil unless state["deploy"].key?("vercel_preview_url")
      state["deploy"]["github_sync_last_planned_at"] = nil unless state["deploy"].key?("github_sync_last_planned_at")
      state["deploy"]["deploy_plan_last_planned_at"] = nil unless state["deploy"].key?("deploy_plan_last_planned_at")
      state
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

    def deploy_plan_payload(state, target:, dry_run:)
      normalized_target = target.to_s.strip.empty? ? nil : normalize_deploy_target(target)
      {
        "schema_version" => 1,
        "status" => "planned",
        "dry_run" => dry_run,
        "created_at" => now,
        "project_id" => state.dig("project", "id"),
        "project_name" => state.dig("project", "name"),
        "mode" => "local_plan_only",
        "planned_artifact_path" => ".ai-web/deploy/deploy-plan.json",
        "planned_config_path" => DEPLOY_PLAN_PATH,
        "artifact_path" => dry_run ? nil : DEPLOY_PLAN_PATH,
        "provider_config_paths" => DEPLOY_PROVIDER_CONFIG_PATHS.dup,
        "target" => normalized_target,
        "supported_targets" => DEPLOY_PROVIDER_CONFIG_PATHS.keys,
        "targets" => normalized_target ? [normalized_target] : DEPLOY_PROVIDER_CONFIG_PATHS.keys,
        "preview_url" => state.dig("deploy", "preview_url"),
        "production_url" => state.dig("deploy", "production_url"),
        "external_actions_allowed" => false,
        "external_push_performed" => false,
        "external_deploy_performed" => false,
        "requires_approval" => true,
        "guardrails" => ["no external deploy", "no provider CLI", "no network", "no build/preview/install", "no .env/.env.* access"],
        "blocked_external_actions" => ["provider CLI execution", "build command execution", "preview command execution", "network deployment"]
      }
    end

    def deploy_provider_descriptor(target, state)
      {
        "schema_version" => 1,
        "target" => target,
        "created_at" => now,
        "project_id" => state.dig("project", "id"),
        "mode" => "dry_run_descriptor_only",
        "planned_config_path" => DEPLOY_PROVIDER_CONFIG_PATHS.fetch(target),
        "build_command" => state.dig("implementation", "scaffold_build_command"),
        "output_directory" => deploy_output_directory(state),
        "preview_url_slot" => target == "cloudflare-pages" ? "cloudflare_preview_url" : "vercel_preview_url",
        "external_push_performed" => false,
        "external_deploy_performed" => false,
        "requires_approval" => true,
        "provider_cli_invoked" => false,
        "network_calls_performed" => false
      }
    end

    def deploy_local_payload(target, state, dry_run:, force:, approved:, run_id:, run_dir:, stdout_path:, stderr_path:, metadata_path:, side_effect_broker_path:)
      descriptor = deploy_provider_descriptor(target, state)
      command = deploy_provider_command(target, descriptor)
      verify_gate = deploy_verify_loop_gate(state, dry_run: dry_run)
      provider_readiness = deploy_provider_readiness(target, descriptor, command)
      blockers = []
      blockers << "--approved is required for real deploy adapter execution" if !dry_run && !approved
      blockers.concat(verify_gate.fetch("blocking_issues"))
      blockers.concat(provider_readiness.fetch("blocking_issues"))
      blocked = !dry_run && !blockers.empty?
      {
        "schema_version" => 1,
        "status" => dry_run ? "planned" : (blocked ? "blocked" : "ready"),
        "target" => target,
        "dry_run" => dry_run,
        "force" => force,
        "approved" => approved,
        "run_id" => run_id,
        "run_dir" => relative(run_dir),
        "stdout_log" => relative(stdout_path),
        "stderr_log" => relative(stderr_path),
        "metadata_path" => relative(metadata_path),
        "side_effect_broker_path" => relative(side_effect_broker_path),
        "planned_artifact_path" => descriptor.fetch("planned_config_path"),
        "planned_config_path" => descriptor.fetch("planned_config_path"),
        "planned_changes" => [DEPLOY_PLAN_PATH, descriptor.fetch("planned_config_path"), relative(run_dir), relative(stdout_path), relative(stderr_path), relative(metadata_path), relative(side_effect_broker_path)],
        "descriptor" => descriptor,
        "verify_loop_gate" => verify_gate,
        "provider_readiness" => provider_readiness,
        "command" => command,
        "side_effect_broker" => deploy_side_effect_broker_plan(
          target: target,
          command: command,
          broker_path: side_effect_broker_path,
          dry_run: dry_run,
          approved: approved,
          blocked: blocked,
          blockers: blockers
        ),
        "side_effect_broker_events" => [],
        "blocking_issues" => blocked ? blockers.uniq : [],
        "external_actions_allowed" => approved && verify_gate["status"] == "passed" && provider_readiness["status"] == "ready",
        "external_push_performed" => false,
        "external_deploy_performed" => false,
        "provider_executed" => false,
        "requires_approval" => !approved,
        "writes_performed" => false,
        "provider_cli_invoked" => false,
        "network_calls_performed" => false
      }
    end

    def deploy_verify_loop_gate(state, dry_run: false)
      path = state.dig("implementation", "latest_verify_loop").to_s.strip
      blockers = []
      metadata = nil
      expected_provenance = nil
      current_provenance = nil
      provenance_comparison = nil
      if path.empty?
        blockers << "passing verify-loop evidence is required before deploy"
      elsif unsafe_env_path?(path)
        blockers << "verify-loop evidence path is unsafe"
      else
        full = File.expand_path(path, root)
        if !full.start_with?(aiweb_dir + File::SEPARATOR) || !File.file?(full)
          blockers << "verify-loop evidence is missing: #{path}"
        else
          begin
            metadata = JSON.parse(File.read(full))
          rescue JSON::ParserError
            blockers << "verify-loop evidence is malformed: #{path}"
          end
        end
      end
      if metadata
        blockers << "verify-loop must pass before deploy" unless metadata["status"] == "passed"
        blockers << "verify-loop evidence must be from an approved real run" unless metadata["approved"] == true && metadata["dry_run"] == false
        expected_provenance = metadata["provenance"]
        if expected_provenance.nil?
          blockers << "verify-loop evidence is missing deployment provenance; rerun aiweb verify-loop --max-cycles 3 --approved"
        elsif !dry_run
          current_provenance = deploy_workspace_provenance(state, include_tool_versions: true)
          provenance_comparison = deploy_provenance_comparison(expected_provenance, current_provenance)
          blockers.concat(provenance_comparison.fetch("blocking_issues"))
        else
          provenance_comparison = {
            "status" => "not_checked",
            "dry_run" => true,
            "blocking_issues" => [],
            "note" => "deploy --dry-run does not execute git/tool version checks"
          }
        end
      end
      {
        "status" => blockers.empty? ? "passed" : "blocked",
        "path" => path.empty? ? nil : path,
        "verify_loop_status" => metadata && metadata["status"],
        "approved" => metadata && metadata["approved"],
        "dry_run" => metadata && metadata["dry_run"],
        "provenance" => {
          "expected" => expected_provenance,
          "current" => current_provenance,
          "comparison" => provenance_comparison
        },
        "blocking_issues" => blockers
      }
    end

    def deploy_workspace_provenance(state, include_tool_versions:)
      output_directory = deploy_output_directory(state)
      {
        "schema_version" => 1,
        "captured_at" => now,
        "workspace" => {
          "git" => git_workspace_provenance(deploy_git_provenance_paths(output_directory)),
          "source" => deploy_source_tree_provenance,
          "package" => deploy_package_provenance
        },
        "output" => deploy_output_provenance(output_directory),
        "tool_versions" => include_tool_versions ? deploy_tool_versions : {}
      }
    end

    def deploy_provenance_comparison(expected, current)
      checks = [
        ["git.commit_sha", expected.dig("workspace", "git", "commit_sha"), current.dig("workspace", "git", "commit_sha")],
        ["git.dirty", expected.dig("workspace", "git", "dirty"), current.dig("workspace", "git", "dirty")],
        ["git.status_sha256", expected.dig("workspace", "git", "status_sha256"), current.dig("workspace", "git", "status_sha256")],
        ["source.sha256", expected.dig("workspace", "source", "sha256"), current.dig("workspace", "source", "sha256")],
        ["package.sha256", expected.dig("workspace", "package", "sha256"), current.dig("workspace", "package", "sha256")],
        ["output.directory", expected.dig("output", "directory"), current.dig("output", "directory")],
        ["output.sha256", expected.dig("output", "sha256"), current.dig("output", "sha256")]
      ]
      expected_tools = expected["tool_versions"].is_a?(Hash) ? expected["tool_versions"] : {}
      current_tools = current["tool_versions"].is_a?(Hash) ? current["tool_versions"] : {}
      (expected_tools.keys | current_tools.keys).sort.each do |tool|
        checks << ["tool_versions.#{tool}", expected_tools[tool], current_tools[tool]]
      end

      mismatches = checks.each_with_object([]) do |(field, expected_value, current_value), memo|
        next if expected_value == current_value

        memo << {
          "field" => field,
          "expected" => expected_value,
          "current" => current_value
        }
      end
      {
        "status" => mismatches.empty? ? "matched" : "mismatched",
        "mismatches" => mismatches,
        "blocking_issues" => mismatches.map { |entry| "verify-loop provenance mismatch for #{entry.fetch("field")}; rerun aiweb verify-loop --max-cycles 3 --approved before deploy" }
      }
    end

    def git_workspace_provenance(paths)
      commit = git_commit_sha
      scope_paths = Array(paths).map { |path| path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "") }
                                .reject { |path| path.empty? || unsafe_env_path?(path) || deploy_hash_excluded_path?(path) }
                                .uniq
                                .sort
      stdout, _stderr, status = Open3.capture3("git", "status", "--porcelain=v1", "-uall", "--", *scope_paths, chdir: root)
      if status.success?
        normalized = stdout.lines.map(&:chomp).sort.join("\n")
        {
          "available" => true,
          "commit_sha" => commit,
          "dirty" => !normalized.empty?,
          "status_sha256" => Digest::SHA256.hexdigest(normalized),
          "scope_paths" => scope_paths
        }
      else
        {
          "available" => false,
          "commit_sha" => commit,
          "dirty" => nil,
          "status_sha256" => nil,
          "scope_paths" => scope_paths
        }
      end
    rescue StandardError
      {
        "available" => false,
        "commit_sha" => "unknown",
        "dirty" => nil,
        "status_sha256" => nil,
        "scope_paths" => []
      }
    end

    def deploy_git_provenance_paths(output_directory)
      paths = deploy_source_provenance_paths + %w[package.json pnpm-lock.yaml package-lock.json yarn.lock bun.lockb]
      paths << output_directory unless output_directory.to_s.empty?
      paths.select { |path| File.exist?(File.join(root, path)) }
    end

    def deploy_source_tree_provenance
      deploy_hash_paths(deploy_source_provenance_paths, "source")
    end

    def deploy_package_provenance
      deploy_hash_paths(%w[package.json pnpm-lock.yaml package-lock.json yarn.lock bun.lockb], "package")
    end

    def deploy_output_provenance(output_directory)
      return { "directory" => nil, "exists" => false, "file_count" => 0, "sha256" => nil } if output_directory.to_s.empty?

      deploy_hash_paths([output_directory], "output").merge("directory" => output_directory)
    end

    def deploy_source_provenance_paths
      candidates = %w[
        src
        public
        astro.config.mjs
        astro.config.js
        next.config.js
        next.config.mjs
        tsconfig.json
        tailwind.config.js
        tailwind.config.mjs
        vite.config.js
        vite.config.mjs
      ]
      candidates.select { |path| File.exist?(File.join(root, path)) }
    end

    def deploy_hash_paths(paths, label)
      files = deploy_hashable_files(paths)
      digest = Digest::SHA256.new
      files.each do |path|
        full = File.join(root, path)
        digest.update("#{path}\0")
        digest.update(Digest::SHA256.file(full).hexdigest)
        digest.update("\0")
      end
      {
        "label" => label,
        "exists" => !files.empty?,
        "file_count" => files.length,
        "sha256" => files.empty? ? nil : digest.hexdigest
      }
    end

    def deploy_hashable_files(paths)
      Array(paths).flat_map do |path|
        normalized = path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
        next [] if normalized.empty? || unsafe_env_path?(normalized)

        full = File.join(root, normalized)
        if File.file?(full)
          [normalized]
        elsif File.directory?(full)
          files = []
          Find.find(full) do |entry|
            rel = relative(entry)
            if deploy_hash_excluded_path?(rel)
              Find.prune if File.directory?(entry)
              next
            end
            files << rel if File.file?(entry)
          end
          files
        else
          []
        end
      end.compact.uniq.sort
    end

    def deploy_hash_excluded_path?(path)
      normalized = path.to_s.tr("\\", "/")
      return true if normalized.empty?
      return true if unsafe_env_path?(normalized)

      normalized.split("/").any? { |part| %w[.git .ai-web node_modules].include?(part) }
    end

    def deploy_tool_versions
      {
        "ruby" => RUBY_VERSION,
        "pnpm" => executable_version("pnpm", "--version"),
        "playwright" => executable_version(File.join("node_modules", ".bin", "playwright"), "--version"),
        "axe" => executable_version(File.join("node_modules", ".bin", "axe"), "--version"),
        "lighthouse" => executable_version(File.join("node_modules", ".bin", "lighthouse"), "--version")
      }
    end

    def executable_version(executable, *args)
      command = if executable.include?(File::SEPARATOR)
                  path = File.join(root, executable)
                  return nil unless File.executable?(path)

                  [path, *args]
                else
                  path = executable_path(executable)
                  return nil unless path

                  [path, *args]
                end
      stdout = ""
      Timeout.timeout(2) do
        stdout, _stderr, status = Open3.capture3(subprocess_path_env, *command, chdir: root, unsetenv_others: true)
        return nil unless status.success?
      end
      stdout.lines.first.to_s.strip[0, 120]
    rescue StandardError
      nil
    end

    def deploy_provider_command(target, descriptor)
      output_directory = descriptor["output_directory"].to_s
      case target
      when "cloudflare-pages"
        ["wrangler", "pages", "deploy", output_directory, "--project-name", deploy_project_name]
      when "vercel"
        ["vercel", "deploy", output_directory, "--prebuilt"]
      else
        [target]
      end
    end

    def deploy_provider_readiness(target, descriptor, command)
      blockers = []
      output_directory = descriptor["output_directory"].to_s
      blockers << "deploy output directory is missing for #{target}: #{output_directory}" if output_directory.empty? || !Dir.exist?(File.join(root, output_directory))
      executable = command.first.to_s
      blockers << "provider CLI executable is missing from PATH: #{executable}" if executable_path(executable).nil?
      {
        "status" => blockers.empty? ? "ready" : "blocked",
        "target" => target,
        "output_directory" => output_directory,
        "executable" => executable,
        "command" => command,
        "blocking_issues" => blockers
      }
    end

    def deploy_side_effect_broker_plan(target:, command:, broker_path:, dry_run:, approved:, blocked:, blockers:)
      side_effect_broker_plan(
        broker: "aiweb.deploy.side_effect_broker",
        scope: "deploy.provider_cli",
        target: target,
        command: command,
        broker_path: broker_path,
        dry_run: dry_run,
        approved: approved,
        blocked: blocked,
        blockers: blockers,
        risk_class: "external_network_deploy",
        policy_extra: {
          "requires_passing_verify_loop" => true,
          "requires_ready_provider_cli" => true
        }
      )
    end

    def deploy_side_effect_broker_context(target:, command:, deploy_payload:)
      side_effect_broker_context(
        broker: "aiweb.deploy.side_effect_broker",
        scope: "deploy.provider_cli",
        target: target,
        command: command,
        risk_class: "external_network_deploy",
        approved: deploy_payload.fetch("approved"),
        extra: {
          "verify_loop_status" => deploy_payload.dig("verify_loop_gate", "status"),
          "provider_readiness_status" => deploy_payload.dig("provider_readiness", "status")
        }
      )
    end

    def deploy_project_name
      name = File.basename(root).gsub(/[^A-Za-z0-9_-]+/, "-").downcase.sub(/\A-+/, "").sub(/-+\z/, "")
      name.empty? ? "aiweb-project" : name
    end

    def pr19_safety_payload(planned_changes)
      {
        "external_push_performed" => false,
        "external_deploy_performed" => false,
        "requires_approval" => true,
        "planned_config_paths" => planned_changes
      }
    end

    def normalize_deploy_target(target)
      normalized = target.to_s.strip.downcase.tr("_", "-")
      aliases = {
        "cloudflare" => "cloudflare-pages",
        "cloudflare-pages" => "cloudflare-pages",
        "pages" => "cloudflare-pages",
        "vercel" => "vercel"
      }
      normalized = aliases[normalized] || normalized
      return normalized if DEPLOY_PROVIDER_CONFIG_PATHS.key?(normalized)

      raise UserError.new("deploy target must be one of #{DEPLOY_PROVIDER_CONFIG_PATHS.keys.join(', ')}", 1)
    end

    def deploy_output_directory(state)
      profile = state.dig("implementation", "scaffold_profile") || state.dig("implementation", "stack_profile")
      case profile
      when "D" then "dist"
      when "S" then ".next"
      else nil
      end
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

    def ensure_scaffold_state_defaults!(state)
      ensure_implementation_state_defaults!(state)
      state["implementation"]["scaffold_created"] = false if state["implementation"]["scaffold_created"].nil?
      state["implementation"]["scaffold_profile"] ||= nil
      state["implementation"]["scaffold_framework"] ||= nil
      state["implementation"]["scaffold_package_manager"] ||= nil
      state["implementation"]["scaffold_dev_command"] ||= nil
      state["implementation"]["scaffold_build_command"] ||= nil
      state["implementation"]["scaffold_metadata_path"] ||= nil
      state["implementation"]["latest_agent_run"] ||= nil
      state["implementation"]["last_diff"] ||= nil
      state
    end

    def apply_scaffold_state!(state, metadata)
      ensure_scaffold_state_defaults!(state)
      state["implementation"]["stack_profile"] = metadata.fetch("profile")
      state["implementation"]["scaffold_target"] = metadata.fetch("scaffold_target")
      state["implementation"]["scaffold_created"] = true
      state["implementation"]["scaffold_profile"] = metadata.fetch("profile")
      state["implementation"]["scaffold_framework"] = metadata.fetch("framework")
      state["implementation"]["scaffold_package_manager"] = metadata.fetch("package_manager")
      state["implementation"]["scaffold_dev_command"] = metadata.fetch("dev_command")
      state["implementation"]["scaffold_build_command"] = metadata.fetch("build_command")
      state["implementation"]["scaffold_metadata_path"] = metadata.fetch("metadata_path")
      state
    end

    def validate_scaffold_design_gate!(state)
      design_path = File.join(aiweb_dir, "DESIGN.md")
      if !File.file?(design_path) || stub_file?(design_path)
        raise UserError.new("scaffold profile D requires substantive .ai-web/DESIGN.md; run aiweb design-system resolve or provide a completed design source of truth before scaffold", 1)
      end

      selected = state.dig("design_candidates", "selected_candidate").to_s.strip
      if selected.empty?
        raise UserError.new("scaffold profile D requires design_candidates.selected_candidate; run aiweb design --candidates 3 then aiweb select-design candidate-01|candidate-02|candidate-03 before scaffold", 1)
      end

      selected_path = selected_candidate_artifact_path(state, selected)
      unless selected_path && File.file?(selected_path)
        relative_selected_path = selected_path ? relative(selected_path) : ".ai-web/design-candidates/#{selected}.html"
        raise UserError.new("scaffold profile D requires selected candidate artifact #{relative_selected_path}; rerun aiweb design --candidates 3 then aiweb select-design #{selected} before scaffold", 1)
      end
    end

    def selected_candidate_artifact_path(state, selected)
      ref = Array(state.dig("design_candidates", "candidates")).find { |candidate| candidate.is_a?(Hash) && candidate["id"].to_s == selected }
      candidates = []
      candidates << File.join(root, ref["path"].to_s) if ref && !ref["path"].to_s.strip.empty?
      candidates << File.join(aiweb_dir, "design-candidates", "#{selected}.html")
      candidates << File.join(aiweb_dir, "design-candidates", "#{selected}.md")
      candidates.find { |path| File.file?(path) } || candidates.first
    end

    def preflight_scaffold_targets!(files, metadata_path:, force:, profile: "D")
      conflicts = scaffold_target_type_conflicts(files.keys + [relative(metadata_path)])
      return if conflicts.empty?

      raise UserError.new("scaffold profile #{profile} cannot write because directories conflict with required scaffold files: #{conflicts.join(", ")}. Remove or rename those directories before rerunning; --force only overwrites regular files and wrote no scaffold files.", 1)
    end

    def scaffold_target_type_conflicts(relative_paths)
      conflicts = []
      relative_paths.each do |relative_path|
        parts = relative_path.split(File::SEPARATOR)
        parts.each_index do |index|
          partial = File.join(root, *parts[0..index])
          next unless File.exist?(partial)

          if index == parts.length - 1
            conflicts << "#{relative_path} (directory exists where file is needed)" if File.directory?(partial)
          elsif !File.directory?(partial)
            conflicts << "#{parts[0..index].join(File::SEPARATOR)} (file exists where directory is needed for #{relative_path})"
            break
          end
        end
      end
      conflicts.uniq
    end

    def scaffold_conflicts(files, force:)
      return [] if force

      files.each_with_object([]) do |(relative_path, content), conflicts|
        path = File.join(root, relative_path)
        next unless File.file?(path)
        next if File.read(path) == content

        conflicts << relative_path
      end
    end

    def scaffold_profile_d_metadata(files, state, profile_data)
      selected = selected_candidate_id
      {
        "schema_version" => 1,
        "profile" => "D",
        "framework" => "Astro",
        "package_manager" => "pnpm",
        "dev_command" => "pnpm dev",
        "build_command" => "pnpm build",
        "scaffold_target" => profile_data.fetch(:scaffold_target),
        "selected_candidate" => selected,
        "selected_candidate_path" => selected ? ".ai-web/design-candidates/#{selected}.html" : nil,
        "design_source" => File.exist?(File.join(aiweb_dir, "DESIGN.md")) ? ".ai-web/DESIGN.md" : nil,
        "design_brief_source" => File.exist?(File.join(aiweb_dir, "design-brief.md")) ? ".ai-web/design-brief.md" : nil,
        "created_at" => now,
        "metadata_path" => SCAFFOLD_PROFILE_D_METADATA_PATH,
        "files" => files.keys.map do |relative_path|
          {
            "path" => relative_path,
            "sha256" => Digest::SHA256.hexdigest(files.fetch(relative_path))
          }
        end
      }
    end

    def scaffold_profile_d_files(state)
      context = scaffold_context(state)
      {
        "package.json" => package_json_profile_d(context),
        "astro.config.mjs" => astro_config_profile_d,
        "tailwind.config.mjs" => tailwind_config_profile_d,
        "src/styles/global.css" => global_css_profile_d,
        "src/content/site.json" => JSON.pretty_generate(site_content_profile_d(context)) + "\n",
        "src/components/Hero.astro" => hero_component_profile_d,
        "src/components/SectionCard.astro" => section_card_component_profile_d,
        "src/pages/index.astro" => index_page_profile_d(context),
        "public/.gitkeep" => ""
      }
    end


    def scaffold_profile_s_metadata(files, profile_data)
      {
        "schema_version" => 1,
        "profile" => "S",
        "framework" => "Next.js",
        "framework_detail" => "Next.js App Router + Supabase SSR",
        "package_manager" => "pnpm",
        "dev_command" => "pnpm dev",
        "build_command" => "pnpm build",
        "scaffold_target" => profile_data.fetch(:scaffold_target),
        "metadata_path" => SCAFFOLD_PROFILE_S_METADATA_PATH,
        "secret_qa_path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH,
        "local_verify_path" => SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH,
        "local_only" => true,
        "external_actions_allowed" => false,
        "env_template_path" => "supabase/env.example.template",
        "env_dotfile_created" => false,
        "supabase_public_env" => %w[NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY],
        "guardrails" => [
          "no external Supabase project creation",
          "no deploy/external hosting",
          "no .env or .env.* files"
        ],
        "created_at" => now,
        "files" => files.keys.map do |relative_path|
          {
            "path" => relative_path,
            "sha256" => Digest::SHA256.hexdigest(files.fetch(relative_path))
          }
        end
      }
    end

    def scaffold_profile_s_files(state)
      context = scaffold_context(state)
      {
        "package.json" => package_json_profile_s(context),
        "next.config.mjs" => next_config_profile_s,
        "tsconfig.json" => tsconfig_profile_s,
        "src/app/layout.tsx" => layout_tsx_profile_s(context),
        "src/app/page.tsx" => page_tsx_profile_s(context),
        "src/app/globals.css" => globals_css_profile_s,
        "src/lib/supabase/client.ts" => supabase_client_ts_profile_s,
        "src/lib/supabase/server.ts" => supabase_server_ts_profile_s,
        "supabase/migrations/0001_initial_schema.sql" => supabase_initial_schema_profile_s,
        "supabase/rls-draft.md" => supabase_rls_draft_profile_s,
        "supabase/storage.md" => supabase_storage_profile_s,
        "supabase/env.example.template" => supabase_env_template_profile_s
      }
    end

    def supabase_secret_qa_scan_files
      SCAFFOLD_PROFILE_S_REQUIRED_FILES.each_with_object({}) do |relative_path, memo|
        next if relative_path == SCAFFOLD_PROFILE_S_SECRET_QA_PATH
        next if unsafe_env_path?(relative_path)

        path = File.join(root, relative_path)
        memo[relative_path] = File.read(path) if File.file?(path)
      end
    end

    def supabase_local_verify_scan_files
      SCAFFOLD_PROFILE_S_REQUIRED_FILES.each_with_object({}) do |relative_path, memo|
        next if unsafe_env_path?(relative_path)

        path = File.join(root, relative_path)
        memo[relative_path] = File.read(path) if File.file?(path)
      end
    end

    def scaffold_profile_s_secret_qa(files)
      scanned = files.keys.reject { |path| unsafe_env_path?(path) }.sort
      findings = scanned.flat_map do |relative_path|
        body = files.fetch(relative_path)
        PROFILE_S_SECRET_EXPOSURE_PATTERNS.each_with_object([]) do |pattern, memo|
          next unless body.match?(pattern)

          memo << { "path" => relative_path, "pattern" => pattern.source }
        end
      end
      {
        "schema_version" => 1,
        "status" => findings.empty? ? "passed" : "failed",
        "created_at" => now,
        "scanned_paths" => scanned,
        "read_dot_env" => false,
        "scan" => {
          "mode" => "generated-safe-files-only",
          "excluded_patterns" => [".env", ".env.*"],
          "scanned_files" => scanned,
          "env_files_read" => false,
          "source_contents_embedded" => false
        },
        "files" => scanned.map { |relative_path| { "path" => relative_path, "sha256" => Digest::SHA256.hexdigest(files.fetch(relative_path)) } },
        "findings" => findings
      }
    end

    def scaffold_profile_s_local_verify(files)
      scanned = files.keys.reject { |path| unsafe_env_path?(path) }.sort
      required_paths = SCAFFOLD_PROFILE_S_REQUIRED_FILES
      missing_paths = required_paths.reject { |path| files.key?(path) }
      checks = {
        "required_files" => supabase_local_required_files_check(missing_paths),
        "safe_env_template" => supabase_local_env_template_check(files["supabase/env.example.template"]),
        "ssr_stubs" => supabase_local_ssr_stubs_check(files),
        "migrations_rls" => supabase_local_migrations_check(files["supabase/migrations/0001_initial_schema.sql"]),
        "storage_docs" => supabase_local_storage_docs_check(files["supabase/storage.md"]),
        "metadata" => supabase_local_metadata_check(files[SCAFFOLD_PROFILE_S_METADATA_PATH]),
        "secret_qa" => supabase_local_secret_qa_check(files[SCAFFOLD_PROFILE_S_SECRET_QA_PATH]),
        "external_actions" => supabase_local_external_actions_check(files)
      }
      findings = checks.flat_map { |name, check| Array(check["findings"]).map { |finding| finding.merge("check" => name) } }
      {
        "schema_version" => 1,
        "status" => findings.empty? ? "passed" : "failed",
        "created_at" => now,
        "local_only" => true,
        "external_actions_performed" => false,
        "provider_cli_invoked" => false,
        "read_dot_env" => false,
        "scanned_paths" => scanned,
        "required_paths" => required_paths,
        "checks" => checks,
        "files" => scanned.map { |relative_path| { "path" => relative_path, "sha256" => Digest::SHA256.hexdigest(files.fetch(relative_path)) } },
        "findings" => findings
      }
    end

    def supabase_local_required_files_check(missing_paths)
      findings = missing_paths.map { |path| { "path" => path, "message" => "required Profile S file is missing" } }
      { "status" => findings.empty? ? "passed" : "failed", "missing_paths" => missing_paths, "findings" => findings }
    end

    def supabase_local_env_template_check(body)
      findings = []
      if body.to_s.empty?
        findings << { "path" => "supabase/env.example.template", "message" => "safe Supabase env template is missing" }
      else
        findings << { "path" => "supabase/env.example.template", "message" => "NEXT_PUBLIC_SUPABASE_URL placeholder is missing" } unless body.match?(/NEXT_PUBLIC_SUPABASE_URL=/)
        findings << { "path" => "supabase/env.example.template", "message" => "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY placeholder is missing" } unless body.match?(/NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=/)
        PROFILE_S_SECRET_EXPOSURE_PATTERNS.each do |pattern|
          findings << { "path" => "supabase/env.example.template", "message" => "unsafe secret placeholder pattern found", "pattern" => pattern.source } if body.match?(pattern)
        end
      end
      { "status" => findings.empty? ? "passed" : "failed", "allowed_public_env" => %w[NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY], "dot_env_created" => false, "findings" => findings }
    end

    def supabase_local_ssr_stubs_check(files)
      client = files["src/lib/supabase/client.ts"].to_s
      server = files["src/lib/supabase/server.ts"].to_s
      findings = []
      findings << { "path" => "src/lib/supabase/client.ts", "message" => "browser Supabase SSR client stub is missing createBrowserClient" } unless client.match?(/createBrowserClient/)
      findings << { "path" => "src/lib/supabase/server.ts", "message" => "server Supabase SSR client stub is missing createServerClient" } unless server.match?(/createServerClient/)
      findings << { "path" => "src/lib/supabase/server.ts", "message" => "server Supabase SSR client stub is missing cookies integration" } unless server.match?(/cookies/)
      %w[NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY].each do |key|
        findings << { "path" => "src/lib/supabase/client.ts", "message" => "#{key} is missing from browser client stub" } unless client.include?(key)
        findings << { "path" => "src/lib/supabase/server.ts", "message" => "#{key} is missing from server client stub" } unless server.include?(key)
      end
      { "status" => findings.empty? ? "passed" : "failed", "client_path" => "src/lib/supabase/client.ts", "server_path" => "src/lib/supabase/server.ts", "findings" => findings }
    end

    def supabase_local_migrations_check(body)
      findings = []
      text = body.to_s
      findings << { "path" => "supabase/migrations/0001_initial_schema.sql", "message" => "migration is missing enable row level security" } unless text.match?(/enable row level security/i)
      findings << { "path" => "supabase/migrations/0001_initial_schema.sql", "message" => "migration is missing create policy statements" } unless text.match?(/create policy/i)
      findings << { "path" => "supabase/migrations/0001_initial_schema.sql", "message" => "migration is missing auth.uid ownership guard" } unless text.match?(/auth\.uid\(\)/i)
      { "status" => findings.empty? ? "passed" : "failed", "path" => "supabase/migrations/0001_initial_schema.sql", "findings" => findings }
    end

    def supabase_local_storage_docs_check(body)
      findings = []
      text = body.to_s
      findings << { "path" => "supabase/storage.md", "message" => "storage planning doc is missing" } if text.empty?
      findings << { "path" => "supabase/storage.md", "message" => "storage planning doc must describe storage options" } unless text.match?(/storage|bucket/i)
      findings << { "path" => "supabase/storage.md", "message" => "storage planning doc must retain external-action guardrails" } unless text.match?(/does not run Supabase CLI commands|no buckets are created/i)
      { "status" => findings.empty? ? "passed" : "failed", "path" => "supabase/storage.md", "findings" => findings }
    end

    def supabase_local_metadata_check(body)
      findings = []
      metadata = body.to_s.empty? ? nil : JSON.parse(body)
      unless metadata.is_a?(Hash)
        findings << { "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "message" => "Profile S metadata is missing or malformed" }
      else
        findings << { "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "message" => "metadata profile must be S" } unless metadata["profile"] == "S"
        findings << { "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "message" => "metadata must stay local-only" } unless metadata["local_only"] == true
        findings << { "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "message" => "metadata must disallow external actions" } unless metadata["external_actions_allowed"] == false
      end
      { "status" => findings.empty? ? "passed" : "failed", "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "findings" => findings }
    rescue JSON::ParserError
      { "status" => "failed", "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "findings" => [{ "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "message" => "Profile S metadata is malformed" }] }
    end

    def supabase_local_secret_qa_check(body)
      findings = []
      qa = body.to_s.empty? ? nil : JSON.parse(body)
      unless qa.is_a?(Hash)
        findings << { "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "message" => "Supabase secret QA artifact is missing or malformed" }
      else
        findings << { "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "message" => "Supabase secret QA must pass before local verification passes" } unless qa["status"] == "passed"
        findings << { "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "message" => "Supabase secret QA must not read dot-env files" } unless qa["read_dot_env"] == false
      end
      { "status" => findings.empty? ? "passed" : "failed", "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "findings" => findings }
    rescue JSON::ParserError
      { "status" => "failed", "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "findings" => [{ "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "message" => "Supabase secret QA artifact is malformed" }] }
    end

    def supabase_local_external_actions_check(files)
      patterns = {
        "supabase_provider_cli" => /supabase\s+(login|link|projects\s+create|init|start|db\s+push)/i,
        "deploy_cli" => /\b(vercel|netlify|cloudflare)\s+deploy\b/i,
        "network_curl" => /\bcurl\s+https?:\/\//i
      }
      findings = files.reject { |path, _| path.start_with?(".ai-web/qa/") }.flat_map do |relative_path, body|
        patterns.each_with_object([]) do |(name, pattern), memo|
          memo << { "path" => relative_path, "message" => "external action command pattern found", "pattern" => name } if body.to_s.match?(pattern)
        end
      end
      { "status" => findings.empty? ? "passed" : "failed", "performed" => false, "network" => false, "provider_cli" => false, "findings" => findings }
    end

    def unsafe_env_path?(relative_path)
      relative_path.to_s.tr("\\", "/").split("/").any? { |part| part.start_with?(".env") }
    end

    def secret_looking_path?(relative_path)
      normalized = relative_path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
      normalized.match?(SECRET_LOOKING_PATH_PATTERN)
    end

    def package_json_profile_s(context)
      JSON.pretty_generate(
        "name" => npm_package_name(context.fetch(:project_id).empty? ? context.fetch(:project_name) : context.fetch(:project_id)),
        "version" => "0.1.0",
        "private" => true,
        "type" => "module",
        "scripts" => {
          "dev" => "next dev",
          "build" => "next build",
          "start" => "next start"
        },
        "dependencies" => {
          "@supabase/ssr" => "latest",
          "@supabase/supabase-js" => "latest",
          "next" => "latest",
          "react" => "latest",
          "react-dom" => "latest"
        },
        "devDependencies" => {
          "@types/node" => "latest",
          "@types/react" => "latest",
          "@types/react-dom" => "latest",
          "typescript" => "latest"
        }
      ) + "\n"
    end

    def next_config_profile_s
      <<~JS
        /** @type {import('next').NextConfig} */
        const nextConfig = {};

        export default nextConfig;
      JS
    end

    def tsconfig_profile_s
      JSON.pretty_generate(
        "compilerOptions" => {
          "target" => "ES2017",
          "lib" => %w[dom dom.iterable esnext],
          "allowJs" => true,
          "skipLibCheck" => true,
          "strict" => true,
          "noEmit" => true,
          "esModuleInterop" => true,
          "module" => "esnext",
          "moduleResolution" => "bundler",
          "resolveJsonModule" => true,
          "isolatedModules" => true,
          "jsx" => "preserve",
          "incremental" => true,
          "plugins" => [{ "name" => "next" }],
          "paths" => { "@/*" => ["./src/*"] }
        },
        "include" => ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
        "exclude" => ["node_modules"]
      ) + "\n"
    end

    def layout_tsx_profile_s(context)
      title = context.fetch(:title).to_s.empty? ? context.fetch(:project_name) : context.fetch(:title)
      <<~TSX
        import type { Metadata } from 'next';
        import './globals.css';

        export const metadata: Metadata = {
          title: #{title.inspect},
          description: #{context.fetch(:description).inspect},
        };

        export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
          return (
            <html lang="ko">
              <body>{children}</body>
            </html>
          );
        }
      TSX
    end

    def page_tsx_profile_s(context)
      title = context.fetch(:title).to_s.empty? ? context.fetch(:project_name) : context.fetch(:title)
      <<~TSX
        import { createClient } from '@/lib/supabase/server';

        export default async function Home() {
          const supabase = await createClient();
          const { data: profileRows } = await supabase.from('profiles').select('id, display_name').limit(3);

          return (
            <main className="mx-auto flex min-h-screen max-w-5xl flex-col gap-8 px-6 py-16">
              <section className="rounded-3xl border border-slate-200 bg-white p-8 shadow-sm">
                <p className="text-sm font-semibold uppercase tracking-[0.24em] text-emerald-700">AI Web Director Profile S</p>
                <h1 className="mt-4 text-4xl font-bold tracking-tight text-slate-950">#{CGI.escapeHTML(title)}</h1>
                <p className="mt-4 max-w-2xl text-lg leading-8 text-slate-700">#{CGI.escapeHTML(context.fetch(:description))}</p>
              </section>

              <section className="rounded-3xl border border-dashed border-emerald-300 bg-emerald-50 p-6">
                <h2 className="text-2xl font-bold text-slate-950">Local Supabase planning stub</h2>
                <p className="mt-3 text-slate-700">
                  This scaffold uses safe public browser env names only and does not create or read dot-env files.
                </p>
                <pre className="mt-4 overflow-auto rounded-2xl bg-slate-950 p-4 text-sm text-emerald-100">
                  {JSON.stringify(profileRows ?? [], null, 2)}
                </pre>
              </section>
            </main>
          );
        }
      TSX
    end

    def globals_css_profile_s
      <<~CSS
        :root {
          color: #0f172a;
          background: #f8fafc;
          font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        }

        * {
          box-sizing: border-box;
        }

        body {
          margin: 0;
          min-width: 320px;
        }
      CSS
    end

    def supabase_client_ts_profile_s
      <<~TS
        import { createBrowserClient } from '@supabase/ssr';

        export function createClient() {
          return createBrowserClient(
            process.env.NEXT_PUBLIC_SUPABASE_URL!,
            process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
          );
        }
      TS
    end

    def supabase_server_ts_profile_s
      <<~TS
        import { createServerClient } from '@supabase/ssr';
        import { cookies } from 'next/headers';

        export async function createClient() {
          const cookieStore = await cookies();

          return createServerClient(
            process.env.NEXT_PUBLIC_SUPABASE_URL!,
            process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
            {
              cookies: {
                getAll() {
                  return cookieStore.getAll();
                },
                setAll(cookiesToSet) {
                  try {
                    cookiesToSet.forEach(({ name, value, options }) => cookieStore.set(name, value, options));
                  } catch {
                    // Server Components cannot set cookies. Middleware should refresh sessions when needed.
                  }
                },
              },
            },
          );
        }
      TS
    end

    def supabase_initial_schema_profile_s
      <<~SQL
        -- Profile S draft migration for local planning only.
        -- Review with a database owner before applying to any external Supabase project.

        create table if not exists public.profiles (
          id uuid primary key references auth.users(id) on delete cascade,
          display_name text,
          created_at timestamptz not null default now(),
          updated_at timestamptz not null default now()
        );

        alter table public.profiles enable row level security;

        create policy "profiles are viewable by owner"
          on public.profiles for select
          using (auth.uid() = id);

        create policy "profiles are insertable by owner"
          on public.profiles for insert
          with check (auth.uid() = id);

        create policy "profiles are updatable by owner"
          on public.profiles for update
          using (auth.uid() = id)
          with check (auth.uid() = id);
      SQL
    end

    def supabase_rls_draft_profile_s
      <<~MD
        # Supabase RLS Draft — Profile S

        Status: draft for local planning only.

        ## Policies
        - `profiles`: owner-only select/insert/update using `auth.uid() = id`.
        - Add table-specific policies before connecting real product data.

        ## Guardrails
        - Do not apply this draft to a hosted Supabase project without review.
        - Keep service-role credentials out of generated app files and browser code.
        - Public browser variables are limited to `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`.
      MD
    end

    def supabase_storage_profile_s
      <<~MD
        # Supabase Storage Options — Profile S

        Status: planning notes only; no buckets are created by this scaffold.

        ## Option A: private user uploads
        - Bucket: `user-uploads`.
        - Access: authenticated owner read/write policies.
        - Use signed URLs for temporary sharing.

        ## Option B: public marketing assets
        - Bucket: `public-assets`.
        - Access: public read, restricted write.
        - Prefer static `public/` files until product scope needs runtime uploads.

        ## External-action guardrail
        This scaffold does not run Supabase CLI commands, create buckets, or contact external APIs.
      MD
    end

    def supabase_env_template_profile_s
      <<~TXT
        # Copy these keys into your local untracked environment file when you are ready.
        # This is intentionally not named .env.example because Profile S must not create dot-env files.
        NEXT_PUBLIC_SUPABASE_URL=https://your-project-ref.supabase.co
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=your-publishable-key
      TXT
    end

    def scaffold_context(state)
      intent = load_intent_artifact
      selected = selected_candidate_id
      {
        project_name: state.dig("project", "name").to_s.empty? ? File.basename(root) : state.dig("project", "name"),
        project_id: state.dig("project", "id").to_s.empty? ? default_project_id : state.dig("project", "id"),
        title: scaffold_title_from_artifacts(state, intent),
        description: scaffold_description_from_artifacts(intent),
        archetype: intent["archetype"].to_s,
        primary_interaction: intent["primary_interaction"].to_s,
        must_have_first_view: Array(intent["must_have_first_view"]),
        must_not_have: Array(intent["must_not_have"]),
        design_brief_excerpt: scaffold_excerpt(File.join(aiweb_dir, "design-brief.md")),
        design_system_excerpt: scaffold_excerpt(File.join(aiweb_dir, "DESIGN.md")),
        selected_candidate: selected,
        selected_candidate_path: selected ? ".ai-web/design-candidates/#{selected}.html" : nil
      }
    end

    def scaffold_title_from_artifacts(state, intent)
      project_path = File.join(aiweb_dir, "project.md")
      if File.exist?(project_path)
        idea_line = File.read(project_path).lines.each_cons(2).find { |a, _b| a.strip == "## Idea" }
        title = idea_line&.last.to_s.strip
        return title unless title.empty? || title.start_with?("TODO")
      end
      concept = intent["original_intent"].to_s.strip
      return concept unless concept.empty?

      state.dig("project", "name").to_s
    end

    def scaffold_description_from_artifacts(intent)
      primary = intent["primary_interaction"].to_s.strip
      archetype = intent["archetype"].to_s.strip
      if primary.empty? && archetype.empty?
        "Source-backed static site scaffold generated by AI Web Director."
      else
        "A #{archetype.empty? ? "static" : archetype} web foundation centered on #{primary.empty? ? "the approved first-view contract" : primary}."
      end
    end

    def scaffold_excerpt(path, max_lines = 18)
      return "" unless File.exist?(path)

      File.read(path).lines.map(&:rstrip).reject(&:empty?).first(max_lines).join("\n")
    end

    def npm_package_name(value)
      ascii = value.to_s.downcase.gsub(/[^a-z0-9._-]+/, "-").gsub(/^-+|-+$/, "")
      ascii = "aiweb-site" if ascii.empty? || ascii.start_with?(".", "_")
      ascii
    end

    def package_json_profile_d(context)
      JSON.pretty_generate(
        "name" => npm_package_name(context.fetch(:project_id).empty? ? context.fetch(:project_name) : context.fetch(:project_id)),
        "version" => "0.1.0",
        "private" => true,
        "type" => "module",
        "scripts" => {
          "dev" => "astro dev",
          "build" => "astro build",
          "preview" => "astro preview"
        },
        "dependencies" => {
          "@astrojs/mdx" => "latest",
          "@astrojs/sitemap" => "latest",
          "astro" => "latest",
          "tailwindcss" => "latest",
          "@tailwindcss/vite" => "latest"
        }
      ) + "\n"
    end

    def astro_config_profile_d
      <<~JS
        import { defineConfig } from 'astro/config';
        import mdx from '@astrojs/mdx';
        import sitemap from '@astrojs/sitemap';
        import tailwindcss from '@tailwindcss/vite';

        export default defineConfig({
          integrations: [mdx(), sitemap()],
          vite: {
            plugins: [tailwindcss()]
          }
        });
      JS
    end

    def tailwind_config_profile_d
      <<~JS
        export default {
          content: ['./src/**/*.{astro,html,js,jsx,md,mdx,svelte,ts,tsx,vue}'],
          theme: {
            extend: {
              colors: {
                ink: '#111827',
                paper: '#fffaf3',
                accent: '#2563eb'
              }
            }
          }
        };
      JS
    end

    def global_css_profile_d
      <<~CSS
        @import "tailwindcss";

        :root {
          color: #111827;
          background: #fffaf3;
          font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        }

        body {
          margin: 0;
          min-width: 320px;
        }

        a {
          color: inherit;
        }
      CSS
    end

    def site_content_profile_d(context)
      {
        "schema_version" => 1,
        "title" => context.fetch(:title),
        "description" => context.fetch(:description),
        "archetype" => context.fetch(:archetype),
        "primary_interaction" => context.fetch(:primary_interaction),
        "must_have_first_view" => context.fetch(:must_have_first_view),
        "must_not_have" => context.fetch(:must_not_have),
        "selected_candidate" => context.fetch(:selected_candidate),
        "selected_candidate_path" => context.fetch(:selected_candidate_path),
        "design_brief_excerpt" => context.fetch(:design_brief_excerpt),
        "design_system_excerpt" => context.fetch(:design_system_excerpt),
        "content_policy" => "Use only source-backed proof. Do not add fake testimonials, fake logos, fake customer counts, or fake metrics."
      }
    end

    def hero_component_profile_d
      <<~ASTRO
        ---
        const { title, description, primaryInteraction, selectedCandidate } = Astro.props;
        ---

        <section class="mx-auto grid max-w-6xl gap-8 px-6 py-20 md:grid-cols-[1.2fr_0.8fr] md:items-center" data-aiweb-id="page.home.hero">
          <div data-aiweb-id="component.hero.copy">
            <p class="mb-3 text-sm font-semibold uppercase tracking-[0.24em] text-blue-700">AI Web Director Profile D</p>
            <h1 class="text-4xl font-bold tracking-tight text-slate-950 md:text-6xl">{title}</h1>
            <p class="mt-5 max-w-2xl text-lg leading-8 text-slate-700">{description}</p>
            <div class="mt-8 rounded-2xl border border-slate-200 bg-white/80 p-5 shadow-sm" data-aiweb-id="component.hero.primary-interaction">
              <p class="text-sm font-semibold text-slate-500">Primary first-view interaction</p>
              <p class="mt-2 text-xl font-semibold text-slate-950">{primaryInteraction || 'TODO: confirm from .ai-web/first-view-contract.md'}</p>
            </div>
          </div>
          <aside class="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm" data-aiweb-id="component.hero.design-reference">
            <p class="text-sm font-semibold text-slate-500">Design reference</p>
            <p class="mt-2 text-2xl font-bold text-slate-950">{selectedCandidate || 'No selected candidate yet'}</p>
            <p class="mt-3 text-sm leading-6 text-slate-600">Generated from Director artifacts. Keep DESIGN.md authoritative and replace placeholders only with source-backed content.</p>
          </aside>
        </section>
      ASTRO
    end

    def section_card_component_profile_d
      <<~ASTRO
        ---
        const { title, items = [], aiwebId = 'component.section-card' } = Astro.props;
        ---

        <section class="mx-auto max-w-6xl px-6 py-10" data-aiweb-id={aiwebId}>
          <div class="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 class="text-2xl font-bold text-slate-950">{title}</h2>
            <ul class="mt-5 grid gap-3 text-slate-700 md:grid-cols-2">
              {items.map((item) => <li class="rounded-2xl bg-slate-50 p-4" data-aiweb-id={`${aiwebId}.item`}>{item}</li>)}
            </ul>
          </div>
        </section>
      ASTRO
    end

    def index_page_profile_d(context)
      <<~ASTRO
        ---
        import '../styles/global.css';
        import site from '../content/site.json';
        import Hero from '../components/Hero.astro';
        import SectionCard from '../components/SectionCard.astro';

        const title = site.title || #{context.fetch(:project_name).inspect};
        const description = site.description || 'Static site scaffold generated from AI Web Director artifacts.';
        ---

        <html lang="ko" data-aiweb-id="document.home">
          <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <meta name="description" content={description} />
            <title>{title}</title>
          </head>
          <body class="bg-[var(--color-paper,#fffaf3)]">
            <main data-aiweb-id="page.home">
              <Hero
                title={title}
                description={description}
                primaryInteraction={site.primary_interaction}
                selectedCandidate={site.selected_candidate}
              />
              <SectionCard title="First-view obligations" items={site.must_have_first_view || []} aiwebId="page.home.first-view-obligations" />
              <SectionCard title="Forbidden or excluded patterns" items={site.must_not_have || []} aiwebId="page.home.must-not-have" />
              <section class="mx-auto max-w-6xl px-6 py-10" data-aiweb-id="page.home.source-notes">
                <div class="rounded-3xl border border-dashed border-slate-300 bg-white/70 p-6">
                  <h2 class="text-2xl font-bold text-slate-950">Source notes</h2>
                  <p class="mt-4 text-sm leading-6 text-slate-600">Selected candidate: {site.selected_candidate || 'none'}</p>
                  <p class="mt-2 text-sm leading-6 text-slate-600">Policy: {site.content_policy}</p>
                </div>
              </section>
            </main>
          </body>
        </html>
      ASTRO
    end

    def stack_markdown(key, data)
      <<~MD
        # Stack Profile #{key} — #{data[:name]}

        ## Canonical default
        #{data[:name]}

        ## Scaffold target
        #{data[:scaffold_target]}

        ## Allowed override
        #{data[:override]}

        ## When to override
        Override only when Gate 1A records the reason, affected deployment/runtime tradeoffs, and rollback path.

        ## Implementation note
        `aiweb init --profile #{key}` records this scaffold target only. Actual app scaffold happens later through a Phase 6 task packet.
      MD
    end

    def deploy_markdown(key, data)
      <<~MD
        # Deploy Plan — Profile #{key}

        ## Baseline
        #{data[:deploy]}

        ## Predeploy requirements
        - Gate 4 predeploy approval must exist.
        - Rollback criteria must be defined before production action.
        - External deploy/provider actions require explicit human approval.

        ## Rollback
        - Keep local `.ai-web` snapshot before deploy.
        - Record deploy target and version/hash.
        - Record dry-run rollback result before release.
      MD
    end

    def classify_intent(idea)
      Archetypes.classify(idea)
    end

    def gate_markdown(title, scope, status)
      <<~MD
        # #{title}

        Status: #{status}
        Approved at:
        Approved by:

        ## Approval scope
        #{scope.map { |item| "- #{item}" }.join("\n")}

        ## Accepted risks
        - None yet.

        ## Artifact hashes
        - TODO: record approved artifact hashes before final approval.
      MD
    end


    def first_view_contract_markdown(intent, idea)
      <<~MD
        # First View Contract

        ## Source idea
        #{idea}

        ## Archetype
        #{intent["archetype"]}

        ## Surface
        #{intent["surface"]}

        ## Primary interaction above the fold
        #{intent["primary_interaction"]}

        ## Must be visible without scrolling
        #{bullet_list(intent["must_have_first_view"])}

        ## Must not be the first-screen experience
        #{bullet_list(intent["must_not_have"])}

        ## Mobile expectations
        - The primary interaction remains visible or reachable in the initial viewport.
        - Supporting panels stack below the core interaction without hiding the action.

        ## Desktop expectations
        - The primary interaction and supporting context are visible together.
        - Secondary marketing or explanatory content must not displace the core interface.
      MD
    end

    def project_markdown(idea, state, intent = Archetypes.classify(idea))
      <<~MD
        # Project

        ## Idea
        #{idea}

        ## Project ID
        #{state.dig("project", "id")}

        ## Detected archetype
        - Archetype: #{intent["archetype"]}
        - Surface: #{intent["surface"]}
        - Primary interaction: #{intent["primary_interaction"]}

        ## Interview questions still to answer
        - Who is the primary visitor?
        - What is the primary conversion goal?
        - What content is already available and what should AI draft?
        - Is login, payment, admin, or database scope required?
        - Which reference sites are liked/disliked?
      MD
    end

    def product_markdown(idea, intent = Archetypes.classify(idea))
      <<~MD
        # Product

        ## One-line concept
        #{idea}

        ## Detected archetype
        #{intent["archetype"]} (#{intent["surface"]})

        ## Target user
        The primary user implied by the idea should be served by the #{intent["surface"]} experience before secondary marketing content.

        ## Value proposition
        Provide a focused #{intent["archetype"]} experience whose first screen supports the core interaction: #{intent["primary_interaction"]}.

        ## Primary conversion / action
        #{intent["primary_interaction"]}.

        ## Wrong interpretations to avoid
        Do not turn this into a generic landing page or #{intent["not_surface"]} when the requested archetype requires #{intent["surface"]}.

        ## Release scope
        #{bullet_list(intent["must_have_first_view"].map { |item| "First-view requirement: #{item}" })}
        #{bullet_list(intent["must_not_have"].map { |item| "Excluded or blocked: #{item}" })}

        #{mocked_blocked_excluded_markdown(idea)}

        ## Success metrics
        - First-view contract is satisfied without scrolling on mobile and desktop.
        - Semantic QA passes for #{intent["archetype"]}.
      MD
    end

    def mocked_blocked_excluded_markdown(idea)
      if safety_sensitive_idea?(idea)
        <<~MD.chomp
          ## Mocked / blocked / excluded for safety
          - Mocked: external account data, third-party API responses, payments/orders, regulated decisions, or provider callbacks until approved integrations exist.
          - Locked/preview only: order, payment, or broker actions may show a review/confirmation preview, but must not execute a real order or provider-side transaction.
          - Blocked: credential collection, real account tokens, approval keys, payment capture, real order execution, production deploys, or irreversible provider actions without explicit human approval.
          - Excluded: medical, legal, financial, investment, or safety-critical advice presented as authoritative without source review, owner approval, and clear user-facing safety framing.
        MD
      else
        <<~MD.chomp
          ## Mocked / blocked / excluded for safety
          - Mocked: unavailable third-party data, provider callbacks, or external integrations until approved sources exist.
          - Locked/preview only: sensitive external actions may show a review/confirmation preview, but must not execute a real provider-side transaction.
          - Blocked: credential collection, payment capture, real order execution, production deploys, or irreversible external actions without explicit human approval.
          - Excluded: regulated or safety-critical claims that lack source review, owner approval, and clear user-facing safety framing.
        MD
      end
    end

    def safety_sensitive_idea?(idea)
      IntentRouter.sensitive?(idea)
    end

    def bullet_list(items)
      Array(items).map { |item| "- #{item}" }.join("\n")
    end

    def brand_markdown(idea)
      <<~MD
        # Brand

        ## Brand direction
        Draft brand direction for: #{idea}

        ## Tone
        - Clear
        - Trustworthy
        - Conversion-focused

        ## Visual mood
        TODO: define preferred colors, type mood, spacing density, and imagery.
      MD
    end

    def content_markdown(idea, intent = Archetypes.classify(idea))
      <<~MD
        # Content

        ## Content provenance
        Drafted by AI from the idea below until replaced by user-provided source material.

        ## Idea
        #{idea}

        ## First-view content outline
        #{bullet_list(intent["must_have_first_view"].map { |item| item.tr("_", " ").capitalize })}

        ## Supporting content outline
        - Context that explains the value proposition.
        - Proof, help, or trust cues appropriate for #{intent["archetype"]}.
        - Follow-up action that reinforces the primary interaction.

        ## SEO draft
        - Title: TODO
        - Description: TODO
      MD
    end

    def write_design_brief_if_needed(intent:, dry_run:, force:)
      path = File.join(aiweb_dir, "design-brief.md")
      return nil if !force && File.exist?(path) && !stub_file?(path)

      write_file(path, DesignBrief.new(intent).markdown, dry_run)
    end

    def design_system_resolver
      @design_system_resolver ||= DesignSystemResolver.new(root, aiweb_dir: aiweb_dir, templates_dir: templates_dir)
    end

    def design_candidate_generator(intent)
      design_path = File.join(aiweb_dir, "DESIGN.md")
      brief_path = File.join(aiweb_dir, "design-brief.md")
      DesignCandidateGenerator.new(
        root: root,
        aiweb_dir: aiweb_dir,
        intent: intent,
        design_markdown: File.exist?(design_path) ? File.read(design_path) : "",
        design_brief: File.exist?(brief_path) ? File.read(brief_path) : ""
      )
    end

    def design_candidate_html_paths
      DesignCandidateGenerator::CANDIDATE_IDS.map do |id|
        File.join(aiweb_dir, "design-candidates", "#{id}.html")
      end
    end

    def complete_design_candidate_artifacts?
      comparison_path = File.join(aiweb_dir, "design-candidates", "comparison.md")
      design_candidate_html_paths.all? { |path| complete_design_candidate_html?(path) } && complete_design_candidate_comparison?(comparison_path)
    end

    def complete_design_candidate_html?(path)
      return false unless File.file?(path)

      id = File.basename(path, ".html")
      html = File.read(path)
      !blank?(html) &&
        html.include?("<!-- aiweb:visual-contract:start #{id} -->") &&
        html.include?("<!-- aiweb:visual-contract:end #{id} -->")
    end

    def complete_design_candidate_comparison?(path)
      return false unless File.file?(path)

      markdown = File.read(path)
      return false if blank?(markdown)

      markdown.include?("Design Candidate Comparison") &&
        markdown.include?("| Candidate | Strategy | Score | First-view | Proof pattern | CTA flow | Mobile behavior | Risks |") &&
        %w[editorial-premium conversion-focused trust-minimal].all? { |strategy| markdown.include?(strategy) } &&
        DesignCandidateGenerator::CANDIDATE_IDS.all? { |id| markdown.include?("| #{id} |") }
    end

    def selected_candidate_id
      state = load_state_if_present
      selected = state&.dig("design_candidates", "selected_candidate")
      selected.to_s.strip.empty? ? nil : selected.to_s
    rescue Psych::SyntaxError
      nil
    end

    def write_design_system_if_needed(intent:, dry_run:, force:)
      return nil unless design_system_resolver.write_needed?(force: force)

      brief_path = File.join(aiweb_dir, "design-brief.md")
      design_brief = File.exist?(brief_path) ? File.read(brief_path) : DesignBrief.new(intent).markdown
      write_file(design_system_resolver.design_path, design_system_resolver.markdown(intent: intent, design_brief: design_brief), dry_run)
    end

    def design_prompt_markdown
      source_names = %w[product.md brand.md content.md ia.md design-brief.md DESIGN.md]
      source_names << "design-reference-brief.md" if design_reference_brief_present?
      inputs = source_names.map do |name|
        path = File.join(aiweb_dir, name)
        "## #{name}\n\n#{File.exist?(path) ? File.read(path) : "TODO: missing #{name}"}"
      end
      selected = selected_candidate_id
      if selected
        selected_path = File.join(aiweb_dir, "design-candidates", "selected.md")
        candidate_path = File.join(aiweb_dir, "design-candidates", "#{selected}.html")
        inputs << "## design-candidates/selected.md\n\n#{File.exist?(selected_path) ? File.read(selected_path) : "Selected candidate: #{selected}"}"
        inputs << "## design-candidates/#{selected}.html\n\n#{File.exist?(candidate_path) ? File.read(candidate_path) : "TODO: missing selected candidate HTML"}"
      end
      inputs = inputs.join("\n\n")
      selected_note = selected ? "Use selected candidate `#{selected}` as visual direction notes while keeping `.ai-web/DESIGN.md` authoritative." : "If deterministic candidates exist, select one with `aiweb select-design candidate-01|candidate-02|candidate-03` before implementation handoff."
      <<~MD
        # Design Prompt Handoff

        ## GPT Image 2 prompt
        Create one high-quality website design candidate based on the product, brand, content, IA, design brief, and `.ai-web/DESIGN.md` source of truth below. Produce a polished responsive homepage concept. Avoid logos or copyrighted brand marks. Emphasize layout, visual hierarchy, component style, typography mood, color system, spacing rhythm, and conversion clarity.

        ## Claude Design prompt
        Convert the selected visual direction into implementation-ready rules that preserve `.ai-web/DESIGN.md`: design tokens, typography scale, color palette, component recipes, layout constraints, `data-aiweb-id` hooks, and responsive behavior. Do not invent product scope beyond the approved artifacts. Preserve the product artifact's wrong-interpretations-to-avoid guidance when choosing first-screen layout and components. Use `.ai-web/design-reference-brief.md` only as pattern evidence when present; do not copy exact reference UI, copy, prices, trademarks, or signed image URLs. #{selected_note}

        ## Candidate evaluation rubric
        - Conversion clarity
        - Brand fit
        - Mobile-first usability
        - Accessibility risk
        - Implementation complexity
        - Token/component consistency

        ## Source artifacts
        #{inputs}
      MD
    end

    def design_candidate_markdown(id, title, source, notes)
      <<~MD
        # #{title}

        Candidate ID: #{id}
        Source: #{source.to_s.empty? ? "manual" : source}
        Created at: #{now}

        ## Visual summary
        #{notes.to_s.empty? ? "TODO: summarize image/design analysis." : notes}

        ## Token implications
        - Colors: TODO
        - Typography: TODO
        - Spacing: TODO
        - Components: TODO

        ## Risks
        - Accessibility: TODO
        - Implementation complexity: TODO
        - Content fit: TODO
      MD
    end

    def normalize_reference_type(value)
      text = value.to_s.strip.downcase
      text = "manual" if text.empty?
      aliases = {
        "gpt-image" => "gpt-image-2",
        "gpt_image_2" => "gpt-image-2",
        "reference-image" => "image",
        "url" => "remote",
        "lazyweb-reference" => "lazyweb"
      }
      normalized = aliases.fetch(text, text)
      allowed = %w[manual image gpt-image-2 remote lazyweb]
      raise UserError.new("ingest-reference --type must be one of: #{allowed.join(", ")}", 1) unless allowed.include?(normalized)

      normalized
    end

    def default_reference_title(reference_type)
      case reference_type
      when "gpt-image-2" then "GPT Image 2 reference notes"
      when "image" then "Reference image notes"
      when "remote" then "Remote reference notes"
      when "lazyweb" then "Lazyweb reference notes"
      else "Manual reference notes"
      end
    end

    def reference_ingestion_brief(existing_brief:, type:, title:, source:, notes:)
      base = existing_brief.to_s.strip
      lines = base.empty? ? ["# Design Reference Brief", "", "Provider: manual", "Generated at: #{now}"] : [base]
      lines.concat([
        "",
        "## Manually Ingested Reference Evidence",
        "",
        "### #{title}",
        "- Type: #{type}",
        "- Source: #{source.to_s.empty? ? "manual notes" : source}",
        "- Recorded at: #{now}",
        "",
        "#### Pattern Constraints",
        *reference_pattern_constraints(notes),
        "",
        "#### No-copy Guardrails",
        *reference_no_copy_guardrails.map { |guardrail| "- #{guardrail}" },
        "",
        "This reference is pattern evidence only. It is not implementation source and must not be routed directly to scaffold, source edits, copywriting, pricing, trademarks, or brand claims."
      ])
      lines.join("\n").rstrip + "\n"
    end

    def reference_pattern_constraints(notes)
      text = notes.to_s.strip
      return ["- Preserve approved product, brand, IA, and `.ai-web/DESIGN.md` constraints; no additional visual constraint was supplied."] if text.empty?

      text.lines.map(&:strip).reject(&:empty?).first(20).map do |line|
        normalized = line.sub(/\A[-*]\s*/, "")
        "- Interpret as pattern constraint: #{normalized}"
      end
    end

    def reference_no_copy_guardrails
      [
        "Borrow only abstract interaction, hierarchy, mood, spacing, composition, and accessibility patterns.",
        "Do not reproduce exact screenshot layout, visual asset, copy, prices, logos, trademarks, brand marks, signed URLs, or brand-specific claims.",
        "Do not treat GPT Image 2 output or reference images as source assets; convert them into design constraints before implementation.",
        "Implementation agents must use this brief as read-only pattern evidence and must not call external research tools during source edits."
      ]
    end

    def reject_reference_secret_path!(value, label)
      text = value.to_s.strip
      return if text.empty?

      reject_env_file_segment!(text, "ingest-reference refuses to read .env or .env.* #{label} paths")
      path_segments = text.split(/[\\\/]+/)
      if path_segments.any? { |part| part.match?(/\A(?:secrets?|credentials?|private[-_.]?keys?)(?:\.|\z|-|_)/i) }
        raise UserError.new("ingest-reference refuses to read secret-looking #{label} paths", 1)
      end
    end

    def design_comparison_markdown(state)
      rows = state.dig("design_candidates", "candidates").map do |candidate|
        "| #{candidate["id"]} | TODO | TODO | TODO | TODO |"
      end.join("\n")
      <<~MD
        # Design Candidate Comparison

        | Candidate | Brand fit | Conversion clarity | Accessibility risk | Complexity |
        |---|---|---|---|---|
        #{rows}

        ## Recommendation
        TODO: select the strongest candidate and explain tradeoffs.
      MD
    end

    def selected_design_markdown(selected_id, selected_ref: {}, refs: [])
      strategy = selected_ref["strategy_id"].to_s.empty? ? "unknown" : selected_ref["strategy_id"]
      score = selected_ref["score"] || "unscored"
      selected_strength = selected_ref["first_view"].to_s.empty? ? "the selected candidate artifact" : selected_ref["first_view"]
      selected_cta = selected_ref["cta_flow"].to_s.empty? ? "the approved primary action flow" : selected_ref["cta_flow"]
      selected_proof = selected_ref["proof_pattern"].to_s.empty? ? "source-backed proof placeholders" : selected_ref["proof_pattern"]
      rejected = Array(refs).reject { |candidate| candidate["id"] == selected_id }.map do |candidate|
        "- #{candidate["id"]}: #{candidate["strategy_id"] || "unknown strategy"} scored #{candidate["score"] || "unscored"}; tradeoff retained for comparison but not selected for this route."
      end
      rejected = ["- No rejected candidates were recorded; rerun `aiweb design --candidates 3 --force` if comparison evidence is missing."] if rejected.empty?
      <<~MD
        # Selected Design Candidate

        Selected candidate: #{selected_id}
        Selected candidate path: .ai-web/design-candidates/#{selected_id}.html
        Strategy: #{strategy}
        Score: #{score}
        Selected at: #{now}

        ## Decision
        Use `#{selected_id}` as the review-selected visual direction for prompt and task-packet handoff. It best balances #{selected_strength}, #{selected_cta}, and #{selected_proof}. DESIGN.md remains the source of truth; `.ai-web/DESIGN.md` remains authoritative for route, tokens, components, visual contract hooks, and implementation constraints.

        ## Why This Candidate
        - Strategy coverage: #{strategy}.
        - Rubric score: #{score}.
        - First-view fit: #{selected_strength}.
        - Proof pattern: #{selected_proof}.
        - CTA flow: #{selected_cta}.
        - Mobile behavior: #{selected_ref["mobile_behavior"] || "preserve approved responsive first-view behavior"}.

        ## Rejected Candidates
        #{rejected.join("\n")}

        ## Required Adjustments Before Code Generation
        - Keep `data-aiweb-id` hooks from the selected candidate or replace them with equally stable semantic IDs.
        - Replace placeholder-safe proof/content slots only with source-backed copy.
        - Resolve conflicts in favor of `.ai-web/DESIGN.md`; do not overwrite custom DESIGN.md from selection alone.
      MD
    end

    def task_packet_markdown(task_id, task_type, state)
      source_targets = agent_run_default_source_targets
      source_target_lines = source_targets.empty? ? "- TODO: add one safe source target before running agent-run." : source_targets.map { |path| "- `#{path}`" }.join("\n")
      machine_source_targets = source_targets.empty? ? "- TODO" : source_targets.map { |path| "- #{path}" }.join("\n")
      <<~MD
        # Task Packet — #{task_type}

        Task ID: #{task_id}
        Phase: #{state.dig("phase", "current")}
        Created at: #{now}

        ## Goal
        Complete the #{task_type} slice without expanding scope beyond approved artifacts.

        ## Inputs
        - `.ai-web/state.yaml`
        - `.ai-web/quality.yaml`
        - `.ai-web/intent.yaml`
        - `.ai-web/first-view-contract.md`
        - `.ai-web/product.md`
        - `.ai-web/content.md`
        - `.ai-web/DESIGN.md`
        #{design_reference_brief_present? ? "- `.ai-web/design-reference-brief.md` (read-only pattern evidence; do not call Lazyweb or copy exact reference UI/copy)" : "- `.ai-web/design-reference-brief.md` is optional and currently absent; do not call external design research during implementation."}
        #{selected_candidate_id ? "- `.ai-web/design-candidates/#{selected_candidate_id}.html` (selected visual direction; DESIGN.md remains authoritative)" : "- Select a design candidate before implementation if Gate 2 has not recorded one."}
        #{source_target_lines}

        ## Constraints
        - Do not read `.env` or `.env.*`.
        - Do not perform external deploy/provider actions without explicit approval.
        - Do not call external Lazyweb/design-research services from implementation tasks; use persisted markdown patterns only.
        - Do not copy exact reference screenshots, layouts, copy, prices, trademarks, or brand-specific claims.
        - Keep changes small and reversible.
        - Respect design tokens and component rules.
        - QA failures must create fix packets or rollback decisions.

        ## Machine Constraints
        shell_allowed: false
        network_allowed: false
        env_access_allowed: false
        requires_selected_design: true
        allowed_source_paths:
        #{machine_source_targets}

        ## Acceptance Criteria
        - The slice is implemented or clearly blocked.
        - Evidence paths are recorded.
        - Relevant QA checklist items are updated.

        ## Verification
        - Run local build/test/lint if available.
        - Run browser QA checklist for user-facing changes.
      MD
    end

    def design_reference_brief_present?
      path = File.join(aiweb_dir, "design-reference-brief.md")
      File.file?(path) && File.read(path).to_s.strip.length >= 40
    end

    def qa_checklist_markdown(state)
      semantic_checks = semantic_qa_checks(state)
      <<~MD
        # QA Checklist

        Phase: #{state.dig("phase", "current")}
        Generated at: #{now}

        ## Runtime guard
        - Stop a single QA run at #{state.dig("budget", "max_qa_runtime_minutes") || 60} minutes.
        - If timed out, create F-QA-TIMEOUT, capture logs/screenshots/state, diagnose cause, generate fix packet, rerun.

        ## Semantic checks
        #{semantic_qa_items(state)}

        ## Checks
        - [ ] Mobile viewport has no horizontal scroll.
        - [ ] Tablet and desktop layouts preserve hierarchy.
        - [ ] Keyboard navigation reaches all interactive controls.
        - [ ] Color contrast appears compliant or is flagged.
        - [ ] Title, description, canonical, and OG metadata exist when public.
        - [ ] Primary CTA appears above the fold.
        - [ ] Console/network errors are captured.
        - [ ] Screenshots/evidence paths are recorded.
        #{semantic_checks.empty? ? "" : "\n## Semantic intent checks\n#{semantic_checks.map { |check| "- [ ] #{check}" }.join("\n")}\n"}
      MD
    end

    def semantic_qa_items(state)
      intent = load_intent_artifact
      first_view_path = File.join(aiweb_dir, "first-view-contract.md")
      first_view_reference = File.exist?(first_view_path) ? "`.ai-web/first-view-contract.md`" : "missing `.ai-web/first-view-contract.md`"

      archetype = intent["archetype"].to_s
      surface = intent["surface"].to_s
      not_surface = intent["not_surface"].to_s
      primary_interaction = intent["primary_interaction"].to_s
      must_have = Array(intent["must_have_first_view"] || [])
      must_not = Array(intent["must_not_have"] || [])
      risks = Array(intent["semantic_risks"] || [])

      lines = []
      lines << "- [ ] Intent artifact (`.ai-web/intent.yaml`) is present and matches the built product experience."
      lines << "- [ ] First-view contract is present and referenced: #{first_view_reference}."
      lines << "- [ ] First viewport behaves as #{archetype.empty? ? "the detected archetype" : archetype}#{surface.empty? ? "" : " (#{surface})"}, not #{not_surface.empty? ? "the forbidden surface" : not_surface}."
      lines << "- [ ] Primary interaction is visible and testable: #{primary_interaction}." unless primary_interaction.empty?
      must_have.each do |item|
        lines << "- [ ] Required first-view element is visible: #{item.tr("_", " ")}."
      end
      must_not.each do |item|
        lines << "- [ ] Forbidden first-view or safety pattern is absent: #{item}."
      end
      risks.each do |risk|
        lines << "- [ ] Semantic risk is explicitly checked: #{risk}."
      end
      lines.join("\n")
    end

    def load_intent_artifact
      path = File.join(aiweb_dir, "intent.yaml")
      return Archetypes.classify("") unless File.exist?(path)
      return Archetypes.classify("") if stub_file?(path)

      intent = YAML.load_file(path) || {}
      return Archetypes.classify("") unless intent.is_a?(Hash)

      fallback = if intent["archetype"].to_s.empty? || intent["archetype"].to_s.start_with?("TODO")
                   Archetypes.classify("")
                 else
                   begin
                     Archetypes.definition(intent["archetype"]).merge("archetype" => intent["archetype"], "schema_version" => 1)
                   rescue KeyError
                     Archetypes.classify("")
                   end
                 end
      fallback.merge(intent.reject { |_key, value| value.nil? || (value.respond_to?(:empty?) && value.empty?) })
    rescue Psych::SyntaxError
      Archetypes.classify("")
    end

    def semantic_qa_checks(state)
      corpus = semantic_intent_corpus(state)
      checks = []
      checks.concat(stock_app_semantic_qa_checks) if stock_app_intent?(corpus)
      checks
    end

    def semantic_intent_corpus(state)
      artifact_paths = %w[project product content ia data security].map do |key|
        state.dig("artifacts", key, "path")
      end.compact
      default_paths = %w[
        .ai-web/intent.yaml
        .ai-web/first-view-contract.md
        .ai-web/project.md
        .ai-web/product.md
        .ai-web/content.md
        .ai-web/ia.md
        .ai-web/data.md
        .ai-web/security.md
      ]
      (artifact_paths + default_paths).uniq.map do |relative_path|
        next if env_file_segment?(relative_path)

        path = File.expand_path(relative_path.to_s, root)
        next unless path.start_with?(File.expand_path(root))
        next unless File.file?(path)

        File.read(path)
      end.compact.join("\n").downcase
    end

    def stock_app_intent?(corpus)
      stock_terms = [
        "stock", "stocks", "trading", "broker", "brokerage", "quote", "portfolio",
        "주식", "국내 주식", "투자", "증권", "종목", "호가", "포트폴리오"
      ]
      app_terms = [
        "assistant", "chat", "order", "account", "token", "approval", "console",
        "비서", "챗", "채팅", "주문", "계좌", "토큰", "승인", "앱"
      ]
      stock_terms.any? { |term| corpus.include?(term) } &&
        app_terms.any? { |term| corpus.include?(term) }
    end

    def stock_app_semantic_qa_checks
      [
        "The first screen presents an app interface for the stock assistant, not a marketing-only landing page.",
        "A stock question can be entered and produces visible user/assistant message states or mocked response states.",
        "Stock quote/status context is visible when the assistant references a symbol or market request.",
        "Any order-related action is limited to preview/confirmation UI and cannot submit a real broker order.",
        "Real account numbers, access tokens, approval keys, broker credentials, and live trading secrets are absent from UI, code, logs, fixtures, and evidence.",
        "The UI clearly states that real trading/account access is locked, unavailable, mocked, or sandbox-only until explicit human approval and credential setup."
      ]
    end

    def default_qa_result(status, task_id, duration_minutes, timed_out)
      started = Time.now.utc - ((duration_minutes || 0).to_f * 60)
      {
        "schema_version" => 1,
        "task_id" => task_id.to_s.empty? ? "manual-qa" : task_id.to_s,
        "status" => status,
        "started_at" => started.iso8601,
        "finished_at" => now,
        "duration_minutes" => (duration_minutes || 0).to_f,
        "timed_out" => timed_out == true,
        "environment" => {
          "url" => "http://localhost",
          "browser" => "codex_browser",
          "browser_version" => "unknown",
          "viewport" => { "width" => 1440, "height" => 900, "name" => "desktop" },
          "commit_sha" => "unknown",
          "server_command" => "unknown"
        },
        "checks" => [],
        "evidence" => [],
        "console_errors" => [],
        "network_errors" => [],
        "recommended_action" => status == "passed" ? "advance" : "create_fix_packet",
        "created_fix_task" => nil
      }
    end

    def normalize_qa_result!(result, state)
      result["schema_version"] ||= 1
      result["task_id"] = "manual-qa" if blank?(result["task_id"])
      result["started_at"] ||= now
      result["finished_at"] ||= now
      result["duration_minutes"] = result["duration_minutes"].to_f
      result["timed_out"] = !!result["timed_out"]
      result["environment"] ||= default_qa_result("pending", result["task_id"], 0, false)["environment"]
      result["checks"] ||= []
      result["evidence"] ||= []
      result["console_errors"] ||= []
      result["network_errors"] ||= []
      result["recommended_action"] ||= "none"
      result["created_fix_task"] = nil unless result.key?("created_fix_task")
      if result["duration_minutes"].to_f > (state.dig("budget", "max_qa_runtime_minutes") || 60).to_f
        result["timed_out"] = true
      end
    end

    def qa_timeout?(result, state)
      result["timed_out"] == true || result["duration_minutes"].to_f > (state.dig("budget", "max_qa_runtime_minutes") || 60).to_f
    end

    def enforce_qa_timeout_recovery_budget!(state, result)
      return unless qa_timeout?(result, state)

      max_cycles = (state.dig("budget", "max_qa_timeout_recovery_cycles") || 3).to_i
      task_id = result["task_id"].to_s
      used = qa_timeout_recovery_cycles_used(state, task_id)
      return if used < max_cycles

      raise UserError.new(
        "QA timeout recovery budget exceeded for task #{task_id.inspect}: #{used}/#{max_cycles} F-QA-TIMEOUT cycles already recorded",
        3
      )
    end

    def qa_timeout_recovery_cycles_used(state, task_id)
      (state.dig("qa", "open_failures") || []).count do |failure|
        next false unless failure["check_id"] == "F-QA-TIMEOUT"

        failure_task = failure["task_id"]
        failure_task.nil? || failure_task.to_s == task_id.to_s
      end
    end

    def qa_failures_from_result(result, state, source_result)
      failures = []
      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      blocking_severities = %w[critical high medium]
      (result["checks"] || []).each_with_index do |check, index|
        next unless %w[failed blocked].include?(check["status"])
        next unless blocking_severities.include?(check["severity"])
        next unless blank?(check["accepted_risk_id"])
        check_id = check["id"].to_s.empty? ? "check-#{index + 1}" : check["id"]
        failures << {
          "id" => "F-QA-#{timestamp}-#{slug(check_id)}",
          "source_result" => source_result,
          "check_id" => check_id,
          "task_id" => result["task_id"],
          "severity" => check["severity"],
          "blocking" => true,
          "accepted_risk_id" => nil
        }
      end

      if qa_timeout?(result, state)
        failures << {
          "id" => "F-QA-TIMEOUT-#{timestamp}",
          "source_result" => source_result,
          "check_id" => "F-QA-TIMEOUT",
          "task_id" => result["task_id"],
          "severity" => "high",
          "blocking" => true,
          "accepted_risk_id" => nil
        }
      elsif result["status"] != "passed" && failures.empty?
        failures << {
          "id" => "F-QA-#{timestamp}-status",
          "source_result" => source_result,
          "check_id" => "QA-STATUS-#{result["status"].upcase}",
          "task_id" => result["task_id"],
          "severity" => "medium",
          "blocking" => true,
          "accepted_risk_id" => nil
        }
      end

      failures
    end

    def qa_fix_task_markdown(failures, result, state)
      primary = failures.first
      source_targets = agent_run_default_source_targets
      source_target_lines = source_targets.empty? ? "- TODO: add one safe source target before running agent-run." : source_targets.map { |path| "- `#{path}`" }.join("\n")
      machine_source_targets = source_targets.empty? ? "- TODO" : source_targets.map { |path| "- #{path}" }.join("\n")
      timeout = failures.any? { |failure| failure["check_id"] == "F-QA-TIMEOUT" }
      timeout_steps = if timeout
        <<~TXT
          ## Timeout recovery loop
          1. Capture logs, screenshots, current state, server/build output.
          2. Classify cause: server start, missing precondition, selector/wait, infinite loading/network stall, runtime/build error, oversized checklist, adapter/browser failure.
          3. Apply smallest fix.
          4. Rerun QA within #{state.dig("budget", "max_qa_runtime_minutes") || 60} minutes.
          5. Repeat up to #{state.dig("budget", "max_qa_timeout_recovery_cycles") || 3} timeout recovery cycles, then escalate blocker.
        TXT
      else
        ""
      end
      failure_list = failures.map do |failure|
        "- #{failure["id"]}: #{failure["check_id"]} (#{failure["severity"]})"
      end.join("\n")
      <<~MD
        # Task Packet — qa-fix

        Task ID: fix-#{primary["id"]}
        QA result: #{primary["source_result"]}
        Created at: #{now}

        ## Goal
        Fix the QA failure with the smallest local source patch.

        ## Inputs
        - `.ai-web/state.yaml`
        - `.ai-web/DESIGN.md`
        - `.ai-web/component-map.json`
        - `#{primary["source_result"]}`
        #{source_target_lines}

        ## Constraints
        - Do not read `.env` or `.env.*`.
        - Patch only the allowed source paths listed below.
        - Do not run package installs, deploys, provider CLIs, or network calls from agent-run.
        - Keep changes minimal and reversible.

        ## Machine Constraints
        shell_allowed: false
        network_allowed: false
        env_access_allowed: false
        requires_selected_design: true
        allowed_source_paths:
        #{machine_source_targets}

        ## Open failures
        #{failure_list}

        #{timeout_steps}
        ## Acceptance Criteria
        - Root cause is identified and documented.
        - Fix is minimal and scoped to the failed checks.
        - QA report is rerun and linked.

        ## Raw status
        #{result["status"]}
      MD
    end

    def resolve_visual_polish_critique_source(from_critique, state)
      requested = from_critique.to_s.strip
      requested = "latest" if requested.empty?
      if requested == "latest"
        latest = state.dig("visual", "latest_critique").to_s.strip
        latest = state.dig("qa", "latest_visual_critique").to_s.strip if latest.empty?
        latest = latest_visual_critique_artifact if latest.empty?
        return { "relative" => nil, "path" => nil, "reason" => "no .ai-web visual critique artifact is available" } if latest.to_s.empty?

        reject_visual_polish_env_path!(latest)
        path = File.expand_path(latest, root)
        return { "relative" => latest, "path" => nil, "reason" => "visual critique #{latest} is missing" } unless File.file?(path)

        return { "relative" => relative(path), "path" => path }
      end

      reject_visual_polish_env_path!(requested)
      path = File.expand_path(requested, root)
      unless File.file?(path)
        raise UserError.new("visual critique #{requested.inspect} does not exist", 1)
      end
      unless File.extname(path) == ".json"
        raise UserError.new("visual-polish --from-critique requires a visual critique JSON path", 1)
      end

      { "relative" => relative(path), "path" => path }
    end

    def latest_visual_critique_artifact
      Dir.glob(File.join(aiweb_dir, "visual", "visual-critique-*.json")).max_by { |path| File.mtime(path) }
    rescue SystemCallError
      nil
    end

    def reject_visual_polish_env_path!(path)
      reject_env_file_segment!(path, "visual-polish refuses to read .env or .env.* critique paths")
    end

    def load_visual_polish_critique(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise UserError.new("cannot parse visual critique JSON: #{e.message}", 1)
    rescue SystemCallError => e
      raise UserError.new("cannot read visual critique JSON: #{e.message}", 1)
    end

    def validate_visual_polish_critique!(critique)
      unless critique.is_a?(Hash)
        raise UserError.new("visual critique JSON must be an object", 1)
      end
      errors = []
      errors << "schema_version must be 1" unless critique["schema_version"] == 1
      errors << "type must be visual_critique" unless critique["type"].to_s == "visual_critique"
      errors << "id is required" if critique["id"].to_s.strip.empty?
      errors << "status is required" if critique["status"].to_s.strip.empty?
      errors << "approval is required" if critique["approval"].to_s.strip.empty?
      errors << "evidence must be an array" unless critique["evidence"].is_a?(Array)
      raise UserError.new("visual critique JSON is malformed: #{errors.join("; ")}", 1) unless errors.empty?

      true
    end

    def visual_polish_critique_passed?(critique)
      approval = critique["approval"].to_s.downcase
      status = critique["status"].to_s.downcase
      approval == "pass" || status == "pass" || status == "passed"
    end

    def visual_polish_cycle_limit(max_cycles, state)
      value = max_cycles.nil? || max_cycles.to_s.strip.empty? ? nil : max_cycles.to_i
      value ||= (state.dig("budget", "max_visual_polish_cycles") || state.dig("budget", "max_repair_cycles") || 3).to_i
      value.positive? ? value : 1
    end

    def visual_polish_cycles_used(source_critique)
      Dir.glob(File.join(aiweb_dir, "visual", "polish-*.json")).count do |path|
        data = JSON.parse(File.read(path))
        data["source_critique"].to_s == source_critique.to_s
      rescue JSON::ParserError, SystemCallError
        false
      end
    end

    def visual_polish_task_path(critique)
      source = critique["artifact"].to_s.strip
      source = critique["artifact_path"].to_s.strip if source.empty?
      source = critique["id"].to_s.strip if source.empty?
      digest = Digest::SHA256.hexdigest(source)[0, 12]
      File.join(aiweb_dir, "tasks", "visual-polish-#{digest}.md")
    end

    def visual_polish_snapshot_manifest(snapshot_id, critique, source_critique, state)
      {
        "id" => snapshot_id,
        "created_at" => now,
        "reason" => "pre-polish snapshot for visual critique #{critique["id"] || source_critique}",
        "phase" => state.dig("phase", "current"),
        "source_critique" => source_critique,
        "state_sha256" => File.exist?(state_path) ? Digest::SHA256.file(state_path).hexdigest : nil
      }
    end

    def visual_polish_record(polish_id:, critique:, source_critique:, snapshot_dir:, task_path:, cycles_used:, max_cycles:, dry_run:, polish_record_path:)
      {
        "schema_version" => 1,
        "type" => "visual_polish",
        "id" => polish_id,
        "status" => dry_run ? "planned" : "created",
        "dry_run" => dry_run,
        "created_at" => now,
        "source_critique" => source_critique,
        "polish_record" => relative(polish_record_path),
        "critique_id" => critique["id"],
        "critique_task_id" => critique["task_id"],
        "critique_status" => critique["status"],
        "critique_approval" => critique["approval"],
        "issues" => critique["issues"] || [],
        "patch_plan" => critique["patch_plan"] || [],
        "design_contract" => critique["design_contract"] || design_contract_context,
        "cycles_used_before" => cycles_used,
        "max_cycles" => max_cycles,
        "pre_polish_snapshot" => relative(snapshot_dir),
        "polish_task" => relative(task_path),
        "guardrails" => [
          "no .env read/write",
          "no exact reference/image/screenshot copying",
          "no source auto-patch",
          "no build execution",
          "no preview/browser/screenshot capture",
          "no QA execution",
          "no package install",
          "no deploy/external hosting",
          "no network/AI calls"
        ]
      }
    end

    def visual_polish_task_markdown(record, critique)
      source_targets = agent_run_default_source_targets
      source_target_lines = source_targets.empty? ? "- TODO: map critique to a safe source target before running agent-run." : source_targets.map { |path| "- `#{path}`" }.join("\n")
      machine_source_targets = source_targets.empty? ? "- TODO" : source_targets.map { |path| "- #{path}" }.join("\n")
      issues = Array(critique["issues"]).map { |issue| "- #{issue}" }.join("\n")
      issues = "- Review #{record["source_critique"]} for non-pass visual critique details." if issues.empty?
      patch_plan = Array(critique["patch_plan"]).map do |item|
        if item.is_a?(Hash)
          "- #{item["area"] || "visual"} (#{item["priority"] || "medium"}): #{item["action"]}"
        else
          "- #{item}"
        end
      end.join("\n")
      patch_plan = "- Make bounded local visual polish edits based on critique evidence." if patch_plan.empty?
      design_contract = visual_polish_design_contract_markdown(record["design_contract"] || critique["design_contract"] || {})

      <<~MD
        # Task Packet — visual-polish

        Task ID: #{record["id"]}
        Phase: visual-polish
        Source critique: #{record["source_critique"]}
        Pre-polish snapshot: #{record["pre_polish_snapshot"]}
        Created at: #{record["created_at"]}
        #{design_contract}

        ## Goal
        Repair or redesign the local visual issues identified by the source critique without expanding scope.

        ## Inputs
        - `.ai-web/state.yaml`
        - `.ai-web/DESIGN.md`
        - `.ai-web/component-map.json`
        - `#{record["source_critique"]}`
        #{source_target_lines}

        ## Issues
        #{issues}

        ## Patch Plan
        #{patch_plan}

        ## Guardrails
        - Do not edit `.env` or `.env.*`.
        - Do not copy exact reference screenshots, layouts, copy, prices, trademarks, or brand claims.
        - Do not run builds, previews, browsers, screenshot capture, package installs, deploys, network calls, or AI calls from the polish loop.
        - Keep source changes manual, reviewable, and verified outside this record-creation command.

        ## Constraints
        - Do not read `.env` or `.env.*`.
        - Patch only the allowed source paths listed below.
        - Keep source changes minimal and reversible.

        ## Machine Constraints
        shell_allowed: false
        network_allowed: false
        env_access_allowed: false
        requires_selected_design: true
        allowed_source_paths:
        #{machine_source_targets}

        ## Acceptance Criteria
        - Visual issues are addressed in local source by a human/agent in a separate implementation step.
        - Visual critique is rerun manually and linked in `.ai-web/visual/`.
      MD
    end

    def visual_polish_design_contract_markdown(contract)
      return "" unless contract.is_a?(Hash) && !contract.empty?

      lines = ["", "## Design Contract Context"]
      lines << "- DESIGN.md: #{contract["design_path"]}" if contract["design_path"]
      lines << "- Design SHA256: #{contract["design_sha256"]}" if contract["design_sha256"]
      lines << "- Reference brief: #{contract["reference_brief_path"]}" if contract["reference_brief_path"]
      lines << "- Selected candidate: #{contract["selected_candidate"]}" if contract["selected_candidate"]
      lines << "- Selected candidate path: #{contract["selected_candidate_path"]}" if contract["selected_candidate_path"]
      lines.join("\n")
    end

    def visual_polish_blocked_payload(state:, source_critique:, reason:, dry_run:, critique: nil, cycles_used: nil, max_cycles: nil, block_type: nil)
      polish_loop = {
        "schema_version" => 1,
        "status" => "blocked",
        "dry_run" => dry_run,
        "source_critique" => source_critique,
        "critique_id" => critique && critique["id"],
        "critique_status" => critique && critique["status"],
        "critique_approval" => critique && critique["approval"],
        "cycles_used" => cycles_used,
        "max_cycles" => max_cycles,
        "blocking_issues" => [reason],
        "block_type" => block_type,
        "planned_changes" => []
      }.compact

      status_hash(state: state, changed_files: []).merge(
        "action_taken" => "visual polish repair loop blocked",
        "changed_files" => [],
        "blocking_issues" => [reason],
        "visual_polish" => polish_loop,
        "next_action" => "record a repair, redesign, failed, or non-pass visual critique before running aiweb visual-polish --repair"
      )
    end

    def visual_polish_payload(state:, record:, changed_files:, planned_changes:, action_taken:, next_action:)
      payload = status_hash(state: state, changed_files: changed_files)
      payload["action_taken"] = action_taken
      polish_loop = record.merge(
        "planned_changes" => planned_changes,
        "changed_files" => changed_files
      )
      unless planned_changes.empty?
        polish_loop["planned_snapshot_path"] = record["pre_polish_snapshot"]
        polish_loop["planned_polish_record_path"] = record["polish_record"]
        polish_loop["planned_task_path"] = record["polish_task"]
        polish_loop["planned_polish_task_path"] = record["polish_task"]
      end
      payload["visual_polish"] = polish_loop
      payload["next_action"] = next_action
      payload
    end

    def resolve_repair_qa_source(from_qa, state)
      requested = from_qa.to_s.strip
      requested = "latest" if requested.empty?
      if requested == "latest"
        latest = state.dig("qa", "last_result").to_s.strip
        return { "relative" => nil, "path" => nil, "reason" => "state.qa.last_result is empty" } if latest.empty?

        reject_env_path!(latest)
        path = File.expand_path(latest, root)
        return { "relative" => latest, "path" => nil, "reason" => "QA result #{latest} is missing" } unless File.file?(path)

        return { "relative" => latest, "path" => path }
      end

      reject_env_path!(requested)
      path = File.expand_path(requested, root)
      unless File.file?(path)
        raise UserError.new("QA result #{requested.inspect} does not exist", 1)
      end
      unless File.extname(path) == ".json"
        raise UserError.new("repair --from-qa requires a QA result JSON path", 1)
      end

      { "relative" => relative(path), "path" => path }
    end

    def reject_env_path!(path)
      reject_env_file_segment!(path, "refusing to read .env path for repair input")
    end


    def reject_env_file_segment!(path, message)
      raise UserError.new(message, 1) if env_file_segment?(path)
    end

    def env_file_segment?(path)
      path.to_s.split(/[\\\/]+/).any? { |part| part == ".env" || part.start_with?(".env.") }
    end

    def load_repair_qa_result(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise UserError.new("cannot parse QA result JSON: #{e.message}", 1)
    rescue SystemCallError => e
      raise UserError.new("cannot read QA result JSON: #{e.message}", 1)
    end

    def repair_cycle_limit(max_cycles, state)
      value = max_cycles.nil? || max_cycles.to_s.strip.empty? ? nil : max_cycles.to_i
      value ||= (state.dig("budget", "max_repair_cycles") || state.dig("budget", "max_qa_timeout_recovery_cycles") || 3).to_i
      value.positive? ? value : 1
    end

    def repair_cycles_used(task_id, source_result)
      Dir.glob(File.join(aiweb_dir, "repairs", "repair-*.json")).count do |path|
        data = JSON.parse(File.read(path))
        data["qa_task_id"].to_s == task_id.to_s && data["source_result"].to_s == source_result.to_s
      rescue JSON::ParserError, SystemCallError
        false
      end
    end

    def repair_fix_task_path(result, primary_failure)
      existing = result["created_fix_task"].to_s.strip
      path = if existing.empty?
        File.join(aiweb_dir, "tasks", "fix-#{primary_failure["id"]}.md")
      else
        reject_env_path!(existing)
        File.expand_path(existing, root)
      end
      ensure_repair_task_path!(path)
      path
    end

    def ensure_repair_task_path!(path)
      expanded = File.expand_path(path)
      tasks_dir = File.expand_path(File.join(aiweb_dir, "tasks"))
      return if expanded.start_with?(tasks_dir + File::SEPARATOR) && File.extname(expanded) == ".md"

      raise UserError.new("repair fix task must stay under .ai-web/tasks as markdown", 1)
    end

    def merge_open_failures!(state, failures)
      existing_ids = state["qa"]["open_failures"].map { |failure| failure["id"] }
      failures.each do |failure|
        next if existing_ids.include?(failure["id"])

        state["qa"]["open_failures"] << failure
      end
    end

    def repair_snapshot_manifest(snapshot_id, result, source_result, state)
      {
        "id" => snapshot_id,
        "created_at" => now,
        "reason" => "pre-repair snapshot for QA task #{result["task_id"]}",
        "phase" => state.dig("phase", "current"),
        "source_result" => source_result,
        "state_sha256" => File.exist?(state_path) ? Digest::SHA256.file(state_path).hexdigest : nil
      }
    end

    def copy_repair_snapshot_contents(snapshot_dir)
      Dir.children(aiweb_dir).each do |entry|
        next if entry == "snapshots" || entry == ".lock"
        next if entry == ".env" || entry.start_with?(".env.")

        src = File.join(aiweb_dir, entry)
        dest = File.join(snapshot_dir, entry)
        if File.directory?(src)
          FileUtils.cp_r(src, dest, remove_destination: true)
        else
          FileUtils.cp(src, dest)
        end
      end
    end

    def repair_record(repair_id:, result:, source_result:, failures:, snapshot_dir:, fix_path:, cycles_used:, max_cycles:, dry_run:, repair_record_path:)
      {
        "schema_version" => 1,
        "id" => repair_id,
        "status" => dry_run ? "planned" : "created",
        "dry_run" => dry_run,
        "created_at" => now,
        "source_result" => source_result,
        "repair_record" => relative(repair_record_path),
        "qa_task_id" => result["task_id"],
        "qa_status" => result["status"],
        "timed_out" => result["timed_out"] == true,
        "failures" => failures,
        "cycles_used_before" => cycles_used,
        "max_cycles" => max_cycles,
        "pre_repair_snapshot" => relative(snapshot_dir),
        "fix_task" => relative(fix_path),
        "guardrails" => [
          "no .env read/write",
          "no source auto-patch",
          "no build execution",
          "no QA execution",
          "no install/preview/deploy/external hosting",
          "no visual polish/edit/backend/GitHub/deploy work"
        ]
      }
    end

    def repair_blocked_payload(state:, source_result:, reason:, dry_run:, qa_result: nil, cycles_used: nil, max_cycles: nil, block_type: nil)
      repair_loop = {
        "schema_version" => 1,
        "status" => "blocked",
        "dry_run" => dry_run,
        "source_result" => source_result,
        "qa_task_id" => qa_result && qa_result["task_id"],
        "qa_status" => qa_result && qa_result["status"],
        "cycles_used" => cycles_used,
        "max_cycles" => max_cycles,
        "blocking_issues" => [reason],
        "block_type" => block_type,
        "planned_changes" => []
      }.compact

      status_hash(state: state, changed_files: []).merge(
        "action_taken" => "repair loop blocked",
        "changed_files" => [],
        "blocking_issues" => [reason],
        "repair_loop" => repair_loop,
        "next_action" => "record a failed or blocked QA result before running aiweb repair"
      )
    end

    def repair_payload(state:, record:, changed_files:, planned_changes:, action_taken:, next_action:)
      payload = status_hash(state: state, changed_files: changed_files)
      payload["action_taken"] = action_taken
      repair_loop = record.merge(
        "planned_changes" => planned_changes,
        "changed_files" => changed_files
      )
      unless planned_changes.empty?
        repair_loop["planned_snapshot_path"] = record["pre_repair_snapshot"]
        repair_loop["planned_repair_record_path"] = record["repair_record"]
        repair_loop["planned_fix_task_path"] = record["fix_task"]
      end
      payload["repair_loop"] = repair_loop
      payload["next_action"] = next_action
      payload
    end

    def final_qa_report_markdown(state, result, failures)
      <<~MD
        # Final QA Report

        Generated at: #{now}
        Phase: #{state.dig("phase", "current")}
        Last result: #{state.dig("qa", "last_result")}
        Status: #{result["status"]}
        Duration minutes: #{result["duration_minutes"]}
        Timed out: #{result["timed_out"]}

        ## Open failures from this result
        #{failures.empty? ? "- None" : failures.map { |failure| "- #{failure["id"]}: #{failure["check_id"]} (#{failure["severity"]})" }.join("\n")}

        ## Evidence
        #{(result["evidence"] || []).empty? ? "- None recorded" : result["evidence"].map { |item| "- #{item}" }.join("\n")}

        ## Release readiness
        #{failures.empty? ? "Ready for Gate 4 review if all other predeploy artifacts are approved." : "Not ready. Resolve open failures before Gate 4 approval."}
      MD
    end

    def rollback_markdown(invalidation)
      <<~MD
        # Rollback Decision — #{invalidation["id"]}

        Failure: #{invalidation["failure"] || "manual"}
        From phase: #{invalidation["from_phase"]}
        To phase: #{invalidation["to_phase"]}
        Created at: #{invalidation["created_at"]}

        ## Reason
        #{invalidation["reason"]}

        ## Affected tasks
        #{invalidation["affected_tasks"].map { |task| "- #{task}" }.join("\n")}
      MD
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

    def load_json_file(path)
      reject_env_file_segment!(path, "refusing to read .env or .env.* JSON path")

      JSON.parse(File.read(File.expand_path(path, root)))
    rescue JSON::ParserError => e
      raise UserError.new("cannot parse JSON #{path}: #{e.message}", 1)
    end

    def component_map_source_paths
      candidates = SCAFFOLD_PROFILE_D_REQUIRED_FILES.grep(%r{\Asrc/})
      candidates.select do |relative_path|
        path = File.join(root, relative_path)
        File.file?(path) && safe_component_map_scan_path?(relative_path)
      end
    end

    def safe_component_map_scan_path?(relative_path)
      normalized = relative_path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
      parts = normalized.split("/")

      return false if normalized.empty? || normalized.start_with?("/")
      return false if parts.any? { |part| part == ".." || part.start_with?(".env") }
      return false if parts.any? { |part| %w[node_modules dist build coverage tmp vendor .git].include?(part) }

      normalized.start_with?("src/")
    end

    def discover_component_map_components
      component_map_source_paths.flat_map do |relative_path|
        path = File.join(root, relative_path)
        discover_component_map_components_in_file(path, relative_path)
      end.sort_by { |component| [component["source_path"].to_s, component["line"].to_i, component["data_aiweb_id"].to_s] }
    end

    def discover_component_map_components_in_file(path, relative_path)
      body = File.read(path)
      components = []
      body.lines.each_with_index do |line, index|
        line.scan(/data-aiweb-id\s*=\s*["']([^"']+)["']/) do |match|
          components << component_map_component_record(match.first, relative_path, line, index + 1, "data-aiweb-id")
        end
        line.scan(/\baiwebId\s*=\s*["']([^"']+)["']/) do |match|
          components << component_map_component_record(match.first, relative_path, line, index + 1, "aiwebId-prop")
        end
      end
      components.uniq { |component| [component["data_aiweb_id"], component["source_path"], component["line"]] }
    rescue SystemCallError
      []
    end

    def component_map_component_record(data_aiweb_id, relative_path, line, line_number, source_hook)
      {
        "data_aiweb_id" => data_aiweb_id.to_s,
        "source_path" => relative_path,
        "kind" => component_map_kind(relative_path, data_aiweb_id),
        "route" => component_map_route(relative_path, data_aiweb_id),
        "editable" => true,
        "line" => line_number,
        "source_hook" => source_hook,
        "snippet_summary" => component_map_snippet_summary(line)
      }
    end

    def component_map_kind(relative_path, data_aiweb_id)
      return "page" if relative_path.start_with?("src/pages/") || data_aiweb_id.to_s.start_with?("page.", "document.")
      return "component" if relative_path.start_with?("src/components/") || data_aiweb_id.to_s.start_with?("component.")

      "region"
    end

    def component_map_route(relative_path, data_aiweb_id)
      return "/" if relative_path == "src/pages/index.astro" || data_aiweb_id.to_s.include?(".home")
      if relative_path.start_with?("src/pages/")
        page = relative_path.sub(%r{\Asrc/pages/}, "").sub(/\.astro\z/, "")
        return "/" if page == "index"

        return "/#{page.sub(%r{/index\z}, "")}"
      end

      nil
    end

    def component_map_snippet_summary(line)
      tag = line.to_s[/<\s*([A-Za-z][A-Za-z0-9:-]*)/, 1]
      classes = line.to_s[/class\s*=\s*"([^"]{0,80})"/, 1] || line.to_s[/class\s*=\s*'([^']{0,80})'/, 1]
      [tag ? "tag=#{tag}" : nil, classes ? "class=#{classes}" : nil].compact.join("; ")
    end

    def component_map_blockers(components, force:)
      missing = SCAFFOLD_PROFILE_D_REQUIRED_FILES.grep(%r{\Asrc/}).reject { |path| File.file?(File.join(root, path)) }
      blockers = []
      blockers << "scaffold/source files are missing: #{missing.join(", ")}" unless missing.empty?
      blockers << "no stable data-aiweb-id hooks found in scaffold/source files" if components.empty?
      blockers
    end

    def component_map_record(status:, artifact_path:, components:, blockers:, dry_run:)
      {
        "schema_version" => 1,
        "status" => status,
        "artifact_path" => relative(artifact_path),
        "generated_at" => dry_run ? nil : now,
        "dry_run" => dry_run,
        "source_root" => ".",
        "scan" => {
          "included_paths" => component_map_source_paths,
          "excluded_patterns" => [".env", ".env.*", "node_modules", "dist", "build", "coverage", "tmp", "vendor/bundle"],
          "source_contents_embedded" => false
        },
        "components" => components,
        "blocking_issues" => blockers
      }
    end

    def component_map_payload(state:, component_map:, changed_files:, planned_changes:, action_taken:, blocking_issues:, next_action:)
      payload = status_hash(state: state, changed_files: changed_files)
      payload["action_taken"] = action_taken
      payload["blocking_issues"] = blocking_issues
      payload["planned_changes"] = planned_changes unless planned_changes.empty?
      payload["component_map"] = component_map
      payload["next_action"] = next_action
      payload
    end

    def resolve_component_map_source(from_map)
      raw = from_map.to_s.strip
      raw = "latest" if raw.empty?
      return { "path" => File.join(aiweb_dir, "component-map.json"), "relative" => ".ai-web/component-map.json", "error" => nil } if raw == "latest"

      normalized = raw.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
      parts = normalized.split("/")
      error = if raw.match?(/\A[a-z][a-z0-9+.-]*:\/\//i) || raw.start_with?("/") || raw.match?(%r{\A[A-Za-z]:[\\/]})
                "component map path must be a local project-relative path"
              elsif parts.any? { |part| part == ".." }
                "component map path must not contain traversal"
              elsif parts.any? { |part| part.start_with?(".env") }
                "component map path must not reference .env files"
              elsif !normalized.start_with?(".ai-web/")
                "component map path must stay under .ai-web"
              end
      return { "path" => nil, "relative" => normalized, "error" => error } if error

      { "path" => File.join(root, normalized), "relative" => normalized, "error" => nil }
    end

    def load_component_map_for_visual_edit(path)
      data = JSON.parse(File.read(path))
      raise UserError.new("component map must be a JSON object", 1) unless data.is_a?(Hash)

      data
    rescue Errno::ENOENT
      nil
    rescue JSON::ParserError => e
      raise UserError.new("cannot parse component map: #{e.message}", 1)
    end

    def component_map_component(component_map, target)
      matches = component_map_components(component_map, target)
      matches.length == 1 ? matches.first : nil
    end

    def component_map_components(component_map, target)
      Array(component_map["components"]).select { |component| component.is_a?(Hash) && component["data_aiweb_id"].to_s == target }
    end

    def visual_edit_blockers(source, component_map, component, target, components:, force:)
      blockers = []
      blockers << source["error"] if source["error"]
      return blockers unless source["error"].nil?

      blockers << "component map not found: #{source["relative"]}" unless component_map
      blockers << "target data-aiweb-id not found in component map: #{target}" if component_map && components.empty?
      blockers << "target data-aiweb-id is ambiguous in component map: #{target}" if component_map && components.length > 1
      blockers << "target data-aiweb-id is not editable: #{target}" if component && component["editable"] == false
      if component
        source_path = agent_run_normalized_relative_path(component["source_path"])
        if source_path.empty?
          blockers << "target component source path is missing for data-aiweb-id: #{target}"
        elsif !agent_run_source_path_allowed?(source_path)
          blockers << "target component source path is unsafe or not editable: #{source_path}"
        end
      end
      blockers
    end

    def visual_edit_record(edit_id:, target:, prompt:, source_map:, component:, task_path:, record_path:, status:, blockers:, dry_run:)
      record = {
        "schema_version" => 1,
        "id" => edit_id,
        "status" => status,
        "created_at" => dry_run ? nil : now,
        "dry_run" => dry_run,
        "source_map" => source_map,
        "target" => {
          "data_aiweb_id" => target,
          "source_path" => component && component["source_path"],
          "line" => component && component["line"],
          "kind" => component && component["kind"],
          "route" => component && component["route"],
          "editable" => component ? component["editable"] : nil
        },
        "target_allowlist" => visual_edit_target_allowlist(target, source_map, component),
        "prompt_summary" => visual_edit_prompt_summary(prompt),
        "prompt_sha256" => Digest::SHA256.hexdigest(prompt),
        "guardrails" => [
          "Target only the selected region identified by data-aiweb-id.",
          "Strict source allowlist: patch only the mapped target source path.",
          "Do not regenerate the full page or unrelated components.",
          "No source auto-patch from this visual-edit command.",
          "Run smoke QA before any later source edit is accepted.",
          "Do not read or include .env or .env.* contents."
        ],
        "task_path" => relative(task_path),
        "record_path" => relative(record_path),
        "blocking_issues" => blockers
      }
      if dry_run
        record["planned_task_path"] = record["task_path"]
        record["planned_record_path"] = record["record_path"]
      end
      record
    end

    def visual_edit_target_allowlist(target, source_map, component)
      source_paths = [component && component["source_path"]].compact.map { |path| agent_run_normalized_relative_path(path) }.reject(&:empty?)
      {
        "type" => "visual_edit_target_allowlist",
        "strict" => true,
        "data_aiweb_ids" => [target],
        "source_paths" => source_paths,
        "component_map_path" => source_map,
        "selected_component" => component ? {
          "data_aiweb_id" => target,
          "source_path" => component["source_path"],
          "line" => component["line"],
          "kind" => component["kind"],
          "route" => component["route"],
          "editable" => component["editable"]
        } : nil,
        "full_page_regeneration_allowed" => false
      }
    end

    def visual_edit_prompt_summary(prompt)
      normalized = prompt.gsub(/\s+/, " ").strip
      normalized.length > 160 ? "#{normalized[0, 157]}..." : normalized
    end

    def visual_edit_payload(state:, record:, changed_files:, planned_changes:, action_taken:, blocking_issues:, next_action:)
      payload = status_hash(state: state, changed_files: changed_files)
      payload["action_taken"] = action_taken
      payload["blocking_issues"] = blocking_issues
      payload["planned_changes"] = planned_changes unless planned_changes.empty?
      payload["visual_edit"] = record
      payload["next_action"] = next_action
      payload
    end

    def visual_edit_task_markdown(record)
      target = record.fetch("target")
      <<~MD
        # Task Packet — visual-edit

        Task ID: #{record.fetch("id")}
        Status: planned

        ## Goal
        Apply the requested visual edit only to the mapped target region.

        ## Inputs
        - `.ai-web/state.yaml`
        - `.ai-web/DESIGN.md`
        - `.ai-web/component-map.json`
        - `#{target["source_path"]}`

        ## Constraints
        - Do not read `.env` or `.env.*`.
        - Patch only the strict target source allowlist below.
        - Do not regenerate the full page or unrelated components.

        ## Machine Constraints
        shell_allowed: false
        network_allowed: false
        env_access_allowed: false
        requires_selected_design: true
        allowed_source_paths:
        - #{target["source_path"]}

        ## Target
        - data-aiweb-id: `#{target["data_aiweb_id"]}`
        - source: `#{target["source_path"]}`#{target["line"] ? ":#{target["line"]}" : ""}
        - route: `#{target["route"] || "unknown"}`
        - component map: `#{record["source_map"]}`

        ## Requested change
        #{record["prompt_summary"]}

        ## Guardrails
        #{record.fetch("guardrails").map { |guardrail| "- #{guardrail}" }.join("\n")}

        ## Target Source Allowlist
        Patch only these strict source paths and data-aiweb-id targets. Do not regenerate the full page or unrelated components.

        ```json
        #{JSON.pretty_generate(record.fetch("target_allowlist"))}
        ```

        ## Next step
        A later implementation pass may patch only this mapped source region after smoke QA evidence is available. This command intentionally created a handoff record only.
      MD
    end

    def visual_critique_evidence_paths(paths, evidence_paths, screenshot, screenshots, metadata)
      requested = [paths, evidence_paths, screenshot, screenshots, metadata].flatten.compact.map(&:to_s).map(&:strip).reject(&:empty?)
      expanded = []
      requested.each do |path|
        if path == "latest" && [screenshots, metadata].flatten.compact.map(&:to_s).map(&:strip).include?("latest")
          expanded.concat(latest_qa_screenshot_evidence_paths)
        else
          expanded << path
        end
      end
      expanded.uniq
    end

    def latest_qa_screenshot_evidence_paths
      state = load_state_if_present
      latest = state&.dig("qa", "latest_screenshot_metadata").to_s.strip
      latest = File.join(".ai-web", "qa", "screenshots", "metadata.json") if latest.empty?
      metadata_path = File.expand_path(latest, root)
      return [latest] unless File.file?(metadata_path)

      metadata = JSON.parse(File.read(metadata_path))
      screenshots = metadata["screenshots"]
      items = if screenshots.is_a?(Hash)
                %w[desktop tablet mobile].map { |name| screenshots[name] }.compact
              else
                Array(screenshots)
              end
      paths = items.map { |item| item.is_a?(Hash) ? item["path"].to_s.strip : "" }.reject(&:empty?)
      paths << relative(metadata_path)
      paths
    rescue JSON::ParserError
      [latest]
    end

    def validate_visual_critique_input_path!(path)
      raise UserError.new("visual-critique evidence path must be local: #{path}", 1) if path.match?(/\A[a-z][a-z0-9+.-]*:\/\//i)
      reject_env_file_segment!(path, "visual-critique refuses to read .env or .env.* evidence paths")

      expanded = File.expand_path(path, root)
      unless File.file?(expanded)
        raise UserError.new("visual-critique evidence path does not exist or is not a file: #{path}", 1)
      end
    end

    def visual_critique_record(critique_id:, task_id:, evidence_paths:, artifact_path:, dry_run:)
      evidence = evidence_paths.map { |path| visual_critique_evidence(path) }
      fixture = visual_critique_fixture(evidence)
      scores = visual_critique_scores(evidence, fixture)
      issues = visual_critique_issues(scores, fixture)
      patch_plan = visual_critique_patch_plan(scores, issues)
      approval = visual_critique_approval(scores, issues)
      screenshot_evidence = evidence.find { |item| item["kind"] == "screenshot" }
      metadata_evidence = evidence.find { |item| item["kind"] == "metadata" }
      status = if dry_run
        "dry_run"
      elsif approval == "pass"
        "passed"
      else
        "failed"
      end
      artifact_relative = relative(artifact_path)
      {
        "schema_version" => 1,
        "type" => "visual_critique",
        "id" => critique_id,
        "task_id" => task_id.to_s.empty? ? critique_id : task_id.to_s,
        "status" => status,
        "dry_run" => dry_run,
        "created_at" => now,
        "artifact" => artifact_relative,
        "artifact_path" => artifact_relative,
        "screenshot_path" => screenshot_evidence && screenshot_evidence["path"],
        "metadata_path" => metadata_evidence && metadata_evidence["path"],
        "design_contract" => design_contract_context,
        "evidence" => evidence,
        "scores" => scores,
        "hierarchy" => scores.fetch("hierarchy"),
        "typography" => scores.fetch("typography"),
        "spacing" => scores.fetch("spacing"),
        "color" => scores.fetch("color"),
        "originality" => scores.fetch("originality"),
        "mobile_polish" => scores.fetch("mobile_polish"),
        "brand_fit" => scores.fetch("brand_fit"),
        "intent_fit" => scores.fetch("intent_fit"),
        "issues" => issues,
        "patch_plan" => patch_plan,
        "approval" => approval,
        "guardrails" => [
          "use screenshots and metadata as local evidence only",
          "compare against .ai-web/DESIGN.md and selected candidate context when present",
          "do not copy external references, screenshots, copy, prices, trademarks, or brand claims",
          "do not read .env or .env.*"
        ]
      }
    end

    def design_contract_context
      design_path = File.join(aiweb_dir, "DESIGN.md")
      reference_path = File.join(aiweb_dir, "design-reference-brief.md")
      selected = selected_candidate_id
      state = load_state_if_present
      selected_path = selected && state && selected_candidate_artifact_path(state, selected)
      {
        "design_path" => File.file?(design_path) ? relative(design_path) : nil,
        "design_sha256" => File.file?(design_path) ? Digest::SHA256.file(design_path).hexdigest : nil,
        "reference_brief_path" => File.file?(reference_path) ? relative(reference_path) : nil,
        "reference_brief_sha256" => File.file?(reference_path) ? Digest::SHA256.file(reference_path).hexdigest : nil,
        "selected_candidate" => selected,
        "selected_candidate_path" => selected_path && File.file?(selected_path) ? relative(selected_path) : nil,
        "selected_candidate_sha256" => selected_path && File.file?(selected_path) ? Digest::SHA256.file(selected_path).hexdigest : nil
      }.compact
    rescue SystemCallError
      {}
    end

    def visual_critique_evidence(path)
      expanded = File.expand_path(path, root)
      stat = File.stat(expanded)
      {
        "path" => relative(expanded),
        "bytes" => stat.size,
        "sha256" => Digest::SHA256.file(expanded).hexdigest,
        "kind" => visual_critique_evidence_kind(expanded)
      }
    end

    def visual_critique_evidence_kind(path)
      case File.extname(path).downcase
      when ".png", ".jpg", ".jpeg", ".webp", ".gif", ".avif", ".svg" then "screenshot"
      when ".json", ".yml", ".yaml", ".txt", ".md" then "metadata"
      else "file"
      end
    end

    def visual_critique_fixture(evidence)
      evidence.each do |item|
        path = File.join(root, item.fetch("path"))
        next unless item["kind"] == "metadata"

        parsed = parse_visual_critique_fixture(path)
        return parsed if parsed.is_a?(Hash)
      end
      {}
    end

    def parse_visual_critique_fixture(path)
      content = File.read(path, 64 * 1024)
      case File.extname(path).downcase
      when ".json"
        JSON.parse(content)
      when ".yml", ".yaml"
        YAML.safe_load(content, permitted_classes: [Time], aliases: false) || {}
      else
        { "notes" => content }
      end
    rescue JSON::ParserError, Psych::Exception
      { "notes" => content.to_s }
    end

    def visual_critique_scores(evidence, fixture)
      categories = visual_critique_score_categories
      explicit = fixture["visual_critique"] || fixture["scores"] || fixture
      scores = categories.each_with_object({}) do |category, memo|
        value = explicit[category] if explicit.is_a?(Hash)
        memo[category] = clamp_score(value || visual_critique_default_score(category, evidence, fixture))
      end
      scores
    end

    def visual_critique_score_categories
      %w[first_impression hierarchy typography layout_rhythm spacing color originality mobile_polish brand_fit intent_fit content_credibility interaction_clarity]
    end

    def visual_critique_default_score(category, evidence, fixture)
      notes = fixture["notes"].to_s.downcase
      score = 72
      score += 5 if evidence.any? { |item| item["kind"] == "screenshot" }
      score += 3 if evidence.any? { |item| item["kind"] == "metadata" }
      score -= 25 if notes.match?(/broken|fail|poor|low|clutter|illegible|generic|misaligned|overflow/)
      score -= 10 if category == "mobile_polish" && notes.match?(/mobile|responsive|viewport/)
      score -= 8 if category == "originality" && notes.match?(/generic|template|stock/)
      score -= 8 if category == "brand_fit" && notes.match?(/brand|tone|voice/)
      score -= 8 if category == "intent_fit" && notes.match?(/intent|goal|audience/)
      score
    end

    def clamp_score(value)
      numeric = value.is_a?(String) ? value.to_f : value.to_f
      [[numeric.round, 0].max, 100].min
    end

    def visual_critique_issues(scores, fixture)
      explicit = fixture["issues"]
      return explicit.map(&:to_s) if explicit.is_a?(Array) && !explicit.empty?

      thresholds = visual_critique_gate_thresholds
      axis_floor = thresholds.fetch("min_axis")
      average_floor = thresholds.fetch("min_average")
      low = scores.select { |_category, score| score < axis_floor }
      average = scores.empty? ? 0.0 : scores.values.sum.to_f / scores.length
      issues = low.map { |category, score| "#{category.tr("_", " ")} score #{score} is below the visual quality target #{axis_floor.to_i}" }
      if average < average_floor
        issues << "average visual score #{format('%.1f', average)} is below the visual quality target #{average_floor.to_i}"
      end
      return [] if issues.empty?

      issues
    end

    def visual_critique_patch_plan(scores, issues)
      return [] if issues.empty?

      axis_floor = visual_critique_gate_thresholds.fetch("min_axis")
      plan = scores.select { |_category, score| score < axis_floor }.map do |category, score|
        {
          "area" => category,
          "priority" => score < 50 ? "high" : "medium",
          "action" => visual_critique_patch_action(category)
        }
      end
      if plan.empty?
        plan << {
          "area" => "overall_visual_quality",
          "priority" => "medium",
          "action" => "raise the average visual quality through stronger first-view composition, contrast, spacing, and source-backed proof"
        }
      end
      plan
    end

    def visual_critique_patch_action(category)
      case category
      when "first_impression" then "tighten first-view composition, value clarity, and brand signal"
      when "hierarchy" then "clarify primary headline, CTA emphasis, and section order"
      when "layout_rhythm" then "rebalance section rhythm, composition changes, and scan path"
      when "typography" then "tighten type scale, line height, and readable contrast"
      when "spacing" then "normalize section rhythm, gutters, and component padding"
      when "color" then "reduce palette noise and improve semantic color contrast"
      when "originality" then "add distinctive composition, imagery, or interaction motif"
      when "mobile_polish" then "verify responsive spacing, tap targets, and above-the-fold composition"
      when "brand_fit" then "align tone, visual motifs, and UI details with brand attributes"
      when "intent_fit" then "make the page goal and user journey more explicit"
      when "content_credibility" then "remove unsupported claims and improve source-backed proof hierarchy"
      when "interaction_clarity" then "clarify CTA states, forms, and navigation affordances"
      else "improve visual quality for #{category.tr("_", " ")}"
      end
    end

    def visual_critique_approval(scores, issues)
      minimum = scores.values.min || 0
      average = scores.empty? ? 0.0 : scores.values.sum.to_f / scores.length
      thresholds = visual_critique_gate_thresholds
      return "redesign" if minimum < 50 || average < 60
      return "repair" if minimum < thresholds.fetch("min_axis") || average < thresholds.fetch("min_average") || !issues.empty?

      "pass"
    end

    def visual_critique_gate_thresholds
      quality = File.file?(quality_path) ? YAML.load_file(quality_path) : {}
      gate = quality.dig("quality", "design", "phase_0_gate") if quality.is_a?(Hash)
      gate = {} unless gate.is_a?(Hash)
      {
        "min_axis" => [gate["min_visual_score_axis"].to_f, 70.0].max,
        "min_average" => [gate["min_visual_score_average"].to_f, 75.0].max
      }
    rescue Psych::Exception, SystemCallError
      { "min_axis" => 75.0, "min_average" => 75.0 }
    end

    def visual_critique_payload(state:, critique:, changed_files:, planned_changes:, action_taken:, next_action:)
      blockers = critique["approval"] == "pass" ? [] : ["visual critique approval=#{critique["approval"]}"]
      {
        "schema_version" => 1,
        "current_phase" => state&.dig("phase", "current"),
        "action_taken" => action_taken,
        "dry_run" => critique["dry_run"],
        "changed_files" => changed_files,
        "planned_changes" => planned_changes,
        "blocking_issues" => blockers,
        "missing_artifacts" => [],
        "visual_critique" => critique,
        "next_action" => next_action
      }
    end

    def visual_critique_next_action(critique)
      case critique["approval"]
      when "pass" then "use #{critique["artifact"]} as local visual critique evidence"
      when "repair" then "review patch_plan in #{critique["artifact"]}, make targeted visual edits, then rerun aiweb visual-critique"
      else "review issues in #{critique["artifact"]}, redesign the weak areas, then rerun aiweb visual-critique"
      end
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
