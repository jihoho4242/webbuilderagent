# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "securerandom"
require "time"

require_relative "store/projection"
require_relative "store/backup_restore"

module Aiweb
  module Brain
    class Store
      SECRET_PATTERN = /(?:\.env|secret|credential|password|token|private[_-]?key)/i.freeze

      def initialize(root: nil)
        @root = root
        @brain_dir = root ? File.join(root, ".ai-web", "brain") : nil
        @path = @brain_dir ? File.join(@brain_dir, "brain.jsonl") : nil
        @index_path = @brain_dir ? File.join(@brain_dir, "brain-index.json") : nil
        @health_report_path = @brain_dir ? File.join(@brain_dir, "memory-health-report.json") : nil
        @lock_path = @brain_dir ? File.join(@brain_dir, "brain.lock") : nil
        @backup_dir = @brain_dir ? File.join(@brain_dir, "backups") : nil
        @backup_restore_drill_path = @brain_dir ? File.join(@brain_dir, "backup-restore-drill.json") : nil
        @legacy_path = @brain_dir ? File.join(@brain_dir, "brain.json") : nil
        @items = []
        @tombstones = []
        @events = []
        @last_event_hash = nil
        @event_hash_chain_valid = true
        load_persistent_state if @path
        write_projection! if @path
        write_health_report! if @path
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
        if persistent?
          with_persistent_lock do
            reload_persistent_state!
            @items << item
            append_event_unlocked!("memory.remembered", "memory_id" => id, "item" => item)
          end
        else
          @items << item
        end
        { "status" => "passed", "memory_id" => id, "blocking_issues" => [] }
      end

      def forget(memory_id)
        if persistent?
          with_persistent_lock do
            reload_persistent_state!
            @tombstones << memory_id.to_s
            @items.reject! { |item| item["id"] == memory_id.to_s }
            append_event_unlocked!("memory.forgotten", "memory_id" => memory_id.to_s, "forgotten_at" => now)
          end
        else
          @tombstones << memory_id.to_s
          @items.reject! { |item| item["id"] == memory_id.to_s }
        end
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

      def index_path
        @index_path
      end

      def health_report_path
        @health_report_path
      end

      def lock_path
        @lock_path
      end

      def backup_restore_drill_path
        @backup_restore_drill_path
      end

      def concurrency_backed?
        persistent? && !@lock_path.to_s.empty?
      end

      def backup_restore_drill_present?
        @backup_restore_drill_path && File.file?(@backup_restore_drill_path)
      end

      def ledger_event_count
        @events.length
      end

      def last_event_hash
        @last_event_hash
      end

      def event_hash_chain_valid?
        @event_hash_chain_valid
      end

      def search_projection_present?
        @index_path && File.file?(@index_path)
      end

      def search_projection_lag
        return 0 unless persistent?
        return ledger_event_count unless search_projection_present?

        index = JSON.parse(File.read(@index_path))
        return ledger_event_count unless index["last_event_hash"].to_s == last_event_hash.to_s

        0
      rescue JSON::ParserError, SystemCallError
        ledger_event_count
      end

      def sqlite_available?
        begin
          require "sqlite3"
          true
        rescue LoadError
          false
        end
      end

      def storage_mode
        persistent? ? "project_local_jsonl_ledger_with_projection" : "memory_only"
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

      def reload_persistent_state!
        reset_loaded_state!
        replay_jsonl_ledger if File.file?(@path)
      end

      def reset_loaded_state!
        @items = []
        @tombstones = []
        @events = []
        @last_event_hash = nil
        @event_hash_chain_valid = true
      end

      def replay_jsonl_ledger
        File.foreach(@path) do |line|
          next if line.strip.empty?

          event = JSON.parse(line)
          @event_hash_chain_valid &&= valid_event_hash_link?(event)
          @events << event
          @last_event_hash = event["event_hash"].to_s unless event["event_hash"].to_s.empty?
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

      def append_event_unlocked!(event, payload)
        return unless @path

        FileUtils.mkdir_p(File.dirname(@path))
        record_without_hash = {
          "schema_version" => 1,
          "event_id" => "brain-event-#{SecureRandom.hex(8)}",
          "event" => event,
          "storage_mode" => storage_mode,
          "previous_event_hash" => @last_event_hash,
          "recorded_at" => now
        }.merge(payload)
        event_hash = event_hash_for(record_without_hash)
        record = record_without_hash.merge("event_hash" => event_hash)
        File.open(@path, "a") { |file| file.write(JSON.generate(record) + "\n") }
        @events << record
        @last_event_hash = event_hash
        write_projection!
        write_health_report!
      end

      def migrate_legacy_snapshot!
        return unless @path

        @items.each do |item|
          append_event_unlocked!("memory.remembered", "memory_id" => item["id"], "item" => item)
        end
        @tombstones.each do |memory_id|
          append_event_unlocked!("memory.forgotten", "memory_id" => memory_id, "forgotten_at" => now)
        end
      end

      def with_persistent_lock
        return yield unless @lock_path

        FileUtils.mkdir_p(File.dirname(@lock_path))
        File.open(@lock_path, "w") do |lock|
          lock.flock(File::LOCK_EX)
          yield
        ensure
          lock.flock(File::LOCK_UN) unless lock.closed?
        end
      end

      def valid_event_hash_link?(event)
        expected_previous = @last_event_hash.to_s
        actual_previous = event["previous_event_hash"].to_s
        return false if expected_previous.empty? && !actual_previous.empty?
        return false if !expected_previous.empty? && actual_previous != expected_previous

        hash = event["event_hash"].to_s
        return true if hash.empty?

        event_hash_for(event.reject { |key, _| key == "event_hash" }) == hash
      end

      def event_hash_for(record)
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(record.sort.to_h))}"
      end

      def relative_to_root(path)
        return nil unless path && @root

        File.expand_path(path).sub(%r{\A#{Regexp.escape(File.expand_path(@root))}[\\/]?}, "").tr("\\", "/")
      end

      def now
        Time.now.utc.iso8601
      end
    end
  end
end
