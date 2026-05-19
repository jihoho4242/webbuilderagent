# frozen_string_literal: true

require "json"
require "yaml"
require "time"

require_relative "support/test_helper"

require "aiweb"


class AgentOsV32DecisionPacketTest < Minitest::Test
  def test_decision_packet_contains_constitution_policy_registry_and_replay_evidence
    builder = Aiweb::Tools::DecisionPacket.new
    packet = builder.build(run_id: "decision-test", goal: "verify site", requested_tool: "build", inputs: { "script" => "build" })

    assert builder.valid?(packet)
    assert_match(/^sha256:/, packet.fetch("constitution_hash"))
    assert_equal Aiweb::Tools::DecisionPacket::POLICY_KERNEL_VERSION, packet.fetch("policy_kernel_version")
    assert_match(/^sha256:/, packet.fetch("tool_registry_version"))
    assert_equal "build", packet.fetch("requested_tool")
    assert_equal "L3", packet.fetch("risk_tier")
    assert_equal "required", packet.fetch("approval_requirement")
    assert_equal [], packet.fetch("read_paths")
    assert_equal [], packet.fetch("write_paths")
    assert_equal [], packet.fetch("process_argv")
    assert_equal "none", packet.fetch("network_policy")
    assert_equal true, packet.dig("replay_policy", "side_effect_free_replay")
    assert_match(/^sha256:/, packet.dig("replay_policy", "decision_replay_key"))
  end

  def test_decision_packet_carries_side_effect_scope_for_gateway_review
    packet = Aiweb::Tools::DecisionPacket.new.build(
      run_id: "decision-test",
      goal: "browser qa",
      requested_tool: "browser_qa",
      inputs: {
        "read_paths" => ["src/pages/index.astro"],
        "write_paths" => [".ai-web/runs/browser-qa/result.json"],
        "process_argv" => %w[pnpm exec playwright],
        "network_policy" => "localhost_only"
      },
      expected_outputs: [".ai-web/runs/browser-qa/result.json"]
    )

    assert_equal ["src/pages/index.astro"], packet.fetch("read_paths")
    assert_equal [".ai-web/runs/browser-qa/result.json"], packet.fetch("write_paths")
    assert_equal %w[pnpm exec playwright], packet.fetch("process_argv")
    assert_equal "localhost_only", packet.fetch("network_policy")
  end

  def test_idempotency_key_is_stable_but_packet_id_is_unique
    builder = Aiweb::Tools::DecisionPacket.new
    a = builder.build(run_id: "decision-test", goal: "same", requested_tool: "finish", inputs: { "a" => 1 })
    b = builder.build(run_id: "decision-test", goal: "same", requested_tool: "finish", inputs: { "a" => 1 })

    assert_equal a.fetch("idempotency_key"), b.fetch("idempotency_key")
    refute_equal a.fetch("packet_id"), b.fetch("packet_id")
  end
end
