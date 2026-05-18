# frozen_string_literal: true

require "json"
require "yaml"
require "time"

require_relative "support/test_helper"

require "aiweb"


require "fileutils"
require "tmpdir"

class AgentOsV32ReplayTest < Minitest::Test
  def test_evidence_ledger_is_hash_chained_for_replay_integrity
    ledger = Aiweb::Observability::EvidenceLedger.new
    first = ledger.append("observe", "goal" => "x")
    second = ledger.append("policy.decision", "decision" => "allow")

    assert_nil first.fetch("previous_event_hash")
    assert_equal first.fetch("event_hash"), second.fetch("previous_event_hash")
    assert_match(/^sha256:/, second.fetch("event_hash"))
  end

  def test_engine_run_dry_run_exposes_constitution_and_goal_runtime_nodes
    Dir.mktmpdir("aiweb-v32-replay-") do |dir|
      project = Aiweb::Project.new(dir)
      project.init(profile: "D")
      payload = project.engine_run(goal: "verify agent os graph", mode: "safe_patch", dry_run: true)
      graph = payload.dig("engine_run", "run_graph")
      node_ids = graph.fetch("nodes").map { |node| node.fetch("node_id") }

      assert_match(/^sha256:/, payload.dig("engine_run", "capability", "constitution_hash"))
      %w[observe_goal load_constitution build_decision_packet policy_check hitl_wait_if_required execute_tool verify_result reflect_next_step write_memory_proposal finish_or_continue].each do |node_id|
        assert_includes node_ids, node_id
      end
      assert_equal true, payload.dig("engine_run", "graph_execution_plan", "validation", "all_side_effect_nodes_gated") if payload.dig("engine_run", "graph_execution_plan")
    end
  end
end
