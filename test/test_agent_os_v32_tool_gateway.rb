# frozen_string_literal: true

require "json"
require "yaml"
require "time"

require_relative "support/test_helper"

require "aiweb"


class AgentOsV32ToolGatewayTest < Minitest::Test
  def test_gateway_wraps_allowed_tool_in_decision_packet_policy_and_events
    result = Aiweb::Tools::Gateway.new.execute(run_id: "gateway-test", goal: "finish", tool_name: "finish") do
      { "status" => "passed", "blocking_issues" => [], "demo" => true }
    end

    assert_equal "passed", result.fetch("status")
    assert Aiweb::Tools::DecisionPacket.new.valid?(result.fetch("packet"))
    assert_equal "allow", result.fetch("policy_decision").fetch("decision")
    assert_equal "allow_l0_l2_local", result.fetch("policy_decision").fetch("rule_id")
    assert_equal %w[tool.requested policy.decision tool.started tool.finished], result.fetch("events").map { |event| event.fetch("event") }
  end

  def test_gateway_blocks_l3_without_approval_and_does_not_yield
    yielded = false
    result = Aiweb::Tools::Gateway.new.execute(run_id: "gateway-test", goal: "build", tool_name: "build") do
      yielded = true
      { "status" => "passed" }
    end

    assert_equal "approval_required", result.fetch("status")
    assert_equal false, yielded
    assert_equal %w[tool.requested policy.decision tool.blocked], result.fetch("events").map { |event| event.fetch("event") }
  end

  def test_gateway_rejects_l3_boolean_approval_without_artifact
    yielded = false
    result = Aiweb::Tools::Gateway.new.execute(run_id: "gateway-test", goal: "build", tool_name: "build", approved: true) do
      yielded = true
      { "status" => "passed", "blocking_issues" => [] }
    end

    assert_equal "approval_required", result.fetch("status")
    assert_equal false, yielded
    assert_equal "boolean_approval_rejected", result.fetch("policy_decision").fetch("approval_status")
  end

  def test_gateway_rejects_verifier_result_hash_as_approval
    yielded = false
    result = Aiweb::Tools::Gateway.new.execute(
      run_id: "gateway-test",
      goal: "build",
      tool_name: "build",
      approval: {
        "schema_version" => 1,
        "status" => "passed",
        "approval_id" => "approval-forged",
        "approval_hash" => "sha256:forged",
        "blocking_issues" => []
      }
    ) do
      yielded = true
      { "status" => "passed", "blocking_issues" => [] }
    end

    assert_equal "approval_required", result.fetch("status")
    assert_equal false, yielded
    assert_equal "blocked", result.fetch("policy_decision").fetch("approval_status")
    assert_match(/not execution authority/, result.fetch("policy_decision").fetch("reason"))
  end

  def test_gateway_allows_l3_only_with_hash_bound_approval_artifact
    packet_builder = Aiweb::Tools::DecisionPacket.new
    packet = packet_builder.build(run_id: "gateway-test", goal: "build", requested_tool: "build")
    action_diff = { "tool" => "build", "outputs" => packet.fetch("expected_outputs") }
    args = { "tool" => "build", "inputs_hash" => packet.fetch("inputs_hash") }
    evidence = { "packet_id" => packet.fetch("packet_id"), "review" => "operator-approved" }
    approval = Aiweb::Approval::Artifact.build(
      run_id: packet.fetch("run_id"),
      decision_packet_ids: [packet.fetch("packet_id")],
      risk_tier: "L3",
      requested_capabilities: ["build"],
      action_diff: action_diff,
      args: args,
      evidence: evidence,
      approver_id: "operator-1"
    )

    result = Aiweb::Tools::Gateway.new(packet_builder: packet_builder).execute(
      run_id: "gateway-test",
      goal: "build",
      tool_name: "build",
      decision_packet: packet,
      approval_artifact: approval,
      action_diff: action_diff,
      args: args,
      evidence: evidence
    ) do
      { "status" => "passed", "blocking_issues" => [] }
    end

    assert_equal "passed", result.fetch("status")
    assert_equal packet.fetch("packet_id"), result.fetch("packet").fetch("packet_id")
    assert_equal "allow", result.fetch("policy_decision").fetch("decision")
    assert_equal "passed", result.fetch("policy_decision").fetch("approval_status")
  end

  def test_gateway_fails_closed_for_unknown_tool
    result = Aiweb::Tools::Gateway.new.execute(run_id: "gateway-test", goal: "unknown", tool_name: "missing_tool")
    assert_equal "blocked", result.fetch("status")
    assert_match(/ToolGateway failed closed/, result.fetch("blocking_issues").join("\n"))
  end
end
