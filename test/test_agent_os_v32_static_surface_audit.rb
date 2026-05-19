# frozen_string_literal: true

require "json"
require "yaml"
require "time"

require_relative "support/test_helper"

require "aiweb"


class AgentOsV32StaticSurfaceAuditTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)

  def test_script_executor_surfaces_are_demoted_not_claimed_as_canonical_engines
    tool_registry = YAML.safe_load(File.read(File.join(REPO_ROOT, "configs", "tool_registry.yaml")), permitted_classes: [], aliases: false)
    assert_equal "removed_script_runner_facade", tool_registry.dig("tools", "verify_loop", "agent_engine_role")

    %w[
      loop.rb
      planner.rb
      executor.rb
      observer.rb
      report_builder.rb
      artifact_writer.rb
      session.rb
      tool_registry.rb
      tool_result.rb
      verifier.rb
      reflector.rb
    ].each do |file|
      refute File.exist?(File.join(REPO_ROOT, "lib", "aiweb", "agent_runtime", file)), "legacy AgentRuntime #{file} must stay deleted"
    end

    facade_source = File.read(File.join(REPO_ROOT, "lib", "aiweb", "project", "agent_runtime_facade.rb"))
    assert_includes facade_source, "engine_run("
    assert_includes facade_source, "removed_script_runner"
    refute_includes facade_source, "Aiweb::AgentRuntime::Loop"

    %w[execution.rb reporting.rb].each do |file|
      refute File.exist?(File.join(REPO_ROOT, "lib", "aiweb", "project", "verify_loop", file)), "legacy verify-loop #{file} must stay deleted"
    end
    verify_loop_source = File.read(File.join(REPO_ROOT, "lib", "aiweb", "project", "verify_loop.rb"))
    assert_includes verify_loop_source, "engine_run("
    assert_includes verify_loop_source, "fixed_pipeline_present"
    refute_match(/verify_loop_record_step|build\(dry_run: false\)|preview\(dry_run: false\)|qa_playwright|agent_run\(task: \"latest\"/, verify_loop_source)

    browser_actions_source = File.read(File.join(REPO_ROOT, "lib", "aiweb", "project", "engine_run", "preview_browser", "browser_actions.rb"))
    browser_schema = File.read(File.join(REPO_ROOT, "docs", "schemas", "browser-evidence.schema.json"))
    [browser_actions_source, browser_schema].each do |text|
      assert_includes text, "deterministic_local_browser_probe"
      assert_includes text, "deterministic_probe_not_autonomous_planning"
      refute_includes text, "static_safe_action_plan"
      refute_includes text, "scenario_plan"
      refute_includes text, "scenario_results"
    end
  end

  def test_baseline_audit_records_inventory_and_preserved_safety_substrate
    audit = JSON.parse(File.read(File.join(REPO_ROOT, ".ai-web", "reports", "agent-os-v32-baseline-audit.json")))
    assert_equal 1, audit.fetch("schema_version")
    agent_runtime = audit.fetch("script_executor_inventory").find { |entry| entry.fetch("surface").include?("AgentRuntime") }
    assert_equal "removed", agent_runtime.fetch("status")
    verify_loop = audit.fetch("script_executor_inventory").find { |entry| entry.fetch("surface") == "verify-loop" }
    assert_equal "converted_to_engine_run_shim", verify_loop.fetch("status")
    assert_includes audit.fetch("preserve_safety_substrate"), "PathPolicy"
  end

  def test_release_evidence_surfaces_do_not_reintroduce_fixture_readiness_claims
    evidence_paths = [
      File.join(REPO_ROOT, "releases", "v0.3.2-rc1", "p5_gate_report.md"),
      File.join(REPO_ROOT, "releases", "v0.3.2-rc1", "release_manifest.yaml"),
      File.join(REPO_ROOT, ".ai-web", "reports", "script-executor-neutralization-20260519.json"),
      File.join(REPO_ROOT, ".ai-web", "reports", "script-executor-neutralization-20260519.md"),
      File.join(REPO_ROOT, ".ai-web", "reports", "agent-os-v32-baseline-audit.json")
    ]
    forbidden_fragments = [
      "Tool gateway: passed",
      "Replay: passed",
      "Brain: safety passed",
      "side_effect_free_replay: true",
      "release_ready: true",
      "production_readiness_claimed: true",
      "production_ready_claim_allowed: true",
      "all_side_effects_require_decision_packet_policy_gateway: true"
    ]

    combined = evidence_paths.map { |path| File.read(path) }.join("\n")
    forbidden_fragments.each do |fragment|
      refute_includes combined, fragment
    end

    manifest = YAML.safe_load(File.read(File.join(REPO_ROOT, "releases", "v0.3.2-rc1", "release_manifest.yaml")), permitted_classes: [], aliases: false)
    assert_equal false, manifest.fetch("release_ready")
    assert_equal false, manifest.fetch("production_readiness_claimed")
    assert_equal false, manifest.dig("policy_gateway_report", "all_side_effects_require_decision_packet_policy_gateway")

    %w[
      tool_gateway_report
      hitl_report
      replay_report
      eval_report
      redteam_report
      brain_report
      self_improvement_report
    ].each do |report_key|
      assert_equal "blocked", manifest.dig(report_key, "production_gate_status"), "#{report_key} must stay production-blocked"
      assert_equal false, manifest.dig(report_key, "production_ready_claim_allowed"), "#{report_key} must not allow production-ready claims"
    end
  end
end
