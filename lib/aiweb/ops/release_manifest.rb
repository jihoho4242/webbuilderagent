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
          "schema_validation_report" => validation_report(p5_evidence),
          "policy_gateway_report" => {
            "status" => p5_evidence.dig("policy_coverage", "status"),
            "coverage_status" => p5_evidence.dig("policy_coverage", "coverage_status"),
            "all_side_effects_require_decision_packet_policy_gateway" => p5_evidence.dig("policy_coverage", "all_side_effects_require_decision_packet_policy_gateway"),
            "production_gate_status" => p5_evidence.dig("policy_coverage", "production_gate_status"),
            "demo_tool" => p5_evidence.dig("policy_coverage", "demo_tool")
          },
          "side_effect_surface_audit_report" => {
            "status" => p5_evidence.dig("side_effect_surface_audit", "status"),
            "scanner" => p5_evidence.dig("side_effect_surface_audit", "scanner"),
            "coverage_status" => p5_evidence.dig("side_effect_surface_audit", "coverage_status"),
            "entry_count" => p5_evidence.dig("side_effect_surface_audit", "entry_count"),
            "unclassified_count" => p5_evidence.dig("side_effect_surface_audit", "unclassified_count"),
            "runtime_universal_enforcement_proven" => p5_evidence.dig("side_effect_surface_audit", "runtime_universal_enforcement_proven"),
            "production_gate_status" => p5_evidence.dig("side_effect_surface_audit", "production_gate_status"),
            "production_ready_claim_allowed" => p5_evidence.dig("side_effect_surface_audit", "production_ready_claim_allowed")
          },
          "tool_gateway_report" => {
            "status" => p5_evidence.dig("tool_gateway_coverage", "status"),
            "verifier_status" => p5_evidence.dig("tool_gateway_coverage", "verifier_status"),
            "demo_tool" => p5_evidence.dig("tool_gateway_coverage", "demo_tool"),
            "production_gate_status" => p5_evidence.dig("tool_gateway_coverage", "production_gate_status"),
            "production_ready_claim_allowed" => p5_evidence.dig("tool_gateway_coverage", "production_ready_claim_allowed")
          },
          "hitl_report" => {
            "status" => p5_evidence.dig("hitl_v2", "fixture_status"),
            "verifier_status" => p5_evidence.dig("hitl_v2", "status"),
            "production_gate_status" => p5_evidence.dig("hitl_v2", "production_gate_status"),
            "approver_fixture_only" => p5_evidence.dig("hitl_v2", "approver_fixture_only"),
            "production_ready_claim_allowed" => p5_evidence.dig("hitl_v2", "production_ready_claim_allowed")
          },
          "replay_report" => {
            "status" => p5_evidence.dig("replay", "status"),
            "fixture_status" => p5_evidence.dig("replay", "fixture_status"),
            "production_gate_status" => p5_evidence.dig("replay", "production_gate_status"),
            "side_effect_free_replay_proven" => p5_evidence.dig("replay", "side_effect_free_replay_proven"),
            "replay_run_attached" => p5_evidence.dig("replay", "replay_run_attached"),
            "production_ready_claim_allowed" => p5_evidence.dig("replay", "production_ready_claim_allowed")
          },
          "eval_report" => {
            "status" => p5_evidence.dig("eval", "status"),
            "production_gate_status" => p5_evidence.dig("eval", "production_gate_status"),
            "case_count" => p5_evidence.dig("eval", "case_count"),
            "case_source" => p5_evidence.dig("eval", "case_source"),
            "human_reviewed_case_count" => p5_evidence.dig("eval", "human_reviewed_case_count"),
            "production_ready_claim_allowed" => p5_evidence.dig("eval", "production_ready_claim_allowed")
          },
          "redteam_report" => {
            "status" => p5_evidence.dig("redteam", "status"),
            "production_gate_status" => p5_evidence.dig("redteam", "production_gate_status"),
            "case_count" => p5_evidence.dig("redteam", "case_count"),
            "case_source" => p5_evidence.dig("redteam", "case_source"),
            "independent_reviewed_case_count" => p5_evidence.dig("redteam", "independent_reviewed_case_count"),
            "secret_canary" => p5_evidence.dig("redteam", "secret_canary"),
            "critical_high_bypass_count" => p5_evidence.dig("redteam", "critical_high_bypass_count"),
            "production_ready_claim_allowed" => p5_evidence.dig("redteam", "production_ready_claim_allowed")
          },
          "brain_report" => {
            "status" => p5_evidence.dig("brain", "status"),
            "verifier_status" => p5_evidence.dig("brain", "verifier_status"),
            "storage_mode" => p5_evidence.dig("brain", "storage_mode"),
            "production_gate_status" => p5_evidence.dig("brain", "production_gate_status"),
            "operational_status" => p5_evidence.dig("brain", "operational_status"),
            "production_ready_claim_allowed" => p5_evidence.dig("brain", "production_ready_claim_allowed")
          },
          "self_improvement_report" => {
            "proposal_status" => p5_evidence.dig("self_improvement", "proposal", "fixture_status"),
            "experiment_status" => p5_evidence.dig("self_improvement", "experiment", "status"),
            "production_gate_status" => p5_evidence.dig("self_improvement", "experiment", "production_gate_status"),
            "patch_generated" => p5_evidence.dig("self_improvement", "proposal", "patch_generated"),
            "promotion_allowed" => p5_evidence.dig("self_improvement", "experiment", "promotion_allowed"),
            "production_ready_claim_allowed" => p5_evidence.dig("self_improvement", "experiment", "production_ready_claim_allowed")
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

      def validation_report(p5_evidence)
        validation = p5_evidence.fetch("validation", {})
        validation_text = validation.to_s
        bin_check_passed = validation_text.match?(/ruby bin\/check.*passed|bin_check.*passed/i)
        test_all_passed = validation_text.match?(/test\/all\.rb.*passed|test_all.*passed/i)
        status = bin_check_passed && test_all_passed ? "full_local_validation_attached" : "targeted_validation_only"
        {
          "status" => status,
          "validation_keys" => validation.is_a?(Hash) ? validation.keys.map(&:to_s).sort : [],
          "ruby_bin_check_passed" => bin_check_passed,
          "test_all_passed" => test_all_passed,
          "github_actions_run_id" => nil,
          "blocking_issue" => status == "full_local_validation_attached" ? nil : "full ruby bin/check, test/all, and CI evidence are not attached to this release manifest"
        }
      end
    end
  end
end
