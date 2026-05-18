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
  end

  def test_policy_requires_explicit_approval_for_l3_local_side_effects
    decision = Aiweb::Policy::Kernel.new.decide(packet: packet("source_patch"), approved: false)
    assert_equal "approval_required", decision.fetch("decision")
    assert_match(/L3 local side effect/, decision.fetch("reason"))
  end

  def test_policy_blocks_secret_or_env_paths_before_side_effect
    decision = Aiweb::Policy::Kernel.new.decide(packet: packet("finish"), paths: ["nested/.env.production"])
    assert_equal "block", decision.fetch("decision")
    assert_match(/unsafe or secret path/, decision.fetch("reason"))
  end

  def test_policy_fails_closed_on_constitution_hash_mismatch
    bad = packet("finish")
    bad["constitution_hash"] = "sha256:bad"
    decision = Aiweb::Policy::Kernel.new.decide(packet: bad)
    assert_equal "block", decision.fetch("decision")
    assert_match(/constitution hash mismatch/, decision.fetch("reason"))
  end
end
