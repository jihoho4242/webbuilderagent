# frozen_string_literal: true

require "yaml"

module Aiweb
  module Ops
    class ReleaseManifest
      def build(p5_evidence)
        {
          "schema_version" => 1,
          "release_id" => p5_evidence.fetch("release_id"),
          "release_ready" => p5_evidence.fetch("release_ready"),
          "constitution_hash" => p5_evidence.fetch("constitution_hash"),
          "p5_evidence_status" => p5_evidence.fetch("blocking_issues").empty? ? "passed" : "blocked"
        }
      end
    end
  end
end
