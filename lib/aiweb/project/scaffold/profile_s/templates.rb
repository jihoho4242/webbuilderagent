# frozen_string_literal: true

module Aiweb
  class Project
    module Scaffold
      module ProfileS
        private

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
