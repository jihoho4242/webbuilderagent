# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"

module Aiweb
  module Brain
    class Store
      SECRET_PATTERN = /(?:\.env|secret|credential|password|token|private[_-]?key)/i.freeze

      def initialize(root: nil)
        @root = root
        @path = root ? File.join(root, ".ai-web", "brain", "brain.json") : nil
        @items = []
        @tombstones = []
        load_persistent_state if @path
      end

      def remember(summary:, evidence_grade: "proposal", source: "manual", scope: "project")
        return { "status" => "blocked", "blocking_issues" => ["secret-like memory rejected"] } if summary.to_s.match?(SECRET_PATTERN)

        id = "memory-#{SecureRandom.hex(8)}"
        @items << { "id" => id, "summary" => summary.to_s, "evidence_grade" => evidence_grade, "source" => source, "scope" => scope, "storage" => storage_mode }
        persist!
        { "status" => "passed", "memory_id" => id, "blocking_issues" => [] }
      end

      def forget(memory_id)
        @tombstones << memory_id.to_s
        @items.reject! { |item| item["id"] == memory_id.to_s }
        persist!
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

      def storage_mode
        persistent? ? "project_local_json_mvp_sqlite_pending" : "memory_only"
      end

      private

      def load_persistent_state
        return unless File.file?(@path)

        data = JSON.parse(File.read(@path))
        @items = Array(data["items"])
        @tombstones = Array(data["tombstones"])
      rescue JSON::ParserError
        @items = []
        @tombstones = []
      end

      def persist!
        return unless @path

        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, JSON.pretty_generate({ "schema_version" => 1, "storage_mode" => storage_mode, "items" => @items, "tombstones" => @tombstones }) + "\n")
      end
    end
  end
end
