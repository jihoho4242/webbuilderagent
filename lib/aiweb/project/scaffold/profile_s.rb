# frozen_string_literal: true

require_relative "profile_s/templates"
require_relative "profile_s/checks"
module Aiweb
  class Project
    module Scaffold
      module ProfileS
        private

    def scaffold_profile_s_metadata(files, profile_data)
      {
        "schema_version" => 1,
        "profile" => "S",
        "framework" => "Next.js",
        "framework_detail" => "Next.js App Router + Supabase SSR",
        "package_manager" => "pnpm",
        "dev_command" => "pnpm dev",
        "build_command" => "pnpm build",
        "scaffold_target" => profile_data.fetch(:scaffold_target),
        "metadata_path" => SCAFFOLD_PROFILE_S_METADATA_PATH,
        "secret_qa_path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH,
        "local_verify_path" => SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH,
        "local_only" => true,
        "external_actions_allowed" => false,
        "env_template_path" => "supabase/env.example.template",
        "env_dotfile_created" => false,
        "supabase_public_env" => %w[NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY],
        "guardrails" => [
          "no external Supabase project creation",
          "no deploy/external hosting",
          "no .env or .env.* files"
        ],
        "created_at" => now,
        "files" => files.keys.map do |relative_path|
          {
            "path" => relative_path,
            "sha256" => Digest::SHA256.hexdigest(files.fetch(relative_path))
          }
        end
      }
    end

    def scaffold_profile_s_files(state)
      context = scaffold_context(state)
      {
        "package.json" => package_json_profile_s(context),
        "next.config.mjs" => next_config_profile_s,
        "tsconfig.json" => tsconfig_profile_s,
        "src/app/layout.tsx" => layout_tsx_profile_s(context),
        "src/app/page.tsx" => page_tsx_profile_s(context),
        "src/app/globals.css" => globals_css_profile_s,
        "src/lib/supabase/client.ts" => supabase_client_ts_profile_s,
        "src/lib/supabase/server.ts" => supabase_server_ts_profile_s,
        "supabase/migrations/0001_initial_schema.sql" => supabase_initial_schema_profile_s,
        "supabase/rls-draft.md" => supabase_rls_draft_profile_s,
        "supabase/storage.md" => supabase_storage_profile_s,
        "supabase/env.example.template" => supabase_env_template_profile_s
      }
    end


      end
    end
  end
end
