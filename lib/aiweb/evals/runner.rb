# frozen_string_literal: true

module Aiweb
  module Evals
    class Runner
      def run(cases: [])
        total = Array(cases).length
        failures = Array(cases).count { |case_record| case_record["status"].to_s == "failed" }
        {
          "schema_version" => 1,
          "status" => failures.zero? ? "passed" : "failed",
          "case_count" => total,
          "failure_count" => failures,
          "production_ready_claim_allowed" => total > 1 && failures.zero?,
          "blocking_issues" => total <= 1 ? ["single fixture cannot claim production-ready eval science"] : []
        }
      end
    end
  end
end
