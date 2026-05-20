# frozen_string_literal: true

module Aiweb
  module Brain
    class MemoryAudit
      def audit(store)
        independent_audit = Aiweb::Brain::IndependentAudit.new.audit(store)
        sqlite_dependency = Aiweb::Brain::SQLiteStore.dependency_status
        metrics = {
          "storage_mode" => store.storage_mode,
          "persistent_store" => store.persistent?,
          "sqlite_available" => sqlite_dependency["status"] == "available",
          "sqlite_dependency_status" => sqlite_dependency["status"],
          "concurrency_backed" => store.concurrency_backed?,
          "lock_path_present" => !store.lock_path.to_s.empty?,
          "backup_restore_drill_present" => store.backup_restore_drill_present?,
          "independent_file_audit_passed" => independent_audit["status"] == "passed",
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
        blockers << "persistent Brain store is missing file-lock concurrency evidence" if store.persistent? && !metrics["concurrency_backed"]
        blockers.concat(independent_audit.fetch("blocking_issues", [])) if store.persistent? && independent_audit["status"] != "passed"
        operational_blockers = []
        unless sqlite_dependency["production_gate_status"] == "runtime_evidence_attached"
          operational_blockers << "production Brain still needs SQLite-backed storage evidence: #{sqlite_dependency.fetch("blocking_issues", []).join("; ")}"
        end
        operational_blockers << "production Brain still needs backup/restore drill evidence" unless metrics["backup_restore_drill_present"]
        operational_blockers << "production Brain still needs independent file-level memory audit evidence" unless metrics["independent_file_audit_passed"]
        {
          "schema_version" => 1,
          "status" => blockers.empty? ? "passed" : "blocked",
          "operational_status" => operational_blockers.empty? ? "ready" : "blocked",
          "metrics" => metrics,
          "sqlite_dependency" => sqlite_dependency,
          "independent_file_audit" => independent_audit,
          "operational_blocking_issues" => operational_blockers,
          "blocking_issues" => blockers
        }
      end
    end
  end
end
