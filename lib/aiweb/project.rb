# frozen_string_literal: true

require "cgi"
require "digest"
require "fileutils"
require "find"
require "json"
require "open3"
require "timeout"
require "time"
require "uri"
require "yaml"

require_relative "archetypes"
require_relative "design_brief"
require_relative "design_candidate_generator"
require_relative "design_system_resolver"
require_relative "intent_router"
require_relative "profiles"

module Aiweb
  class UserError < StandardError
    attr_reader :exit_code

    def initialize(message, exit_code = 1)
      super(message)
      @exit_code = exit_code
    end
  end

  class Project
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
      schema_version project phase gates artifacts design_candidates implementation qa deploy budget adapters invalidations decisions snapshots
    ].freeze

    SCAFFOLD_PROFILE_D_METADATA_PATH = ".ai-web/scaffold-profile-D.json".freeze


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
    ].freeze

    WORKBENCH_CONTROLS = [
      ["run", "Run director", "aiweb run"],
      ["design", "Generate design candidates", "aiweb design"],
      ["build", "Plan or run scaffold build", "aiweb build"],
      ["preview", "Start local preview", "aiweb preview"],
      ["qa_playwright", "Run Playwright QA", "aiweb qa-playwright"],
      ["visual_critique", "Record visual critique", "aiweb visual-critique"],
      ["repair", "Create repair packet", "aiweb repair"],
      ["visual_polish", "Plan visual polish loop", "aiweb visual-polish"]
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
        changes << write_file(File.join(aiweb_dir, "design-candidates", "selected.md"), selected_design_markdown(selected_id), dry_run)
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


    def scaffold(profile: "D", dry_run: false, force: false)
      assert_initialized!
      selected_profile, profile_data = Profiles.fetch!(profile)
      unless selected_profile == "D"
        raise UserError.new("scaffold currently supports --profile D only; received #{profile.inspect}", 1)
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
        preflight_scaffold_targets!(files, metadata_path: scaffold_metadata_path, force: force)

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

    def workbench(export: false, dry_run: false, force: false)
      state, state_error = workbench_state_snapshot
      paths = workbench_paths
      should_export = !!export && !dry_run
      status = state_error ? "blocked" : (should_export ? "exported" : "planned")
      blockers = state_error ? [state_error] : []
      planned_changes = [paths["index_html"], paths["manifest_json"]]
      manifest = workbench_manifest(state: state, status: status, export: should_export, dry_run: dry_run, blocking_issues: blockers, paths: paths)

      if blockers.empty? && should_export
        existing_conflicts = workbench_existing_conflicts(paths, manifest)
        unless existing_conflicts.empty? || force
          blockers = existing_conflicts.map { |path| "workbench artifact already exists and differs: #{path}" }
          manifest = workbench_manifest(state: state, status: "blocked", export: true, dry_run: false, blocking_issues: blockers, paths: paths)
          return workbench_payload(state: state, workbench: manifest, changed_files: [], blocking_issues: blockers, next_action: "review existing workbench artifacts or rerun aiweb workbench --export --force")
        end

        changes = []
        mutation(dry_run: false) do
          changes << write_file(File.join(root, paths["index_html"]), workbench_html(manifest), false)
          changes << write_json(File.join(root, paths["manifest_json"]), manifest, false)
        end
        return workbench_payload(state: state, workbench: manifest, changed_files: compact_changes(changes), blocking_issues: [], next_action: "open .ai-web/workbench/index.html locally or inspect .ai-web/workbench/workbench.json")
      end

      workbench_payload(
        state: state,
        workbench: manifest,
        changed_files: blockers.empty? ? planned_changes : [],
        blocking_issues: blockers,
        next_action: blockers.empty? ? "rerun aiweb workbench --export to write the local workbench artifacts" : "run aiweb init or aiweb start before exporting the workbench"
      )
    end

    def runtime_plan
      state, state_error = runtime_state_snapshot
      ensure_scaffold_state_defaults!(state) if state

      scaffold = runtime_scaffold_summary(state)
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary
      missing_files = SCAFFOLD_PROFILE_D_REQUIRED_FILES.reject { |path| File.exist?(File.join(root, path)) }
      blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files)
      readiness = blockers.empty? ? "ready" : "blocked"

      {
        "schema_version" => 1,
        "current_phase" => state&.dig("phase", "current"),
        "action_taken" => "reported runtime plan",
        "changed_files" => [],
        "blocking_issues" => blockers,
        "missing_artifacts" => state ? [] : [".ai-web/state.yaml"],
        "runtime_plan" => {
          "readiness" => readiness,
          "scaffold" => scaffold,
          "metadata" => metadata,
          "package_json" => package_json,
          "design" => design,
          "missing_required_scaffold_files" => missing_files,
          "blockers" => blockers
        },
        "next_action" => readiness == "ready" ? "runtime tools may inspect scripts next; do not install packages or launch Node from this read-only check" : "resolve blockers, then rerun aiweb runtime-plan"
      }
    end


    def build(dry_run: false)
      assert_initialized!

      state, state_error = runtime_state_snapshot
      ensure_scaffold_state_defaults!(state) if state
      scaffold = runtime_scaffold_summary(state)
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary
      missing_files = SCAFFOLD_PROFILE_D_REQUIRED_FILES.reject { |path| File.exist?(File.join(root, path)) }
      blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files)
      return build_blocked_payload(state, blockers, dry_run: dry_run) unless blockers.empty?

      run_id = "build-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}"
      run_dir = File.join(aiweb_dir, "runs", run_id)
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      metadata_path = File.join(run_dir, "build.json")
      command = scaffold["build_command"].to_s.empty? ? "pnpm build" : scaffold["build_command"].to_s
      planned_changes = [relative(run_dir), relative(stdout_path), relative(stderr_path), relative(metadata_path)]

      if dry_run
        return build_payload(
          state: state,
          metadata: build_run_metadata(
            run_id: run_id,
            status: "dry_run",
            command: command,
            started_at: nil,
            finished_at: nil,
            exit_code: nil,
            stdout_log: relative(stdout_path),
            stderr_log: relative(stderr_path),
            metadata_path: relative(metadata_path),
            blocking_issues: [],
            dry_run: true
          ),
          changed_files: planned_changes,
          action_taken: "planned scaffold build",
          blocking_issues: [],
          next_action: "rerun aiweb build without --dry-run to execute #{command.inspect}"
        )
      end

      changes = []
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << relative(run_dir)
        started_at = now
        status = "blocked"
        exit_code = nil
        blocking_issues = []
        stdout = ""
        stderr = ""

        if executable_path("pnpm").nil?
          blocking_issues << "pnpm executable is missing; install project dependencies outside aiweb build, then rerun."
          stderr = blocking_issues.join("\n") + "\n"
        elsif !File.directory?(File.join(root, "node_modules"))
          blocking_issues << "node_modules is missing; run pnpm install outside aiweb build after reviewing package.json, then rerun."
          stderr = blocking_issues.join("\n") + "\n"
        else
          stdout, stderr, process_status = Open3.capture3(command, chdir: root)
          exit_code = process_status.exitstatus
          status = process_status.success? ? "passed" : "failed"
          blocking_issues << "#{command} failed with exit code #{exit_code}" unless process_status.success?
        end

        changes << write_file(stdout_path, stdout, false)
        changes << write_file(stderr_path, stderr, false)
        metadata = build_run_metadata(
          run_id: run_id,
          status: status,
          command: command,
          started_at: started_at,
          finished_at: now,
          exit_code: exit_code,
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          metadata_path: relative(metadata_path),
          blocking_issues: blocking_issues,
          dry_run: false
        )
        changes << write_json(metadata_path, metadata, false)
        return build_payload(
          state: state,
          metadata: metadata,
          changed_files: compact_changes(changes),
          action_taken: status == "passed" ? "ran scaffold build" : "scaffold build #{status}",
          blocking_issues: blocking_issues,
          next_action: build_next_action(status)
        )
      end
    end

    def preview(dry_run: false, stop: false)
      assert_initialized!

      return stop_preview(dry_run: dry_run) if stop

      state, state_error = runtime_state_snapshot
      ensure_scaffold_state_defaults!(state) if state
      scaffold = runtime_scaffold_summary(state)
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary
      missing_files = SCAFFOLD_PROFILE_D_REQUIRED_FILES.reject { |path| File.exist?(File.join(root, path)) }
      blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files)
      return preview_blocked_payload(state, blockers, dry_run: dry_run) unless blockers.empty?

      running = running_preview_metadata
      return preview_already_running_payload(state, running, dry_run: dry_run) if running

      run_id = "preview-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}"
      run_dir = File.join(aiweb_dir, "runs", run_id)
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      metadata_path = File.join(run_dir, "preview.json")
      command = preview_command(scaffold)
      port = preview_port(command)
      url = "http://127.0.0.1:#{port}/"
      planned_changes = [relative(run_dir), relative(stdout_path), relative(stderr_path), relative(metadata_path)]

      if dry_run
        return preview_payload(
          state: state,
          metadata: preview_run_metadata(
            run_id: run_id,
            status: "dry_run",
            command: command,
            started_at: nil,
            finished_at: nil,
            exit_code: nil,
            pid: nil,
            port: port,
            url: url,
            stdout_log: relative(stdout_path),
            stderr_log: relative(stderr_path),
            metadata_path: relative(metadata_path),
            blocking_issues: [],
            dry_run: true
          ),
          changed_files: planned_changes,
          action_taken: "planned scaffold preview",
          blocking_issues: [],
          next_action: "rerun aiweb preview without --dry-run to start #{command.inspect}"
        )
      end

      changes = []
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << relative(run_dir)
        started_at = now
        status = "blocked"
        blocking_issues = []
        pid = nil
        exit_code = nil

        if executable_path("pnpm").nil?
          blocking_issues << "pnpm executable is missing; install project dependencies outside aiweb preview, then rerun."
          changes << write_file(stdout_path, "", false)
          changes << write_file(stderr_path, blocking_issues.join("\n") + "\n", false)
        elsif !File.directory?(File.join(root, "node_modules"))
          blocking_issues << "node_modules is missing; run pnpm install outside aiweb preview after reviewing package.json, then rerun."
          changes << write_file(stdout_path, "", false)
          changes << write_file(stderr_path, blocking_issues.join("\n") + "\n", false)
        else
          FileUtils.touch(stdout_path)
          FileUtils.touch(stderr_path)
          stdout_file = File.open(stdout_path, "ab")
          stderr_file = File.open(stderr_path, "ab")
          begin
            pid = Process.spawn(command, chdir: root, out: stdout_file, err: stderr_file)
            Process.detach(pid)
            status = "running"
          ensure
            stdout_file.close
            stderr_file.close
          end
          changes << relative(stdout_path)
          changes << relative(stderr_path)
        end

        metadata = preview_run_metadata(
          run_id: run_id,
          status: status,
          command: command,
          started_at: started_at,
          finished_at: status == "running" ? nil : now,
          exit_code: exit_code,
          pid: pid,
          port: port,
          url: url,
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          metadata_path: relative(metadata_path),
          blocking_issues: blocking_issues,
          dry_run: false
        )
        changes << write_json(metadata_path, metadata, false)
        return preview_payload(
          state: state,
          metadata: metadata,
          changed_files: compact_changes(changes),
          action_taken: status == "running" ? "started scaffold preview" : "scaffold preview blocked",
          blocking_issues: blocking_issues,
          next_action: preview_next_action(status)
        )
      end
    end

    def qa_playwright(url: nil, task_id: nil, force: false, dry_run: false)
      state, state_error = runtime_state_snapshot
      return qa_playwright_blocked_payload(state, [state_error], dry_run: dry_run, command: qa_playwright_command(nil), target: nil) unless state_error.nil?

      ensure_scaffold_state_defaults!(state) if state
      scaffold = runtime_scaffold_summary(state)
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary
      missing_files = SCAFFOLD_PROFILE_D_REQUIRED_FILES.reject { |path| File.exist?(File.join(root, path)) }
      blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files)
      return qa_playwright_blocked_payload(state, blockers, dry_run: dry_run, command: qa_playwright_command(nil), target: nil) unless blockers.empty?

      preview = running_preview_metadata
      target = qa_playwright_target(url: url, preview: preview)
      target_blockers = qa_playwright_target_blockers(state, target, preview: preview, force: force)
      return qa_playwright_blocked_payload(state, target_blockers, dry_run: dry_run, command: qa_playwright_command(target && target["url"]), target: target) unless target_blockers.empty?

      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      run_id = "playwright-qa-#{timestamp}"
      result_task_id = qa_playwright_task_id(task_id, run_id)
      run_dir = File.join(aiweb_dir, "runs", run_id)
      spec_path = File.join(run_dir, "smoke.spec.js")
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      result_path = File.join(aiweb_dir, "qa", "results", "qa-#{timestamp}-#{slug(result_task_id)}.json")
      metadata_path = File.join(run_dir, "playwright-qa.json")
      command = qa_playwright_command(relative(spec_path))
      planned_changes = [relative(run_dir), relative(spec_path), relative(stdout_path), relative(stderr_path), relative(result_path), relative(metadata_path)]

      if dry_run
        result = qa_playwright_result(
          task_id: result_task_id,
          status: "pending",
          started_at: nil,
          finished_at: nil,
          duration_minutes: 0,
          timed_out: false,
          target: target,
          checks: [qa_playwright_pending_check],
          evidence: [],
          console_errors: [],
          network_errors: []
        )
        validate_qa_result!(result)
        metadata = qa_playwright_run_metadata(
          run_id: run_id,
          task_id: result_task_id,
          status: "dry_run",
          command: command,
          started_at: nil,
          finished_at: nil,
          exit_code: nil,
          target: target,
          spec_path: relative(spec_path),
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          result_path: relative(result_path),
          metadata_path: relative(metadata_path),
          blocking_issues: [],
          dry_run: true
        )
        metadata["qa_result"] = result
        return qa_playwright_payload(
          state: state,
          metadata: metadata,
          changed_files: planned_changes,
          action_taken: "planned Playwright QA",
          blocking_issues: [],
          next_action: "rerun aiweb qa-playwright without --dry-run to execute local Playwright QA against #{target["url"]}"
        )
      end

      changes = []
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << relative(run_dir)
        changes << write_file(spec_path, qa_playwright_spec, false)
        started_at = Time.now.utc
        status = "blocked"
        exit_code = nil
        blocking_issues = []
        stdout = ""
        stderr = ""
        executable = qa_playwright_executable_path

        if executable.nil?
          blocking_issues << "Local Playwright executable node_modules/.bin/playwright is missing; install project dependencies outside aiweb qa-playwright, then rerun."
          stderr = blocking_issues.join("\n") + "\n"
        elsif executable_path("pnpm").nil?
          blocking_issues << "pnpm executable is missing; install project dependencies outside aiweb qa-playwright, then rerun."
          stderr = blocking_issues.join("\n") + "\n"
        else
          stdout, stderr, process_status = Open3.capture3({ "PLAYWRIGHT_BASE_URL" => target["url"] }, "pnpm", "exec", "playwright", "test", relative(spec_path), "--reporter=json", chdir: root)
          exit_code = process_status.exitstatus
          status = process_status.success? ? "passed" : "failed"
          blocking_issues << "#{command} failed with exit code #{exit_code}" unless process_status.success?
        end

        finished_at = Time.now.utc
        duration_minutes = ((finished_at - started_at) / 60.0).round(4)
        changes << write_file(stdout_path, stdout, false)
        changes << write_file(stderr_path, stderr, false)
        result = qa_playwright_result(
          task_id: result_task_id,
          status: status == "passed" ? "passed" : status,
          started_at: started_at.iso8601,
          finished_at: finished_at.iso8601,
          duration_minutes: duration_minutes,
          timed_out: false,
          target: target,
          checks: [qa_playwright_status_check(status, blocking_issues, stdout_path, stderr_path)],
          evidence: [relative(stdout_path), relative(stderr_path)],
          console_errors: [],
          network_errors: []
        )
        validate_qa_result!(result)
        changes << write_json(result_path, result, false)
        metadata = qa_playwright_run_metadata(
          run_id: run_id,
          task_id: result_task_id,
          status: status,
          command: command,
          started_at: started_at.iso8601,
          finished_at: finished_at.iso8601,
          exit_code: exit_code,
          target: target,
          spec_path: relative(spec_path),
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          result_path: relative(result_path),
          metadata_path: relative(metadata_path),
          blocking_issues: blocking_issues,
          dry_run: false
        )
        changes << write_json(metadata_path, metadata, false)
        state["qa"] ||= {}
        state["qa"]["last_result"] = relative(result_path)
        add_decision!(state, "qa_playwright", "Recorded Playwright QA result #{result["status"]} for #{result["task_id"]}")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)
        return qa_playwright_payload(
          state: state,
          metadata: metadata,
          changed_files: compact_changes(changes),
          action_taken: status == "blocked" ? "playwright QA blocked" : "ran Playwright QA",
          blocking_issues: blocking_issues,
          next_action: qa_playwright_next_action(status)
        )
      end
    end

    def browser_qa(dry_run: false)
      qa_playwright(dry_run: dry_run)
    end

    def qa_a11y(url: nil, task_id: nil, force: false, dry_run: false)
      qa_static_browser_tool(
        key: "a11y_qa",
        label: "axe accessibility",
        run_prefix: "a11y-qa",
        executable: "axe",
        result_check_id: "QA-A11Y",
        category: "accessibility",
        severity: "critical",
        url: url,
        task_id: task_id,
        force: force,
        dry_run: dry_run
      )
    end

    def qa_lighthouse(url: nil, task_id: nil, force: false, dry_run: false)
      qa_static_browser_tool(
        key: "lighthouse_qa",
        label: "Lighthouse",
        run_prefix: "lighthouse-qa",
        executable: "lighthouse",
        result_check_id: "QA-LIGHTHOUSE",
        category: "performance",
        severity: "high",
        url: url,
        task_id: task_id,
        force: force,
        dry_run: dry_run
      )
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
      component = component_map ? component_map_component(component_map, target) : nil
      blockers = visual_edit_blockers(source, component_map, component, target, force: force)

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


    def visual_critique(paths: nil, evidence_paths: nil, screenshot: nil, screenshots: nil, metadata: nil, task_id: nil, dry_run: false, **_options)
      assert_initialized!
      evidence = visual_critique_evidence_paths(paths, evidence_paths, screenshot, screenshots, metadata)
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

    def ensure_defaults!(state)
      state["invalidations"] ||= []
      state["decisions"] ||= []
      state["snapshots"] ||= []
      state["qa"] ||= {}
      state["qa"]["open_failures"] ||= []
      state["design_candidates"] ||= {}
      state["design_candidates"]["candidates"] ||= []
      ensure_scaffold_state_defaults!(state)
      state["budget"] ||= {}
      state["budget"]["cost_mode"] ||= "subscription_usage"
      state["budget"]["meter_model_cost"] = false if state["budget"]["meter_model_cost"].nil?
      state["budget"]["max_design_generations_total"] ||= 10
      state["budget"]["max_design_candidates"] ||= 10
      state["budget"]["max_qa_runtime_minutes"] ||= 60
      state["budget"]["qa_timeout_action"] ||= "self_diagnose_fix_rerun"
      state["budget"]["max_qa_timeout_recovery_cycles"] ||= 3
      state
    end

    def refresh_state!(state)
      ensure_defaults!(state)
      mark_artifacts_from_files!(state)
      update_design_counts!(state)
      state
    end

    def mark_artifacts_from_files!(state)
      artifacts = state["artifacts"] || {}
      artifacts.each do |name, meta|
        next unless meta.is_a?(Hash)
        path = meta["path"]
        next if path.nil?
        full = File.join(root, path)
        if File.directory?(full)
          meta["status"] = Dir.children(full).empty? ? "missing" : "draft"
        elsif File.exist?(full)
          meta["status"] = stub_file?(full) ? "stub" : "draft"
        else
          meta["status"] = "missing"
        end
      end
      state
    end

    def update_design_counts!(state)
      dir = File.join(aiweb_dir, "design-candidates")
      candidate_files = Dir.exist?(dir) ? Dir.glob(File.join(dir, "candidate-*.{md,html}"), File::FNM_EXTGLOB).sort : []
      refs = state.dig("design_candidates", "candidates") || []
      known = refs.map { |r| r["path"] }
      candidate_files.each do |path|
        rel = relative(path)
        next if known.include?(rel)
        refs << {
          "id" => File.basename(path, File.extname(path)),
          "path" => rel,
          "status" => "draft"
        }
      end
      state["design_candidates"]["candidates"] = refs
      count = refs.length
      state["design_candidates"]["max_allowed"] ||= state.dig("budget", "max_design_candidates") || 10
      if state.dig("artifacts", "design_candidates")
        state["artifacts"]["design_candidates"]["count"] = count
        state["artifacts"]["design_candidates"]["status"] = count.zero? ? "missing" : "draft"
      end
      state
    end

    def validate_state_shape(state)
      errors = []
      schema_errors = validate_json_schema(state, load_schema("state.schema.json"))
      errors.concat(schema_errors.map { |error| "state.schema: #{error}" })
      errors.concat(validate_intent_shape)
      REQUIRED_TOP_LEVEL_STATE_KEYS.each { |key| errors << "missing #{key}" unless state.key?(key) }
      unknown = state.keys - REQUIRED_TOP_LEVEL_STATE_KEYS
      errors << "unknown top-level keys: #{unknown.join(", ")}" unless unknown.empty?
      errors << "schema_version must be 1" unless state["schema_version"] == 1
      current = state.dig("phase", "current")
      errors << "unknown phase #{current.inspect}" unless PHASES.include?(current)
      budget = state["budget"] || {}
      errors << "budget.cost_mode missing" unless budget.key?("cost_mode")
      errors << "budget.max_design_candidates must be >= 1" if budget["max_design_candidates"].to_i < 1
      errors << "budget.max_qa_runtime_minutes must be >= 1" if budget["max_qa_runtime_minutes"].to_i < 1
      errors << "Gate 1B key missing" unless state.dig("gates", "gate_1b_product_content_ia_data_security")
      validate_accepted_risks(state, errors)
      errors
    end

    def validate_intent_shape
      path = File.join(aiweb_dir, "intent.yaml")
      return ["intent artifact missing"] unless File.exist?(path)
      return [] if stub_file?(path)

      intent = YAML.load_file(path)
      validate_json_schema(intent, load_schema("intent.schema.json")).map { |error| "intent.schema: #{error}" }
    rescue Psych::SyntaxError => e
      ["intent.yaml parse failed: #{e.message}"]
    end

    def validate_qa_result!(result)
      errors = validate_json_schema(result, load_schema("qa-result.schema.json"))
      raise UserError.new("QA result schema failed: #{errors.join("; ")}", 1) unless errors.empty?
      true
    end

    def load_schema(name)
      project_schema = name == "qa-result.schema.json" ? File.join(aiweb_dir, "qa", name) : File.join(aiweb_dir, name)
      path = File.exist?(project_schema) ? project_schema : File.join(templates_dir, name)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise UserError.new("cannot parse schema #{name}: #{e.message}", 1)
    end

    def validate_json_schema(value, schema, path = "$", root_schema = nil)
      root_schema ||= schema
      if schema["$ref"]
        schema = resolve_schema_ref(root_schema, schema["$ref"])
      end

      errors = []
      if schema.key?("const") && value != schema["const"]
        errors << "#{path} must equal #{schema["const"].inspect}"
      end
      if schema.key?("enum") && !schema["enum"].include?(value)
        errors << "#{path} must be one of #{schema["enum"].map(&:inspect).join(", ")}"
      end
      if schema["type"] && !schema_type_match?(value, schema["type"])
        errors << "#{path} expected #{Array(schema["type"]).join("|")}, got #{value.class}"
        return errors
      end
      if schema.key?("minimum") && value.is_a?(Numeric) && value < schema["minimum"]
        errors << "#{path} must be >= #{schema["minimum"]}"
      end

      if value.is_a?(Hash)
        required = schema["required"] || []
        required.each do |key|
          errors << "#{path}.#{key} is required" unless value.key?(key)
        end

        properties = schema["properties"] || {}
        properties.each do |key, child_schema|
          next unless value.key?(key)
          errors.concat(validate_json_schema(value[key], child_schema, "#{path}.#{key}", root_schema))
        end

        additional = schema["additionalProperties"]
        unknown = value.keys - properties.keys
        if additional == false
          unknown.each { |key| errors << "#{path}.#{key} is not allowed" }
        elsif additional.is_a?(Hash)
          unknown.each do |key|
            errors.concat(validate_json_schema(value[key], additional, "#{path}.#{key}", root_schema))
          end
        end
      elsif value.is_a?(Array) && schema["items"]
        value.each_with_index do |item, index|
          errors.concat(validate_json_schema(item, schema["items"], "#{path}[#{index}]", root_schema))
        end
      end

      errors
    end

    def resolve_schema_ref(root_schema, ref)
      unless ref.start_with?("#/")
        raise UserError.new("unsupported schema ref #{ref}", 1)
      end
      ref.sub("#/", "").split("/").reduce(root_schema) do |node, part|
        key = part.gsub("~1", "/").gsub("~0", "~")
        node.fetch(key)
      end
    end

    def schema_type_match?(value, type)
      Array(type).any? do |kind|
        case kind
        when "null" then value.nil?
        when "object" then value.is_a?(Hash)
        when "array" then value.is_a?(Array)
        when "string" then value.is_a?(String)
        when "integer" then value.is_a?(Integer) && !value.is_a?(TrueClass) && !value.is_a?(FalseClass)
        when "number" then value.is_a?(Numeric) && !value.is_a?(TrueClass) && !value.is_a?(FalseClass)
        when "boolean" then value == true || value == false
        else true
        end
      end
    end

    def phase_blockers(state)
      blockers = []
      current = state.dig("phase", "current")
      artifacts = state["artifacts"] || {}
      blockers.concat(phase_lock_blockers(state))
      case current
      when "phase-0"
        blockers.concat(missing_artifacts(artifacts, %w[project product intent first_view_contract]))
      when "phase-0.25"
        blockers.concat(missing_artifacts(artifacts, %w[quality]))
        blockers.concat(quality_contract_blockers)
      when "phase-0.5"
        blockers << "implementation.stack_profile is required" if blank?(state.dig("implementation", "stack_profile"))
        blockers.concat(missing_artifacts(artifacts, %w[stack]))
        blockers << "Gate 1A approval artifact is missing" unless File.exist?(File.join(root, state.dig("gates", "gate_1a_scope_quality_stack", "artifact").to_s))
        blockers << "Gate 1A approval is pending" unless gate_approved?(state, "gate_1a_scope_quality_stack")
      when "phase-1"
        blockers.concat(missing_artifacts(artifacts, %w[product]))
      when "phase-1.5"
        blockers.concat(missing_artifacts(artifacts, %w[brand content]))
      when "phase-2"
        blockers.concat(missing_artifacts(artifacts, %w[ia]))
      when "phase-2.5"
        blockers.concat(missing_artifacts(artifacts, %w[data security]))
        blockers << "Gate 1B approval artifact is missing" unless File.exist?(File.join(root, state.dig("gates", "gate_1b_product_content_ia_data_security", "artifact").to_s))
        blockers << "Gate 1B approval is pending" unless gate_approved?(state, "gate_1b_product_content_ia_data_security")
      when "phase-3"
        blockers.concat(missing_artifacts(artifacts, %w[design_brief]))
      when "phase-3.5"
        count = state.dig("artifacts", "design_candidates", "count").to_i
        min = state.dig("design_candidates", "min_required").to_i
        blockers << "design candidates must be >= #{min}; currently #{count}" if count < min
        blockers.concat(missing_artifacts(artifacts, %w[design_comparison selected_design_candidate]))
        blockers << "Gate 2 design draft is missing" unless File.exist?(File.join(root, state.dig("design_candidates", "gate_2_draft_path").to_s))
        selected = state.dig("design_candidates", "selected_candidate")
        candidate_ids = (state.dig("design_candidates", "candidates") || []).map { |candidate| candidate["id"] }
        blockers << "selected design candidate is required" if blank?(selected)
        blockers << "selected design candidate #{selected.inspect} is not in candidates" if !blank?(selected) && !candidate_ids.include?(selected)
        blockers << "Gate 2 design approval is pending" unless gate_approved?(state, "gate_2_design")
      when "phase-4"
        blockers.concat(missing_artifacts(artifacts, %w[design_system]))
      when "phase-5"
        blockers << "root AGENTS.md is missing" unless File.exist?(File.join(root, "AGENTS.md"))
      when "phase-6"
        blockers << "implementation.current_task is required for bootstrap" if blank?(state.dig("implementation", "current_task"))
      when "phase-7"
        blockers.concat(completed_task_evidence_blockers(state, {
          "design tokens" => [/design[-_ ]?tokens?/i],
          "component primitives" => [/component[-_ ]?primitives?/i],
          "component audit" => [/component[-_ ]?audit/i]
        }))
      when "phase-8"
        blockers << "Gate 3 golden flow artifact is missing" unless File.exist?(File.join(root, state.dig("gates", "gate_3_golden_flow", "artifact").to_s))
        blockers << "Gate 3 golden flow approval is pending" unless gate_approved?(state, "gate_3_golden_flow")
      when "phase-9"
        blockers.concat(completed_task_evidence_blockers(state, {
          "remaining page/feature completion" => [/phase[-_ ]?9/i, /remaining/i, /page/i, /feature/i]
        }))
      when "phase-10"
        blockers << "QA checklist is required" if blank?(state.dig("qa", "current_checklist")) || !File.exist?(File.join(root, state.dig("qa", "current_checklist").to_s))
      when "phase-11"
        blockers.concat(missing_artifacts(artifacts, %w[deploy final_qa_report post_launch_backlog]))
        blockers << "Gate 4 predeploy approval artifact is missing" unless File.exist?(File.join(root, state.dig("gates", "gate_4_predeploy", "artifact").to_s))
        blockers << "Gate 4 predeploy approval is pending" unless gate_approved?(state, "gate_4_predeploy")
        blockers << "deploy.rollback_defined must be true" unless state.dig("deploy", "rollback_defined") == true
        blockers << "deploy.rollback_dry_run_result is required" if blank?(state.dig("deploy", "rollback_dry_run_result"))
      end
      blockers.concat(approved_hash_drift_blockers(state))
      open_failures = state.dig("qa", "open_failures") || []
      blocking_open_failures = open_failures.select { |failure| failure["blocking"] != false }
      blockers << "open QA failures: #{blocking_open_failures.length}" if qa_failures_block_phase?(current) && !blocking_open_failures.empty?
      blockers
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


    def workbench_state_snapshot
      return [nil, "Project is not initialized; run aiweb init or aiweb start before exporting the workbench."] unless File.file?(state_path)

      state = YAML.load_file(state_path)
      return [refresh_state!(state), nil] if state.is_a?(Hash)

      [nil, ".ai-web/state.yaml must be a YAML mapping; repair state before exporting the workbench."]
    rescue Psych::Exception => e
      [nil, "Cannot parse .ai-web/state.yaml: #{e.message}"]
    end

    def workbench_paths
      {
        "index_html" => ".ai-web/workbench/index.html",
        "manifest_json" => ".ai-web/workbench/workbench.json"
      }
    end

    def workbench_manifest(state:, status:, export:, dry_run:, blocking_issues:, paths:)
      {
        "schema_version" => 1,
        "status" => status,
        "export" => export,
        "dry_run" => dry_run,
        "generated_at" => now,
        "root" => root,
        "paths" => paths,
        "panels" => workbench_panels(state),
        "controls" => workbench_controls,
        "guardrails" => [
          "declarative CLI command descriptors only",
          "does not directly write .ai-web/state.yaml",
          "excludes local environment secret files from file-tree and artifact summaries",
          "local artifact only; no install, build, preview, QA, deploy, network, or AI calls"
        ],
        "blocking_issues" => blocking_issues
      }
    end

    def workbench_payload(state:, workbench:, changed_files:, blocking_issues:, next_action:)
      {
        "schema_version" => 1,
        "current_phase" => state&.dig("phase", "current"),
        "action_taken" => workbench["status"] == "exported" ? "exported workbench UI" : "planned workbench UI",
        "changed_files" => changed_files,
        "blocking_issues" => blocking_issues,
        "missing_artifacts" => state ? [] : [".ai-web/state.yaml"],
        "workbench" => workbench,
        "next_action" => next_action
      }
    end

    def workbench_controls
      WORKBENCH_CONTROLS.map do |id, label, command|
        {
          "id" => id,
          "label" => label,
          "command" => command,
          "mode" => "cli_descriptor",
          "mutates_state" => false,
          "notes" => "UI may invoke this CLI command through an approved shell/daemon adapter; it must not edit state files directly."
        }
      end
    end

    def workbench_panels(state)
      WORKBENCH_PANELS.map do |panel|
        { "id" => panel }.merge(workbench_panel(panel, state))
      end
    end

    def workbench_panel(panel, state)
      case panel
      when "chat"
        { "status" => "planned", "summary" => "Local chat/command log placeholder; no network or AI calls are made by this static export." }
      when "plan_artifacts"
        { "status" => state ? "ready" : "blocked", "artifacts" => workbench_artifact_summaries(state) }
      when "design_candidates"
        { "status" => workbench_design_candidates(state).empty? ? "empty" : "ready", "candidates" => workbench_design_candidates(state) }
      when "selected_design"
        workbench_selected_design(state)
      when "preview"
        { "status" => latest_preview_metadata ? "ready" : "empty", "latest" => workbench_safe_metadata(latest_preview_metadata) }
      when "file_tree"
        { "status" => "ready", "entries" => workbench_file_tree }
      when "qa_results"
        { "status" => workbench_latest_json(".ai-web/qa/results/*.json") ? "ready" : "empty", "latest" => workbench_latest_json(".ai-web/qa/results/*.json") }
      when "visual_critique"
        path = state&.dig("qa", "latest_visual_critique") || latest_visual_critique_artifact
        { "status" => path ? "ready" : "empty", "latest" => path ? workbench_json_summary(path) : nil }
      when "run_timeline"
        { "status" => "ready", "runs" => workbench_run_timeline }
      else
        { "status" => "planned" }
      end
    end

    def workbench_artifact_summaries(state)
      return [] unless state

      (state["artifacts"] || {}).sort.map do |name, meta|
        meta = {} unless meta.is_a?(Hash)
        path = meta["path"].to_s
        next if workbench_excluded_path?(path)

        full = File.join(root, path)
        {
          "id" => name,
          "path" => path,
          "status" => meta["status"],
          "exists" => File.exist?(full),
          "directory" => File.directory?(full),
          "size_bytes" => File.file?(full) ? File.size(full) : nil
        }
      end.compact
    end

    def workbench_design_candidates(state)
      refs = Array(state&.dig("design_candidates", "candidates"))
      refs.map do |candidate|
        next unless candidate.is_a?(Hash)
        path = candidate["path"].to_s
        next if workbench_excluded_path?(path)
        full = File.join(root, path)
        candidate.slice("id", "path", "status").merge(
          "exists" => File.exist?(full),
          "size_bytes" => File.file?(full) ? File.size(full) : nil
        )
      end.compact
    end

    def workbench_selected_design(state)
      selected = state&.dig("design_candidates", "selected_candidate")
      design_md = File.join(aiweb_dir, "DESIGN.md")
      selected_md = File.join(aiweb_dir, "design-candidates", "selected.md")
      {
        "status" => selected.to_s.empty? ? "empty" : "ready",
        "selected_candidate" => selected,
        "design_md" => { "path" => ".ai-web/DESIGN.md", "exists" => File.file?(design_md), "substantive" => File.file?(design_md) && !stub_file?(design_md) },
        "selected_notes" => { "path" => ".ai-web/design-candidates/selected.md", "exists" => File.file?(selected_md) }
      }
    end

    def workbench_file_tree
      entries = []
      return entries unless File.directory?(root)

      Find.find(root) do |path|
        rel = relative(path)
        next if rel.empty?
        if workbench_excluded_path?(rel)
          Find.prune if File.directory?(path)
          next
        end
        entries << {
          "path" => rel,
          "type" => File.directory?(path) ? "directory" : "file",
          "size_bytes" => File.file?(path) ? File.size(path) : nil
        }
        Find.prune if entries.length >= 200
      end
      entries
    end

    def workbench_run_timeline
      Dir.glob(File.join(aiweb_dir, "runs", "*", "*.json")).sort.last(20).map do |path|
        workbench_json_summary(relative(path))
      end.compact
    end

    def workbench_latest_json(pattern)
      path = Dir.glob(File.join(root, pattern)).sort.last
      path ? workbench_json_summary(relative(path)) : nil
    end

    def workbench_json_summary(path)
      return nil if workbench_excluded_path?(path)

      full = File.expand_path(path, root)
      data = JSON.parse(File.read(full))
      summary = workbench_safe_metadata(data)
      summary["path"] = relative(full)
      summary["size_bytes"] = File.size(full) if File.file?(full)
      summary
    rescue JSON::ParserError, SystemCallError
      { "path" => path, "status" => "unreadable" }
    end

    def workbench_safe_metadata(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), memo|
          key = key.to_s
          next if key.match?(/secret|token|password|api[_-]?key|credential/i)
          next if workbench_excluded_path?(item.to_s)

          memo[key] = workbench_safe_metadata(item)
        end
      when Array
        value.first(20).map { |item| workbench_safe_metadata(item) }
      when String
        workbench_excluded_path?(value) ? "[excluded]" : value[0, 300]
      else
        value
      end
    end

    def workbench_excluded_path?(path)
      value = path.to_s
      return true if value.empty? && path
      parts = value.split(/[\\\/]+/)
      return true if parts.any? { |part| part == ".env" || part.start_with?(".env.") }

      normalized = value.sub(%r{\A\./}, "")
      WORKBENCH_FILE_TREE_EXCLUDES.any? do |excluded|
        normalized == excluded || normalized.start_with?(excluded + "/")
      end
    end

    def workbench_existing_conflicts(paths, manifest)
      index_path = File.join(root, paths["index_html"])
      manifest_path = File.join(root, paths["manifest_json"])
      conflicts = []
      conflicts << paths["index_html"] if File.file?(index_path) && File.read(index_path) != workbench_html(manifest)
      conflicts << paths["manifest_json"] if File.file?(manifest_path) && File.read(manifest_path) != JSON.pretty_generate(manifest) + "\n"
      conflicts
    end

    def workbench_html(manifest)
      panels = manifest.fetch("panels").map do |panel|
        name = panel["id"].to_s
        "<section class=\"panel\"><h2>#{CGI.escapeHTML(name.tr("_", " ").split.map(&:capitalize).join(" "))}</h2><pre>#{CGI.escapeHTML(JSON.pretty_generate(panel))}</pre></section>"
      end.join("\n")
      controls = manifest.fetch("controls").map do |control|
        "<li><code>#{CGI.escapeHTML(control["command"])}</code><span>#{CGI.escapeHTML(control["label"])}</span></li>"
      end.join("\n")
      <<~HTML
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>AI Web Director Workbench</title>
          <style>
            :root { color-scheme: light dark; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
            body { margin: 0; background: #0f172a; color: #e2e8f0; }
            header { padding: 32px; border-bottom: 1px solid #334155; background: linear-gradient(135deg, #111827, #1e293b); }
            main { display: grid; grid-template-columns: minmax(220px, 320px) 1fr; gap: 20px; padding: 24px; }
            aside, .panel { border: 1px solid #334155; border-radius: 16px; background: #111827; box-shadow: 0 18px 50px rgba(0, 0, 0, 0.25); }
            aside { padding: 20px; align-self: start; position: sticky; top: 16px; }
            .grid { display: grid; gap: 20px; }
            .panel { padding: 20px; overflow: hidden; }
            h1, h2 { margin: 0 0 12px; }
            p { color: #94a3b8; }
            ul { list-style: none; padding: 0; display: grid; gap: 12px; }
            li { display: grid; gap: 4px; padding: 12px; border: 1px solid #334155; border-radius: 12px; background: #0f172a; }
            code, pre { white-space: pre-wrap; word-break: break-word; color: #bfdbfe; }
            pre { max-height: 360px; overflow: auto; padding: 12px; border-radius: 12px; background: #020617; }
          </style>
        </head>
        <body>
          <header>
            <h1>AI Web Director Workbench</h1>
            <p>Status: #{CGI.escapeHTML(manifest["status"])} · Manifest: #{CGI.escapeHTML(manifest.dig("paths", "manifest_json"))}</p>
          </header>
          <main>
            <aside>
              <h2>Declarative controls</h2>
              <ul>#{controls}</ul>
              <p>Controls describe approved CLI commands only. This static UI does not directly mutate .ai-web/state.yaml.</p>
            </aside>
            <div class="grid">#{panels}</div>
          </main>
        </body>
        </html>
      HTML
    end

    def build_blocked_payload(state, blockers, dry_run:)
      build_payload(
        state: state,
        metadata: {
          "schema_version" => 1,
          "status" => "blocked",
          "command" => "pnpm build",
          "dry_run" => dry_run,
          "blocking_issues" => blockers
        },
        changed_files: [],
        action_taken: "scaffold build blocked",
        blocking_issues: blockers,
        next_action: "resolve runtime-plan blockers, then rerun aiweb build"
      )
    end

    def build_payload(state:, metadata:, changed_files:, action_taken:, blocking_issues:, next_action:)
      {
        "schema_version" => 1,
        "current_phase" => state&.dig("phase", "current"),
        "action_taken" => action_taken,
        "changed_files" => changed_files,
        "blocking_issues" => blocking_issues,
        "missing_artifacts" => [],
        "build" => metadata,
        "next_action" => next_action
      }
    end

    def build_run_metadata(run_id:, status:, command:, started_at:, finished_at:, exit_code:, stdout_log:, stderr_log:, metadata_path:, blocking_issues:, dry_run:)
      output_path = File.join(root, "dist")
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "command" => command,
        "cwd" => root,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "exit_code" => exit_code,
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "metadata_path" => metadata_path,
        "build_output_path" => File.directory?(output_path) ? "dist" : nil,
        "dry_run" => dry_run,
        "blocking_issues" => blocking_issues
      }
    end

    def build_next_action(status)
      case status
      when "passed" then "continue to the next approved roadmap stage; preview/QA/repair are intentionally outside aiweb build"
      when "blocked" then "resolve the blocked local build precondition, then rerun aiweb build"
      else "inspect .ai-web/runs build logs, fix the scaffold, then rerun aiweb build"
      end
    end

    def preview_blocked_payload(state, blockers, dry_run:)
      preview_payload(
        state: state,
        metadata: {
          "schema_version" => 1,
          "status" => "blocked",
          "command" => "pnpm dev --host 127.0.0.1",
          "dry_run" => dry_run,
          "blocking_issues" => blockers
        },
        changed_files: [],
        action_taken: "scaffold preview blocked",
        blocking_issues: blockers,
        next_action: "resolve runtime-plan blockers, then rerun aiweb preview"
      )
    end

    def preview_already_running_payload(state, metadata, dry_run:)
      payload_metadata = metadata.merge(
        "status" => "already_running",
        "dry_run" => dry_run,
        "blocking_issues" => []
      )
      preview_payload(
        state: state,
        metadata: payload_metadata,
        changed_files: [],
        action_taken: "scaffold preview already running",
        blocking_issues: [],
        next_action: "open #{payload_metadata["url"] || payload_metadata["preview_url"]} or run aiweb preview --stop before starting another preview"
      )
    end

    def preview_payload(state:, metadata:, changed_files:, action_taken:, blocking_issues:, next_action:)
      {
        "schema_version" => 1,
        "current_phase" => state&.dig("phase", "current"),
        "action_taken" => action_taken,
        "changed_files" => changed_files,
        "blocking_issues" => blocking_issues,
        "missing_artifacts" => [],
        "preview" => metadata,
        "next_action" => next_action
      }
    end

    def qa_playwright_payload(state:, metadata:, changed_files:, action_taken:, blocking_issues:, next_action:)
      {
        "schema_version" => 1,
        "current_phase" => state&.dig("phase", "current"),
        "action_taken" => action_taken,
        "changed_files" => changed_files,
        "blocking_issues" => blocking_issues,
        "missing_artifacts" => [],
        "playwright_qa" => metadata,
        "next_action" => next_action
      }
    end

    def qa_playwright_blocked_payload(state, blockers, dry_run:, command:, target:)
      qa_playwright_payload(
        state: state,
        metadata: {
          "schema_version" => 1,
          "status" => "blocked",
          "command" => command,
          "url" => target && target["url"],
          "dry_run" => dry_run,
          "blocking_issues" => blockers
        },
        changed_files: [],
        action_taken: "playwright QA blocked",
        blocking_issues: blockers,
        next_action: "resolve Playwright QA blockers, then rerun aiweb qa-playwright"
      ).tap do |payload|
        payload["status"] = "error"
        payload["error"] = { "message" => blockers.join("; ") }
      end
    end

    def qa_playwright_run_metadata(run_id:, task_id:, status:, command:, started_at:, finished_at:, exit_code:, target:, spec_path:, stdout_log:, stderr_log:, result_path:, metadata_path:, blocking_issues:, dry_run:)
      adapter = browser_qa_adapter(load_state_if_present)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "task_id" => task_id,
        "status" => status,
        "command" => command,
        "cwd" => root,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "exit_code" => exit_code,
        "url" => target["url"],
        "preview_url" => target["url"],
        "preview_run_id" => target["preview_run_id"],
        "spec_path" => spec_path,
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "result_path" => result_path,
        "metadata_path" => metadata_path,
        "provider" => adapter["provider"],
        "evidence_schema" => adapter["evidence_schema"],
        "allowed_hosts" => Array(adapter["allowed_hosts"]),
        "file_access" => adapter["file_access"],
        "dry_run" => dry_run,
        "blocking_issues" => blocking_issues
      }
    end

    def qa_playwright_command(spec_path)
      parts = ["pnpm", "exec", "playwright", "test"]
      parts << spec_path unless spec_path.to_s.empty?
      parts << "--reporter=json"
      parts.join(" ")
    end

    def qa_playwright_executable_path
      path = File.join(root, "node_modules", ".bin", "playwright")
      File.executable?(path) && !File.directory?(path) ? path : nil
    end

    def browser_qa_adapter(state)
      adapter = state&.dig("adapters", "browser_qa")
      adapter = {} unless adapter.is_a?(Hash)
      {
        "provider" => adapter["provider"] || "playwright_script",
        "allowed_hosts" => Array(adapter["allowed_hosts"]).empty? ? %w[localhost 127.0.0.1] : Array(adapter["allowed_hosts"]),
        "evidence_schema" => adapter["evidence_schema"] || "qa-result-v1",
        "file_access" => adapter["file_access"] || "workspace_only"
      }
    end

    def qa_playwright_target(url:, preview:)
      target_url = url.to_s.strip
      target_url = (preview && (preview["preview_url"] || preview["url"]).to_s) if target_url.empty?
      return nil if target_url.empty?

      {
        "url" => target_url,
        "preview_run_id" => preview && preview["run_id"],
        "server_command" => preview ? preview["command"].to_s : "external local preview (--force)",
        "source" => url.to_s.strip.empty? ? "recorded_preview" : "explicit_url"
      }
    end

    def qa_playwright_target_blockers(state, target, preview:, force:)
      blockers = []
      adapter = browser_qa_adapter(state)
      unless target
        blockers << "No running local preview was found; run aiweb preview first and keep it running before Playwright QA, or pass --url with an explicit local http://localhost or http://127.0.0.1 preview URL."
        return blockers
      end
      begin
        uri = URI.parse(target["url"].to_s)
        host = uri.host.to_s
        unless uri.scheme == "http" && %w[localhost 127.0.0.1].include?(host)
          blockers << "Playwright QA may only target local http preview URLs on localhost or 127.0.0.1; found #{target["url"].inspect}."
        end
        unless adapter.fetch("allowed_hosts").include?(host)
          blockers << "Preview host #{host.inspect} is not in adapters.browser_qa.allowed_hosts #{adapter.fetch("allowed_hosts").inspect}."
        end
      rescue URI::InvalidURIError
        blockers << "Preview URL #{target["url"].inspect} is not a valid URI."
      end

      if adapter["file_access"] == "unrestricted"
        blockers << "Playwright QA file_access must be workspace_only or explicit_paths, not unrestricted."
      end
      blockers
    end

    def qa_playwright_spec
      <<~JS
        const { test, expect } = require('@playwright/test');

        test('AI Web Director PR11 smoke', async ({ page }) => {
          const url = process.env.PLAYWRIGHT_BASE_URL;
          if (!url) throw new Error('PLAYWRIGHT_BASE_URL is required');
          await page.goto(url);
          await expect(page.locator('body')).toBeVisible();
        });
      JS
    end

    def qa_playwright_task_id(task_id, run_id)
      value = task_id.to_s.strip
      value.empty? ? run_id : value
    end

    def qa_playwright_result(task_id:, status:, started_at:, finished_at:, duration_minutes:, timed_out:, target:, checks:, evidence:, console_errors:, network_errors:)
      {
        "schema_version" => 1,
        "task_id" => task_id,
        "status" => status,
        "started_at" => started_at || now,
        "finished_at" => finished_at || now,
        "duration_minutes" => duration_minutes,
        "timed_out" => timed_out,
        "environment" => {
          "url" => target["url"],
          "browser" => "playwright",
          "browser_version" => "unknown",
          "viewport" => { "width" => 1440, "height" => 900, "name" => "desktop" },
          "commit_sha" => git_commit_sha,
          "server_command" => target["server_command"].to_s
        },
        "checks" => checks,
        "evidence" => evidence,
        "console_errors" => console_errors,
        "network_errors" => network_errors,
        "recommended_action" => status == "passed" ? "advance" : "create_fix_packet",
        "created_fix_task" => nil
      }
    end

    def qa_playwright_pending_check
      {
        "id" => "QA-PLAYWRIGHT",
        "category" => "flow",
        "severity" => "high",
        "status" => "pending",
        "expected" => "Playwright QA runs only against a local preview URL under the configured browser QA adapter contract.",
        "actual" => "Dry run only; no files, browsers, or Node processes are started.",
        "evidence" => [],
        "notes" => "No files or browser processes are created during --dry-run.",
        "accepted_risk_id" => nil
      }
    end

    def qa_playwright_status_check(status, blocking_issues, stdout_path, stderr_path)
      {
        "id" => "QA-PLAYWRIGHT",
        "category" => "flow",
        "severity" => "high",
        "status" => status == "passed" ? "passed" : status,
        "expected" => "Local Playwright QA completes without installs, builds, repairs, deploys, external hosts, or .env mutation.",
        "actual" => blocking_issues.empty? ? "Playwright command completed successfully." : blocking_issues.join("; "),
        "evidence" => [relative(stdout_path), relative(stderr_path)],
        "notes" => "Runner command uses node_modules/.bin/playwright with PLAYWRIGHT_BASE_URL and executes from the project root.",
        "accepted_risk_id" => nil
      }
    end

    def qa_playwright_next_action(status)
      case status
      when "passed" then "use the recorded qa-result-v1 evidence for QA gate review or rerun aiweb qa-report --from if a phase report is required"
      when "blocked" then "resolve the blocked local Playwright QA precondition, then rerun aiweb qa-playwright"
      else "inspect .ai-web/runs Playwright QA logs, fix the scaffold or tests, then rerun aiweb qa-playwright"
      end
    end

    def qa_static_browser_tool(key:, label:, run_prefix:, executable:, result_check_id:, category:, severity:, url:, task_id:, force:, dry_run:)
      assert_initialized!

      state, state_error = runtime_state_snapshot
      ensure_scaffold_state_defaults!(state) if state
      scaffold = runtime_scaffold_summary(state)
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary
      missing_files = SCAFFOLD_PROFILE_D_REQUIRED_FILES.reject { |path| File.exist?(File.join(root, path)) }
      blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files)
      return qa_static_blocked_payload(key, label, state, blockers, dry_run: dry_run, command: qa_static_command(executable, nil, nil), target: nil) unless blockers.empty?

      preview = running_preview_metadata
      target = qa_playwright_target(url: url, preview: preview)
      target_blockers = qa_playwright_target_blockers(state, target, preview: preview, force: force)
      return qa_static_blocked_payload(key, label, state, target_blockers, dry_run: dry_run, command: qa_static_command(executable, target && target["url"], nil), target: target) unless target_blockers.empty?

      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      run_id = "#{run_prefix}-#{timestamp}"
      result_task_id = qa_playwright_task_id(task_id, run_id)
      run_dir = File.join(aiweb_dir, "runs", run_id)
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      tool_report_path = File.join(run_dir, "#{run_prefix}.json")
      result_path = File.join(aiweb_dir, "qa", "results", "qa-#{timestamp}-#{slug(result_task_id)}.json")
      metadata_path = File.join(run_dir, "#{run_prefix}.json")
      metadata_path = File.join(run_dir, "#{run_prefix}-metadata.json") if metadata_path == tool_report_path
      command = qa_static_command(executable, target["url"], relative(tool_report_path))
      planned_changes = [relative(run_dir), relative(stdout_path), relative(stderr_path), relative(tool_report_path), relative(result_path), relative(metadata_path)]

      if dry_run
        result = qa_static_result(
          task_id: result_task_id,
          status: "pending",
          started_at: nil,
          finished_at: nil,
          duration_minutes: 0,
          timed_out: false,
          target: target,
          check: qa_static_pending_check(result_check_id, label, category, severity),
          evidence: [],
          browser: executable
        )
        validate_qa_result!(result)
        metadata = qa_static_run_metadata(
          run_id: run_id,
          task_id: result_task_id,
          status: "dry_run",
          command: command,
          started_at: nil,
          finished_at: nil,
          exit_code: nil,
          target: target,
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          tool_report: relative(tool_report_path),
          result_path: relative(result_path),
          metadata_path: relative(metadata_path),
          blocking_issues: [],
          dry_run: true
        )
        metadata["qa_result"] = result
        return qa_static_payload(
          key: key,
          state: state,
          metadata: metadata,
          changed_files: planned_changes,
          action_taken: "planned #{label} QA",
          blocking_issues: [],
          next_action: "rerun aiweb #{key.tr('_', '-').sub('-qa', '') == 'a11y' ? 'qa-a11y' : 'qa-lighthouse'} without --dry-run to execute local #{label} QA against #{target["url"]}"
        )
      end

      changes = []
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << relative(run_dir)
        started_at = Time.now.utc
        status = "blocked"
        exit_code = nil
        blocking_issues = []
        stdout = ""
        stderr = ""

        if qa_static_executable_path(executable).nil?
          blocking_issues << "Local #{label} executable node_modules/.bin/#{executable} is missing; install project dependencies outside aiweb #{key.tr('_', '-')}, then rerun."
          stderr = blocking_issues.join("\n") + "\n"
        elsif executable_path("pnpm").nil?
          blocking_issues << "pnpm executable is missing; install project dependencies outside aiweb #{key.tr('_', '-')}, then rerun."
          stderr = blocking_issues.join("\n") + "\n"
        else
          stdout, stderr, process_status = Open3.capture3({ "AIWEB_QA_URL" => target["url"] }, *qa_static_command_parts(executable, target["url"], relative(tool_report_path)), chdir: root)
          exit_code = process_status.exitstatus
          status = process_status.success? ? "passed" : "failed"
          blocking_issues << "#{command} failed with exit code #{exit_code}" unless process_status.success?
        end

        finished_at = Time.now.utc
        duration_minutes = ((finished_at - started_at) / 60.0).round(4)
        changes << write_file(stdout_path, stdout, false)
        changes << write_file(stderr_path, stderr, false)
        changes << write_file(tool_report_path, stdout.to_s.empty? ? "{}\n" : stdout, false) unless File.exist?(tool_report_path)
        result = qa_static_result(
          task_id: result_task_id,
          status: status,
          started_at: started_at.iso8601,
          finished_at: finished_at.iso8601,
          duration_minutes: duration_minutes,
          timed_out: false,
          target: target,
          check: qa_static_status_check(result_check_id, label, category, severity, status, blocking_issues, stdout_path, stderr_path, tool_report_path),
          evidence: [relative(stdout_path), relative(stderr_path), relative(tool_report_path)],
          browser: executable
        )
        validate_qa_result!(result)
        changes << write_json(result_path, result, false)
        metadata = qa_static_run_metadata(
          run_id: run_id,
          task_id: result_task_id,
          status: status,
          command: command,
          started_at: started_at.iso8601,
          finished_at: finished_at.iso8601,
          exit_code: exit_code,
          target: target,
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          tool_report: relative(tool_report_path),
          result_path: relative(result_path),
          metadata_path: relative(metadata_path),
          blocking_issues: blocking_issues,
          dry_run: false
        )
        changes << write_json(metadata_path, metadata, false)
        state["qa"] ||= {}
        state["qa"]["last_result"] = relative(result_path)
        add_decision!(state, key, "Recorded #{label} QA result #{result["status"]} for #{result["task_id"]}")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)
        qa_static_payload(
          key: key,
          state: state,
          metadata: metadata,
          changed_files: compact_changes(changes),
          action_taken: status == "blocked" ? "#{label} QA blocked" : "ran #{label} QA",
          blocking_issues: blocking_issues,
          next_action: qa_static_next_action(key, label, status)
        )
      end
    end

    def qa_static_payload(key:, state:, metadata:, changed_files:, action_taken:, blocking_issues:, next_action:)
      {
        "schema_version" => 1,
        "current_phase" => state&.dig("phase", "current"),
        "action_taken" => action_taken,
        "changed_files" => changed_files,
        "blocking_issues" => blocking_issues,
        "missing_artifacts" => [],
        key => metadata,
        "next_action" => next_action
      }
    end

    def qa_static_blocked_payload(key, label, state, blockers, dry_run:, command:, target:)
      qa_static_payload(
        key: key,
        state: state,
        metadata: {
          "schema_version" => 1,
          "status" => "blocked",
          "command" => command,
          "url" => target && target["url"],
          "dry_run" => dry_run,
          "blocking_issues" => blockers
        },
        changed_files: [],
        action_taken: "#{label} QA blocked",
        blocking_issues: blockers,
        next_action: "resolve #{label} QA blockers, then rerun aiweb #{key == "a11y_qa" ? "qa-a11y" : "qa-lighthouse"}"
      )
    end

    def qa_static_run_metadata(run_id:, task_id:, status:, command:, started_at:, finished_at:, exit_code:, target:, stdout_log:, stderr_log:, tool_report:, result_path:, metadata_path:, blocking_issues:, dry_run:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "task_id" => task_id,
        "status" => status,
        "command" => command,
        "cwd" => root,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "exit_code" => exit_code,
        "url" => target["url"],
        "preview_url" => target["url"],
        "preview_run_id" => target["preview_run_id"],
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "tool_report" => tool_report,
        "result_path" => result_path,
        "metadata_path" => metadata_path,
        "dry_run" => dry_run,
        "blocking_issues" => blocking_issues
      }
    end

    def qa_static_command(executable, url, report_path)
      qa_static_command_parts(executable, url, report_path).join(" ")
    end

    def qa_static_command_parts(executable, url, report_path)
      parts = ["pnpm", "exec", executable]
      parts << url unless url.to_s.empty?
      if executable == "lighthouse"
        parts += ["--output=json", "--output-path=#{report_path}", "--quiet", "--chrome-flags=--headless"] unless report_path.to_s.empty?
      else
        parts << "--reporter=json"
      end
      parts
    end

    def qa_static_executable_path(executable)
      path = File.join(root, "node_modules", ".bin", executable)
      File.executable?(path) && !File.directory?(path) ? path : nil
    end

    def qa_static_result(task_id:, status:, started_at:, finished_at:, duration_minutes:, timed_out:, target:, check:, evidence:, browser:)
      {
        "schema_version" => 1,
        "task_id" => task_id,
        "status" => status,
        "started_at" => started_at || now,
        "finished_at" => finished_at || now,
        "duration_minutes" => duration_minutes,
        "timed_out" => timed_out,
        "environment" => {
          "url" => target["url"],
          "browser" => browser,
          "browser_version" => "unknown",
          "viewport" => { "width" => 1440, "height" => 900, "name" => "desktop" },
          "commit_sha" => git_commit_sha,
          "server_command" => target["server_command"].to_s
        },
        "checks" => [check],
        "evidence" => evidence,
        "console_errors" => [],
        "network_errors" => [],
        "recommended_action" => status == "passed" ? "advance" : "create_fix_packet",
        "created_fix_task" => nil
      }
    end

    def qa_static_pending_check(id, label, category, severity)
      {
        "id" => id,
        "category" => category,
        "severity" => severity,
        "status" => "pending",
        "expected" => "#{label} QA runs only against a local preview URL under the configured browser QA adapter contract.",
        "actual" => "Dry run only; no files, browsers, Node processes, installs, repairs, or deploys are started.",
        "evidence" => [],
        "notes" => "No files or browser processes are created during --dry-run.",
        "accepted_risk_id" => nil
      }
    end

    def qa_static_status_check(id, label, category, severity, status, blocking_issues, stdout_path, stderr_path, tool_report_path)
      {
        "id" => id,
        "category" => category,
        "severity" => severity,
        "status" => status == "passed" ? "passed" : status,
        "expected" => "Local #{label} QA completes without installs, builds, repairs, deploys, external hosts, or .env mutation.",
        "actual" => blocking_issues.empty? ? "#{label} command completed successfully." : blocking_issues.join("; "),
        "evidence" => [relative(stdout_path), relative(stderr_path), relative(tool_report_path)],
        "notes" => "Runner command uses node_modules/.bin tooling through pnpm exec from the project root.",
        "accepted_risk_id" => nil
      }
    end

    def qa_static_next_action(key, label, status)
      command = key == "a11y_qa" ? "qa-a11y" : "qa-lighthouse"
      case status
      when "passed" then "use the recorded qa-result-v1 evidence for QA gate review or rerun aiweb qa-report --from if a phase report is required"
      when "blocked" then "resolve the blocked local #{label} QA precondition, then rerun aiweb #{command}"
      else "inspect .ai-web/runs #{label} QA logs, fix the scaffold or tests, then rerun aiweb #{command}"
      end
    end

    def git_commit_sha
      stdout, _stderr, status = Open3.capture3("git", "rev-parse", "HEAD", chdir: root)
      status.success? ? stdout.strip : "unknown"
    rescue StandardError
      "unknown"
    end

    def preview_run_metadata(run_id:, status:, command:, started_at:, finished_at:, exit_code:, pid:, port:, url:, stdout_log:, stderr_log:, metadata_path:, blocking_issues:, dry_run:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "command" => command,
        "cwd" => root,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "exit_code" => exit_code,
        "pid" => pid,
        "port" => port,
        "url" => url,
        "preview_url" => url,
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "metadata_path" => metadata_path,
        "dry_run" => dry_run,
        "blocking_issues" => blocking_issues
      }
    end

    def preview_next_action(status)
      case status
      when "running" then "open the preview_url locally; run aiweb preview --stop when finished"
      when "stopped" then "rerun aiweb preview to start a new local preview"
      when "not_running" then "run aiweb preview to start the local preview"
      when "blocked" then "resolve the blocked local preview precondition, then rerun aiweb preview"
      else "inspect .ai-web/runs preview logs, fix the scaffold, then rerun aiweb preview"
      end
    end

    def preview_command(scaffold)
      base = scaffold["dev_command"].to_s.strip
      base = "pnpm dev" if base.empty?
      base.match?(/--host(?:\s|=)/) ? base : "#{base} --host 127.0.0.1"
    end

    def preview_port(command)
      match = command.match(/(?:--port(?:=|\s+))(\d+)/)
      match ? match[1].to_i : 4321
    end

    def running_preview_metadata
      preview_metadata_files.reverse_each do |path|
        metadata = read_preview_metadata(path)
        next unless metadata
        next unless metadata["status"] == "running"

        pid = metadata["pid"].to_i
        next unless live_process?(pid)

        metadata["metadata_path"] ||= relative(path)
        return metadata
      end
      nil
    end

    def latest_preview_metadata
      preview_metadata_files.reverse_each do |path|
        metadata = read_preview_metadata(path)
        next unless metadata

        metadata["metadata_path"] ||= relative(path)
        return [metadata, path]
      end
      nil
    end

    def preview_metadata_files
      Dir.glob(File.join(aiweb_dir, "runs", "preview-*", "preview.json")).sort
    end

    def read_preview_metadata(path)
      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def live_process?(pid)
      return false unless pid.positive?

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def stop_preview(dry_run:)
      state, = runtime_state_snapshot
      latest = latest_preview_metadata
      metadata, path = latest if latest
      live = metadata && metadata["status"] == "running" && live_process?(metadata["pid"].to_i)

      if dry_run
        planned = metadata ? [metadata["metadata_path"] || relative(path)] : []
        status = live ? "dry_run" : "not_running"
        preview = (metadata || { "schema_version" => 1 }).merge(
          "status" => status,
          "dry_run" => true,
          "would_stop_pid" => live ? metadata["pid"] : nil,
          "blocking_issues" => []
        )
        return preview_payload(
          state: state,
          metadata: preview,
          changed_files: planned,
          action_taken: live ? "planned scaffold preview stop" : "scaffold preview not running",
          blocking_issues: [],
          next_action: live ? "rerun aiweb preview --stop without --dry-run to stop the recorded preview pid" : preview_next_action("not_running")
        )
      end

      return preview_payload(
        state: state,
        metadata: { "schema_version" => 1, "status" => "not_running", "dry_run" => false, "blocking_issues" => [] },
        changed_files: [],
        action_taken: "scaffold preview not running",
        blocking_issues: [],
        next_action: preview_next_action("not_running")
      ) unless live

      mutation(dry_run: false) do
        pid = metadata["pid"].to_i
        Process.kill("TERM", pid)
        begin
          Timeout.timeout(5) do
            sleep 0.05 while live_process?(pid)
          end
        rescue Timeout::Error
          # Leave the process alone after TERM timeout; metadata still records the stop request.
        end
        stopped = metadata.merge(
          "status" => "stopped",
          "pid" => nil,
          "stopped_pid" => pid,
          "finished_at" => now,
          "dry_run" => false,
          "blocking_issues" => []
        )
        write_json(path, stopped, false)
        preview_payload(
          state: state,
          metadata: stopped,
          changed_files: [relative(path)],
          action_taken: "stopped scaffold preview",
          blocking_issues: [],
          next_action: preview_next_action("stopped")
        )
      end
    end

    def executable_path(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }.find { |path| File.executable?(path) && !File.directory?(path) }
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

      approved = quality.dig("quality", "approved")
      approved == true ? [] : ["quality contract must be explicitly approved in .ai-web/quality.yaml (quality.approved: true)"]
    rescue Psych::SyntaxError => e
      ["cannot parse quality.yaml: #{e.message}"]
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


    def runtime_state_snapshot
      return [nil, "Project is not initialized; run aiweb init --profile D or aiweb start before checking runtime readiness."] unless File.file?(state_path)

      state = YAML.load_file(state_path)
      return [state, nil] if state.is_a?(Hash)

      [nil, ".ai-web/state.yaml must be a YAML mapping; repair state before checking runtime readiness."]
    rescue Psych::Exception => e
      [nil, "Cannot parse .ai-web/state.yaml: #{e.message}"]
    end

    def runtime_scaffold_summary(state)
      implementation = state&.fetch("implementation", {}) || {}
      metadata_path = runtime_scaffold_metadata_path(implementation["scaffold_metadata_path"])
      {
        "scaffold_created" => implementation["scaffold_created"] == true,
        "profile" => implementation["scaffold_profile"] || implementation["stack_profile"],
        "framework" => implementation["scaffold_framework"],
        "package_manager" => implementation["scaffold_package_manager"],
        "dev_command" => implementation["scaffold_dev_command"],
        "build_command" => implementation["scaffold_build_command"],
        "metadata_path" => metadata_path.fetch("path"),
        "metadata_path_state_value" => metadata_path.fetch("state_value"),
        "metadata_path_safe" => metadata_path.fetch("safe"),
        "metadata_path_error" => metadata_path.fetch("error")
      }
    end

    def runtime_scaffold_metadata_path(state_value)
      raw = state_value.to_s.strip
      return { "path" => SCAFFOLD_PROFILE_D_METADATA_PATH, "state_value" => nil, "safe" => true, "error" => nil } if raw.empty?

      normalized = raw.tr("\\", "/")
      normalized = normalized.sub(%r{\A(?:\./)+}, "")
      parts = normalized.split("/")
      error = if raw.start_with?("/") || raw.match?(%r{\A[A-Za-z]:[\\/]})
                "scaffold metadata path must be relative to the project .ai-web directory, not absolute"
              elsif parts.any? { |part| part == ".." }
                "scaffold metadata path must not contain traversal"
              elsif parts.any? { |part| part.start_with?(".env") }
                "scaffold metadata path must not reference .env files"
              elsif normalized != SCAFFOLD_PROFILE_D_METADATA_PATH
                "scaffold metadata path must be #{SCAFFOLD_PROFILE_D_METADATA_PATH}"
              end

      {
        "path" => normalized,
        "state_value" => raw,
        "safe" => error.nil?,
        "error" => error
      }
    end

    def runtime_metadata_summary(scaffold)
      relative_metadata_path = scaffold["metadata_path"]
      summary = {
        "path" => relative_metadata_path,
        "present" => false,
        "valid_json" => false,
        "profile" => nil,
        "framework" => nil,
        "package_manager" => nil,
        "dev_command" => nil,
        "build_command" => nil,
        "selected_candidate" => nil,
        "selected_candidate_path" => nil,
        "path_safe" => scaffold["metadata_path_safe"] == true,
        "error" => scaffold["metadata_path_error"]
      }
      return summary unless summary["path_safe"]

      path = File.join(root, relative_metadata_path)
      summary["present"] = File.file?(path)
      return summary unless File.file?(path)

      data = JSON.parse(File.read(path))
      unless data.is_a?(Hash)
        summary["error"] = "metadata must be a JSON object"
        return summary
      end

      summary.merge!(
        "valid_json" => true,
        "profile" => data["profile"],
        "framework" => data["framework"],
        "package_manager" => data["package_manager"],
        "dev_command" => data["dev_command"],
        "build_command" => data["build_command"],
        "selected_candidate" => data["selected_candidate"],
        "selected_candidate_path" => data["selected_candidate_path"]
      )
    rescue JSON::ParserError => e
      summary["error"] = "invalid JSON: #{e.message}"
      summary
    rescue SystemCallError => e
      summary["error"] = e.message
      summary
    end

    def runtime_design_summary(state, metadata)
      state_selected = state&.dig("design_candidates", "selected_candidate").to_s.strip
      metadata_selected = metadata["selected_candidate"].to_s.strip if metadata && metadata["valid_json"]
      metadata_selected ||= ""
      selected = state_selected.empty? ? metadata_selected : state_selected
      design_path = File.join(aiweb_dir, "DESIGN.md")
      selected_path = selected.empty? ? nil : selected_candidate_artifact_path_from_snapshot(state, selected)
      generated_reference = runtime_generated_design_reference_summary
      {
        "selected_candidate" => selected.empty? ? nil : selected,
        "state_selected_candidate" => state_selected.empty? ? nil : state_selected,
        "metadata_selected_candidate" => metadata_selected.empty? ? nil : metadata_selected,
        "generated_reference" => generated_reference,
        "selected_candidate_present" => selected_path ? File.file?(selected_path) : false,
        "selected_candidate_path" => selected_path ? relative(selected_path) : nil,
        "design_md_path" => ".ai-web/DESIGN.md",
        "design_md_present" => File.file?(design_path),
        "design_md_substantive" => File.file?(design_path) && !stub_file?(design_path)
      }
    end

    def runtime_generated_design_reference_summary
      path = File.join(root, "src/content/site.json")
      summary = {
        "path" => "src/content/site.json",
        "present" => File.file?(path),
        "valid_json" => false,
        "selected_candidate" => nil,
        "selected_candidate_path" => nil,
        "error" => nil
      }
      return summary unless File.file?(path)

      data = JSON.parse(File.read(path))
      unless data.is_a?(Hash)
        summary["error"] = "src/content/site.json must be a JSON object"
        return summary
      end

      summary.merge!(
        "valid_json" => true,
        "selected_candidate" => data["selected_candidate"],
        "selected_candidate_path" => data["selected_candidate_path"]
      )
    rescue JSON::ParserError => e
      summary["error"] = "invalid JSON: #{e.message}"
      summary
    rescue SystemCallError => e
      summary["error"] = e.message
      summary
    end

    def selected_candidate_artifact_path_from_snapshot(state, selected)
      ref = Array(state&.dig("design_candidates", "candidates")).find { |candidate| candidate.is_a?(Hash) && candidate["id"].to_s == selected }
      candidates = []
      candidates << File.join(root, ref["path"].to_s) if ref && !ref["path"].to_s.strip.empty?
      candidates << File.join(aiweb_dir, "design-candidates", "#{selected}.html")
      candidates << File.join(aiweb_dir, "design-candidates", "#{selected}.md")
      candidates.find { |path| File.file?(path) } || candidates.first
    end

    def runtime_package_json_summary
      path = File.join(root, "package.json")
      summary = {
        "path" => "package.json",
        "present" => File.file?(path),
        "valid_json" => false,
        "scripts" => runtime_expected_map(PROFILE_D_EXPECTED_SCRIPTS),
        "dependencies" => runtime_expected_map(PROFILE_D_EXPECTED_DEPENDENCIES.to_h { |name| [name, "present"] }),
        "error" => nil
      }
      return summary unless File.file?(path)

      data = JSON.parse(File.read(path))
      unless data.is_a?(Hash)
        summary["error"] = "package.json must be a JSON object"
        return summary
      end

      scripts = data["scripts"].is_a?(Hash) ? data["scripts"] : {}
      dependencies = data["dependencies"].is_a?(Hash) ? data["dependencies"] : {}
      summary["valid_json"] = true
      summary["scripts"] = PROFILE_D_EXPECTED_SCRIPTS.each_with_object({}) do |(name, expected), memo|
        actual = scripts[name]
        memo[name] = {
          "expected" => expected,
          "actual" => actual,
          "present" => !actual.to_s.empty?,
          "matches" => actual == expected
        }
      end
      summary["dependencies"] = PROFILE_D_EXPECTED_DEPENDENCIES.each_with_object({}) do |name, memo|
        actual = dependencies[name]
        memo[name] = {
          "expected" => "present",
          "actual" => actual,
          "present" => !actual.to_s.empty?
        }
      end
      summary
    rescue JSON::ParserError => e
      summary["error"] = "invalid JSON: #{e.message}"
      summary
    rescue SystemCallError => e
      summary["error"] = e.message
      summary
    end

    def runtime_expected_map(expected)
      expected.each_with_object({}) do |(name, value), memo|
        memo[name] = {
          "expected" => value,
          "actual" => nil,
          "present" => false,
          "matches" => false
        }
      end
    end

    def runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files)
      blockers = []
      blockers << state_error if state_error
      unless scaffold["scaffold_created"]
        blockers << "Scaffold has not been created; run aiweb scaffold --profile D after selecting a design candidate."
      end
      if scaffold["profile"].to_s != "D"
        blockers << "Runtime plan currently expects Profile D; run aiweb scaffold --profile D or repair implementation.scaffold_profile."
      end
      unless scaffold["metadata_path_safe"]
        blockers << "Unsafe scaffold metadata path #{scaffold["metadata_path_state_value"].inspect}: #{scaffold["metadata_path_error"]}. Runtime plan only reads #{SCAFFOLD_PROFILE_D_METADATA_PATH}."
      end
      blockers << "Scaffold metadata .ai-web/scaffold-profile-D.json is missing; rerun aiweb scaffold --profile D after reviewing existing files." if scaffold["metadata_path_safe"] && !metadata["present"]
      blockers << "Scaffold metadata #{metadata["path"]} is malformed: #{metadata["error"]}" if metadata["present"] && !metadata["valid_json"]
      runtime_expected_metadata_blockers(scaffold, metadata).each { |blocker| blockers << blocker } if metadata["valid_json"]
      runtime_selected_design_drift_blockers(design).each { |blocker| blockers << blocker }
      unless design["design_md_present"]
        blockers << "Design source .ai-web/DESIGN.md is missing; run aiweb design-system resolve or restore the approved design source."
      end
      if design["design_md_present"] && !design["design_md_substantive"]
        blockers << "Design source .ai-web/DESIGN.md is stub-like; provide substantive design constraints before runtime QA."
      end
      if design["selected_candidate"].to_s.empty?
        blockers << "No selected design candidate recorded; run aiweb design --candidates 3 then aiweb select-design candidate-01|candidate-02|candidate-03."
      elsif !design["selected_candidate_present"]
        blockers << "Selected design candidate artifact #{design["selected_candidate_path"] || design["selected_candidate"]} is missing; rerun aiweb design --candidates 3 or select an existing candidate."
      end
      missing_files.each do |path|
        blockers << "Required scaffold file #{path} is missing; rerun aiweb scaffold --profile D to complete safe missing files."
      end
      runtime_package_blockers(package_json).each { |blocker| blockers << blocker }
      blockers.compact.uniq
    end

    def runtime_expected_metadata_blockers(scaffold, metadata)
      expected = {
        "profile" => "D",
        "framework" => "Astro",
        "package_manager" => "pnpm",
        "dev_command" => "pnpm dev",
        "build_command" => "pnpm build"
      }
      expected.each_with_object([]) do |(key, value), blockers|
        actual = metadata[key]
        blockers << "Scaffold metadata #{key} should be #{value.inspect}, found #{actual.inspect}; rerun aiweb scaffold --profile D or repair metadata." unless actual == value
        state_actual = scaffold[key]
        next if state_actual.to_s.empty? || state_actual == actual

        blockers << "State scaffold #{key} (#{state_actual.inspect}) does not match metadata (#{actual.inspect}); repair .ai-web/state.yaml or rerun scaffold with reviewed force."
      end
    end

    def runtime_selected_design_drift_blockers(design)
      blockers = []
      state_selected = design["state_selected_candidate"].to_s.strip
      metadata_selected = design["metadata_selected_candidate"].to_s.strip
      generated = design.fetch("generated_reference", {})
      generated_selected = generated["selected_candidate"].to_s.strip

      if state_selected.empty? && !metadata_selected.empty?
        blockers << "Selected design drift: state design_candidates.selected_candidate is missing but scaffold metadata selected_candidate is #{metadata_selected.inspect}; reselect the intended candidate and rerun aiweb scaffold --profile D, or repair .ai-web/state.yaml."
      elsif !state_selected.empty? && metadata_selected.empty?
        blockers << "Selected design drift: state design_candidates.selected_candidate is #{state_selected.inspect} but scaffold metadata selected_candidate is missing; rerun aiweb scaffold --profile D or repair #{SCAFFOLD_PROFILE_D_METADATA_PATH}."
      elsif state_selected != metadata_selected
        blockers << "Selected design drift: state design_candidates.selected_candidate (#{state_selected.inspect}) does not match scaffold metadata selected_candidate (#{metadata_selected.inspect}); reselect the intended candidate and rerun aiweb scaffold --profile D, or repair .ai-web/state.yaml and #{SCAFFOLD_PROFILE_D_METADATA_PATH}."
      end

      if generated["present"] && !generated["valid_json"]
        blockers << "Generated scaffold content #{generated["path"]} is malformed: #{generated["error"]}; rerun aiweb scaffold --profile D after reviewing local edits."
      elsif generated["present"] && generated["valid_json"]
        expected = state_selected.empty? ? metadata_selected : state_selected
        if !expected.empty? && generated_selected.empty?
          blockers << "Selected design drift: generated scaffold content #{generated["path"]} selected_candidate is missing but selected design is #{expected.inspect}; rerun aiweb scaffold --profile D after reviewing generated content."
        elsif !expected.empty? && generated_selected != expected
          blockers << "Selected design drift: generated scaffold content #{generated["path"]} selected_candidate (#{generated_selected.inspect}) does not match selected design (#{expected.inspect}); rerun aiweb scaffold --profile D after reviewing generated content."
        end
        if !metadata_selected.empty? && !generated_selected.empty? && generated_selected != metadata_selected
          blockers << "Selected design drift: generated scaffold content #{generated["path"]} selected_candidate (#{generated_selected.inspect}) does not match scaffold metadata selected_candidate (#{metadata_selected.inspect}); rerun aiweb scaffold --profile D after reviewing generated content."
        end
      end

      blockers
    end

    def runtime_package_blockers(package_json)
      blockers = []
      unless package_json["present"]
        blockers << "package.json is missing; rerun aiweb scaffold --profile D before runtime tools."
        return blockers
      end
      unless package_json["valid_json"]
        blockers << "package.json is malformed: #{package_json["error"]}; fix JSON before runtime tools."
        return blockers
      end
      package_json.fetch("scripts").each do |name, status|
        unless status["matches"]
          blockers << "package.json script #{name.inspect} should be #{status["expected"].inspect}; found #{status["actual"].inspect}."
        end
      end
      package_json.fetch("dependencies").each do |name, status|
        blockers << "package.json dependency #{name.inspect} is missing; restore Profile D scaffold dependencies." unless status["present"]
      end
      blockers
    end

    def ensure_scaffold_state_defaults!(state)
      state["implementation"] ||= {}
      state["implementation"]["scaffold_created"] = false if state["implementation"]["scaffold_created"].nil?
      state["implementation"]["scaffold_profile"] ||= nil
      state["implementation"]["scaffold_framework"] ||= nil
      state["implementation"]["scaffold_package_manager"] ||= nil
      state["implementation"]["scaffold_dev_command"] ||= nil
      state["implementation"]["scaffold_build_command"] ||= nil
      state["implementation"]["scaffold_metadata_path"] ||= nil
      state
    end

    def apply_scaffold_state!(state, metadata)
      ensure_scaffold_state_defaults!(state)
      state["implementation"]["stack_profile"] = "D"
      state["implementation"]["scaffold_target"] = metadata.fetch("scaffold_target")
      state["implementation"]["scaffold_created"] = true
      state["implementation"]["scaffold_profile"] = metadata.fetch("profile")
      state["implementation"]["scaffold_framework"] = metadata.fetch("framework")
      state["implementation"]["scaffold_package_manager"] = metadata.fetch("package_manager")
      state["implementation"]["scaffold_dev_command"] = metadata.fetch("dev_command")
      state["implementation"]["scaffold_build_command"] = metadata.fetch("build_command")
      state["implementation"]["scaffold_metadata_path"] = ".ai-web/scaffold-profile-D.json"
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

    def preflight_scaffold_targets!(files, metadata_path:, force:)
      conflicts = scaffold_target_type_conflicts(files.keys + [relative(metadata_path)])
      return if conflicts.empty?

      raise UserError.new("scaffold profile D cannot write because directories conflict with required scaffold files: #{conflicts.join(", ")}. Remove or rename those directories before rerunning; --force only overwrites regular files and wrote no scaffold files.", 1)
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
        markdown.include?("| Candidate | Mood | Layout | Strengths | Tradeoffs |") &&
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
      inputs = %w[product.md brand.md content.md ia.md design-brief.md DESIGN.md].map do |name|
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
        Convert the selected visual direction into implementation-ready rules that preserve `.ai-web/DESIGN.md`: design tokens, typography scale, color palette, component recipes, layout constraints, `data-aiweb-id` hooks, and responsive behavior. Do not invent product scope beyond the approved artifacts. Preserve the product artifact's wrong-interpretations-to-avoid guidance when choosing first-screen layout and components. #{selected_note}

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

    def selected_design_markdown(selected_id)
      <<~MD
        # Selected Design Candidate

        Selected candidate: #{selected_id}
        Selected candidate path: .ai-web/design-candidates/#{selected_id}.html
        Selected at: #{now}

        ## Decision
        Use `#{selected_id}` as the review-selected visual direction for prompt and task-packet handoff. DESIGN.md remains the source of truth; `.ai-web/DESIGN.md` remains authoritative for route, tokens, components, visual contract hooks, and implementation constraints.

        ## Why This Candidate
        TODO: explain why this candidate best satisfies quality.yaml, `.ai-web/DESIGN.md`, first-view obligations, and product goals.

        ## Rejected Candidates
        - TODO: summarize tradeoffs from `.ai-web/design-candidates/comparison.md`.

        ## Required Adjustments Before Code Generation
        - Keep `data-aiweb-id` hooks from the selected candidate or replace them with equally stable semantic IDs.
        - Replace placeholder-safe proof/content slots only with source-backed copy.
        - Resolve conflicts in favor of `.ai-web/DESIGN.md`; do not overwrite custom DESIGN.md from selection alone.
      MD
    end

    def task_packet_markdown(task_id, task_type, state)
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
        #{selected_candidate_id ? "- `.ai-web/design-candidates/#{selected_candidate_id}.html` (selected visual direction; DESIGN.md remains authoritative)" : "- Select a design candidate before implementation if Gate 2 has not recorded one."}

        ## Constraints
        - Do not perform external deploy/provider actions without explicit approval.
        - Keep changes small and reversible.
        - Respect design tokens and component rules.
        - QA failures must create fix packets or rollback decisions.

        ## Acceptance Criteria
        - The slice is implemented or clearly blocked.
        - Evidence paths are recorded.
        - Relevant QA checklist items are updated.

        ## Verification
        - Run local build/test/lint if available.
        - Run browser QA checklist for user-facing changes.
      MD
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
        # QA Fix Packet — #{primary["id"]}

        QA result: #{primary["source_result"]}
        Created at: #{now}

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
      parts = path.to_s.split(/[\\\/]+/)
      if parts.any? { |part| part == ".env" || part.start_with?(".env.") }
        raise UserError.new("visual-polish refuses to read .env or .env.* critique paths", 1)
      end
    end

    def load_visual_polish_critique(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise UserError.new("cannot parse visual critique JSON: #{e.message}", 1)
    rescue SystemCallError => e
      raise UserError.new("cannot read visual critique JSON: #{e.message}", 1)
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
        "cycles_used_before" => cycles_used,
        "max_cycles" => max_cycles,
        "pre_polish_snapshot" => relative(snapshot_dir),
        "polish_task" => relative(task_path),
        "guardrails" => [
          "no .env read/write",
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

      <<~MD
        # Visual Polish Task — #{record["id"]}

        Source critique: #{record["source_critique"]}
        Pre-polish snapshot: #{record["pre_polish_snapshot"]}
        Created at: #{record["created_at"]}

        ## Goal
        Repair or redesign the local visual issues identified by the source critique without expanding scope.

        ## Issues
        #{issues}

        ## Patch Plan
        #{patch_plan}

        ## Guardrails
        - Do not edit `.env` or `.env.*`.
        - Do not run builds, previews, browsers, screenshot capture, package installs, deploys, network calls, or AI calls from the polish loop.
        - Keep source changes manual, reviewable, and verified outside this record-creation command.

        ## Acceptance Criteria
        - Visual issues are addressed in local source by a human/agent in a separate implementation step.
        - Visual critique is rerun manually and linked in `.ai-web/visual/`.
      MD
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
      parts = path.to_s.split(/[\\\/]+/)
      if parts.any? { |part| part == ".env" || part.start_with?(".env.") }
        raise UserError.new("refusing to read .env path for repair input", 1)
      end
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
      Array(component_map["components"]).find { |component| component.is_a?(Hash) && component["data_aiweb_id"].to_s == target }
    end

    def visual_edit_blockers(source, component_map, component, target, force:)
      blockers = []
      blockers << source["error"] if source["error"]
      return blockers unless source["error"].nil?

      blockers << "component map not found: #{source["relative"]}" unless component_map
      blockers << "target data-aiweb-id not found in component map: #{target}" if component_map && component.nil?
      blockers << "target data-aiweb-id is not editable: #{target}" if component && component["editable"] == false
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
        "prompt_summary" => visual_edit_prompt_summary(prompt),
        "prompt_sha256" => Digest::SHA256.hexdigest(prompt),
        "guardrails" => [
          "Target only the selected region identified by data-aiweb-id.",
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
        # Visual Edit Handoff — #{record.fetch("id")}

        Status: planned

        ## Target
        - data-aiweb-id: `#{target["data_aiweb_id"]}`
        - source: `#{target["source_path"]}`#{target["line"] ? ":#{target["line"]}" : ""}
        - route: `#{target["route"] || "unknown"}`
        - component map: `#{record["source_map"]}`

        ## Requested change
        #{record["prompt_summary"]}

        ## Guardrails
        #{record.fetch("guardrails").map { |guardrail| "- #{guardrail}" }.join("\n")}

        ## Next step
        A later implementation pass may patch only this mapped source region after smoke QA evidence is available. This command intentionally created a handoff record only.
      MD
    end

    def visual_critique_evidence_paths(paths, evidence_paths, screenshot, screenshots, metadata)
      [paths, evidence_paths, screenshot, screenshots, metadata].flatten.compact.map(&:to_s).map(&:strip).reject(&:empty?).uniq
    end

    def validate_visual_critique_input_path!(path)
      raise UserError.new("visual-critique evidence path must be local: #{path}", 1) if path.match?(/\A[a-z][a-z0-9+.-]*:\/\//i)

      expanded = File.expand_path(path, root)
      basename = File.basename(expanded)
      if basename == ".env" || basename.start_with?(".env.")
        raise UserError.new("visual-critique refuses to read .env or .env.* evidence paths", 1)
      end
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
        "approval" => approval
      }
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
      %w[hierarchy typography spacing color originality mobile_polish brand_fit intent_fit]
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

      low = scores.select { |_category, score| score < 75 }
      return [] if low.empty?

      low.map { |category, score| "#{category.tr("_", " ")} score #{score} is below the visual quality target 75" }
    end

    def visual_critique_patch_plan(scores, issues)
      return [] if issues.empty?

      scores.select { |_category, score| score < 75 }.map do |category, score|
        {
          "area" => category,
          "priority" => score < 50 ? "high" : "medium",
          "action" => visual_critique_patch_action(category)
        }
      end
    end

    def visual_critique_patch_action(category)
      case category
      when "hierarchy" then "clarify primary headline, CTA emphasis, and section order"
      when "typography" then "tighten type scale, line height, and readable contrast"
      when "spacing" then "normalize section rhythm, gutters, and component padding"
      when "color" then "reduce palette noise and improve semantic color contrast"
      when "originality" then "add distinctive composition, imagery, or interaction motif"
      when "mobile_polish" then "verify responsive spacing, tap targets, and above-the-fold composition"
      when "brand_fit" then "align tone, visual motifs, and UI details with brand attributes"
      when "intent_fit" then "make the page goal and user journey more explicit"
      else "improve visual quality for #{category.tr("_", " ")}"
      end
    end

    def visual_critique_approval(scores, issues)
      minimum = scores.values.min || 0
      average = scores.values.sum.to_f / scores.length
      return "redesign" if minimum < 50 || average < 60
      return "repair" if minimum < 75 || !issues.empty?

      "pass"
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
