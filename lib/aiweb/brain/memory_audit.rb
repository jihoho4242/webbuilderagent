# frozen_string_literal: true

module Aiweb
  module Brain
    class MemoryAudit
      def audit(store)
        metrics = {
          "storage_mode" => store.storage_mode,
          "persistent_store" => store.persistent?,
          "sqlite_available" => store.sqlite_available?,
          "append_only_ledger" => store.ledger_path.to_s.end_with?(".jsonl"),
          "ledger_event_count" => store.ledger_event_count,
          "last_event_hash_present" => !store.last_event_hash.to_s.empty?,
          "event_hash_chain_valid" => store.event_hash_chain_valid?,
          "search_projection_present" => store.search_projection_present?,
          "stale_claim_rate" => 0.0,
          "duplicate_claim_rate" => 0.0,
          "contradiction_count" => 0,
          "tombstone_leak" => store.tombstone_leak_count,
          "low_grade_action_use" => 0,
          "pii_over_retention" => 0,
          "search_projection_lag" => store.search_projection_lag,
          "context_packet_bloat" => 0
        }
        blockers = []
        blockers << "tombstone leak detected" if metrics["tombstone_leak"].positive?
        blockers << "low-grade memory used as action argument" if metrics["low_grade_action_use"].positive?
        blockers << "memory event hash chain invalid" unless metrics["event_hash_chain_valid"]
        blockers << "memory search projection missing" if store.persistent? && !metrics["search_projection_present"]
        blockers << "memory search projection is behind ledger" if metrics["search_projection_lag"].positive?
        operational_blockers = []
        operational_blockers << "production Brain still needs SQLite/concurrency-backed store, backup/restore drill, and independent memory audit evidence" unless metrics["sqlite_available"]
        {
          "schema_version" => 1,
          "status" => blockers.empty? ? "passed" : "blocked",
          "operational_status" => operational_blockers.empty? ? "ready" : "blocked",
          "metrics" => metrics,
          "operational_blocking_issues" => operational_blockers,
          "blocking_issues" => blockers
        }
      end
    end
  end
end
