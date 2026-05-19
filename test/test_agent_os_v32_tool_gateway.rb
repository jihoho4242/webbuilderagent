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

  def test_gateway_allows_l3_only_with_approval
    result = Aiweb::Tools::Gateway.new.execute(run_id: "gateway-test", goal: "build", tool_name: "build", approved: true) do
      { "status" => "passed", "blocking_issues" => [] }
    end

    assert_equal "passed", result.fetch("status")
    assert_equal "allow", result.fetch("policy_decision").fetch("decision")
    assert_equal "dev_fixture_only", result.fetch("policy_decision").fetch("approval_status")
  end

  def test_gateway_fails_closed_for_unknown_tool
    result = Aiweb::Tools::Gateway.new.execute(run_id: "gateway-test", goal: "unknown", tool_name: "missing_tool")
    assert_equal "blocked", result.fetch("status")
    assert_match(/ToolGateway failed closed/, result.fetch("blocking_issues").join("\n"))
  end
end
