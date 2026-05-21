# frozen_string_literal: true

module Aiweb
  class DesignCandidateGenerator
    private

    def strategy_id_for(theme)
      case theme
      when "editorial-luxury" then "editorial-premium"
      when "trust-service" then "trust-minimal"
      else "conversion-focused"
      end
    end

    def candidate_score_for(theme)
      case strategy_id_for(theme)
      when "editorial-premium" then 84
      when "conversion-focused" then 86
      else 85
      end
    end

    def candidate_rubric_scores(theme)
      case strategy_id_for(theme)
      when "editorial-premium"
        { "first_impression" => 90, "hierarchy" => 84, "originality" => 88, "conversion_clarity" => 78, "mobile_polish" => 82 }
      when "conversion-focused"
        { "first_impression" => 84, "hierarchy" => 88, "originality" => 78, "conversion_clarity" => 91, "mobile_polish" => 86 }
      else
        { "first_impression" => 82, "hierarchy" => 86, "originality" => 80, "conversion_clarity" => 84, "mobile_polish" => 88 }
      end
    end

    def first_view_for(spec)
      "#{spec.fetch(:mood)}; #{spec.fetch(:layout)}"
    end

    def proof_pattern_for(theme)
      case strategy_id_for(theme)
      when "editorial-premium" then "source-backed narrative details and restrained proof slots"
      when "conversion-focused" then "benefit proof panel, comparison grid, and claim-safe CTA support"
      else "calm reassurance row, process evidence, and no unsupported proof"
      end
    end

    def cta_flow_for(theme)
      case strategy_id_for(theme)
      when "editorial-premium" then "quiet primary CTA with secondary review path"
      when "conversion-focused" then "dominant primary CTA with repeated mobile-safe action"
      else "clear contact or next-step CTA with reassurance before commitment"
      end
    end

    def mobile_behavior_for(theme)
      case strategy_id_for(theme)
      when "editorial-premium" then "stacked editorial rhythm with preserved first-view hierarchy"
      when "conversion-focused" then "sticky or repeated action, compact proof, and short scan path"
      else "single-column trust flow with visible contact/action affordance"
      end
    end

    def risks_for(spec)
      spec.fetch(:tradeoffs).map { |item| item.to_s.sub(/\Aneeds? /i, "needs ") }
    end

    def route_specs
      case market_route
      when "saas"
        [
          {
            theme: "conversion-product",
            mood: "Product-led, precise, and action-oriented",
            layout: "Split hero with product workflow panel, capability cards, and CTA band",
            strengths: ["fast value comprehension", "strong primary action hierarchy", "clear component extraction"],
            tradeoffs: ["less atmospheric brand depth", "requires disciplined product copy"]
          },
          {
            theme: "trust-service",
            mood: "Calm operational trust with safety-forward proof slots",
            layout: "Centered hero, compliance-safe reassurance row, process ladder, FAQ preview",
            strengths: ["low claim risk", "good for regulated or B2B buyers", "accessible hierarchy"],
            tradeoffs: ["can feel conservative", "needs real proof before launch"]
          },
          {
            theme: "editorial-luxury",
            mood: "Editorial software narrative with premium restraint",
            layout: "Magazine-style lead, large whitespace, annotated product moments, quiet CTA",
            strengths: ["distinctive brand feel", "less dashboard cliché", "strong typography direction"],
            tradeoffs: ["conversion cues are subtler", "more care needed on responsive spacing"]
          }
        ]
      when "ecommerce"
        [
          {
            theme: "commerce-mobile",
            mood: "Mobile-first, shoppable, and reassuring",
            layout: "Sticky commerce header, collection hero, product cards, safe offer/help modules",
            strengths: ["tap-friendly browsing", "clear product decision flow", "strong mobile contract"],
            tradeoffs: ["higher density", "needs real product data to replace placeholders"]
          },
          {
            theme: "editorial-luxury",
            mood: "Curated collection story with premium pacing",
            layout: "Editorial hero, featured collection strip, material/detail blocks, measured CTA",
            strengths: ["brand differentiation", "good for premium assortment", "strong imagery direction"],
            tradeoffs: ["slower direct shopping", "requires high-quality source imagery"]
          },
          {
            theme: "conversion-product",
            mood: "Direct product value with clear purchase-path reassurance",
            layout: "Value hero, product proof placeholders, comparison grid, shipping/help band",
            strengths: ["strong conversion clarity", "safe provenance reminders", "straightforward implementation"],
            tradeoffs: ["less bespoke atmosphere", "can become generic if copy is thin"]
          }
        ]
      when "service"
        [
          {
            theme: "trust-service",
            mood: "Warm local trust and appointment readiness",
            layout: "Service hero with contact panel, location/hours module, process cards, safe proof slots",
            strengths: ["clear booking/contact path", "trustworthy without fake claims", "excellent local-service fit"],
            tradeoffs: ["conservative visual energy", "needs owner-supplied local details"]
          },
          {
            theme: "editorial-luxury",
            mood: "Refined neighborhood editorial with calm confidence",
            layout: "Large typographic hero, story/detail sections, service menu, quiet contact CTA",
            strengths: ["distinctive premium feel", "good for high-touch services", "strong whitespace discipline"],
            tradeoffs: ["booking action is less forceful", "imagery must be carefully sourced"]
          },
          {
            theme: "conversion-product",
            mood: "Practical service conversion with immediate next steps",
            layout: "Problem-fit hero, service cards, eligibility/visit checklist, sticky CTA footer",
            strengths: ["high action clarity", "mobile-friendly conversion path", "easy QA mapping"],
            tradeoffs: ["less editorial softness", "can feel utilitarian"]
          }
        ]
      else
        [
          {
            theme: "editorial-luxury",
            mood: "Premium editorial restraint with crafted hierarchy",
            layout: "Asymmetric hero, image/detail rail, modular narrative sections, quiet CTA",
            strengths: ["strong brand memorability", "clear token direction", "avoids template sameness"],
            tradeoffs: ["requires careful content editing", "conversion path is measured"]
          },
          {
            theme: "trust-service",
            mood: "Credible and reassuring with service-grade clarity",
            layout: "Centered promise, trust-safe proof placeholders, process cards, contact/help strip",
            strengths: ["low fake-proof risk", "accessible content hierarchy", "safe default for broad briefs"],
            tradeoffs: ["less dramatic visual identity", "needs source-backed proof later"]
          },
          {
            theme: "conversion-product",
            mood: "Focused conversion/product clarity",
            layout: "Direct hero, action panel, benefit grid, implementation-ready component sections",
            strengths: ["strong first-view action", "simple implementation", "clear section IDs"],
            tradeoffs: ["less luxurious", "may need brand polish after selection"]
          }
        ]
      end
    end
  end
end
