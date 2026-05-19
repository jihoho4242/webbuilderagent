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
    %w[webbuilding_gold.jsonl webbuilding_adversarial.jsonl abstention_cases.jsonl tool_selection_cases.jsonl].each do |name|
      path = File.join(REPO_ROOT, "evals", "packs", name)
      assert File.file?(path), "missing #{name}"
      assert_operator File.readlines(path).length, :>=, 1
    end
  end
end
