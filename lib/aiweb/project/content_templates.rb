# frozen_string_literal: true

require_relative "content_templates/reference_ingestion"
require_relative "content_templates/design_handoffs"

module Aiweb
  class Project
    private

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

  end
end
