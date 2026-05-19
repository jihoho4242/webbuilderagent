# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"

module Aiweb
  module SelfImprovement
    class ExperimentRegistry
      def initialize(path: nil)
        @path = path
      end

      def record(proposal)
        record = {
          "schema_version" => 1,
          "experiment_id" => "experiment-#{SecureRandom.hex(8)}",
          "proposal_id" => proposal.fetch("proposal_id"),
          "status" => proposal.fetch("mode") == "blocked" ? "blocked" : "sandbox_planned",
          "fixture_status" => proposal.fetch("mode") == "blocked" ? "experiment_blocked" : "experiment_fixture_recorded",
          "production_gate_status" => "blocked",
          "sandbox_only" => true,
          "eval_result" => { "status" => "not_run", "required_before_promotion" => true },
          "promotion_allowed" => false,
          "production_ready_claim_allowed" => false,
          "operational_blocking_issues" => Array(proposal["operational_blocking_issues"])
        }
        persist(record)
        record
      end

      private

      def persist(record)
        return unless @path

        FileUtils.mkdir_p(File.dirname(@path))
        File.open(@path, "a") { |file| file.write(JSON.generate(record) + "\n") }
      end
    end
  end
end
