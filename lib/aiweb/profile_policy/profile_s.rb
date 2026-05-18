# frozen_string_literal: true

module Aiweb
  module ProfilePolicy
    module ProfileS
      REQUIRED_FILES = %w[
        package.json
        next.config.mjs
        tsconfig.json
        src/app/layout.tsx
        src/app/page.tsx
        src/app/globals.css
        src/lib/supabase/client.ts
        src/lib/supabase/server.ts
        supabase/migrations/0001_initial_schema.sql
        supabase/rls-draft.md
        supabase/storage.md
        supabase/env.example.template
        .ai-web/scaffold-profile-S.json
        .ai-web/qa/supabase-secret-qa.json
        .ai-web/qa/supabase-local-verify.json
      ].freeze

      EXPECTED_SCRIPTS = {
        "dev" => "next dev",
        "build" => "next build",
        "start" => "next start"
      }.freeze

      EXPECTED_DEPENDENCIES = %w[
        @supabase/ssr
        @supabase/supabase-js
        next
        react
        react-dom
      ].freeze

      def self.contract
        Contract.new(
          id: "S",
          display_name: "Profile S - Next.js + Supabase local scaffold",
          framework: "Next.js",
          framework_detail: "Next.js App Router + Supabase SSR local-only scaffold",
          metadata_path: ".ai-web/scaffold-profile-S.json",
          required_files: REQUIRED_FILES,
          expected_scripts: EXPECTED_SCRIPTS,
          expected_dependencies: EXPECTED_DEPENDENCIES,
          package_manager: "pnpm",
          dev_command: "pnpm dev",
          build_command: "pnpm build",
          runtime_readiness: "local_planning_only",
          capabilities: {
            setup: false,
            build: false,
            preview: false,
            browser_qa: false,
            visual_critique: false,
            source_patch: true,
            local_verify: true,
            supabase_secret_qa: true
          },
          forbidden_actions: %w[hosted_supabase_project_creation supabase_provider_cli provider_network_mutation deploy credential_use dot_env_read],
          env_policy: {
            "reads_dot_env" => false,
            "child_process_env" => "scrubbed_allowlist",
            "public_placeholder_env_allowed" => true
          },
          documentation_summary: "Local-only Next.js/Supabase planning scaffold with secret QA and local verification before any optional runtime work."
        )
      end
    end
  end
end
