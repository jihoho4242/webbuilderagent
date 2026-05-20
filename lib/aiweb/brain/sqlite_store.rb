# frozen_string_literal: true

module Aiweb
  module Brain
    class SQLiteStore
      def self.available?
        require "sqlite3"
        true
      rescue LoadError
        false
      end

      def self.dependency_status
        if available?
          {
            "schema_version" => 1,
            "adapter" => "aiweb.brain.sqlite_store.v1",
            "status" => "available",
            "gem" => "sqlite3",
            "production_gate_status" => "blocked",
            "blocking_issues" => ["SQLite adapter dependency is available, but runtime migration/storage evidence is not attached"]
          }
        else
          {
            "schema_version" => 1,
            "adapter" => "aiweb.brain.sqlite_store.v1",
            "status" => "missing_dependency",
            "gem" => "sqlite3",
            "production_gate_status" => "blocked",
            "blocking_issues" => ["sqlite3 Ruby gem is not available in this runtime; production SQLite-backed Brain evidence cannot be claimed"]
          }
        end
      end

      def initialize(root:)
        raise LoadError, "sqlite3 Ruby gem is required for Aiweb::Brain::SQLiteStore" unless self.class.available?

        @root = root
      end

      attr_reader :root
    end
  end
end
