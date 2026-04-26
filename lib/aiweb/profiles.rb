# frozen_string_literal: true

module Aiweb
  module Profiles
    PROFILES = {
      "A" => {
        name: "Rails 8 + PostgreSQL + Hotwire/Turbo + Tailwind",
        scaffold_target: "Rails 8 + PostgreSQL + Hotwire/Turbo + Tailwind + Kamal + Cloudflare DNS/CDN/WAF notes",
        deploy: "Kamal deploy plan with Cloudflare DNS/CDN/WAF notes",
        override: "Use when the release needs server-rendered dynamic flows, auth, or relational data."
      },
      "B" => {
        name: "Astro + Cloudflare Pages + Tailwind",
        scaffold_target: "Astro + Cloudflare Pages + Tailwind + optional Pages Functions for forms",
        deploy: "Cloudflare Pages deploy plan with optional Pages Functions form handler",
        override: "Use for static marketing sites with a small form or light dynamic edge behavior."
      },
      "C" => {
        name: "Hybrid Rails main app + Cloudflare edge",
        scaffold_target: "Rails 8 main app + PostgreSQL + Hotwire/Turbo + Tailwind + Kamal + Cloudflare DNS/CDN/WAF + optional R2 notes",
        deploy: "Kamal-backed Rails app with Cloudflare DNS/CDN/WAF and optional R2 notes",
        override: "Use when a content site also needs app-like account, admin, or data workflows."
      },
      "D" => {
        name: "Astro content site + MDX",
        scaffold_target: "Astro + MDX/Content Collections + Cloudflare Pages + Tailwind + sitemap/RSS",
        deploy: "Cloudflare Pages static deploy with sitemap/RSS release checklist",
        override: "Canonical default for content/SEO/brand sites without server-side app complexity."
      }
    }.freeze

    def self.fetch!(profile)
      key = profile.to_s.upcase
      data = PROFILES[key]
      raise ArgumentError, "unknown profile #{profile.inspect}; expected A, B, C, or D" unless data
      [key, data]
    end
  end
end
