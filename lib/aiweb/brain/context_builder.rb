# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

module Aiweb
  module Brain
    class ContextBuilder
      def build(items:, source: "project", scope: "project", evidence_grade: "proposal")
        packet = {
          "schema_version" => 1,
          "context_packet_id" => "brain-context-#{SecureRandom.hex(8)}",
          "source" => source,
          "scope" => scope,
          "evidence_grade" => evidence_grade,
          "items" => Array(items),
          "low_grade_action_use_allowed" => false
        }
        packet["context_hash"] = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(packet))}"
        packet
      end
    end
  end
end
