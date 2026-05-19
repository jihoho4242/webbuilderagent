# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"
require "time"

module Aiweb
  module Brain
    class Store
      SECRET_PATTERN = /(?:\.env|secret|credential|password|token|private[_-]?key)/i.freeze

      def initialize(root: nil)
        @root = root
        @path = root ? File.join(root, ".ai-web", "brain", "brain.jsonl") : nil
        @legacy_path = root ? File.join(root, ".ai-web", "brain", "brain.json") : nil
        @items = []
        @tombstones = []
        load_persistent_state if @path
      end

      def remember(summary:, evidence_grade: "proposal", source: "manual", scope: "project")
        return { "status" => "blocked", "blocking_issues" => ["secret-like memory rejected"] } if summary.to_s.match?(SECRET_PATTERN)

        id = "memory-#{SecureRandom.hex(8)}"
        item = {
          "id" => id,
          "summary" => summary.to_s,
          "evidence_grade" => evidence_grade,
          "source" => source,
          "scope" => scope,
          "storage" => storage_mode,
          "created_at" => now
        }
        @items << item
        append_event!("memory.remembered", "memory_id" => id, "item" => item)
        { "status" => "passed", "memory_id" => id, "blocking_issues" => [] }
      end

      def forget(memory_id)
        @tombstones << memory_id.to_s
        @items.reject! { |item| item["id"] == memory_id.to_s }
        append_event!("memory.forgotten", "memory_id" => memory_id.to_s, "forgotten_at" => now)
        { "status" => "passed", "memory_id" => memory_id.to_s }
      end

      def search
        @items.reject { |item| @tombstones.include?(item["id"]) }
      end

      def tombstone_leak_count
        search.count { |item| @tombstones.include?(item["id"]) }
      end

      def persistent?
        !@path.nil?
      end

      def ledger_path
        @path
      end

      def sqlite_available?
        false
      end

      def storage_mode
        persistent? ? "project_local_jsonl_ledger_sqlite_unavailable" : "memory_only"
      end

      private

      def load_persistent_state
        if File.file?(@path)
          replay_jsonl_ledger
          return
        end
        return unless File.file?(@legacy_path)

        data = JSON.parse(File.read(@legacy_path))
        @tombstones = Array(data["tombstones"]).map(&:to_s)
        @items = Array(data["items"]).reject { |item| @tombstones.include?(item["id"].to_s) }
        migrate_legacy_snapshot!
      rescue JSON::ParserError
        @items = []
        @tombstones = []
      end

      def replay_jsonl_ledger
        File.foreach(@path) do |line|
          next if line.strip.empty?

          event = JSON.parse(line)
          case event["event"]
          when "memory.remembered"
            item = event["item"].is_a?(Hash) ? event["item"] : nil
            @items << item if item && !@tombstones.include?(item["id"])
          when "memory.forgotten"
            memory_id = event["memory_id"].to_s
            @tombstones << memory_id
            @items.reject! { |item| item["id"] == memory_id }
          end
        end
      end

      def append_event!(event, payload)
        return unless @path

        FileUtils.mkdir_p(File.dirname(@path))
        record = {
          "schema_version" => 1,
          "event_id" => "brain-event-#{SecureRandom.hex(8)}",
          "event" => event,
          "storage_mode" => storage_mode,
          "recorded_at" => now
        }.merge(payload)
        File.open(@path, "a") { |file| file.write(JSON.generate(record) + "\n") }
      end

      def migrate_legacy_snapshot!
        return unless @path

        @items.each do |item|
          append_event!("memory.remembered", "memory_id" => item["id"], "item" => item)
        end
        @tombstones.each do |memory_id|
          append_event!("memory.forgotten", "memory_id" => memory_id, "forgotten_at" => now)
        end
      end

      def now
        Time.now.utc.iso8601
      end
    end
  end
end
