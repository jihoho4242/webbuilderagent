# frozen_string_literal: true

require_relative "browser_qa/playwright"
require_relative "browser_qa/screenshot"

module Aiweb
  module ProjectRuntimeCommands
    def browser_qa(dry_run: false)
      qa_playwright(dry_run: dry_run)
    end

  end
end
