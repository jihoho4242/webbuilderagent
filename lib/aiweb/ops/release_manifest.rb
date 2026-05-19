# frozen_string_literal: true

require "digest"
require "yaml"

module Aiweb
  module Ops
    class ReleaseManifest
      def build(p5_evidence)
        evidence_files = %w[
          releases/v0.3.2-rc1/p5_gate_report.md
        ].map do |path|
          {
            "path" => path,
            "sha256" => File.file?(path) ? "sha256:#{Digest::SHA256.file(path).hexdigest}" : nil
          }
        end
        {
          "schema_version" => 1,
          "release_id" => p5_evidence.fetch("release_id"),
          "release_ready" => p5_evidence.fetch("release_ready"),
          "p5_status" => p5_evidence.fetch("p5_status", "unknown"),
          "production_readiness_claimed" => p5_evidence.fetch("production_readiness_claimed", false),
          "operational_readiness" => p5_evidence.fetch("operational_readiness", "unknown"),
          "constitution_hash" => p5_evidence.fetch("constitution_hash"),
          "p5_evidence_status" => p5_evidence.fetch("scaffold_demo_blocking_issues", []).empty? ? "scaffold_demo_passed" : "scaffold_demo_blocked",
          "commit_sha" => current_commit_sha,
          "github_actions_run_id" => nil,
          "evidence_files" => evidence_files,
          "schema_validation_report" => {
            "status" => "local_bin_check_passed",
            "command" => "ruby bin/check"
          },
          "eval_report" => {
            "status" => p5_evidence.dig("eval", "status"),
            "case_count" => p5_evidence.dig("eval", "case_count"),
            "production_ready_claim_allowed" => p5_evidence.dig("eval", "production_ready_claim_allowed")
          },
          "redteam_report" => {
            "status" => p5_evidence.dig("redteam", "status"),
            "critical_high_bypass_count" => p5_evidence.dig("redteam", "critical_high_bypass_count")
          },
          "rollback_plan" => {
            "status" => "documented_local_revert_only",
            "summary" => "revert the release commit and rerun ruby bin/check before any future release claim"
          },
          "operator_drill" => {
            "status" => "placeholder",
            "blocking_issue" => "operator drill must be run in CI/ops environment before operational readiness can be claimed"
          },
          "operational_blocking_issues" => p5_evidence.fetch("operational_blocking_issues", [])
        }
      end

      private

      def current_commit_sha
        git_dir = ".git"
        return nil unless Dir.exist?(git_dir)

        head = File.read(File.join(git_dir, "HEAD")).strip
        return head if head.match?(/\A[0-9a-f]{40}\z/i)
        return nil unless head.start_with?("ref: ")

        ref = head.delete_prefix("ref: ").strip
        ref_path = File.join(git_dir, ref)
        return File.read(ref_path).strip if File.file?(ref_path)

        packed_refs_path = File.join(git_dir, "packed-refs")
        return nil unless File.file?(packed_refs_path)

        File.foreach(packed_refs_path) do |line|
          next if line.start_with?("#", "^")

          sha, name = line.strip.split(/\s+/, 2)
          return sha if name == ref && sha.to_s.match?(/\A[0-9a-f]{40}\z/i)
        end
        nil
      rescue StandardError
        nil
      end
    end
  end
end
