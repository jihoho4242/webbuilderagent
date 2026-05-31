# frozen_string_literal: true

require "json"
require "yaml"
require "time"
require "digest"

require_relative "support/test_helper"

require "aiweb"


class AgentOsV32ReleaseEvidenceTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)

  def test_p5_gate_builds_honest_scaffold_demo_evidence_bundle
    evidence = Aiweb::Ops::P5Gate.new.evidence(validation: { "unit" => "test" })
    assert_equal "v0.3.2-rc1", evidence.fetch("release_id")
    assert_equal "scaffold_demo_passed", evidence.fetch("p5_status")
    assert_equal false, evidence.fetch("release_ready")
    assert_equal false, evidence.fetch("production_readiness_claimed")
    assert_match(/blocked_pending/, evidence.fetch("operational_readiness"))
    assert_match(/GitHub Actions run id/, evidence.fetch("operational_blocking_issues").join("\n"))
    assert_match(/full ruby bin\/check evidence is not attached/, evidence.fetch("operational_blocking_issues").join("\n"))
    assert_match(/test\/all\.rb evidence is not attached/, evidence.fetch("operational_blocking_issues").join("\n"))
    assert_equal "gateway_demo_passed", evidence.dig("policy_coverage", "status")
    assert_equal "unproven", evidence.dig("policy_coverage", "coverage_status")
    assert_equal false, evidence.dig("policy_coverage", "all_side_effects_require_decision_packet_policy_gateway")
    assert_equal "blocked", evidence.dig("policy_coverage", "production_gate_status")
    assert_match(/static side-effect surface audit is attached/, evidence.fetch("operational_blocking_issues").join("\n"))
    assert_equal "static_audit_attached", evidence.dig("side_effect_surface_audit", "status")
    assert_equal "classified", evidence.dig("side_effect_surface_audit", "coverage_status")
    assert_equal 0, evidence.dig("side_effect_surface_audit", "unclassified_count")
    assert_equal false, evidence.dig("side_effect_surface_audit", "runtime_universal_enforcement_proven")
    assert_equal "blocked", evidence.dig("side_effect_surface_audit", "production_gate_status")
    assert_equal false, evidence.dig("side_effect_surface_audit", "production_ready_claim_allowed")
    assert_match(/static classification evidence only/, evidence.dig("side_effect_surface_audit", "operational_blocking_issues").join("\n"))
    assert_equal "gateway_demo_passed", evidence.dig("tool_gateway_coverage", "status")
    assert_equal "passed", evidence.dig("tool_gateway_coverage", "verifier_status")
    assert_equal true, evidence.dig("tool_gateway_coverage", "l3_boolean_approval_rejected")
    assert_equal "approval_required", evidence.dig("tool_gateway_coverage", "l3_boolean_gateway_status")
    assert_equal true, evidence.dig("tool_gateway_coverage", "l3_hash_bound_approval_passed")
    assert_equal "passed", evidence.dig("tool_gateway_coverage", "l3_artifact_gateway_status")
    assert_equal true, evidence.dig("tool_gateway_coverage", "verifier_result_hash_rejected")
    assert_equal "approval_required", evidence.dig("tool_gateway_coverage", "verifier_result_gateway_status")
    assert_equal "blocked", evidence.dig("tool_gateway_coverage", "production_gate_status")
    assert_equal false, evidence.dig("tool_gateway_coverage", "production_ready_claim_allowed")
    assert_match(/full side-effect tool gateway audit/, evidence.fetch("operational_blocking_issues").join("\n"))
    assert_match(/^sha256:/, evidence.fetch("constitution_hash"))
    assert_equal "catalog_fixture_passed", evidence.dig("redteam", "status")
    assert_equal "blocked", evidence.dig("redteam", "production_gate_status")
    assert_equal false, evidence.dig("redteam", "production_ready_claim_allowed")
    assert_equal "local_attack_catalog_fixture", evidence.dig("redteam", "case_source")
    assert_match(/independent adversarial review/, evidence.dig("redteam", "operational_blocking_issues").join("\n"))
    assert_equal false, evidence.dig("redteam", "secret_canary", "canary_value_emitted")
    assert_equal 0, evidence.dig("redteam", "critical_high_bypass_count")
    assert_equal "expanded_fixture_passed", evidence.dig("eval", "status")
    assert_equal "blocked", evidence.dig("eval", "production_gate_status")
    assert_equal false, evidence.dig("eval", "production_ready_claim_allowed")
    assert_equal "memory_safety_fixture_passed", evidence.dig("brain", "status")
    assert_equal "passed", evidence.dig("brain", "verifier_status")
    assert_equal "project_local_jsonl_ledger_with_projection", evidence.dig("brain", "storage_mode")
    assert_equal true, evidence.dig("brain", "concurrency_backed")
    assert_equal "passed", evidence.dig("brain", "backup_restore_drill", "status")
    assert_equal 2, evidence.dig("brain", "ledger_event_count")
    assert_equal true, evidence.dig("brain", "event_hash_chain_valid")
    assert_equal true, evidence.dig("brain", "health_report_present")
    assert_equal "ready", evidence.dig("brain", "search_projection", "status")
    assert_equal 0, evidence.dig("brain", "search_projection", "search_projection_lag")
    assert_equal true, evidence.dig("brain", "metrics", "event_hash_chain_valid")
    assert_equal "missing_dependency", evidence.dig("brain", "metrics", "sqlite_dependency_status")
    assert_equal "missing_dependency", evidence.dig("brain", "sqlite_dependency", "status")
    assert_equal true, evidence.dig("brain", "metrics", "search_projection_present")
    assert_equal true, evidence.dig("brain", "metrics", "concurrency_backed")
    assert_equal true, evidence.dig("brain", "metrics", "backup_restore_drill_present")
    assert_equal true, evidence.dig("brain", "metrics", "independent_file_audit_passed")
    assert_equal "passed", evidence.dig("brain", "independent_file_audit", "status")
    assert_equal true, evidence.dig("brain", "independent_file_audit", "backup_restore_drill_matches_ledger")
    assert_equal 0, evidence.dig("brain", "metrics", "search_projection_lag")
    assert_equal "blocked", evidence.dig("brain", "production_gate_status")
    assert_equal "blocked", evidence.dig("brain", "operational_status")
    assert_equal false, evidence.dig("brain", "production_ready_claim_allowed")
    assert_match(/SQLite-backed storage evidence/, evidence.dig("brain", "operational_blocking_issues").join("\n"))
    assert_match(/sqlite3 Ruby gem is not available/, evidence.dig("brain", "operational_blocking_issues").join("\n"))
    refute_match(/backup\/restore drill evidence/, evidence.dig("brain", "operational_blocking_issues").join("\n"))
    refute_match(/independent file-level memory audit evidence/, evidence.dig("brain", "operational_blocking_issues").join("\n"))
    assert_equal false, evidence.dig("self_improvement", "proposal", "source_changed")
    assert_equal "proposal_fixture_recorded", evidence.dig("self_improvement", "proposal", "fixture_status")
    assert_equal "blocked", evidence.dig("self_improvement", "proposal", "production_gate_status")
    assert_equal false, evidence.dig("self_improvement", "proposal", "production_ready_claim_allowed")
    assert_equal "sandbox_planned", evidence.dig("self_improvement", "experiment", "status")
    assert_equal "blocked", evidence.dig("self_improvement", "experiment", "production_gate_status")
    assert_equal false, evidence.dig("self_improvement", "experiment", "promotion_allowed")
    assert_match(/self-improvement requires sandbox patch diff/, evidence.fetch("operational_blocking_issues").join("\n"))
    assert_equal "replay_demo_passed", evidence.dig("replay", "status")
    assert_equal "decision_replay_key_fixture_present", evidence.dig("replay", "fixture_status")
    assert_equal "blocked", evidence.dig("replay", "production_gate_status")
    assert_equal false, evidence.dig("replay", "side_effect_free_replay")
    assert_equal false, evidence.dig("replay", "side_effect_free_replay_proven")
    assert_equal false, evidence.dig("replay", "replay_run_attached")
    assert_equal false, evidence.dig("replay", "production_ready_claim_allowed")
    assert_match(/durable replay\/resume audit/, evidence.fetch("operational_blocking_issues").join("\n"))
    assert_equal "passed", evidence.dig("hitl_v2", "status")
    assert_equal "approval_fixture_passed", evidence.dig("hitl_v2", "fixture_status")
    assert_equal true, evidence.dig("hitl_v2", "artifact_hash_self_verified")
    assert_equal true, evidence.dig("hitl_v2", "validation_hash_verified")
    assert_equal "blocked", evidence.dig("hitl_v2", "production_gate_status")
    assert_equal true, evidence.dig("hitl_v2", "approver_fixture_only")
    assert_equal false, evidence.dig("hitl_v2", "production_ready_claim_allowed")
    assert_match(/real operator approval artifact/, evidence.fetch("operational_blocking_issues").join("\n"))

    manifest = Aiweb::Ops::ReleaseManifest.new.build(evidence)
    assert_equal "catalog_fixture_passed", manifest.dig("redteam_report", "status")
    assert_equal "blocked", manifest.dig("redteam_report", "production_gate_status")
    assert_equal false, manifest.dig("redteam_report", "production_ready_claim_allowed")
    assert_equal 0, manifest.dig("redteam_report", "independent_reviewed_case_count")
    assert_equal false, manifest.dig("redteam_report", "secret_canary", "canary_value_emitted")
    assert_equal "memory_safety_fixture_passed", manifest.dig("brain_report", "status")
    assert_equal "passed", manifest.dig("brain_report", "verifier_status")
    assert_equal true, manifest.dig("brain_report", "concurrency_backed")
    assert_equal "passed", manifest.dig("brain_report", "backup_restore_drill", "status")
    assert_equal "missing_dependency", manifest.dig("brain_report", "sqlite_dependency", "status")
    assert_equal "passed", manifest.dig("brain_report", "independent_file_audit", "status")
    assert_equal true, manifest.dig("brain_report", "independent_file_audit", "backup_restore_drill_matches_ledger")
    assert_equal 2, manifest.dig("brain_report", "ledger_event_count")
    assert_equal true, manifest.dig("brain_report", "event_hash_chain_valid")
    assert_equal true, manifest.dig("brain_report", "health_report_present")
    assert_equal "ready", manifest.dig("brain_report", "search_projection", "status")
    assert_equal "blocked", manifest.dig("brain_report", "production_gate_status")
    assert_equal "blocked", manifest.dig("brain_report", "operational_status")
    assert_equal false, manifest.dig("brain_report", "production_ready_claim_allowed")
    assert_equal "targeted_validation_only", manifest.dig("schema_validation_report", "status")
    assert_equal false, manifest.dig("schema_validation_report", "ruby_bin_check_passed")
    assert_equal false, manifest.dig("schema_validation_report", "test_all_passed")
    assert_match(/not attached/, manifest.dig("schema_validation_report", "blocking_issue"))
    assert_equal "gateway_demo_passed", manifest.dig("policy_gateway_report", "status")
    assert_equal "unproven", manifest.dig("policy_gateway_report", "coverage_status")
    assert_equal false, manifest.dig("policy_gateway_report", "all_side_effects_require_decision_packet_policy_gateway")
    assert_equal "static_audit_attached", manifest.dig("side_effect_surface_audit_report", "status")
    assert_equal "classified", manifest.dig("side_effect_surface_audit_report", "coverage_status")
    assert_equal 0, manifest.dig("side_effect_surface_audit_report", "unclassified_count")
    assert_equal false, manifest.dig("side_effect_surface_audit_report", "runtime_universal_enforcement_proven")
    assert_equal "blocked", manifest.dig("side_effect_surface_audit_report", "production_gate_status")
    assert_equal false, manifest.dig("side_effect_surface_audit_report", "production_ready_claim_allowed")
    assert_equal "gateway_demo_passed", manifest.dig("tool_gateway_report", "status")
    assert_equal "passed", manifest.dig("tool_gateway_report", "verifier_status")
    assert_equal true, manifest.dig("tool_gateway_report", "l3_boolean_approval_rejected")
    assert_equal "approval_required", manifest.dig("tool_gateway_report", "l3_boolean_gateway_status")
    assert_equal true, manifest.dig("tool_gateway_report", "l3_hash_bound_approval_passed")
    assert_equal "passed", manifest.dig("tool_gateway_report", "l3_artifact_gateway_status")
    assert_equal true, manifest.dig("tool_gateway_report", "verifier_result_hash_rejected")
    assert_equal "approval_required", manifest.dig("tool_gateway_report", "verifier_result_gateway_status")
    assert_equal "blocked", manifest.dig("tool_gateway_report", "production_gate_status")
    assert_equal false, manifest.dig("tool_gateway_report", "production_ready_claim_allowed")
    assert_equal "approval_fixture_passed", manifest.dig("hitl_report", "status")
    assert_equal true, manifest.dig("hitl_report", "artifact_hash_self_verified")
    assert_equal true, manifest.dig("hitl_report", "validation_hash_verified")
    assert_equal "blocked", manifest.dig("hitl_report", "production_gate_status")
    assert_equal true, manifest.dig("hitl_report", "approver_fixture_only")
    assert_equal false, manifest.dig("hitl_report", "production_ready_claim_allowed")
    assert_equal "replay_demo_passed", manifest.dig("replay_report", "status")
    assert_equal "blocked", manifest.dig("replay_report", "production_gate_status")
    assert_equal false, manifest.dig("replay_report", "side_effect_free_replay_proven")
    assert_equal false, manifest.dig("replay_report", "replay_run_attached")
    assert_equal false, manifest.dig("replay_report", "production_ready_claim_allowed")
    assert_equal "sandbox_planned", manifest.dig("self_improvement_report", "experiment_status")
    assert_equal "blocked", manifest.dig("self_improvement_report", "production_gate_status")
    assert_equal false, manifest.dig("self_improvement_report", "patch_generated")
    assert_equal false, manifest.dig("self_improvement_report", "promotion_allowed")
  end

  def test_release_evidence_files_exist_and_reference_p5_gate
    %w[release_manifest.yaml evidence_integrity_manifest.yaml p5_gate_report.md].each do |name|
      assert File.file?(File.join(REPO_ROOT, "releases", "v0.3.2-rc1", name)), "missing #{name}"
    end
    manifest = YAML.safe_load(File.read(File.join(REPO_ROOT, "releases", "v0.3.2-rc1", "release_manifest.yaml")), permitted_classes: [], aliases: false)
    assert_equal "v0.3.2-rc1", manifest.fetch("release_id")
    assert_match(/^sha256:/, manifest.fetch("constitution_hash"))
    assert_equal false, manifest.fetch("production_readiness_claimed")
    assert manifest.fetch("evidence_files").any? { |item| item.fetch("path") == "releases/v0.3.2-rc1/p5_gate_report.md" }
    assert_includes manifest.fetch("rollback_plan").fetch("status"), "documented"
    assert_equal "placeholder", manifest.fetch("operator_drill").fetch("status")
    assert_match(/SQLite-backed storage evidence/, manifest.fetch("operational_blocking_issues").join("\n"))
    assert_match(/sqlite3 Ruby gem is not available/, manifest.fetch("operational_blocking_issues").join("\n"))
    refute_match(/backup\/restore drill evidence/, manifest.fetch("operational_blocking_issues").join("\n"))
    refute_match(/independent file-level memory audit evidence/, manifest.fetch("operational_blocking_issues").join("\n"))
    assert_equal "targeted_validation_only", manifest.dig("schema_validation_report", "status")
    assert_equal false, manifest.dig("schema_validation_report", "ruby_bin_check_passed")
    assert_equal false, manifest.dig("schema_validation_report", "test_all_passed")
    assert_match(/not attached/, manifest.dig("schema_validation_report", "blocking_issue"))
    assert_equal "gateway_demo_passed", manifest.dig("policy_gateway_report", "status")
    assert_equal "unproven", manifest.dig("policy_gateway_report", "coverage_status")
    assert_equal false, manifest.dig("policy_gateway_report", "all_side_effects_require_decision_packet_policy_gateway")
    assert_match(/static side-effect surface audit is attached/, manifest.fetch("operational_blocking_issues").join("\n"))
    assert_match(/static classification evidence only/, manifest.fetch("operational_blocking_issues").join("\n"))
    assert_equal "static_audit_attached", manifest.dig("side_effect_surface_audit_report", "status")
    assert_equal "classified", manifest.dig("side_effect_surface_audit_report", "coverage_status")
    assert_equal 0, manifest.dig("side_effect_surface_audit_report", "unclassified_count")
    assert_equal false, manifest.dig("side_effect_surface_audit_report", "runtime_universal_enforcement_proven")
    assert_equal "blocked", manifest.dig("side_effect_surface_audit_report", "production_gate_status")
    assert_equal false, manifest.dig("side_effect_surface_audit_report", "production_ready_claim_allowed")
    assert_equal "gateway_demo_passed", manifest.dig("tool_gateway_report", "status")
    assert_equal "passed", manifest.dig("tool_gateway_report", "verifier_status")
    assert_equal true, manifest.dig("tool_gateway_report", "l3_boolean_approval_rejected")
    assert_equal "approval_required", manifest.dig("tool_gateway_report", "l3_boolean_gateway_status")
    assert_equal true, manifest.dig("tool_gateway_report", "l3_hash_bound_approval_passed")
    assert_equal "passed", manifest.dig("tool_gateway_report", "l3_artifact_gateway_status")
    assert_equal true, manifest.dig("tool_gateway_report", "verifier_result_hash_rejected")
    assert_equal "approval_required", manifest.dig("tool_gateway_report", "verifier_result_gateway_status")
    assert_equal "blocked", manifest.dig("tool_gateway_report", "production_gate_status")
    assert_equal false, manifest.dig("tool_gateway_report", "production_ready_claim_allowed")
    assert_match(/full side-effect tool gateway audit/, manifest.fetch("operational_blocking_issues").join("\n"))
    assert_equal "approval_fixture_passed", manifest.dig("hitl_report", "status")
    assert_equal true, manifest.dig("hitl_report", "artifact_hash_self_verified")
    assert_equal true, manifest.dig("hitl_report", "validation_hash_verified")
    assert_equal "blocked", manifest.dig("hitl_report", "production_gate_status")
    assert_equal true, manifest.dig("hitl_report", "approver_fixture_only")
    assert_equal false, manifest.dig("hitl_report", "production_ready_claim_allowed")
    assert_equal "replay_demo_passed", manifest.dig("replay_report", "status")
    assert_equal "blocked", manifest.dig("replay_report", "production_gate_status")
    assert_equal false, manifest.dig("replay_report", "side_effect_free_replay_proven")
    assert_equal false, manifest.dig("replay_report", "replay_run_attached")
    assert_equal false, manifest.dig("replay_report", "production_ready_claim_allowed")
    assert_match(/durable replay\/resume audit/, manifest.fetch("operational_blocking_issues").join("\n"))
    assert_match(/real operator approval artifact/, manifest.fetch("operational_blocking_issues").join("\n"))
    assert_equal "catalog_fixture_passed", manifest.dig("redteam_report", "status")
    assert_equal "blocked", manifest.dig("redteam_report", "production_gate_status")
    assert_equal false, manifest.dig("redteam_report", "production_ready_claim_allowed")
    assert_equal 0, manifest.dig("redteam_report", "independent_reviewed_case_count")
    assert_equal false, manifest.dig("redteam_report", "secret_canary", "canary_value_emitted")
    assert_equal "memory_safety_fixture_passed", manifest.dig("brain_report", "status")
    assert_equal "passed", manifest.dig("brain_report", "verifier_status")
    assert_equal true, manifest.dig("brain_report", "concurrency_backed")
    assert_equal "passed", manifest.dig("brain_report", "backup_restore_drill", "status")
    assert_equal "missing_dependency", manifest.dig("brain_report", "sqlite_dependency", "status")
    assert_equal "passed", manifest.dig("brain_report", "independent_file_audit", "status")
    assert_equal true, manifest.dig("brain_report", "independent_file_audit", "backup_restore_drill_matches_ledger")
    assert_equal 2, manifest.dig("brain_report", "ledger_event_count")
    assert_equal true, manifest.dig("brain_report", "event_hash_chain_valid")
    assert_equal true, manifest.dig("brain_report", "health_report_present")
    assert_equal "blocked", manifest.dig("brain_report", "production_gate_status")
    assert_equal "blocked", manifest.dig("brain_report", "operational_status")
    assert_equal false, manifest.dig("brain_report", "production_ready_claim_allowed")
    assert_equal "sandbox_planned", manifest.dig("self_improvement_report", "experiment_status")
    assert_equal "blocked", manifest.dig("self_improvement_report", "production_gate_status")
    assert_equal false, manifest.dig("self_improvement_report", "patch_generated")
    assert_equal false, manifest.dig("self_improvement_report", "promotion_allowed")
    assert_match(/independent adversarial review/, manifest.fetch("operational_blocking_issues").join("\n"))
    assert_match(/self-improvement requires sandbox patch diff/, manifest.fetch("operational_blocking_issues").join("\n"))

    integrity = YAML.safe_load(File.read(File.join(REPO_ROOT, "releases", "v0.3.2-rc1", "evidence_integrity_manifest.yaml")), permitted_classes: [], aliases: false)
    integrity.fetch("files").each do |entry|
      absolute = File.join(REPO_ROOT, entry.fetch("path"))
      assert_equal "sha256:#{Digest::SHA256.file(absolute).hexdigest}", entry.fetch("sha256")
    end
  end

  def test_rc2_release_evidence_bundle_records_ci_profile_eval_and_redteam
    release_dir = File.join(REPO_ROOT, "releases", "v0.3.2-rc2")
    %w[
      release_manifest.yaml
      evidence_integrity_manifest.yaml
      p5_gate_report.md
      ci_evidence.json
      profile-d-smoke.json
      profile-s-smoke.json
      eval_report.json
      redteam_report.json
      operator_drill_report.json
    ].each do |name|
      assert File.file?(File.join(release_dir, name)), "missing rc2 #{name}"
    end

    manifest = YAML.safe_load(File.read(File.join(release_dir, "release_manifest.yaml")), permitted_classes: [], aliases: false)
    assert_equal "v0.3.2-rc2", manifest.fetch("release_id")
    assert_equal false, manifest.fetch("production_readiness_claimed")
    assert_equal "evidence_backed_rc_candidate_production_blocked", manifest.fetch("operational_readiness")
    assert_equal 26365437613, manifest.fetch("github_actions_run_id")
    assert_equal "success", manifest.dig("github_actions_report", "conclusion")
    assert_equal "profile_smoke_attached", manifest.dig("profile_smoke_report", "status")
    assert_equal "expanded_fixture_passed", manifest.dig("eval_report", "status")
    assert_equal 150, manifest.dig("eval_report", "case_count")
    assert_equal "catalog_fixture_passed", manifest.dig("redteam_report", "status")
    assert_equal 10, manifest.dig("redteam_report", "case_count")
    assert_equal 0, manifest.dig("redteam_report", "critical_high_bypass_count")

    profile_d = JSON.parse(File.read(File.join(release_dir, "profile-d-smoke.json")))
    assert_equal "smoke_completed_with_environment_blockers", profile_d.fetch("status")
    assert_equal false, profile_d.dig("forbidden_side_effects", "production_side_effect")

    profile_s = JSON.parse(File.read(File.join(release_dir, "profile-s-smoke.json")))
    assert_equal "local_only_smoke_passed", profile_s.fetch("status")
    assert_equal "passed", profile_s.dig("local_verify", "status")
    assert_equal false, profile_s.dig("forbidden_side_effects", "provider_cli_invoked")

    integrity = YAML.safe_load(File.read(File.join(release_dir, "evidence_integrity_manifest.yaml")), permitted_classes: [], aliases: false)
    integrity.fetch("files").each do |entry|
      absolute = File.join(REPO_ROOT, entry.fetch("path"))
      assert_equal "sha256:#{Digest::SHA256.file(absolute).hexdigest}", entry.fetch("sha256")
    end
  end

  def test_release_manifest_attaches_ci_and_operator_drill_evidence_when_supplied
    github_actions = {
      "run_id" => 123456,
      "head_sha" => "a" * 40,
      "workflow_name" => "CI",
      "status" => "completed",
      "conclusion" => "success",
      "url" => "https://github.example/actions/runs/123456"
    }
    operator_drill = {
      "status" => "local_dry_run_passed",
      "evidence_path" => "releases/v0.3.2-rc1/operator_drill_report.json",
      "steps" => [
        { "name" => "run-status", "status" => "passed" },
        { "name" => "engine-run dry-run", "status" => "passed" }
      ],
      "blocking_issue" => "local drill only; production CI/ops drill still required"
    }
    validation = {
      "ruby bin/check" => "passed: full local suite",
      "ruby -Itest test/all.rb" => "passed: full test suite"
    }

    evidence = Aiweb::Ops::P5Gate.new.evidence(validation: validation, github_actions: github_actions, operator_drill: operator_drill)
    blockers = evidence.fetch("operational_blocking_issues").join("\n")
    refute_match(/GitHub Actions run id is not attached/, blockers)
    assert_match(/operator drill evidence is local_dry_run_passed/, blockers)
    assert_equal 123456, evidence.dig("github_actions", "run_id")
    assert_equal "completed", evidence.dig("github_actions", "status")
    assert_equal "success", evidence.dig("github_actions", "conclusion")
    assert_equal "local_dry_run_passed", evidence.dig("operator_drill", "status")
    assert_equal false, evidence.dig("operator_drill", "production_ready_claim_allowed")

    manifest = Aiweb::Ops::ReleaseManifest.new.build(evidence)
    assert_equal 123456, manifest.fetch("github_actions_run_id")
    assert_equal 123456, manifest.dig("schema_validation_report", "github_actions_run_id")
    assert_equal "full_local_validation_attached", manifest.dig("schema_validation_report", "status")
    assert_equal true, manifest.dig("schema_validation_report", "ruby_bin_check_passed")
    assert_equal true, manifest.dig("schema_validation_report", "test_all_passed")
    assert_nil manifest.dig("schema_validation_report", "blocking_issue")
    assert_equal "completed", manifest.dig("github_actions_report", "status")
    assert_equal "success", manifest.dig("github_actions_report", "conclusion")
    assert_equal "local_dry_run_passed", manifest.dig("operator_drill", "status")
    assert_equal "releases/v0.3.2-rc1/operator_drill_report.json", manifest.dig("operator_drill", "evidence_path")
    assert_equal false, manifest.dig("operator_drill", "production_ready_claim_allowed")
  end
end
