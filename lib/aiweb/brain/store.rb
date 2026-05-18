# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"

module Aiweb
  module Brain
    class Store
      SECRET_PATTERN = /(?:\.env|secret|credential|password|token|private[_-]?key)/i.freeze

      def initialize
        @items = []
        @tombstones = []
      end

      def remember(summary:, evidence_grade: "proposal", source: "manual", scope: "project")
        return { "status" => "blocked", "blocking_issues" => ["secret-like memory rejected"] } if summary.to_s.match?(SECRET_PATTERN)

        id = "memory-#{SecureRandom.hex(8)}"
        @items << { "id" => id, "summary" => summary.to_s, "evidence_grade" => evidence_grade, "source" => source, "scope" => scope }
        { "status" => "passed", "memory_id" => id, "blocking_issues" => [] }
      end

      def forget(memory_id)
        @tombstones << memory_id.to_s
        @items.reject! { |item| item["id"] == memory_id.to_s }
        { "status" => "passed", "memory_id" => memory_id.to_s }
      end

      def search
        @items.reject { |item| @tombstones.include?(item["id"]) }
      end

      def tombstone_leak_count
        search.count { |item| @tombstones.include?(item["id"]) }
      end
    end
  end
end
