# frozen_string_literal: true

module Aiweb
  module AgentRuntime
    class ToolRegistry
      TOOLS = {
        "build" => { "profile_support" => %w[D], "artifact" => "tool-result-build.json" },
        "preview" => { "profile_support" => %w[D], "artifact" => "tool-result-preview.json" },
        "browser_qa" => { "profile_support" => %w[D], "artifact" => "browser-qa-feedback.json" },
        "local_verify" => { "profile_support" => %w[S], "artifact" => "tool-result-local-verify.json" },
        "source_patch" => { "profile_support" => %w[D S], "artifact" => "source-patch-manifest.json" },
        "finish" => { "profile_support" => %w[D S], "artifact" => "final-report.json" }
      }.freeze

      def to_h
        TOOLS
      end
    end
  end
end
