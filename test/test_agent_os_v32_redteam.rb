# frozen_string_literal: true

require "json"
require "open3"
require "yaml"
require "time"

require_relative "support/test_helper"

require "aiweb"


class AgentOsV32RedteamTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)

  def test_redteam_arena_blocks_or_requires_approval_for_critical_high_attacks
    result = Aiweb::Redteam::Arena.new.run(policy_kernel: Aiweb::Policy::Kernel.new, packet_builder: Aiweb::Tools::DecisionPacket.new)
    assert_equal "catalog_fixture_passed", result.fetch("status")
    assert_equal "blocked", result.fetch("production_gate_status")
    assert_equal false, result.fetch("production_ready_claim_allowed")
    assert_equal "local_attack_catalog_fixture", result.fetch("case_source")
    assert_equal 0, result.fetch("independent_reviewed_case_count")
    assert_match(/independent adversarial review/, result.fetch("operational_blocking_issues").join("\n"))
    assert_equal 0, result.fetch("critical_high_bypass_count")
    case_ids = result.fetch("cases").map { |case_record| case_record.fetch("case_id") }
    assert_includes case_ids, "rag_instruction_override_001"
    assert_includes case_ids, "browser_session_exfil_001"
    assert_includes case_ids, "policy_kernel_bypass_001"
    assert_includes case_ids, "hitl_downgrade_001"
    assert_includes case_ids, "source_patch_boundary_bypass_001"
    assert_includes case_ids, "unauthorized_deploy_provider_001"
    assert result.fetch("cases").all? { |case_record| case_record.key?("expected_satisfied") }
    assert_equal false, result.dig("secret_canary", "canary_value_emitted")
    assert_equal "blocked", result.dig("secret_canary", "production_gate_status")
  end

  def test_redteam_attack_catalog_exists
    path = File.join(REPO_ROOT, "redteam", "attack_catalog.yaml")
    catalog = YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
    attacks = catalog.fetch("attacks")
    attack_classes = attacks.map { |attack| attack.fetch("attack_class") }
    assert_includes attack_classes, "approval_bypass"
    assert_includes attack_classes, "secret_exfiltration"
    assert_includes attack_classes, "policy_bypass"
    assert_includes attack_classes, "hitl_downgrade"
    assert_includes attack_classes, "source_patch_boundary_bypass"
    assert_includes attack_classes, "unauthorized_deploy_provider"
    assert attacks.all? { |attack| attack.key?("injection_surface") && attack.key?("payload") && attack.key?("expected_policy_decision") }
  end

  def test_redteam_arena_fails_closed_when_catalog_is_missing
    arena = Aiweb::Redteam::Arena.new
    def arena.attack_cases = []

    result = arena.run(policy_kernel: Aiweb::Policy::Kernel.new, packet_builder: Aiweb::Tools::DecisionPacket.new)

    assert_equal "catalog_fixture_blocked", result.fetch("status")
    assert_equal "blocked", result.fetch("production_gate_status")
    assert_equal false, result.fetch("production_ready_claim_allowed")
    assert_equal 1, result.fetch("critical_high_bypass_count")
    assert_match(/catalog missing or empty/, result.fetch("blocking_issues").join("\n"))
    assert_equal false, result.dig("secret_canary", "canary_value_emitted")
  end

  def test_secret_canary_runner_never_prints_canary_value_or_passes_production_gate
    stdout, stderr, status = Open3.capture3("ruby", File.join(REPO_ROOT, "redteam", "secret_canary.rb"), chdir: REPO_ROOT)

    assert status.success?, stderr
    refute_includes stdout, Aiweb::Redteam::SecretCanary::VALUE
    report = JSON.parse(stdout)
    assert_equal "canary_configured", report.fetch("status")
    assert_equal "blocked", report.fetch("production_gate_status")
    assert_equal false, report.fetch("canary_value_emitted")
    assert_equal false, report.fetch("production_ready_claim_allowed")
    assert_match(/^sha256:/, report.fetch("canary_fingerprint"))
    assert_match(/CI redaction transcript/, report.fetch("operational_blocking_issues").join("\n"))
  end
end
