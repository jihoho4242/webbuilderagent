# frozen_string_literal: true

module Aiweb
  module Brain
    class SearchProjection
      def self.status(store = nil)
        return { "schema_version" => 1, "status" => "not_configured", "global_rerank" => false } unless store

        {
          "schema_version" => 1,
          "status" => store.search_projection_lag.zero? ? "ready" : "lagging",
          "global_rerank" => false,
          "index_path" => store.index_path,
          "ledger_event_count" => store.ledger_event_count,
          "last_event_hash" => store.last_event_hash,
          "search_projection_lag" => store.search_projection_lag,
          "event_hash_chain_valid" => store.event_hash_chain_valid?
        }
      end
    end
  end
end
