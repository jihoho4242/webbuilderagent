# frozen_string_literal: true

require "json"
require "yaml"
require "time"

require_relative "support/test_helper"

require "aiweb"


class AgentOsV32PolicyKernelTest < Minitest::Test
  def packet(tool = "finish", inputs = {})
    Aiweb::Tools::DecisionPacket.new.build(run_id: "policy-test", goal: "policy test", requested_tool: tool, inputs: inputs)
  end

  def test_policy_allows_l0_finish_with_valid_constitution
    decision = Aiweb::Policy::Kernel.new.decide(packet: packet("finish"))
    assert_equal "allow", decision.fetch("decision")
    assert_equal "L0", decision.fetch("risk_tier")
    assert_match(/^policy-decision-/, decision.fetch("decision_id"))
    assert_equal "allow_l0_l2_local", decision.fetch("rule_id")
    assert_match(/^sha256:/, decision.fetch("policy_registry_version"))
    assert_match(/^sha256:/, decision.fetch("capability_matrix_version"))
  end

  def test_policy_requires_explicit_approval_for_l3_local_side_effects
    decision = Aiweb::Policy::Kernel.new.decide(packet: packet("source_patch"), approved: false)
    assert_equal "approval_required", decision.fetch("decision")
    assert_match(/L3 local side effect/, decision.fetch("reason"))
    assert_equal "require_approval_for_l3", decision.fetch("rule_id")
  end

  def test_policy_verifies_l3_hitl_artifact_when_supplied
    source_patch = packet("source_patch")
    action_diff = { "tool" => "source_patch", "diff" => "bounded" }
    args = { "path" => "src/app/page.tsx" }
    evidence = { "review" => "local-human" }
    approval = Aiweb::Approval::Artifact.build(
      run_id: source_patch.fetch("run_id"),
      decision_packet_ids: [source_patch.fetch("packet_id")],
      risk_tier: "L3",
      requested_capabilities: ["source_patch"],
      action_diff: action_diff,
      args: args,
      evidence: evidence,
      approver_id: "operator-1"
    )

    decision = Aiweb::Policy::Kernel.new.decide(packet: source_patch, approval_artifact: approval, action_diff: action_diff, args: args, evidence: evidence)

    assert_equal "allow", decision.fetch("decision")
    assert_equal "passed", decision.fetch("approval_status")
  end

  def test_policy_blocks_l4_when_approval_artifact_hashes_do_not_match
    deploy = packet("external_deploy")
    approval = Aiweb::Approval::Artifact.build(
      run_id: deploy.fetch("run_id"),
      decision_packet_ids: [deploy.fetch("packet_id")],
      risk_tier: "L4",
      requested_capabilities: ["external_deploy"],
      action_diff: { "tool" => "external_deploy" },
      args: { "target" => "dry-run" },
      evidence: { "review" => true },
      approver_id: "operator-1",
      second_reviewer_id: "operator-2"
    )

    decision = Aiweb::Policy::Kernel.new.decide(
      packet: deploy,
      approval_artifact: approval,
      action_diff: { "tool" => "external_deploy" },
      args: { "target" => "changed" },
      evidence: { "review" => true }
    )

    assert_equal "approval_required", decision.fetch("decision")
    assert_match(/args_hash mismatch/, decision.fetch("reason"))
  end

  def test_policy_blocks_verifier_result_hash_as_l4_execution_authority
    deploy = packet("external_deploy")
    forged_verifier_result = {
      "schema_version" => 1,
      "status" => "passed",
      "approval_id" => "approval-forged",
      "approval_hash" => "sha256:forged",
      "blocking_issues" => []
    }

    decision = Aiweb::Policy::Kernel.new.decide(packet: deploy, approval: forged_verifier_result)

    assert_equal "approval_required", decision.fetch("decision")
    assert_equal "blocked", decision.fetch("approval_status")
    assert_match(/schema_version 2/, decision.fetch("reason"))
    assert_match(/not execution authority/, decision.fetch("reason"))
  end

  def test_policy_rejects_boolean_l3_approval_without_hitl_artifact
    decision = Aiweb::Policy::Kernel.new.decide(packet: packet("build"), approved: true)
    assert_equal "approval_required", decision.fetch("decision")
    assert_equal "boolean_approval_rejected", decision.fetch("approval_status")
    assert_match(/HITL v2 approval artifact/, decision.fetch("reason"))
  end

  def test_policy_blocks_verifier_result_hash_as_l3_execution_authority
    forged_verifier_result = {
      "schema_version" => 1,
      "status" => "passed",
      "approval_id" => "approval-forged",
      "approval_hash" => "sha256:forged",
      "blocking_issues" => []
    }

    decision = Aiweb::Policy::Kernel.new.decide(packet: packet("build"), approval: forged_verifier_result)

    assert_equal "approval_required", decision.fetch("decision")
    assert_equal "blocked", decision.fetch("approval_status")
    assert_match(/schema_version 2/, decision.fetch("reason"))
    assert_match(/not execution authority/, decision.fetch("reason"))
  end

  def test_policy_blocks_secret_or_env_paths_before_side_effect
    decision = Aiweb::Policy::Kernel.new.decide(packet: packet("finish"), paths: ["nested/.env.production"])
    assert_equal "block", decision.fetch("decision")
    assert_match(/unsafe or secret path/, decision.fetch("reason"))

    secret_surface = Aiweb::Policy::Kernel.new.decide(packet: packet("finish"), paths: [".kube/config"])
    assert_equal "block", secret_surface.fetch("decision")
    assert_match(/unsafe or secret path/, secret_surface.fetch("reason"))
  end

  def test_policy_blocks_mismatched_external_network_scope_before_side_effect
    scoped = packet("build", "process_argv" => %w[curl https://example.invalid], "network_policy" => "none")

    decision = Aiweb::Policy::Kernel.new.decide(packet: scoped, approved: true)

    assert_equal "block", decision.fetch("decision")
    assert_equal "side_effect_scope_violation", decision.fetch("rule_id")
    assert_match(/external network|process argv/, decision.fetch("reason"))
  end

  def test_policy_blocks_raw_environment_process_argv
    scoped = packet("build", "process_argv" => %w[printenv])

    decision = Aiweb::Policy::Kernel.new.decide(packet: scoped, approved: true)

    assert_equal "block", decision.fetch("decision")
    assert_match(/environment|secret/, decision.fetch("reason"))
  end

  def test_policy_fails_closed_on_constitution_hash_mismatch
    bad = packet("finish")
    bad["constitution_hash"] = "sha256:bad"
    decision = Aiweb::Policy::Kernel.new.decide(packet: bad)
    assert_equal "block", decision.fetch("decision")
    assert_match(/constitution hash mismatch/, decision.fetch("reason"))
  end

  def test_policy_obeys_capability_matrix_auto_allow_tier
    Dir.mktmpdir("aiweb-policy-matrix-test-") do |dir|
      registry_path = File.join(dir, "policy_rule_registry.yaml")
      matrix_path = File.join(dir, "capability_matrix.yaml")
      File.write(registry_path, YAML.dump(
        "schema_version" => 1,
        "default_decision" => "block",
        "rules" => [
          { "id" => "block_secret_paths", "match" => "secret_or_env_path", "decision" => "block" },
          { "id" => "require_approval_for_l3", "match" => "risk_tier_l3_without_approval", "decision" => "approval_required" },
          { "id" => "require_hitl_for_l4_l5", "match" => "risk_tier_l4_l5", "decision" => "approval_required" },
          { "id" => "allow_l0_l2_local", "match" => "risk_tier_l0_l2", "decision" => "allow" },
          { "id" => "require_approval_above_auto_allow", "match" => "risk_tier_above_auto_allow_without_approval", "decision" => "approval_required" }
        ]
      ))
      File.write(matrix_path, YAML.dump(
        "schema_version" => 1,
        "permission_tiers" => {
          "L0" => "read_only_local_metadata",
          "L1" => "local_artifact_read",
          "L2" => "local_evidence_write",
          "L3" => "local_process_browser_or_source_patch",
          "L4" => "external_network_package_provider_deploy_git_or_mcp_credentials",
          "L5" => "irreversible_production_account_customer_financial_or_security_action"
        },
        "autonomous_local_auto_allow_max_tier" => "L1",
        "l4_l5_requires_second_reviewer" => true,
        "secret_read_policy" => "block"
      ))

      kernel = Aiweb::Policy::Kernel.new(rule_registry: Aiweb::Policy::RuleRegistry.new(registry_path, matrix_path))
      local_verify = packet("local_verify")
      decision = kernel.decide(packet: local_verify)

      assert_equal "approval_required", decision.fetch("decision")
      assert_equal "require_approval_above_auto_allow", decision.fetch("rule_id")
      assert_match(/auto-allow max tier L1/, decision.fetch("reason"))
    end
  end
end
