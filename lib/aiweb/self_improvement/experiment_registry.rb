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
          "status" => proposal.fetch("mode") == "blocked" ? "blocked" : "planned",
          "sandbox_only" => true,
          "eval_result" => { "status" => "not_run", "required_before_promotion" => true },
          "promotion_allowed" => false
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
