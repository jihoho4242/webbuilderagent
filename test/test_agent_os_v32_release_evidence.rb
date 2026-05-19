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
    assert_match(/^sha256:/, evidence.fetch("constitution_hash"))
    assert_equal "catalog_fixture_passed", evidence.dig("redteam", "status")
    assert_equal "blocked", evidence.dig("redteam", "production_gate_status")
    assert_equal false, evidence.dig("redteam", "production_ready_claim_allowed")
    assert_equal "local_attack_catalog_fixture", evidence.dig("redteam", "case_source")
    assert_match(/independent adversarial review/, evidence.dig("redteam", "operational_blocking_issues").join("\n"))
    assert_equal 0, evidence.dig("redteam", "critical_high_bypass_count")
    assert_equal "expanded_fixture_passed", evidence.dig("eval", "status")
    assert_equal "blocked", evidence.dig("eval", "production_gate_status")
    assert_equal false, evidence.dig("eval", "production_ready_claim_allowed")
    assert_equal "project_local_jsonl_ledger_sqlite_unavailable", evidence.dig("brain", "storage_mode")
    assert_equal "blocked", evidence.dig("brain", "operational_status")
    assert_match(/SQLite backend unavailable/, evidence.dig("brain", "operational_blocking_issues").join("\n"))
    assert_equal false, evidence.dig("self_improvement", "proposal", "source_changed")
    assert_equal true, evidence.dig("replay", "side_effect_free_replay")
    assert_equal "passed", evidence.dig("hitl_v2", "status")

    manifest = Aiweb::Ops::ReleaseManifest.new.build(evidence)
    assert_equal "catalog_fixture_passed", manifest.dig("redteam_report", "status")
    assert_equal "blocked", manifest.dig("redteam_report", "production_gate_status")
    assert_equal false, manifest.dig("redteam_report", "production_ready_claim_allowed")
    assert_equal 0, manifest.dig("redteam_report", "independent_reviewed_case_count")
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
    assert_match(/SQLite backend unavailable/, manifest.fetch("operational_blocking_issues").join("\n"))
    assert_equal "catalog_fixture_passed", manifest.dig("redteam_report", "status")
    assert_equal "blocked", manifest.dig("redteam_report", "production_gate_status")
    assert_equal false, manifest.dig("redteam_report", "production_ready_claim_allowed")
    assert_equal 0, manifest.dig("redteam_report", "independent_reviewed_case_count")
    assert_match(/independent adversarial review/, manifest.fetch("operational_blocking_issues").join("\n"))

    integrity = YAML.safe_load(File.read(File.join(REPO_ROOT, "releases", "v0.3.2-rc1", "evidence_integrity_manifest.yaml")), permitted_classes: [], aliases: false)
    integrity.fetch("files").each do |entry|
      absolute = File.join(REPO_ROOT, entry.fetch("path"))
      assert_equal "sha256:#{Digest::SHA256.file(absolute).hexdigest}", entry.fetch("sha256")
    end
  end
end
