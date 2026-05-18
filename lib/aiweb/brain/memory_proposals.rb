# frozen_string_literal: true

module Aiweb
  module Brain
    class MemoryProposals
      def self.propose(summary:, source: "worker")
        { "schema_version" => 1, "status" => "proposal", "summary" => summary.to_s, "source" => source, "direct_write_allowed" => false }
      end
    end
  end
end
