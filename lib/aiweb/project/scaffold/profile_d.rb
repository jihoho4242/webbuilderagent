# frozen_string_literal: true

module Aiweb
  class Project
    module Scaffold
      module ProfileD
        private

    def scaffold_profile_d_metadata(files, state, profile_data)
      selected = selected_candidate_id
      {
        "schema_version" => 1,
        "profile" => "D",
        "framework" => "Astro",
        "package_manager" => "pnpm",
        "dev_command" => "pnpm dev",
        "build_command" => "pnpm build",
        "scaffold_target" => profile_data.fetch(:scaffold_target),
        "selected_candidate" => selected,
        "selected_candidate_path" => selected ? ".ai-web/design-candidates/#{selected}.html" : nil,
        "design_source" => File.exist?(File.join(aiweb_dir, "DESIGN.md")) ? ".ai-web/DESIGN.md" : nil,
        "design_brief_source" => File.exist?(File.join(aiweb_dir, "design-brief.md")) ? ".ai-web/design-brief.md" : nil,
        "created_at" => now,
        "metadata_path" => SCAFFOLD_PROFILE_D_METADATA_PATH,
        "files" => files.keys.map do |relative_path|
          {
            "path" => relative_path,
            "sha256" => Digest::SHA256.hexdigest(files.fetch(relative_path))
          }
        end
      }
    end

    def scaffold_profile_d_files(state)
      context = scaffold_context(state)
      {
        "package.json" => package_json_profile_d(context),
        "astro.config.mjs" => astro_config_profile_d,
        "tailwind.config.mjs" => tailwind_config_profile_d,
        "src/styles/global.css" => global_css_profile_d,
        "src/content/site.json" => JSON.pretty_generate(site_content_profile_d(context)) + "\n",
        "src/components/Hero.astro" => hero_component_profile_d,
        "src/components/SectionCard.astro" => section_card_component_profile_d,
        "src/pages/index.astro" => index_page_profile_d(context),
        "public/.gitkeep" => ""
      }
    end


    def package_json_profile_d(context)
      JSON.pretty_generate(
        "name" => npm_package_name(context.fetch(:project_id).empty? ? context.fetch(:project_name) : context.fetch(:project_id)),
        "version" => "0.1.0",
        "private" => true,
        "type" => "module",
        "scripts" => {
          "dev" => "astro dev",
          "build" => "astro build",
          "preview" => "astro preview"
        },
        "dependencies" => {
          "@astrojs/mdx" => "latest",
          "@astrojs/sitemap" => "latest",
          "astro" => "latest",
          "tailwindcss" => "latest",
          "@tailwindcss/vite" => "latest"
        }
      ) + "\n"
    end

    def astro_config_profile_d
      <<~JS
        import { defineConfig } from 'astro/config';
        import mdx from '@astrojs/mdx';
        import sitemap from '@astrojs/sitemap';
        import tailwindcss from '@tailwindcss/vite';

        export default defineConfig({
          integrations: [mdx(), sitemap()],
          vite: {
            plugins: [tailwindcss()]
          }
        });
      JS
    end

    def tailwind_config_profile_d
      <<~JS
        export default {
          content: ['./src/**/*.{astro,html,js,jsx,md,mdx,svelte,ts,tsx,vue}'],
          theme: {
            extend: {
              colors: {
                ink: '#111827',
                paper: '#fffaf3',
                accent: '#2563eb'
              }
            }
          }
        };
      JS
    end

    def global_css_profile_d
      <<~CSS
        @import "tailwindcss";

        :root {
          color: #111827;
          background: #fffaf3;
          font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
        }

        body {
          margin: 0;
          min-width: 320px;
        }

        a {
          color: inherit;
        }
      CSS
    end

    def site_content_profile_d(context)
      {
        "schema_version" => 1,
        "title" => context.fetch(:title),
        "description" => context.fetch(:description),
        "archetype" => context.fetch(:archetype),
        "primary_interaction" => context.fetch(:primary_interaction),
        "must_have_first_view" => context.fetch(:must_have_first_view),
        "must_not_have" => context.fetch(:must_not_have),
        "selected_candidate" => context.fetch(:selected_candidate),
        "selected_candidate_path" => context.fetch(:selected_candidate_path),
        "design_brief_excerpt" => context.fetch(:design_brief_excerpt),
        "design_system_excerpt" => context.fetch(:design_system_excerpt),
        "content_policy" => "Use only source-backed proof. Do not add fake testimonials, fake logos, fake customer counts, or fake metrics."
      }
    end

    def hero_component_profile_d
      <<~ASTRO
        ---
        const { title, description, primaryInteraction, selectedCandidate } = Astro.props;
        ---

        <section class="mx-auto grid max-w-6xl gap-8 px-6 py-20 md:grid-cols-[1.2fr_0.8fr] md:items-center" data-aiweb-id="page.home.hero">
          <div data-aiweb-id="component.hero.copy">
            <p class="mb-3 text-sm font-semibold uppercase tracking-[0.24em] text-blue-700">AI Web Director Profile D</p>
            <h1 class="text-4xl font-bold tracking-tight text-slate-950 md:text-6xl">{title}</h1>
            <p class="mt-5 max-w-2xl text-lg leading-8 text-slate-700">{description}</p>
            <div class="mt-8 rounded-2xl border border-slate-200 bg-white/80 p-5 shadow-sm" data-aiweb-id="component.hero.primary-interaction">
              <p class="text-sm font-semibold text-slate-500">Primary first-view interaction</p>
              <p class="mt-2 text-xl font-semibold text-slate-950">{primaryInteraction || 'TODO: confirm from .ai-web/first-view-contract.md'}</p>
            </div>
          </div>
          <aside class="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm" data-aiweb-id="component.hero.design-reference">
            <p class="text-sm font-semibold text-slate-500">Design reference</p>
            <p class="mt-2 text-2xl font-bold text-slate-950">{selectedCandidate || 'No selected candidate yet'}</p>
            <p class="mt-3 text-sm leading-6 text-slate-600">Generated from Director artifacts. Keep DESIGN.md authoritative and replace placeholders only with source-backed content.</p>
          </aside>
        </section>
      ASTRO
    end

    def section_card_component_profile_d
      <<~ASTRO
        ---
        const { title, items = [], aiwebId = 'component.section-card' } = Astro.props;
        ---

        <section class="mx-auto max-w-6xl px-6 py-10" data-aiweb-id={aiwebId}>
          <div class="rounded-3xl border border-slate-200 bg-white p-6 shadow-sm">
            <h2 class="text-2xl font-bold text-slate-950">{title}</h2>
            <ul class="mt-5 grid gap-3 text-slate-700 md:grid-cols-2">
              {items.map((item) => <li class="rounded-2xl bg-slate-50 p-4" data-aiweb-id={`${aiwebId}.item`}>{item}</li>)}
            </ul>
          </div>
        </section>
      ASTRO
    end

    def index_page_profile_d(context)
      <<~ASTRO
        ---
        import '../styles/global.css';
        import site from '../content/site.json';
        import Hero from '../components/Hero.astro';
        import SectionCard from '../components/SectionCard.astro';

        const title = site.title || #{context.fetch(:project_name).inspect};
        const description = site.description || 'Static site scaffold generated from AI Web Director artifacts.';
        ---

        <html lang="ko" data-aiweb-id="document.home">
          <head>
            <meta charset="utf-8" />
            <meta name="viewport" content="width=device-width, initial-scale=1" />
            <meta name="description" content={description} />
            <title>{title}</title>
          </head>
          <body class="bg-[var(--color-paper,#fffaf3)]">
            <main data-aiweb-id="page.home">
              <Hero
                title={title}
                description={description}
                primaryInteraction={site.primary_interaction}
                selectedCandidate={site.selected_candidate}
              />
              <SectionCard title="First-view obligations" items={site.must_have_first_view || []} aiwebId="page.home.first-view-obligations" />
              <SectionCard title="Forbidden or excluded patterns" items={site.must_not_have || []} aiwebId="page.home.must-not-have" />
              <section class="mx-auto max-w-6xl px-6 py-10" data-aiweb-id="page.home.source-notes">
                <div class="rounded-3xl border border-dashed border-slate-300 bg-white/70 p-6">
                  <h2 class="text-2xl font-bold text-slate-950">Source notes</h2>
                  <p class="mt-4 text-sm leading-6 text-slate-600">Selected candidate: {site.selected_candidate || 'none'}</p>
                  <p class="mt-2 text-sm leading-6 text-slate-600">Policy: {site.content_policy}</p>
                </div>
              </section>
            </main>
          </body>
        </html>
      ASTRO
    end
      end
    end
  end
end
