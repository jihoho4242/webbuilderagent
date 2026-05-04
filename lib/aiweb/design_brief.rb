# frozen_string_literal: true

module Aiweb
  class DesignBrief
    CRAFT_IDS = %w[anti-ai-slop color typography spacing-responsive].freeze

    SECTION_TITLES = [
      "Product Type",
      "Audience",
      "Emotional Target",
      "Brand Adjectives",
      "Preferred Mood",
      "Non-preferred Mood",
      "Typography Direction",
      "Color Direction",
      "Layout Density",
      "Imagery/Icon Direction",
      "Motion Intensity",
      "First-view Obligations",
      "Forbidden Patterns",
      "Reference Research Intent",
      "Candidate Generation Instructions"
    ].freeze

    def initialize(intent)
      @intent = intent || {}
      @idea = @intent["original_intent"].to_s
      @market = @intent["market_archetype"].to_s.empty? ? "fallback" : @intent["market_archetype"].to_s
      @design_system = present(@intent["recommended_design_system"], "luxury-editorial")
      @skill = present(@intent["recommended_skill"], "premium-landing-page")
    end

    def markdown
      sections = {
        "Product Type" => product_type,
        "Audience" => audience,
        "Emotional Target" => emotional_target,
        "Brand Adjectives" => brand_adjectives,
        "Preferred Mood" => preferred_mood,
        "Non-preferred Mood" => non_preferred_mood,
        "Typography Direction" => typography_direction,
        "Color Direction" => color_direction,
        "Layout Density" => layout_density,
        "Imagery/Icon Direction" => imagery_icon_direction,
        "Motion Intensity" => motion_intensity,
        "First-view Obligations" => first_view_obligations,
        "Forbidden Patterns" => forbidden_patterns,
        "Reference Research Intent" => reference_research_intent,
        "Candidate Generation Instructions" => candidate_generation_instructions
      }

      (["# Design Brief", "", source_summary] + SECTION_TITLES.flat_map { |title| ["", "## #{title}", sections.fetch(title)] }).join("\n").rstrip + "\n"
    end

    private

    def source_summary
      <<~MD.chomp
        Generated deterministically from `.ai-web/intent.yaml`; do not reinterpret or reclassify the original idea.

        - Original intent: #{present(@idea, "unspecified")}
        - Intent archetype: #{present(@intent["archetype"], "landing-page")}
        - Market route: #{@market}
        - Design system ID: #{@design_system}
        - Skill ID: #{@skill}
        - Craft rule IDs: #{CRAFT_IDS.join(", ")}
      MD
    end

    def product_type
      "Build a #{present(@intent["surface"], "website")} experience for `#{present(@intent["archetype"], "landing-page")}` using the PR2 route assets `#{@design_system}` and `#{@skill}`."
    end

    def audience
      "Primary audience: #{present(@intent["primary_user"], "the visitor implied by the approved product intent")}. Keep the first screen optimized for #{present(@intent["primary_interaction"], "the primary conversion action")}."
    end

    def emotional_target
      base = case @market
             when "saas" then "credible, capable, calm, and product-led"
             when "ecommerce" then "confident, easy, shoppable, and reassuring"
             when "service" then "warm, local, trustworthy, and appointment-ready"
             when "premium" then "refined, selective, crafted, and high-trust"
             else "clear, focused, trustworthy, and specific"
             end
      [base, overlay_sentence("Emotional overlay")].compact.join(" ")
    end

    def brand_adjectives
      adjectives = (Array(@intent["style_keywords"]) + overlay_adjectives + route_adjectives).uniq
      bullet_list(adjectives)
    end

    def preferred_mood
      lines = [route_mood, overlay_sentence("Mood overlay")].compact
      bullet_list(lines)
    end

    def non_preferred_mood
      bullet_list([
        "generic AI-template polish, vague innovation language, unrelated gradients, and visual filler",
        "anything that contradicts `#{@design_system}`, `#{@skill}`, or craft rules #{CRAFT_IDS.join(", ")}",
        overlay_avoidance
      ].compact)
    end

    def typography_direction
      case @design_system
      when "conversion-saas"
        "Use crisp product typography with strong headline clarity, scannable body copy, and numeric/UI labels that feel operational rather than decorative. Follow craft `typography`."
      when "mobile-commerce"
        "Use commerce-readable type: compact product names, clear price hierarchy, generous tap-target labels, and no ornamental fonts that reduce scan speed. Follow craft `typography`."
      when "local-service-trust"
        "Use approachable, legible service typography with confident headings, direct booking/contact labels, and readable local details. Follow craft `typography`."
      else
        "Use refined editorial typography with restrained contrast, elegant headings, readable body text, and no luxury-cliché script excess. Follow craft `typography`."
      end
    end

    def color_direction
      base = case @design_system
             when "conversion-saas" then "Use a conversion SaaS palette: clean neutrals, one confident product accent, restrained status colors, and high-contrast CTA states."
             when "mobile-commerce" then "Use a mobile commerce palette: product-supportive neutrals, clear sale/availability semantics, and touch-friendly contrast."
             when "local-service-trust" then "Use a local service trust palette: warm neutrals, grounded accent colors, and accessible contact/booking emphasis."
             else "Use a luxury editorial palette: restrained neutrals, one premium accent, deep contrast, and intentional whitespace."
             end
      [base, "Follow craft `color`; avoid decorative colors that do not repeat as a system.", safety_color_overlay].compact.join(" ")
    end

    def layout_density
      case @market
      when "ecommerce"
        "Medium-high density on product browsing areas, but keep first-view hierarchy and cart/offer entry clear. Follow craft `spacing-responsive`."
      when "saas"
        "Medium density: show product proof and the primary CTA without cramming dashboard decoration above the fold. Follow craft `spacing-responsive`."
      when "service"
        "Medium-low density: surface service fit, contact/booking, hours/location/trust cues, and keep mobile contact immediate. Follow craft `spacing-responsive`."
      else
        "Low-to-medium editorial density: fewer stronger blocks, deliberate whitespace, and clear first-view conversion path. Follow craft `spacing-responsive`."
      end
    end

    def imagery_icon_direction
      case @market
      when "saas" then "Prefer product-relevant UI diagrams, workflow proof, and simple system icons; reject nonsense dashboards and fake metrics."
      when "ecommerce" then "Prefer product-first imagery, price/offer clarity, trust/shipping cues, and minimal icons that help shopping decisions."
      when "service" then "Prefer real-world service context, location/team/process cues, and trust-building icons; do not invent fake credentials or reviews."
      else "Prefer curated editorial imagery, tactile detail, restrained iconography, and crafted composition; avoid stock-photo clichés."
      end
    end

    def motion_intensity
      if safety_sensitive?
        "Low motion only: subtle feedback, state transitions, and no urgency/pressure animation on safety-sensitive decisions."
      elsif @market == "premium"
        "Low-to-medium motion: elegant reveals and hover polish, never sparkle overload or distracting parallax."
      else
        "Moderate functional motion: clarify state, hierarchy, and interaction without slowing the primary action."
      end
    end

    def first_view_obligations
      obligations = Array(@intent["must_have_first_view"]).map { |item| "Must show: #{item}" }
      obligations << "Primary interaction: #{present(@intent["primary_interaction"], "approved first-view action")}."
      obligations << "Use `#{@design_system}` and `#{@skill}` to shape the first screen without changing intent."
      bullet_list(obligations)
    end

    def forbidden_patterns
      patterns = Array(@intent["must_not_have"]) + Array(@intent["forbidden_design_patterns"]) + safety_forbidden_patterns
      bullet_list(patterns.uniq)
    end

    def reference_research_intent
      bullet_list(reference_research_queries.map { |query| "If design research is enabled, use pattern-only reference query: #{query}" } + [
        "Use reference research only for hierarchy, CTA, layout, visual language, responsive, and trust-pattern grounding.",
        "Do not copy exact screenshots, layouts, copy, prices, trademarks, or brand-specific claims from references."
      ])
    end

    def candidate_generation_instructions
      bullet_list([
        "Generate design candidates from this brief, `.ai-web/product.md`, `.ai-web/brand.md`, `.ai-web/content.md`, `.ai-web/ia.md`, `.ai-web/first-view-contract.md`, and `.ai-web/design-reference-brief.md` when present.",
        "Use PR2 design system `#{@design_system}`, skill `#{@skill}`, and craft IDs #{CRAFT_IDS.join(", ")} as explicit constraints.",
        "Preserve the existing intent fields exactly; do not reclassify the idea, surface, audience, or first-view obligations.",
        "Every candidate must satisfy first-view obligations, avoid forbidden patterns, and pass safety overlay checks before visual novelty.",
        "Return implementation-useful notes for typography, color, layout, imagery/icons, motion, and risks.",
        "If reference research exists, interpret patterns rather than imitating exact reference layouts or copy."
      ])
    end

    def reference_research_queries
      case @market
      when "saas"
        ["B2B SaaS landing page", "developer tools pricing page", "dashboard onboarding"]
      when "ecommerce"
        ["mobile product detail page", "checkout flow", "cart upsell"]
      when "service"
        ["local service booking page", "trust section", "contact booking CTA"]
      when "premium"
        ["luxury editorial landing page", "premium product page", "high trust hero"]
      else
        if @intent["archetype"].to_s.include?("chat")
          ["AI assistant onboarding", "chat app first screen", "dashboard empty state"]
        else
          ["high trust landing page", "responsive first screen", "conversion CTA pattern"]
        end
      end
    end

    def route_mood
      case @market
      when "saas" then "Product-led clarity with trustworthy proof, focused CTAs, and restrained technical confidence."
      when "ecommerce" then "Shoppable confidence with visible product value, price/offer clarity, and mobile-first ease."
      when "service" then "Local trust with warm proof, direct contact, practical service detail, and no inflated claims."
      when "premium" then "Premium editorial restraint with crafted whitespace, selective detail, and confident conversion hierarchy."
      else "Specific, clear, conversion-ready mood with no generic landing-page filler."
      end
    end

    def route_adjectives
      case @market
      when "saas" then %w[credible product-led precise calm]
      when "ecommerce" then %w[shoppable trustworthy touch-friendly clear]
      when "service" then %w[warm local practical reliable]
      when "premium" then %w[premium editorial restrained crafted]
      else %w[clear focused trustworthy specific]
      end
    end

    def overlay_adjectives
      overlays.flat_map do |name|
        case name
        when :premium then %w[luxurious premium refined restrained]
        when :emotional then %w[emotional atmospheric warm editorial]
        when :trust then %w[trustworthy stable credible reassuring]
        else []
        end
      end
    end

    def overlay_sentence(label)
      return nil if overlays.empty?

      details = overlays.map do |name|
        case name
        when :premium then "고급스럽게/프리미엄 → refined materials, restrained contrast, high-end editorial confidence"
        when :emotional then "인스타 감성/감성 → atmospheric warmth, shareable detail, soft editorial composition"
        when :trust then "믿음직하게/신뢰 → stable hierarchy, clear proof, conservative interaction states, accessible contrast"
        end
      end.compact
      "#{label}: #{details.join('; ')}."
    end

    def overlay_avoidance
      return nil if overlays.empty?

      "Avoid overlay failure modes: cheap luxury clichés, over-filtered Instagram sameness, or trust theater without real proof."
    end

    def safety_color_overlay
      return nil unless safety_sensitive?

      "Safety overlay: reserve warning/error colors for real risk states and avoid colors that imply approved transactions, medical/legal/financial certainty, or real-world execution."
    end

    def safety_forbidden_patterns
      return [] unless safety_sensitive?

      [
        "credential collection or token/password capture",
        "real payment, order, broker, medical, legal, or regulated-action execution",
        "authoritative safety-critical advice without clear scope, review, and user-facing framing",
        "urgency pressure, fake proof, or confidence cues that imply approved regulated outcomes"
      ]
    end

    def safety_sensitive?
      @intent["safety_sensitive"] == true || @idea.match?(/금융|의료|법률|결제|주식|투자|account|payment|medical|legal|financial|stock|trading/i)
    end

    def overlays
      @overlays ||= begin
        text = @idea.downcase
        selected = []
        selected << :premium if text.match?(/고급스럽게|프리미엄|premium|luxury|high-end|highend/)
        selected << :emotional if text.match?(/인스타 감성|감성|instagram|emotional|atmospheric/)
        selected << :trust if text.match?(/믿음직하게|신뢰|trust|trusted|reliable|credible/)
        selected
      end
    end

    def bullet_list(items)
      Array(items).flatten.compact.reject { |item| item.to_s.strip.empty? }.map { |item| "- #{item}" }.join("\n")
    end

    def present(value, fallback)
      value.to_s.strip.empty? ? fallback : value.to_s.strip
    end
  end
end
