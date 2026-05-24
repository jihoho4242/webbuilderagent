# frozen_string_literal: true

module Aiweb
  module Brain
    class Store
      def backup_restore_drill!
        return { "status" => "blocked", "blocking_issues" => ["backup/restore drill requires a persistent project-local Brain store"] } unless persistent?

        with_persistent_lock do
          reload_persistent_state!
          write_projection!
          write_health_report!
          FileUtils.mkdir_p(@backup_dir)
          backup_path = File.join(@backup_dir, "brain-backup-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}-#{SecureRandom.hex(4)}.json")
          backup = {
            "schema_version" => 1,
            "storage_mode" => storage_mode,
            "ledger_path" => relative_to_root(@path),
            "ledger_events" => @events,
            "ledger_event_count" => ledger_event_count,
            "last_event_hash" => last_event_hash,
            "created_at" => now
          }
          File.write(backup_path, JSON.pretty_generate(backup) + "\n")
          restored = restore_events_for_drill(Array(backup["ledger_events"]))
          status = restored.fetch("event_hash_chain_valid") && restored.fetch("last_event_hash") == last_event_hash && restored.fetch("item_count") == search.length ? "passed" : "blocked"
          drill = {
            "schema_version" => 1,
            "status" => status,
            "storage_mode" => storage_mode,
            "backup_path" => relative_to_root(backup_path),
            "source_ledger_event_count" => ledger_event_count,
            "restored_ledger_event_count" => restored.fetch("ledger_event_count"),
            "source_last_event_hash" => last_event_hash,
            "restored_last_event_hash" => restored.fetch("last_event_hash"),
            "source_item_count" => search.length,
            "restored_item_count" => restored.fetch("item_count"),
            "restored_tombstone_count" => restored.fetch("tombstone_count"),
            "event_hash_chain_valid" => restored.fetch("event_hash_chain_valid"),
            "blocking_issues" => status == "passed" ? [] : ["backup restore drill did not reproduce the Brain ledger state"],
            "recorded_at" => now
          }
          File.write(@backup_restore_drill_path, JSON.pretty_generate(drill) + "\n")
          write_health_report!
          drill
        end
      end

      private

      def restore_events_for_drill(events)
        items = []
        tombstones = []
        last_hash = nil
        valid = true
        events.each do |event|
          expected_previous = last_hash.to_s
          actual_previous = event["previous_event_hash"].to_s
          valid &&= expected_previous.empty? ? actual_previous.empty? : actual_previous == expected_previous
          event_hash = event["event_hash"].to_s
          valid &&= event_hash.empty? || event_hash_for(event.reject { |key, _| key == "event_hash" }) == event_hash
          last_hash = event_hash unless event_hash.empty?
          case event["event"]
          when "memory.remembered"
            item = event["item"].is_a?(Hash) ? event["item"] : nil
            items << item if item && !tombstones.include?(item["id"])
          when "memory.forgotten"
            memory_id = event["memory_id"].to_s
            tombstones << memory_id
            items.reject! { |item| item["id"] == memory_id }
          end
        end
        {
          "ledger_event_count" => events.length,
          "last_event_hash" => last_hash,
          "event_hash_chain_valid" => valid,
          "item_count" => items.reject { |item| tombstones.include?(item["id"]) }.length,
          "tombstone_count" => tombstones.uniq.length
        }
      end
    end
  end
end
