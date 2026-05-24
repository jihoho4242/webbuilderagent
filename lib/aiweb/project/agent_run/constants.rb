# frozen_string_literal: true

module Aiweb
  module ProjectAgentRun
    AGENT_RUN_SHELL_REQUEST_PATTERN = /
      \b(?:
        rm\s+-[A-Za-z]*r|
        cat\s+\.env|
        printenv|
        curl|
        wget|
        ssh|
        scp|
        sudo|
        chmod|
        pnpm|
        npm|
        yarn|
        bun|
        vercel|
        netlify
      )\b
    /ix.freeze
    AGENT_RUN_SECRET_VALUE_PATTERN = /
      (?:\b[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PRIVATE[_-]?KEY|API[_-]?KEY)[A-Z0-9_]*=[^\s]+)|
      (?:-----BEGIN\ [A-Z ]*PRIVATE\ KEY-----)|
      (?:\bAKIA[0-9A-Z]{16}\b)|
      (?:\b(?:ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{10,}\b)|
      (?:\bxox[baprs]-[A-Za-z0-9-]{10,}\b)|
      (?:\b(?:sk|rk)_(?:live|test|proj)_[A-Za-z0-9_-]{10,}\b)
    /ix.freeze
    AGENT_RUN_SNAPSHOT_PRUNE_DIRS = %w[
      .git
      node_modules
      dist
      build
      coverage
      tmp
      vendor
    ].freeze
  end
end
