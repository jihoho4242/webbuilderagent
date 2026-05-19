# frozen_string_literal: true

require "json"
require "yaml"
require "time"

require_relative "support/test_helper"

require "aiweb"


class AgentOsV32ApprovalTest < Minitest::Test
  def setup
    @packet = Aiweb::Tools::DecisionPacket.new.build(run_id: "approval-test", goal: "deploy dry-run", requested_tool: "external_deploy", inputs: { "dry_run" => true })
  end

  def artifact(**overrides)
    Aiweb::Approval::Artifact.build(
      run_id: "approval-test",
      decision_packet_ids: [@packet.fetch("packet_id")],
      risk_tier: overrides.fetch(:risk_tier, "L4"),
      requested_capabilities: ["external_deploy"],
      action_diff: overrides.fetch(:action_diff, "dry-run diff"),
      args: overrides.fetch(:args, { "dry_run" => true }),
      evidence: overrides.fetch(:evidence, { "review" => true }),
      approver_id: "human-1",
      second_reviewer_id: overrides.fetch(:second_reviewer_id, "human-2"),
      ttl_seconds: overrides.fetch(:ttl_seconds, 900)
    )
  end

  def verify(record, **overrides)
    Aiweb::Approval::Verifier.new.verify(
      artifact: record,
      decision_packet: @packet,
      action_diff: overrides.fetch(:action_diff, "dry-run diff"),
      args: overrides.fetch(:args, { "dry_run" => true }),
      evidence: overrides.fetch(:evidence, { "review" => true })
    )
  end

  def test_hash_bound_l4_approval_with_second_reviewer_passes
    check = verify(artifact)
    assert_equal "passed", check.fetch("status")
    assert_equal "human-2", check.fetch("second_reviewer_id")
    assert_equal true, check.fetch("artifact_hash_self_verified")
    assert_equal true, check.fetch("validation_hash_verified")

    reordered = artifact.to_a.reverse.to_h
    reordered_check = verify(reordered)
    assert_equal "passed", reordered_check.fetch("status")
    assert_equal true, reordered_check.fetch("artifact_hash_self_verified")
  end

  def test_expired_mismatched_reused_and_single_reviewer_artifacts_block
    expired = verify(artifact(ttl_seconds: -1))
    assert_equal "blocked", expired.fetch("status")
    assert_match(/expired/, expired.fetch("blocking_issues").join("\n"))

    mismatch = verify(artifact, args: { "dry_run" => false })
    assert_equal "blocked", mismatch.fetch("status")
    assert_match(/args_hash mismatch/, mismatch.fetch("blocking_issues").join("\n"))

    reused_record = artifact
    reused_record["consumed_at"] = Time.now.utc.iso8601
    reused = verify(reused_record)
    assert_equal "blocked", reused.fetch("status")
    assert_match(/single-use/, reused.fetch("blocking_issues").join("\n"))

    no_second = verify(artifact(second_reviewer_id: nil))
    assert_equal "blocked", no_second.fetch("status")
    assert_match(/second_reviewer_id/, no_second.fetch("blocking_issues").join("\n"))
  end

  def test_tampered_approval_hash_validation_hash_and_scope_block
    tampered_hash = artifact
    tampered_hash["approval_hash"] = "sha256:#{"0" * 64}"
    hash_check = verify(tampered_hash)
    assert_equal "blocked", hash_check.fetch("status")
    assert_match(/approval_hash mismatch/, hash_check.fetch("blocking_issues").join("\n"))
    assert_equal false, hash_check.fetch("artifact_hash_self_verified")

    tampered_validation = artifact
    tampered_validation["validation_hash"] = "sha256:#{"1" * 64}"
    validation_check = verify(tampered_validation)
    assert_equal "blocked", validation_check.fetch("status")
    assert_match(/validation_hash mismatch/, validation_check.fetch("blocking_issues").join("\n"))
    assert_equal false, validation_check.fetch("validation_hash_verified")

    wrong_run = artifact
    wrong_run["run_id"] = "other-run"
    run_check = verify(wrong_run)
    assert_equal "blocked", run_check.fetch("status")
    assert_match(/run_id mismatch/, run_check.fetch("blocking_issues").join("\n"))

    wrong_risk = artifact(risk_tier: "L5")
    risk_check = verify(wrong_risk)
    assert_equal "blocked", risk_check.fetch("status")
    assert_match(/risk_tier mismatch/, risk_check.fetch("blocking_issues").join("\n"))

    wrong_capability = artifact
    wrong_capability["requested_capabilities"] = ["build"]
    capability_check = verify(wrong_capability)
    assert_equal "blocked", capability_check.fetch("status")
    assert_match(/requested_capabilities/, capability_check.fetch("blocking_issues").join("\n"))
  end
end
