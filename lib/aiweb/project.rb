# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "time"
require "yaml"

require_relative "archetypes"
require_relative "design_brief"
require_relative "design_system_resolver"
require_relative "intent_router"

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
      candidate_files = Dir.exist?(dir) ? Dir.glob(File.join(dir, "candidate-*.md")).sort : []
      refs = state.dig("design_candidates", "candidates") || []
      known = refs.map { |r| r["path"] }
      candidate_files.each do |path|
        rel = relative(path)
        next if known.include?(rel)
        refs << {
          "id" => File.basename(path, ".md"),
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
      end.join("\n\n")
      <<~MD
        # Design Prompt Handoff

        ## GPT Image 2 prompt
        Create one high-quality website design candidate based on the product, brand, content, IA, design brief, and `.ai-web/DESIGN.md` source of truth below. Produce a polished responsive homepage concept. Avoid logos or copyrighted brand marks. Emphasize layout, visual hierarchy, component style, typography mood, color system, spacing rhythm, and conversion clarity.

        ## Claude Design prompt
        Convert the selected visual direction into implementation-ready rules that preserve `.ai-web/DESIGN.md`: design tokens, typography scale, color palette, component recipes, layout constraints, `data-aiweb-id` hooks, and responsive behavior. Do not invent product scope beyond the approved artifacts. Preserve the product artifact's wrong-interpretations-to-avoid guidance when choosing first-screen layout and components.

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
        Selected at: #{now}

        ## Reason
        TODO: explain why this candidate best satisfies quality.yaml and product goals.

        ## Required transformation into DESIGN.md
        - Extract colors into tokens.
        - Extract typography into scale and usage rules.
        - Extract layout into responsive section rules.
        - Extract components into reusable recipes.
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
