# frozen_string_literal: true

require "yaml"

require_relative "design_brief"

module Aiweb
  class DesignSystemResolver
    CRAFT_IDS = DesignBrief::CRAFT_IDS.freeze
    MANAGED_MARKER = "<!-- aiweb:design-system-resolved:v1 -->"

    attr_reader :root, :aiweb_dir, :templates_dir

    def initialize(root, aiweb_dir:, templates_dir:)
      @root = File.expand_path(root)
      @aiweb_dir = aiweb_dir
      @templates_dir = templates_dir
    end

    def design_path
      File.join(aiweb_dir, "DESIGN.md")
    end

    def write_needed?(force: false)
      return true if force
      return true unless File.exist?(design_path)

      placeholder_design?(File.read(design_path))
    end

    def placeholder_design?(content)
      normalized = normalize(content)
      return true if normalized.empty?
      return true if normalize(template_design) == normalized

      content.include?(MANAGED_MARKER)
    end

    def markdown(intent:, design_brief:)
      selected_design_system = present(intent["recommended_design_system"], "luxury-editorial")
      selected_skill = present(intent["recommended_skill"], "premium-landing-page")
      market = present(intent["market_archetype"], intent["archetype"] || "fallback")
      design_system_body = read_design_system(selected_design_system)
      craft_sections = CRAFT_IDS.map { |id| [id, read_craft(id)] }
      reference_brief = design_reference_brief

      <<~MD
        #{MANAGED_MARKER}
        # AI Web Design Source of Truth

        This file is the deterministic design source of truth for downstream candidate generation, visual editing, and implementation. Do not rely on prompt luck: use this file before generating candidates or code.

        ## Source Route
        - Original intent: #{present(intent["original_intent"], "unspecified")}
        - Intent archetype: #{present(intent["archetype"], "landing-page")}
        - Market route: #{market}
        - Surface: #{present(intent["surface"], "website")}
        - Primary user: #{present(intent["primary_user"], "the approved target visitor")}
        - Primary interaction: #{present(intent["primary_interaction"], "the approved first-view action")}
        - Selected design system ID: #{selected_design_system}
        - Selected skill ID: #{selected_skill}
        - Craft rule IDs: #{CRAFT_IDS.join(", ")}
        - Safety sensitive: #{intent["safety_sensitive"] == true}

        ## Downstream Constraints
        - No generic AI-slop: every section must orient, prove, explain, compare, convert, reassure, or support SEO.
        - Visual edit requirement: every generated/implemented editable section and component must include stable `data-aiweb-id` attributes.
        - Mobile-first: design and QA start at 375x812, then expand to tablet and desktop.
        - First-view obligations are mandatory before visual novelty, animation, or extra sections.
        - Component/token guardrails: use tokens, component recipes, and layout rules from this file; do not invent one-off colors, fonts, radii, shadows, spacing, or button variants.
        - No fake proof: logos, testimonials, metrics, medical/legal/financial claims, reviews, prices, and availability require source/provenance or explicit draft status.
        - Preserve approved intent: do not reclassify the idea, surface, audience, first-screen interaction, or safety scope.

        ## First-view Obligations
        #{bullet_list(Array(intent["must_have_first_view"]).map { |item| "Must show: #{item}" })}
        #{bullet_list(Array(intent["must_not_have"]).map { |item| "Must not show/do: #{item}" })}
        #{bullet_list(Array(intent["forbidden_design_patterns"]).map { |item| "Forbidden route pattern: #{item}" })}

        ## Component and Token Guardrails
        - Tokens must cover color, typography, spacing, radius, shadow/elevation, focus, and semantic states.
        - Components must be named and reusable: header, hero/first-view, buttons, cards, forms, proof/trust modules, section shells, and route-specific modules.
        - Maximum button emphasis levels: primary, secondary, quiet/text unless the selected design system explicitly defines fewer.
        - `data-aiweb-id` values must be semantic and stable, for example `hero.primary-cta`, `product-grid.card-01`, `booking.sticky-call`, or `proof.trust-card`.
        - Responsive behavior must be specified for every multi-column region; horizontal scroll is a blocker unless intentionally controlled.

        ## PR4 Design Brief
        #{indent_block(design_brief)}

        #{reference_pattern_constraints(reference_brief)}

        ## Selected Design System: #{selected_design_system}
        #{indent_block(design_system_body)}

        ## Relevant Craft Rules
        #{craft_sections.map { |id, body| "### Craft: #{id}\n\n#{indent_block(body)}" }.join("\n\n")}

        ## Candidate Generation Contract
        - Candidate prompts must include or reference this `.ai-web/DESIGN.md` file and the PR4 design brief.
        - Candidate images must visibly satisfy the first-view obligations and selected route assets (`#{selected_design_system}`, `#{selected_skill}`).
        - Candidate notes must map visual choices back to token/component decisions in this file.
        - Reject candidates that look polished but violate craft rules, first-view obligations, mobile usability, or provenance constraints.

        ## Implementation Contract
        - Implement from `.ai-web/DESIGN.md` before `.ai-web/design-prompt.md` or candidate notes when conflicts exist.
        - Do not add new visual primitives unless this file is updated by an explicit `aiweb design-system resolve --force` or a human custom edit.
        - Keep visual edit hooks (`data-aiweb-id`) in generated markup and component APIs.
        - Use mobile-first CSS and named design tokens rather than arbitrary values.
      MD
    end

    private

    def read_design_system(id)
      path = asset_path("design-systems", id, "DESIGN.md")
      return File.read(path) if path && File.exist?(path)

      "Missing design system `#{id}` at `design-systems/#{id}/DESIGN.md`. Use the closest shipped design system before candidate generation."
    end

    def read_craft(id)
      path = asset_path("craft", "#{id}.md")
      return File.read(path) if path && File.exist?(path)

      "Missing craft rule `#{id}` at `craft/#{id}.md`."
    end

    def design_reference_brief
      path = File.join(aiweb_dir, "design-reference-brief.md")
      return nil unless File.file?(path)

      content = File.read(path).to_s.strip
      content.length >= 40 ? content : nil
    end

    def reference_pattern_constraints(reference_brief)
      return "" if reference_brief.to_s.strip.empty?

      <<~MD.rstrip
        ## Reference-backed Pattern Constraints
        The following local reference brief is pattern evidence only. Use it for hierarchy, CTA, layout, visual language, responsive behavior, and trust decisions. Do not copy exact screenshots, layouts, copy, prices, trademarks, or brand-specific claims.

        #{indent_block(reference_brief)}
      MD
    end

    def asset_path(*parts)
      [root, package_root].map { |base| File.join(base, *parts) }.find { |path| File.exist?(path) }
    end

    def package_root
      File.expand_path("../..", __dir__)
    end

    def template_design
      path = File.join(templates_dir, "DESIGN.md")
      File.exist?(path) ? File.read(path) : ""
    end

    def present(value, fallback)
      string = value.to_s.strip
      string.empty? ? fallback : string
    end

    def bullet_list(items)
      rows = Array(items).reject { |item| item.to_s.strip.empty? }
      rows = ["Follow `.ai-web/first-view-contract.md` and approved product intent."] if rows.empty?
      rows.map { |item| "- #{item}" }.join("\n")
    end

    def indent_block(content)
      content.to_s.rstrip.empty? ? "TODO: missing source." : content.to_s.rstrip
    end

    def normalize(content)
      content.to_s.gsub(/\s+/, " ").strip
    end
  end
end
