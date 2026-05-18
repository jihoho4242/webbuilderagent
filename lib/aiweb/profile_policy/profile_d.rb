# frozen_string_literal: true

module Aiweb
  module ProfilePolicy
    module ProfileD
      REQUIRED_FILES = %w[
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

      EXPECTED_SCRIPTS = {
        "dev" => "astro dev",
        "build" => "astro build",
        "preview" => "astro preview"
      }.freeze

      EXPECTED_DEPENDENCIES = %w[
        @astrojs/mdx
        @astrojs/sitemap
        astro
        tailwindcss
        @tailwindcss/vite
      ].freeze

      def self.contract
        Contract.new(
          id: "D",
          display_name: "Profile D - Astro content site + MDX",
          framework: "Astro",
          framework_detail: "Astro + MDX/Content Collections + Cloudflare Pages + Tailwind",
          metadata_path: ".ai-web/scaffold-profile-D.json",
          required_files: REQUIRED_FILES,
          expected_scripts: EXPECTED_SCRIPTS,
          expected_dependencies: EXPECTED_DEPENDENCIES,
          package_manager: "pnpm",
          dev_command: "pnpm dev",
          build_command: "pnpm build",
          runtime_readiness: "ready",
          capabilities: {
            setup: true,
            build: true,
            preview: true,
            browser_qa: true,
            visual_critique: true,
            source_patch: true,
            local_verify: true
          },
          forbidden_actions: %w[silent_deploy provider_cli credential_use external_production_mutation],
          env_policy: {
            "reads_dot_env" => false,
            "child_process_env" => "scrubbed_allowlist"
          },
          documentation_summary: "Astro/static frontend runtime with build, preview, browser QA, visual critique, and bounded repair."
        )
      end
    end
  end
end
