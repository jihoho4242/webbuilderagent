# frozen_string_literal: true

module Aiweb
  module ProjectDesignCommands
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

  end
end
