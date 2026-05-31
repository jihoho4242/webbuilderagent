# frozen_string_literal: true

require "json"
require "yaml"
require "time"

require_relative "support/test_helper"

require "aiweb"


class AgentOsV32EvalsTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)

  def test_eval_runner_requires_more_than_single_fixture_for_production_claim
    single = Aiweb::Evals::Runner.new.run(cases: [{ "status" => "passed" }])
    assert_equal "insufficient_fixture_blocked", single.fetch("status")
    assert_equal "blocked", single.fetch("production_gate_status")
    assert_equal false, single.fetch("production_ready_claim_allowed")
    assert_match(/minimum expanded fixture count/, single.fetch("blocking_issues").join("\n"))

    expanded = Aiweb::Evals::Runner.new.run(cases: Aiweb::Evals::Runner.default_fixture_cases)
    assert_equal "expanded_fixture_passed", expanded.fetch("status")
    assert_equal "blocked", expanded.fetch("production_gate_status")
    assert_equal true, expanded.fetch("expanded_fixture_gate_passed")
    assert_equal false, expanded.fetch("production_ready_claim_allowed")
    assert_equal 0, expanded.fetch("human_reviewed_case_count")
    assert_match(/production-ready eval science requires/, expanded.fetch("blocking_issues").join("\n"))
  end

  def test_eval_fixture_packs_and_sampling_plan_exist
    assert File.file?(File.join(REPO_ROOT, "evals", "eval_sampling_plan.yaml"))
    %w[
      webbuilding_gold.jsonl
      webbuilding_adversarial.jsonl
      abstention_cases.jsonl
      tool_selection_cases.jsonl
      holdout_webbuilding_gold.jsonl
      holdout_webbuilding_adversarial.jsonl
      holdout_abstention_cases.jsonl
      holdout_tool_selection_cases.jsonl
    ].each do |name|
      path = File.join(REPO_ROOT, "evals", "packs", name)
      assert File.file?(path), "missing #{name}"
      assert_operator File.readlines(path).length, :>=, 1
    end
  end

  def test_eval_runner_uses_jsonl_operational_seed_packs
    result = Aiweb::Evals::Runner.new.run(cases: Aiweb::Evals::Runner.pack_cases)

    assert_equal "expanded_holdout_fixture_passed", result.fetch("status")
    assert_equal "jsonl_operational_seed_with_holdout", result.fetch("case_source")
    assert_operator result.fetch("case_count"), :>=, 240
    assert_equal 0, result.fetch("failure_count")
    assert_equal 0, result.fetch("safety_critical_failure_count")
    assert_equal 50, result.fetch("tool_selection_case_count")
    assert_equal 1.0, result.fetch("tool_routing_accuracy")
    assert_equal true, result.fetch("holdout_fixture_gate_passed")
    assert_equal 90, result.fetch("holdout_case_count")
    assert_equal 0, result.fetch("holdout_failure_count")
    assert_equal 0, result.fetch("holdout_safety_critical_failure_count")
    assert_equal 20, result.fetch("holdout_tool_selection_case_count")
    assert_equal 1.0, result.fetch("holdout_tool_routing_accuracy")
    assert_equal 50, result.fetch("pack_counts").fetch("webbuilding_gold.jsonl")
    assert_equal 50, result.fetch("pack_counts").fetch("webbuilding_adversarial.jsonl")
    assert_equal 20, result.fetch("pack_counts").fetch("abstention_cases.jsonl")
    assert_equal 30, result.fetch("pack_counts").fetch("tool_selection_cases.jsonl")
    assert_equal 30, result.fetch("pack_counts").fetch("holdout_webbuilding_gold.jsonl")
    assert_equal 30, result.fetch("pack_counts").fetch("holdout_webbuilding_adversarial.jsonl")
    assert_equal 10, result.fetch("pack_counts").fetch("holdout_abstention_cases.jsonl")
    assert_equal 20, result.fetch("pack_counts").fetch("holdout_tool_selection_cases.jsonl")
  end
end
