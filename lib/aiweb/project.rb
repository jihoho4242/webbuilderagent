# frozen_string_literal: true

require "cgi"
require "digest"
require "fileutils"
require "find"
require "json"
require "open3"
require "rbconfig"
require "securerandom"
require "set"
require "shellwords"
require "timeout"
require "time"
require "uri"
require "yaml"

require_relative "errors"
require_relative "redaction"
require_relative "authz_contract"
require_relative "archetypes"
require_relative "design_brief"
require_relative "design_candidate_generator"
require_relative "design_research"
require_relative "design_system_resolver"
require_relative "intent_router"
require_relative "lazyweb_client"
require_relative "profiles"
require_relative "profile_policy"
require_relative "runtime"
require_relative "constitution"
require_relative "policy"
require_relative "tools"
require_relative "approval"
require_relative "brain"
require_relative "self_improvement"
require_relative "observability"
require_relative "evals"
require_relative "redteam"
require_relative "ops"
require_relative "agent_runtime"
require_relative "project/features"

module Aiweb
  class Project
    include ProjectFeatures
    PHASES = %w[
      phase--1
      phase-0
      phase-0.25
      phase-0.5
      phase-1
      phase-1.5
      phase-2
      phase-2.5
      phase-3
      phase-3.5
      phase-4
      phase-5
      phase-6
      phase-7
      phase-8
      phase-9
      phase-10
      phase-11
      complete
    ].freeze

    ADVANCE_PHASES = (PHASES - ["phase--1", "complete"]).freeze

    REQUIRED_TOP_LEVEL_STATE_KEYS = %w[
      schema_version project phase gates artifacts design_candidates research implementation setup qa deploy budget adapters invalidations decisions snapshots
    ].freeze

    DESIGN_REFERENCE_BRIEF_PATH = ".ai-web/design-reference-brief.md".freeze
    DESIGN_REFERENCE_RESULTS_PATH = ".ai-web/research/lazyweb/results.json".freeze
    DESIGN_PATTERN_MATRIX_PATH = ".ai-web/research/lazyweb/pattern-matrix.md".freeze

    SCAFFOLD_PROFILE_D_METADATA_PATH = ".ai-web/scaffold-profile-D.json".freeze
    SCAFFOLD_PROFILE_S_METADATA_PATH = ".ai-web/scaffold-profile-S.json".freeze
    SCAFFOLD_PROFILE_S_SECRET_QA_PATH = ".ai-web/qa/supabase-secret-qa.json".freeze
    SCAFFOLD_PROFILE_S_LOCAL_VERIFY_PATH = ".ai-web/qa/supabase-local-verify.json".freeze
    GITHUB_SYNC_PLAN_PATH = ".ai-web/github-sync.json".freeze
    DEPLOY_PLAN_PATH = ".ai-web/deploy-plan.json".freeze
    DEPLOY_PROVIDER_CONFIG_PATHS = {
      "cloudflare-pages" => ".ai-web/deploy/cloudflare-pages.json",
      "vercel" => ".ai-web/deploy/vercel.json"
    }.freeze
    VERIFY_LOOP_MAX_CYCLES = 10
    ACTIVE_RUN_LOCK_PATH = ".ai-web/runs/active-run.json"
    RUN_LIFECYCLE_FILE = "lifecycle.json"
    RUN_CANCEL_REQUEST_FILE = "cancel-request.json"
    RUN_RESUME_PLAN_FILE = "resume-plan.json"
    RUN_METADATA_FILENAMES = %w[
      verify-loop.json
      deploy.json
      workbench-serve.json
      setup.json
      agent-run.json
      engine-run.json
      preview.json
    ].freeze

    REMOVED_DIRECTOR_RUN_ACTIONS = %w[
      interview
      design-prompt
      placeholder-design-candidate
      next-task
      qa-checklist
    ].freeze

    SCAFFOLD_PROFILE_D_REQUIRED_FILES = %w[
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

    PROFILE_D_EXPECTED_SCRIPTS = {
      "dev" => "astro dev",
      "build" => "astro build",
      "preview" => "astro preview"
    }.freeze

    PROFILE_D_EXPECTED_DEPENDENCIES = %w[
      @astrojs/mdx
      @astrojs/sitemap
      astro
      tailwindcss
      @tailwindcss/vite
    ].freeze

    SCAFFOLD_PROFILE_S_REQUIRED_FILES = %w[
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
    ].freeze

    PROFILE_S_SECRET_EXPOSURE_PATTERNS = [
      /SUPABASE_SERVICE_ROLE_KEY/,
      /sb_secret_[A-Za-z0-9_-]+/,
      /eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/
    ].freeze
    attr_reader :root, :templates_dir

    def initialize(root)
      @root = File.expand_path(root)
      @templates_dir = File.expand_path("../../docs/templates", __dir__)
    end

    def aiweb_dir
      File.join(root, ".ai-web")
    end

    def initialized?
      File.exist?(state_path)
    end

    def state_path
      File.join(aiweb_dir, "state.yaml")
    end

    def quality_path
      File.join(aiweb_dir, "quality.yaml")
    end

    def load_state
      assert_initialized!
      YAML.load_file(state_path)
    rescue Psych::SyntaxError => e
      raise UserError.new("cannot parse state.yaml: #{e.message}", 1)
    end




    private

  end
end
