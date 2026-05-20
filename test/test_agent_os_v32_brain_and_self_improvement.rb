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
      assert_equal "project_local_jsonl_ledger_with_projection", store.storage_mode
      assert_equal false, store.sqlite_available?
      assert_equal true, store.concurrency_backed?
      assert_match(/brain\.lock\z/, store.lock_path)

      path = File.join(dir, ".ai-web", "brain", "brain.jsonl")
      index_path = File.join(dir, ".ai-web", "brain", "brain-index.json")
      health_path = File.join(dir, ".ai-web", "brain", "memory-health-report.json")
      assert File.file?(path)
      assert File.file?(index_path)
      assert File.file?(health_path)
      events = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
      assert_equal ["memory.remembered"], events.map { |event| event.fetch("event") }
      assert_match(/^sha256:/, events.first.fetch("event_hash"))
      assert_nil events.first["previous_event_hash"]
      index = JSON.parse(File.read(index_path))
      assert_equal 1, index.fetch("ledger_event_count")
      assert_equal events.first.fetch("event_hash"), index.fetch("last_event_hash")
      assert_equal true, index.fetch("event_hash_chain_valid")
      assert_equal 1, index.fetch("item_count")

      reloaded = Aiweb::Brain::Store.new(root: dir)
      assert_equal ["Use a compact premium editorial layout"], reloaded.search.map { |item| item.fetch("summary") }
      assert_equal true, reloaded.event_hash_chain_valid?
      assert_equal 0, reloaded.search_projection_lag

      reloaded.forget(result.fetch("memory_id"))
      events = File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[memory.remembered memory.forgotten], events.map { |event| event.fetch("event") }
      assert_equal events.first.fetch("event_hash"), events.last.fetch("previous_event_hash")
      assert_match(/^sha256:/, events.last.fetch("event_hash"))

      tombstone_reload = Aiweb::Brain::Store.new(root: dir)
      assert_empty tombstone_reload.search
      assert_equal 0, tombstone_reload.tombstone_leak_count
      pre_drill_audit = Aiweb::Brain::MemoryAudit.new.audit(tombstone_reload)
      assert_equal "passed", pre_drill_audit.fetch("status")
      assert_equal "blocked", pre_drill_audit.fetch("operational_status")
      assert_equal true, pre_drill_audit.dig("metrics", "event_hash_chain_valid")
      assert_equal true, pre_drill_audit.dig("metrics", "search_projection_present")
      assert_equal true, pre_drill_audit.dig("metrics", "concurrency_backed")
      assert_equal false, pre_drill_audit.dig("metrics", "backup_restore_drill_present")
      assert_equal 0, pre_drill_audit.dig("metrics", "search_projection_lag")
      assert_match(/backup\/restore drill evidence/, pre_drill_audit.fetch("operational_blocking_issues").join("\n"))

      drill = tombstone_reload.backup_restore_drill!
      assert_equal "passed", drill.fetch("status")
      assert_equal true, File.file?(tombstone_reload.backup_restore_drill_path)
      assert_equal drill.fetch("source_last_event_hash"), drill.fetch("restored_last_event_hash")
      audit = Aiweb::Brain::MemoryAudit.new.audit(tombstone_reload)
      assert_equal true, audit.dig("metrics", "backup_restore_drill_present")
      refute_match(/backup\/restore drill evidence/, audit.fetch("operational_blocking_issues").join("\n"))
      assert_match(/SQLite-backed storage evidence/, audit.fetch("operational_blocking_issues").join("\n"))
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
      index_path = File.join(brain_dir, "brain-index.json")
      assert File.file?(ledger_path)
      assert File.file?(index_path)
      events = File.readlines(ledger_path, chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[memory.remembered memory.forgotten], events.map { |event| event.fetch("event") }
      assert events.all? { |event| event.fetch("event_hash").start_with?("sha256:") }

      reloaded = Aiweb::Brain::Store.new(root: dir)
      assert_equal ["Keep this approved preference"], reloaded.search.map { |item| item.fetch("summary") }
      assert_equal true, reloaded.event_hash_chain_valid?
      assert_equal 0, reloaded.search_projection_lag
    end
  end

  def test_brain_store_file_lock_preserves_hash_chain_across_reloaded_writers
    Dir.mktmpdir("aiweb-brain-lock-test") do |dir|
      first = Aiweb::Brain::Store.new(root: dir)
      second = Aiweb::Brain::Store.new(root: dir)

      first_result = first.remember(summary: "First concurrent-safe preference", evidence_grade: "operator_approved")
      second_result = second.remember(summary: "Second concurrent-safe preference", evidence_grade: "operator_approved")

      assert_equal "passed", first_result.fetch("status")
      assert_equal "passed", second_result.fetch("status")
      reloaded = Aiweb::Brain::Store.new(root: dir)
      assert_equal 2, reloaded.ledger_event_count
      assert_equal true, reloaded.event_hash_chain_valid?
      assert_equal ["First concurrent-safe preference", "Second concurrent-safe preference"], reloaded.search.map { |item| item.fetch("summary") }
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

      assert_equal "sandbox_planned", record.fetch("status")
      assert_equal "experiment_fixture_recorded", record.fetch("fixture_status")
      assert_equal "blocked", record.fetch("production_gate_status")
      assert_equal false, record.fetch("promotion_allowed")
      assert_equal false, record.fetch("production_ready_claim_allowed")
      assert_equal true, record.fetch("sandbox_only")
      assert File.file?(path)

      persisted = File.readlines(path).map { |line| JSON.parse(line) }
      assert_equal [record.fetch("experiment_id")], persisted.map { |item| item.fetch("experiment_id") }
    end
  end

  def test_self_improvement_governor_never_claims_production_ready_or_generates_patch
    proposal = Aiweb::SelfImprovement::Governor.new.dry_run_proposal(
      target_component: "runtime_tool_description",
      hypothesis: "Improve clarity without changing source",
      eval_plan: { "required" => true },
      rollback_plan: { "summary" => "revert proposal" }
    )

    assert_equal "dry_run", proposal.fetch("mode")
    assert_equal "proposal_fixture_recorded", proposal.fetch("fixture_status")
    assert_equal "blocked", proposal.fetch("production_gate_status")
    assert_equal false, proposal.fetch("production_ready_claim_allowed")
    assert_equal true, proposal.fetch("sandbox_only")
    assert_equal false, proposal.fetch("patch_generated")
    assert_equal false, proposal.fetch("promotion_allowed")
    assert_equal false, proposal.fetch("source_changed")
    assert_match(/sandbox patch diff/, proposal.fetch("operational_blocking_issues").join("\n"))
  end

  def test_self_improvement_forbidden_component_blocks_even_fixture_proposal
    proposal = Aiweb::SelfImprovement::Governor.new.dry_run_proposal(
      target_component: "policy_kernel",
      hypothesis: "Try to loosen policy",
      eval_plan: {},
      rollback_plan: {}
    )

    assert_equal "blocked", proposal.fetch("mode")
    assert_equal "proposal_blocked", proposal.fetch("fixture_status")
    assert_equal "blocked", proposal.fetch("production_gate_status")
    assert_equal "L5", proposal.fetch("risk_tier")
    assert_match(/cannot directly patch forbidden component/, proposal.fetch("blocking_issues").join("\n"))
  end
end
