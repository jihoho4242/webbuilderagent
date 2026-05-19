# frozen_string_literal: true

require "json"
require "tmpdir"

require_relative "support/test_helper"

require "aiweb"


class AgentOsV32BrainAndSelfImprovementTest < Minitest::Test
  def test_brain_store_persists_project_local_json_mvp_and_honors_tombstones
    Dir.mktmpdir("aiweb-brain-test") do |dir|
      store = Aiweb::Brain::Store.new(root: dir)
      result = store.remember(summary: "Use a compact premium editorial layout", evidence_grade: "operator_approved", source: "test", scope: "project")

      assert_equal "passed", result.fetch("status")
      assert_equal "project_local_json_mvp_sqlite_pending", store.storage_mode

      path = File.join(dir, ".ai-web", "brain", "brain.json")
      assert File.file?(path)

      reloaded = Aiweb::Brain::Store.new(root: dir)
      assert_equal ["Use a compact premium editorial layout"], reloaded.search.map { |item| item.fetch("summary") }

      reloaded.forget(result.fetch("memory_id"))

      tombstone_reload = Aiweb::Brain::Store.new(root: dir)
      assert_empty tombstone_reload.search
      assert_equal 0, tombstone_reload.tombstone_leak_count
    end
  end

  def test_brain_store_rejects_secret_like_memory
    result = Aiweb::Brain::Store.new.remember(summary: "Save token=abc123 in memory")

    assert_equal "blocked", result.fetch("status")
    assert_includes result.fetch("blocking_issues").join("; "), "secret-like memory rejected"
  end

  def test_self_improvement_experiment_registry_persists_sandbox_only_records
    Dir.mktmpdir("aiweb-improvement-test") do |dir|
      path = File.join(dir, ".ai-web", "self-improvement", "experiment_registry.jsonl")
      proposal = {
        "proposal_id" => "proposal-test-001",
        "mode" => "dry_run",
        "target_component" => "evals/runner",
        "hypothesis" => "Expanded fixture checks reduce accidental production-readiness claims"
      }

      record = Aiweb::SelfImprovement::ExperimentRegistry.new(path: path).record(proposal)

      assert_equal "planned", record.fetch("status")
      assert_equal false, record.fetch("promotion_allowed")
      assert_equal true, record.fetch("sandbox_only")
      assert File.file?(path)

      persisted = File.readlines(path).map { |line| JSON.parse(line) }
      assert_equal [record.fetch("experiment_id")], persisted.map { |item| item.fetch("experiment_id") }
    end
  end
end
