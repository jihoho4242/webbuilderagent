# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    ENGINE_RUN_STATUSES = %w[dry_run blocked running waiting_approval failed no_changes passed cancelled quarantined].freeze
    ENGINE_RUN_MODES = %w[safe_patch agentic_local external_approval].freeze
    ENGINE_RUN_AGENTS = %w[codex openmanus openhands langgraph openai_agents_sdk].freeze
    ENGINE_RUN_DEFAULT_WRITABLE_GLOBS = %w[
      src/**
      app/**
      components/**
      pages/**
      styles/**
      test/**
      tests/**
      public/**
      lib/**
      package.json
      astro.config.*
      next.config.*
      tailwind.config.*
      vite.config.*
      tsconfig.json
    ].freeze
    ENGINE_RUN_STAGE_EXCLUDES = %w[
      .git
      node_modules
      dist
      build
      coverage
      vendor/bundle
      .ssh
      .aws
      .azure
      .gcloud
      .docker
      .kube
      .vercel
      .netlify
      .config/google-chrome
      .config/chromium
      .mozilla
      .npmrc
      .yarnrc
      .pypirc
      .netrc
      .ai-web/runs
      .ai-web/tmp
      .ai-web/diffs
      .ai-web/snapshots
      .ai-web/workbench
    ].freeze
    ENGINE_RUN_HIGH_RISK_PATTERNS = [
      %r{\Apackage(?:-lock)?\.json\z},
      %r{\A(?:pnpm-lock|yarn\.lock|bun\.lockb)\z},
      %r{\A(?:vercel|netlify|wrangler)\.json\z},
      %r{\A\.github/workflows/}
    ].freeze
    ENGINE_RUN_EXTERNAL_ACTION_PATTERN = /\b(?:npm|pnpm|yarn|bun)\s+(?:add|install|i|ci|update|upgrade|up)\b|\b(?:curl|wget)\s+https?:|(?:vercel|netlify|cloudflare|wrangler)\b|\bgit\s+push\b/i.freeze
    ENGINE_RUN_SECRET_VALUE_PATTERN = Aiweb::Redaction::SECRET_VALUE_PATTERN
  end
end
