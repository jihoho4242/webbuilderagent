# frozen_string_literal: true

module Aiweb
  class Project
    private

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
  end
end
