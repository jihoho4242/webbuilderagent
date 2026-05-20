# frozen_string_literal: true

require "digest"
require "json"

module Aiweb
  module Brain
    class IndependentAudit
      def audit(store)
        events = read_jsonl(store.ledger_path)
        replay = replay_events(events)
        projection = read_json(store.index_path)
        health = read_json(store.health_report_path)
        drill = read_json(store.backup_restore_drill_path)
        blockers = []
        blockers << "Brain ledger is missing" if store.persistent? && events.empty?
        blockers << "Brain event hash chain invalid" unless replay.fetch("event_hash_chain_valid")
        blockers << "Brain projection does not match ledger" unless projection_matches?(projection, replay)
        blockers << "Brain health report does not match ledger" unless health_matches?(health, replay)
        blockers << "Brain backup/restore drill does not match ledger" if !drill.empty? && !drill_matches?(drill, replay)
        {
          "schema_version" => 1,
          "auditor" => "aiweb.brain.independent_file_audit.v1",
          "status" => blockers.empty? ? "passed" : "blocked",
          "storage_mode" => store.storage_mode,
          "ledger_event_count" => replay.fetch("ledger_event_count"),
          "last_event_hash" => replay.fetch("last_event_hash"),
          "event_hash_chain_valid" => replay.fetch("event_hash_chain_valid"),
          "projection_matches_ledger" => projection_matches?(projection, replay),
          "health_report_matches_ledger" => health_matches?(health, replay),
          "backup_restore_drill_present" => !drill.empty?,
          "backup_restore_drill_matches_ledger" => drill_matches?(drill, replay),
          "active_item_count" => replay.fetch("active_item_count"),
          "tombstone_count" => replay.fetch("tombstone_count"),
          "blocking_issues" => blockers
        }
      rescue JSON::ParserError, SystemCallError => e
        {
          "schema_version" => 1,
          "auditor" => "aiweb.brain.independent_file_audit.v1",
          "status" => "blocked",
          "blocking_issues" => ["Brain independent file audit failed: #{e.class}: #{e.message}"]
        }
      end

      private

      def read_jsonl(path)
        return [] unless path && File.file?(path)

        File.readlines(path, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
      end

      def read_json(path)
        return {} unless path && File.file?(path)

        JSON.parse(File.read(path))
      end

      def replay_events(events)
        active = {}
        tombstones = []
        last_hash = nil
        valid = true
        events.each do |event|
          previous = event["previous_event_hash"].to_s
          valid &&= last_hash.to_s.empty? ? previous.empty? : previous == last_hash
          event_hash = event["event_hash"].to_s
          valid &&= event_hash.start_with?("sha256:") && event_hash_for(event.reject { |key, _| key == "event_hash" }) == event_hash
          last_hash = event_hash
          case event["event"]
          when "memory.remembered"
            item = event["item"].is_a?(Hash) ? event["item"] : nil
            active[item["id"].to_s] = item if item && !tombstones.include?(item["id"].to_s)
          when "memory.forgotten"
            memory_id = event["memory_id"].to_s
            tombstones << memory_id
            active.delete(memory_id)
          else
            valid = false
          end
        end
        {
          "ledger_event_count" => events.length,
          "last_event_hash" => last_hash,
          "event_hash_chain_valid" => valid,
          "active_item_count" => active.length,
          "tombstone_count" => tombstones.uniq.length
        }
      end

      def projection_matches?(projection, replay)
        projection["ledger_event_count"] == replay.fetch("ledger_event_count") &&
          projection["last_event_hash"].to_s == replay.fetch("last_event_hash").to_s &&
          projection["event_hash_chain_valid"] == replay.fetch("event_hash_chain_valid") &&
          projection["item_count"] == replay.fetch("active_item_count")
      end

      def health_matches?(health, replay)
        health["ledger_event_count"] == replay.fetch("ledger_event_count") &&
          health["last_event_hash"].to_s == replay.fetch("last_event_hash").to_s &&
          health["event_hash_chain_valid"] == replay.fetch("event_hash_chain_valid")
      end

      def drill_matches?(drill, replay)
        drill["status"] == "passed" &&
          drill["source_ledger_event_count"] == replay.fetch("ledger_event_count") &&
          drill["restored_ledger_event_count"] == replay.fetch("ledger_event_count") &&
          drill["source_last_event_hash"].to_s == replay.fetch("last_event_hash").to_s &&
          drill["restored_last_event_hash"].to_s == replay.fetch("last_event_hash").to_s &&
          drill["source_item_count"] == replay.fetch("active_item_count") &&
          drill["restored_item_count"] == replay.fetch("active_item_count") &&
          drill["event_hash_chain_valid"] == replay.fetch("event_hash_chain_valid")
      end

      def event_hash_for(record)
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(record.sort.to_h))}"
      end
    end
  end
end
