# frozen_string_literal: true

require "json"
require "fileutils"
require "tmpdir"

require_relative "support/test_helper"

require "aiweb"


class AgentOsV32BrainAndSelfImprovementTest < Minitest::Test
  def test_brain_store_persists_project_local_jsonl_ledger_and_honors_tombstones
    Dir.mktmpdir("aiweb-brain-test") do |dir|
      store = Aiweb::Brain::Store.new(root: dir)
      result = store.remember(summary: "Use a compact premium editorial layout", evidence_grade: "operator_approved", source: "test", scope: "project")

      assert_equal "passed", result.fetch("status")
      assert_equal "project_local_jsonl_ledger_sqlite_unavailable", store.storage_mode
      assert_equal false, store.sqlite_available?

      path = File.join(dir, ".ai-web", "brain", "brain.jsonl")
      assert File.file?(path)
      events = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
      assert_equal ["memory.remembered"], events.map { |event| event.fetch("event") }

      reloaded = Aiweb::Brain::Store.new(root: dir)
      assert_equal ["Use a compact premium editorial layout"], reloaded.search.map { |item| item.fetch("summary") }

      reloaded.forget(result.fetch("memory_id"))
      events = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[memory.remembered memory.forgotten], events.map { |event| event.fetch("event") }

      tombstone_reload = Aiweb::Brain::Store.new(root: dir)
      assert_empty tombstone_reload.search
      assert_equal 0, tombstone_reload.tombstone_leak_count
      audit = Aiweb::Brain::MemoryAudit.new.audit(tombstone_reload)
      assert_equal "passed", audit.fetch("status")
      assert_equal "blocked", audit.fetch("operational_status")
      assert_match(/SQLite backend unavailable/, audit.fetch("operational_blocking_issues").join("\n"))
    end
  end

  def test_brain_store_migrates_legacy_json_snapshot_to_jsonl_ledger
    Dir.mktmpdir("aiweb-brain-legacy-test") do |dir|
      brain_dir = File.join(dir, ".ai-web", "brain")
      FileUtils.mkdir_p(brain_dir)
      legacy_path = File.join(brain_dir, "brain.json")
      File.write(
        legacy_path,
        JSON.pretty_generate(
          "items" => [
            { "id" => "memory-keep", "summary" => "Keep this approved preference", "evidence_grade" => "high" },
            { "id" => "memory-forget", "summary" => "Do not leak this tombstoned preference", "evidence_grade" => "high" }
          ],
          "tombstones" => ["memory-forget"]
        )
      )

      migrated = Aiweb::Brain::Store.new(root: dir)

      assert_equal ["Keep this approved preference"], migrated.search.map { |item| item.fetch("summary") }
      assert_equal 0, migrated.tombstone_leak_count

      ledger_path = File.join(brain_dir, "brain.jsonl")
      assert File.file?(ledger_path)
      events = File.readlines(ledger_path, chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[memory.remembered memory.forgotten], events.map { |event| event.fetch("event") }

      reloaded = Aiweb::Brain::Store.new(root: dir)
      assert_equal ["Keep this approved preference"], reloaded.search.map { |item| item.fetch("summary") }
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
