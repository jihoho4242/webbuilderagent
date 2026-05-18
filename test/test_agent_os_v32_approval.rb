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
end
