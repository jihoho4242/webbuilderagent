# frozen_string_literal: true

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

    def supabase_secret_qa_scan_files
      SCAFFOLD_PROFILE_S_REQUIRED_FILES.each_with_object({}) do |relative_path, memo|
        next if relative_path == SCAFFOLD_PROFILE_S_SECRET_QA_PATH
        next if unsafe_env_path?(relative_path)

        path = File.join(root, relative_path)
        memo[relative_path] = File.read(path) if File.file?(path)
      end
    end

    def supabase_local_verify_scan_files
      SCAFFOLD_PROFILE_S_REQUIRED_FILES.each_with_object({}) do |relative_path, memo|
        next if unsafe_env_path?(relative_path)

        path = File.join(root, relative_path)
        memo[relative_path] = File.read(path) if File.file?(path)
      end
    end

    def scaffold_profile_s_secret_qa(files)
      scanned = files.keys.reject { |path| unsafe_env_path?(path) }.sort
      findings = scanned.flat_map do |relative_path|
        body = files.fetch(relative_path)
        PROFILE_S_SECRET_EXPOSURE_PATTERNS.each_with_object([]) do |pattern, memo|
          next unless body.match?(pattern)

          memo << { "path" => relative_path, "pattern" => pattern.source }
        end
      end
      {
        "schema_version" => 1,
        "status" => findings.empty? ? "passed" : "failed",
        "created_at" => now,
        "scanned_paths" => scanned,
        "read_dot_env" => false,
        "scan" => {
          "mode" => "generated-safe-files-only",
          "excluded_patterns" => [".env", ".env.*"],
          "scanned_files" => scanned,
          "env_files_read" => false,
          "source_contents_embedded" => false
        },
        "files" => scanned.map { |relative_path| { "path" => relative_path, "sha256" => Digest::SHA256.hexdigest(files.fetch(relative_path)) } },
        "findings" => findings
      }
    end

    def scaffold_profile_s_local_verify(files)
      scanned = files.keys.reject { |path| unsafe_env_path?(path) }.sort
      required_paths = SCAFFOLD_PROFILE_S_REQUIRED_FILES
      missing_paths = required_paths.reject { |path| files.key?(path) }
      checks = {
        "required_files" => supabase_local_required_files_check(missing_paths),
        "safe_env_template" => supabase_local_env_template_check(files["supabase/env.example.template"]),
        "ssr_stubs" => supabase_local_ssr_stubs_check(files),
        "migrations_rls" => supabase_local_migrations_check(files["supabase/migrations/0001_initial_schema.sql"]),
        "storage_docs" => supabase_local_storage_docs_check(files["supabase/storage.md"]),
        "metadata" => supabase_local_metadata_check(files[SCAFFOLD_PROFILE_S_METADATA_PATH]),
        "secret_qa" => supabase_local_secret_qa_check(files[SCAFFOLD_PROFILE_S_SECRET_QA_PATH]),
        "external_actions" => supabase_local_external_actions_check(files)
      }
      findings = checks.flat_map { |name, check| Array(check["findings"]).map { |finding| finding.merge("check" => name) } }
      {
        "schema_version" => 1,
        "status" => findings.empty? ? "passed" : "failed",
        "created_at" => now,
        "local_only" => true,
        "external_actions_performed" => false,
        "provider_cli_invoked" => false,
        "read_dot_env" => false,
        "scanned_paths" => scanned,
        "required_paths" => required_paths,
        "checks" => checks,
        "files" => scanned.map { |relative_path| { "path" => relative_path, "sha256" => Digest::SHA256.hexdigest(files.fetch(relative_path)) } },
        "findings" => findings
      }
    end

    def supabase_local_required_files_check(missing_paths)
      findings = missing_paths.map { |path| { "path" => path, "message" => "required Profile S file is missing" } }
      { "status" => findings.empty? ? "passed" : "failed", "missing_paths" => missing_paths, "findings" => findings }
    end

    def supabase_local_env_template_check(body)
      findings = []
      if body.to_s.empty?
        findings << { "path" => "supabase/env.example.template", "message" => "safe Supabase env template is missing" }
      else
        findings << { "path" => "supabase/env.example.template", "message" => "NEXT_PUBLIC_SUPABASE_URL placeholder is missing" } unless body.match?(/NEXT_PUBLIC_SUPABASE_URL=/)
        findings << { "path" => "supabase/env.example.template", "message" => "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY placeholder is missing" } unless body.match?(/NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=/)
        PROFILE_S_SECRET_EXPOSURE_PATTERNS.each do |pattern|
          findings << { "path" => "supabase/env.example.template", "message" => "unsafe secret placeholder pattern found", "pattern" => pattern.source } if body.match?(pattern)
        end
      end
      { "status" => findings.empty? ? "passed" : "failed", "allowed_public_env" => %w[NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY], "dot_env_created" => false, "findings" => findings }
    end

    def supabase_local_ssr_stubs_check(files)
      client = files["src/lib/supabase/client.ts"].to_s
      server = files["src/lib/supabase/server.ts"].to_s
      findings = []
      findings << { "path" => "src/lib/supabase/client.ts", "message" => "browser Supabase SSR client stub is missing createBrowserClient" } unless client.match?(/createBrowserClient/)
      findings << { "path" => "src/lib/supabase/server.ts", "message" => "server Supabase SSR client stub is missing createServerClient" } unless server.match?(/createServerClient/)
      findings << { "path" => "src/lib/supabase/server.ts", "message" => "server Supabase SSR client stub is missing cookies integration" } unless server.match?(/cookies/)
      %w[NEXT_PUBLIC_SUPABASE_URL NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY].each do |key|
        findings << { "path" => "src/lib/supabase/client.ts", "message" => "#{key} is missing from browser client stub" } unless client.include?(key)
        findings << { "path" => "src/lib/supabase/server.ts", "message" => "#{key} is missing from server client stub" } unless server.include?(key)
      end
      { "status" => findings.empty? ? "passed" : "failed", "client_path" => "src/lib/supabase/client.ts", "server_path" => "src/lib/supabase/server.ts", "findings" => findings }
    end

    def supabase_local_migrations_check(body)
      findings = []
      text = body.to_s
      findings << { "path" => "supabase/migrations/0001_initial_schema.sql", "message" => "migration is missing enable row level security" } unless text.match?(/enable row level security/i)
      findings << { "path" => "supabase/migrations/0001_initial_schema.sql", "message" => "migration is missing create policy statements" } unless text.match?(/create policy/i)
      findings << { "path" => "supabase/migrations/0001_initial_schema.sql", "message" => "migration is missing auth.uid ownership guard" } unless text.match?(/auth\.uid\(\)/i)
      { "status" => findings.empty? ? "passed" : "failed", "path" => "supabase/migrations/0001_initial_schema.sql", "findings" => findings }
    end

    def supabase_local_storage_docs_check(body)
      findings = []
      text = body.to_s
      findings << { "path" => "supabase/storage.md", "message" => "storage planning doc is missing" } if text.empty?
      findings << { "path" => "supabase/storage.md", "message" => "storage planning doc must describe storage options" } unless text.match?(/storage|bucket/i)
      findings << { "path" => "supabase/storage.md", "message" => "storage planning doc must retain external-action guardrails" } unless text.match?(/does not run Supabase CLI commands|no buckets are created/i)
      { "status" => findings.empty? ? "passed" : "failed", "path" => "supabase/storage.md", "findings" => findings }
    end

    def supabase_local_metadata_check(body)
      findings = []
      metadata = body.to_s.empty? ? nil : JSON.parse(body)
      unless metadata.is_a?(Hash)
        findings << { "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "message" => "Profile S metadata is missing or malformed" }
      else
        findings << { "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "message" => "metadata profile must be S" } unless metadata["profile"] == "S"
        findings << { "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "message" => "metadata must stay local-only" } unless metadata["local_only"] == true
        findings << { "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "message" => "metadata must disallow external actions" } unless metadata["external_actions_allowed"] == false
      end
      { "status" => findings.empty? ? "passed" : "failed", "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "findings" => findings }
    rescue JSON::ParserError
      { "status" => "failed", "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "findings" => [{ "path" => SCAFFOLD_PROFILE_S_METADATA_PATH, "message" => "Profile S metadata is malformed" }] }
    end

    def supabase_local_secret_qa_check(body)
      findings = []
      qa = body.to_s.empty? ? nil : JSON.parse(body)
      unless qa.is_a?(Hash)
        findings << { "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "message" => "Supabase secret QA artifact is missing or malformed" }
      else
        findings << { "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "message" => "Supabase secret QA must pass before local verification passes" } unless qa["status"] == "passed"
        findings << { "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "message" => "Supabase secret QA must not read dot-env files" } unless qa["read_dot_env"] == false
      end
      { "status" => findings.empty? ? "passed" : "failed", "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "findings" => findings }
    rescue JSON::ParserError
      { "status" => "failed", "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "findings" => [{ "path" => SCAFFOLD_PROFILE_S_SECRET_QA_PATH, "message" => "Supabase secret QA artifact is malformed" }] }
    end

    def supabase_local_external_actions_check(files)
      patterns = {
        "supabase_provider_cli" => /supabase\s+(login|link|projects\s+create|init|start|db\s+push)/i,
        "deploy_cli" => /\b(vercel|netlify|cloudflare)\s+deploy\b/i,
        "network_curl" => /\bcurl\s+https?:\/\//i
      }
      findings = files.reject { |path, _| path.start_with?(".ai-web/qa/") }.flat_map do |relative_path, body|
        patterns.each_with_object([]) do |(name, pattern), memo|
          memo << { "path" => relative_path, "message" => "external action command pattern found", "pattern" => name } if body.to_s.match?(pattern)
        end
      end
      { "status" => findings.empty? ? "passed" : "failed", "performed" => false, "network" => false, "provider_cli" => false, "findings" => findings }
    end

    def package_json_profile_s(context)
      JSON.pretty_generate(
        "name" => npm_package_name(context.fetch(:project_id).empty? ? context.fetch(:project_name) : context.fetch(:project_id)),
        "version" => "0.1.0",
        "private" => true,
        "type" => "module",
        "scripts" => {
          "dev" => "next dev",
          "build" => "next build",
          "start" => "next start"
        },
        "dependencies" => {
          "@supabase/ssr" => "latest",
          "@supabase/supabase-js" => "latest",
          "next" => "latest",
          "react" => "latest",
          "react-dom" => "latest"
        },
        "devDependencies" => {
          "@types/node" => "latest",
          "@types/react" => "latest",
          "@types/react-dom" => "latest",
          "typescript" => "latest"
        }
      ) + "\n"
    end

    def next_config_profile_s
      <<~JS
        /** @type {import('next').NextConfig} */
        const nextConfig = {};

        export default nextConfig;
      JS
    end

    def tsconfig_profile_s
      JSON.pretty_generate(
        "compilerOptions" => {
          "target" => "ES2017",
          "lib" => %w[dom dom.iterable esnext],
          "allowJs" => true,
          "skipLibCheck" => true,
          "strict" => true,
          "noEmit" => true,
          "esModuleInterop" => true,
          "module" => "esnext",
          "moduleResolution" => "bundler",
          "resolveJsonModule" => true,
          "isolatedModules" => true,
          "jsx" => "preserve",
          "incremental" => true,
          "plugins" => [{ "name" => "next" }],
          "paths" => { "@/*" => ["./src/*"] }
        },
        "include" => ["next-env.d.ts", "**/*.ts", "**/*.tsx", ".next/types/**/*.ts"],
        "exclude" => ["node_modules"]
      ) + "\n"
    end

    def layout_tsx_profile_s(context)
      title = context.fetch(:title).to_s.empty? ? context.fetch(:project_name) : context.fetch(:title)
      <<~TSX
        import type { Metadata } from 'next';
        import './globals.css';

        export const metadata: Metadata = {
          title: #{title.inspect},
          description: #{context.fetch(:description).inspect},
        };

        export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
          return (
            <html lang="ko">
              <body>{children}</body>
            </html>
          );
        }
      TSX
    end

    def page_tsx_profile_s(context)
      title = context.fetch(:title).to_s.empty? ? context.fetch(:project_name) : context.fetch(:title)
      <<~TSX
        import { createClient } from '@/lib/supabase/server';

        export default async function Home() {
          const supabase = await createClient();
          const { data: profileRows } = await supabase.from('profiles').select('id, display_name').limit(3);

          return (
            <main className="mx-auto flex min-h-screen max-w-5xl flex-col gap-8 px-6 py-16">
              <section className="rounded-3xl border border-slate-200 bg-white p-8 shadow-sm">
                <p className="text-sm font-semibold uppercase tracking-[0.24em] text-emerald-700">AI Web Director Profile S</p>
                <h1 className="mt-4 text-4xl font-bold tracking-tight text-slate-950">#{CGI.escapeHTML(title)}</h1>
                <p className="mt-4 max-w-2xl text-lg leading-8 text-slate-700">#{CGI.escapeHTML(context.fetch(:description))}</p>
              </section>

              <section className="rounded-3xl border border-dashed border-emerald-300 bg-emerald-50 p-6">
                <h2 className="text-2xl font-bold text-slate-950">Local Supabase planning stub</h2>
                <p className="mt-3 text-slate-700">
                  This scaffold uses safe public browser env names only and does not create or read dot-env files.
                </p>
                <pre className="mt-4 overflow-auto rounded-2xl bg-slate-950 p-4 text-sm text-emerald-100">
                  {JSON.stringify(profileRows ?? [], null, 2)}
                </pre>
              </section>
            </main>
          );
        }
      TSX
    end

    def globals_css_profile_s
      <<~CSS
        :root {
          color: #0f172a;
          background: #f8fafc;
          font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        }

        * {
          box-sizing: border-box;
        }

        body {
          margin: 0;
          min-width: 320px;
        }
      CSS
    end

    def supabase_client_ts_profile_s
      <<~TS
        import { createBrowserClient } from '@supabase/ssr';

        export function createClient() {
          return createBrowserClient(
            process.env.NEXT_PUBLIC_SUPABASE_URL!,
            process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
          );
        }
      TS
    end

    def supabase_server_ts_profile_s
      <<~TS
        import { createServerClient } from '@supabase/ssr';
        import { cookies } from 'next/headers';

        export async function createClient() {
          const cookieStore = await cookies();

          return createServerClient(
            process.env.NEXT_PUBLIC_SUPABASE_URL!,
            process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY!,
            {
              cookies: {
                getAll() {
                  return cookieStore.getAll();
                },
                setAll(cookiesToSet) {
                  try {
                    cookiesToSet.forEach(({ name, value, options }) => cookieStore.set(name, value, options));
                  } catch {
                    // Server Components cannot set cookies. Middleware should refresh sessions when needed.
                  }
                },
              },
            },
          );
        }
      TS
    end

    def supabase_initial_schema_profile_s
      <<~SQL
        -- Profile S draft migration for local planning only.
        -- Review with a database owner before applying to any external Supabase project.

        create table if not exists public.profiles (
          id uuid primary key references auth.users(id) on delete cascade,
          display_name text,
          created_at timestamptz not null default now(),
          updated_at timestamptz not null default now()
        );

        alter table public.profiles enable row level security;

        create policy "profiles are viewable by owner"
          on public.profiles for select
          using (auth.uid() = id);

        create policy "profiles are insertable by owner"
          on public.profiles for insert
          with check (auth.uid() = id);

        create policy "profiles are updatable by owner"
          on public.profiles for update
          using (auth.uid() = id)
          with check (auth.uid() = id);
      SQL
    end

    def supabase_rls_draft_profile_s
      <<~MD
        # Supabase RLS Draft — Profile S

        Status: draft for local planning only.

        ## Policies
        - `profiles`: owner-only select/insert/update using `auth.uid() = id`.
        - Add table-specific policies before connecting real product data.

        ## Guardrails
        - Do not apply this draft to a hosted Supabase project without review.
        - Keep service-role credentials out of generated app files and browser code.
        - Public browser variables are limited to `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`.
      MD
    end

    def supabase_storage_profile_s
      <<~MD
        # Supabase Storage Options — Profile S

        Status: planning notes only; no buckets are created by this scaffold.

        ## Option A: private user uploads
        - Bucket: `user-uploads`.
        - Access: authenticated owner read/write policies.
        - Use signed URLs for temporary sharing.

        ## Option B: public marketing assets
        - Bucket: `public-assets`.
        - Access: public read, restricted write.
        - Prefer static `public/` files until product scope needs runtime uploads.

        ## External-action guardrail
        This scaffold does not run Supabase CLI commands, create buckets, or contact external APIs.
      MD
    end

    def supabase_env_template_profile_s
      <<~TXT
        # Copy these keys into your local untracked environment file when you are ready.
        # This is intentionally not named .env.example because Profile S must not create dot-env files.
        NEXT_PUBLIC_SUPABASE_URL=https://your-project-ref.supabase.co
        NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=your-publishable-key
      TXT
    end

      end
    end
  end
end
