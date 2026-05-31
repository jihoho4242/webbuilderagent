# frozen_string_literal: true

require "digest"
require "yaml"

module Aiweb
  module Ops
    class ReleaseManifest
      def build(p5_evidence)
        release_id = p5_evidence.fetch("release_id")
        evidence_names = %w[
          p5_gate_report.md
          ci_evidence.json
          profile-d-smoke.json
          profile-d-e2e-smoke.json
          profile-s-smoke.json
          eval_report.json
          redteam_report.json
          operator_drill_report.json
        ]
        evidence_files = evidence_names.map do |name|
          path = "releases/#{release_id}/#{name}"
          {
            "path" => path,
            "sha256" => File.file?(path) ? "sha256:#{Digest::SHA256.file(path).hexdigest}" : nil
          }
        end.select { |entry| entry["sha256"] }
        {
          "schema_version" => 1,
          "release_id" => release_id,
          "release_ready" => p5_evidence.fetch("release_ready"),
          "p5_status" => p5_evidence.fetch("p5_status", "unknown"),
          "production_readiness_claimed" => p5_evidence.fetch("production_readiness_claimed", false),
          "operational_readiness" => p5_evidence.fetch("operational_readiness", "unknown"),
          "constitution_hash" => p5_evidence.fetch("constitution_hash"),
          "p5_evidence_status" => p5_evidence.fetch("scaffold_demo_blocking_issues", []).empty? ? "scaffold_demo_passed" : "scaffold_demo_blocked",
          "commit_sha" => current_commit_sha,
          "github_actions_run_id" => github_actions_run_id(p5_evidence),
          "github_actions_report" => github_actions_report(p5_evidence),
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
            "l3_boolean_approval_rejected" => p5_evidence.dig("tool_gateway_coverage", "l3_boolean_approval_rejected"),
            "l3_boolean_gateway_status" => p5_evidence.dig("tool_gateway_coverage", "l3_boolean_gateway_status"),
            "l3_hash_bound_approval_passed" => p5_evidence.dig("tool_gateway_coverage", "l3_hash_bound_approval_passed"),
            "l3_artifact_gateway_status" => p5_evidence.dig("tool_gateway_coverage", "l3_artifact_gateway_status"),
            "verifier_result_hash_rejected" => p5_evidence.dig("tool_gateway_coverage", "verifier_result_hash_rejected"),
            "verifier_result_gateway_status" => p5_evidence.dig("tool_gateway_coverage", "verifier_result_gateway_status"),
            "production_gate_status" => p5_evidence.dig("tool_gateway_coverage", "production_gate_status"),
            "production_ready_claim_allowed" => p5_evidence.dig("tool_gateway_coverage", "production_ready_claim_allowed")
          },
          "hitl_report" => {
            "status" => p5_evidence.dig("hitl_v2", "fixture_status"),
            "verifier_status" => p5_evidence.dig("hitl_v2", "status"),
            "artifact_hash_self_verified" => p5_evidence.dig("hitl_v2", "artifact_hash_self_verified"),
            "validation_hash_verified" => p5_evidence.dig("hitl_v2", "validation_hash_verified"),
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
            "holdout_case_count" => p5_evidence.dig("eval", "holdout_case_count"),
            "holdout_failure_count" => p5_evidence.dig("eval", "holdout_failure_count"),
            "holdout_safety_critical_failure_count" => p5_evidence.dig("eval", "holdout_safety_critical_failure_count"),
            "holdout_tool_routing_accuracy" => p5_evidence.dig("eval", "holdout_tool_routing_accuracy"),
            "human_reviewed_case_count" => p5_evidence.dig("eval", "human_reviewed_case_count"),
            "production_ready_claim_allowed" => p5_evidence.dig("eval", "production_ready_claim_allowed")
          },
          "redteam_report" => {
            "status" => p5_evidence.dig("redteam", "status"),
            "production_gate_status" => p5_evidence.dig("redteam", "production_gate_status"),
            "case_count" => p5_evidence.dig("redteam", "case_count"),
            "case_source" => p5_evidence.dig("redteam", "case_source"),
            "holdout_case_count" => p5_evidence.dig("redteam", "holdout_case_count"),
            "holdout_critical_high_bypass_count" => p5_evidence.dig("redteam", "holdout_critical_high_bypass_count"),
            "catalog_counts" => p5_evidence.dig("redteam", "catalog_counts"),
            "independent_reviewed_case_count" => p5_evidence.dig("redteam", "independent_reviewed_case_count"),
            "secret_canary" => p5_evidence.dig("redteam", "secret_canary"),
            "critical_high_bypass_count" => p5_evidence.dig("redteam", "critical_high_bypass_count"),
            "production_ready_claim_allowed" => p5_evidence.dig("redteam", "production_ready_claim_allowed")
          },
          "profile_smoke_report" => p5_evidence.fetch("profile_smoke", {}),
          "brain_report" => {
            "status" => p5_evidence.dig("brain", "status"),
            "verifier_status" => p5_evidence.dig("brain", "verifier_status"),
            "storage_mode" => p5_evidence.dig("brain", "storage_mode"),
            "concurrency_backed" => p5_evidence.dig("brain", "concurrency_backed"),
            "backup_restore_drill" => p5_evidence.dig("brain", "backup_restore_drill"),
            "ledger_event_count" => p5_evidence.dig("brain", "ledger_event_count"),
            "event_hash_chain_valid" => p5_evidence.dig("brain", "event_hash_chain_valid"),
            "search_projection" => p5_evidence.dig("brain", "search_projection"),
            "health_report_present" => p5_evidence.dig("brain", "health_report_present"),
            "metrics" => p5_evidence.dig("brain", "metrics"),
            "sqlite_dependency" => p5_evidence.dig("brain", "sqlite_dependency"),
            "independent_file_audit" => p5_evidence.dig("brain", "independent_file_audit"),
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
          "operator_drill" => operator_drill_report(p5_evidence),
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
          "github_actions_run_id" => github_actions_run_id(p5_evidence),
          "blocking_issue" => status == "full_local_validation_attached" ? nil : "full ruby bin/check, test/all, and CI evidence are not attached to this release manifest"
        }
      end

      def github_actions_run_id(p5_evidence)
        github_actions_report(p5_evidence)["run_id"]
      end

      def github_actions_report(p5_evidence)
        report = p5_evidence["github_actions"]
        return default_github_actions_report unless report.is_a?(Hash)

        default_github_actions_report.merge(report)
      end

      def default_github_actions_report
        {
          "schema_version" => 1,
          "status" => "missing",
          "run_id" => nil,
          "head_sha" => nil,
          "workflow_name" => nil,
          "url" => nil,
          "conclusion" => nil,
          "production_gate_status" => "blocked",
          "production_ready_claim_allowed" => false
        }
      end

      def operator_drill_report(p5_evidence)
        report = p5_evidence["operator_drill"]
        return default_operator_drill_report unless report.is_a?(Hash)

        default_operator_drill_report.merge(report)
      end

      def default_operator_drill_report
        {
          "schema_version" => 1,
          "status" => "placeholder",
          "evidence_path" => nil,
          "steps" => [],
          "production_gate_status" => "blocked",
          "production_ready_claim_allowed" => false,
          "blocking_issue" => "operator drill must be run in CI/ops environment before operational readiness can be claimed"
        }
      end
    end
  end
end
