# frozen_string_literal: true

module Aiweb
  module Brain
    class Store
      private

      def write_projection!
        return unless @index_path

        FileUtils.mkdir_p(File.dirname(@index_path))
        projection = {
          "schema_version" => 1,
          "storage_mode" => storage_mode,
          "projection" => "bounded_lexical_memory_index",
          "ledger_path" => relative_to_root(@path),
          "ledger_event_count" => ledger_event_count,
          "last_event_hash" => last_event_hash,
          "event_hash_chain_valid" => event_hash_chain_valid?,
          "item_count" => search.length,
          "tombstone_count" => @tombstones.uniq.length,
          "items" => search.map { |item| index_item(item) },
          "tombstones" => @tombstones.uniq,
          "updated_at" => now
        }
        File.write(@index_path, JSON.pretty_generate(projection) + "\n")
      end

      def write_health_report!
        return unless @health_report_path

        report = {
          "schema_version" => 1,
          "storage_mode" => storage_mode,
          "ledger_path" => relative_to_root(@path),
          "index_path" => relative_to_root(@index_path),
          "ledger_event_count" => ledger_event_count,
          "last_event_hash" => last_event_hash,
          "event_hash_chain_valid" => event_hash_chain_valid?,
          "concurrency_backed" => concurrency_backed?,
          "lock_path" => relative_to_root(@lock_path),
          "backup_restore_drill_present" => backup_restore_drill_present?,
          "backup_restore_drill_path" => relative_to_root(@backup_restore_drill_path),
          "search_projection_lag" => search_projection_lag,
          "tombstone_leak" => tombstone_leak_count,
          "recorded_at" => now
        }
        File.write(@health_report_path, JSON.pretty_generate(report) + "\n")
      end

      def index_item(item)
        summary = item["summary"].to_s
        {
          "id" => item["id"].to_s,
          "summary_hash" => "sha256:#{Digest::SHA256.hexdigest(summary)}",
          "evidence_grade" => item["evidence_grade"].to_s,
          "source" => item["source"].to_s,
          "scope" => item["scope"].to_s,
          "created_at" => item["created_at"].to_s,
          "search_text" => summary.downcase
        }
      end
    end
  end
end
