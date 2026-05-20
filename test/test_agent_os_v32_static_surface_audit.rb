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
    assert_equal "read_only_removed_script_runner_facade", tool_registry.dig("tools", "verify_loop", "agent_engine_role")
    assert_equal "read_only_engine_run_migration_shim", tool_registry.dig("tools", "verify_loop", "side_effect_class")
    assert_equal false, tool_registry.dig("tools", "verify_loop", "execution_available")

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
    assert_includes verify_loop_source, "read_only_migration_shim"
    assert_includes verify_loop_source, '"execution_allowed" => false'
    assert_includes verify_loop_source, "fixed_pipeline_present"
    refute_includes verify_loop_source, "approved: execute_engine"
    refute_includes verify_loop_source, "execute_engine = approved"
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
    assert_equal "read_only_engine_run_migration_shim", verify_loop.fetch("status")
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

  def test_cli_help_does_not_market_engine_run_as_manus_grade
    help = Aiweb::CLI::HelpText::TEXT

    refute_includes help, ["Manus", "-style"].join
    refute_includes help, ["Manus", "-grade"].join
    assert_includes help, "engine-run: supervised local engine-run runtime for bounded web-building tasks"
    assert_includes help, "network/install/deploy/provider CLI/git push remain elevated-approval actions"
    refute_includes help, "verify-loop [--max-cycles N:1-10] [--agent codex|openmanus] [--sandbox docker|podman] [--approval-hash HASH] [--approved]"
    assert_includes help, 'agent "..." [--mode plan-only|supervised|autonomous-local] [--profile D|S] [--max-steps N] [--dry-run] [--approval-hash HASH] [--approved]'
    refute_includes help, 'agent "..." [--mode plan-only|supervised|autonomous-local] [--profile D|S] [--max-steps N] [--approved] [--dry-run]'
  end

  def test_live_guidance_does_not_reintroduce_approved_only_execution_shortcuts
    live_guidance = %w[
      lib/aiweb/project/agent_runtime_facade.rb
      lib/aiweb/project/engine_run/run_state.rb
      lib/aiweb/project/verify_loop.rb
      lib/aiweb/project/run_lifecycle.rb
      lib/aiweb/project/workbench.rb
      lib/aiweb/project/engine_run/eval_baseline.rb
      docs/schemas/engine-run-human-review-pack.schema.json
      lib/aiweb/cli/help_text.rb
      bin/webbuilder
      lib/aiweb/cli/agent_run_payload.rb
      lib/aiweb/cli/dispatch.rb
      lib/aiweb/project/agent_run.rb
      lib/aiweb/project/agent_run/openmanus.rb
      lib/aiweb/project/agent_run/metadata_payload.rb
      lib/aiweb/project/mcp_broker.rb
      lib/aiweb/project/engine_run/eval_baseline.rb
      lib/aiweb/project/engine_scheduler_service_domain.rb
      lib/aiweb/project/runtime_commands/setup.rb
      lib/aiweb/project/workbench.rb
    ].to_h { |relative| [relative, File.read(File.join(REPO_ROOT, relative))] }

    refute_match(/aiweb agent --mode supervised --approved(?!.*--approval-hash)/, live_guidance.fetch("lib/aiweb/project/agent_runtime_facade.rb"))
    refute_match(/engine-run --resume .*--approved after reviewing/, live_guidance.fetch("lib/aiweb/project/engine_run/run_state.rb"))
    refute_match(/verify-loop --max-cycles \d+ --approved/, live_guidance.fetch("lib/aiweb/project/run_lifecycle.rb"))
    refute_match(/workbench", "--serve", "--approved"/, live_guidance.fetch("lib/aiweb/project/run_lifecycle.rb"))
    refute_match(/setup", "--install", "--approved"/, live_guidance.fetch("lib/aiweb/project/run_lifecycle.rb"))
    refute_match(/agent-run".*"--approved"/m, live_guidance.fetch("lib/aiweb/project/run_lifecycle.rb"))
    assert_includes live_guidance.fetch("lib/aiweb/project/run_lifecycle.rb"), 'aiweb agent "improve this website" --mode supervised --dry-run'
    refute_includes live_guidance.fetch("lib/aiweb/project/workbench.rb"), "aiweb verify-loop --max-cycles 3"
    assert_includes live_guidance.fetch("lib/aiweb/project/workbench.rb"), "aiweb engine-run --agent codex --mode agentic_local --max-cycles 3 --dry-run"
    assert_includes live_guidance.fetch("lib/aiweb/project/workbench.rb"), "Plan supervised natural-language agent run"
    assert_includes live_guidance.fetch("lib/aiweb/project/workbench.rb"), "--mode supervised --dry-run"
    refute_includes live_guidance.fetch("lib/aiweb/project/engine_run/eval_baseline.rb"), "import still requires --approved"
    refute_includes live_guidance.fetch("docs/schemas/engine-run-human-review-pack.schema.json"), "import_requires_approved_flag"
    refute_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), '[--approved] [--dry-run]'
    refute_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), "verify-loop --max-cycles 3 --agent codex --approval-hash HASH --approved"
    refute_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), "agent-run --task latest --agent codex --approval-hash HASH --approved"
    refute_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), "agent-run --task latest --agent openmanus --sandbox docker --approval-hash HASH --approved"
    assert_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), "agent-run: advanced internal source-patch adapter"
    refute_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), "deploy --target cloudflare-pages|vercel --approved"
    refute_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), "setup --install --approval-hash HASH --approved"
    refute_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), "workbench --serve --approval-hash HASH --approved"
    refute_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), "engine-scheduler tick [--run-id latest|ID] [--approval-hash HASH] [--approved] [--execute]"
    refute_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), "engine-scheduler daemon [--run-id latest|ID] [--max-ticks N] [--interval-seconds N] [--workers N] [--approval-hash HASH] [--approved] [--execute]"
    refute_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), "mcp-broker call --server lazyweb --tool lazyweb_health|lazyweb_search [--query QUERY] [--limit N] [--endpoint URL] [--approval-hash HASH] [--approved]"
    refute_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), "eval-baseline import --path .ai-web/eval/candidate-human-baselines.json --approval-hash HASH --approved"
    assert_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), "Real package install remains a lower-level ops action"
    assert_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), "real serve is a lower-level localhost ops action"
    assert_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), "resume execution remains a lower-level ops action"
    assert_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), "mcp-broker call --server lazyweb --tool lazyweb_health|lazyweb_search [--query QUERY] [--limit N] [--endpoint URL] --dry-run"
    assert_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), "eval-baseline import --path .ai-web/eval/candidate-human-baselines.json --dry-run"
    %w[
      lib/aiweb/cli/agent_run_payload.rb
      lib/aiweb/cli/dispatch.rb
      lib/aiweb/project/agent_run.rb
      lib/aiweb/project/agent_run/openmanus.rb
      lib/aiweb/project/agent_run/metadata_payload.rb
      lib/aiweb/project/mcp_broker.rb
      lib/aiweb/project/engine_run/eval_baseline.rb
      lib/aiweb/project/engine_scheduler_service_domain.rb
      lib/aiweb/project/runtime_commands/setup.rb
      lib/aiweb/project/workbench.rb
    ].each do |relative|
      refute_includes live_guidance.fetch(relative), "then rerun with --approval-hash HASH --approved", "#{relative} must not emit copy-paste approved next_action guidance"
    end
    assert_includes live_guidance.fetch("lib/aiweb/project/agent_run/openmanus.rb"), "prefer aiweb agent or aiweb engine-run for user-facing execution"
    assert_includes live_guidance.fetch("lib/aiweb/project/mcp_broker.rb"), "lower-level ops action"
    assert_includes live_guidance.fetch("lib/aiweb/project/engine_run/eval_baseline.rb"), "not a friendly runbook"
    assert_includes live_guidance.fetch("lib/aiweb/project/runtime_commands/setup.rb"), "lower-level ops action"
    assert_includes live_guidance.fetch("lib/aiweb/project/workbench.rb"), "lower-level localhost ops action"
    assert_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), 'agent "verify and improve this local scaffold" --mode supervised --dry-run'
    assert_includes live_guidance.fetch("lib/aiweb/cli/help_text.rb"), "engine-run --agent codex --mode agentic_local --max-cycles 3 --dry-run"
    refute_match(/setup --install(?:(?!approval_hash).)*stdout\.log/m, live_guidance.fetch("bin/webbuilder"))
    refute_includes live_guidance.fetch("bin/webbuilder"), '--approved --approval-hash HASH'
    refute_includes live_guidance.fetch("bin/webbuilder"), "verify-loop --max-cycles 3 --approval-hash HASH --approved"
    refute_includes live_guidance.fetch("bin/webbuilder"), "agent-run --task latest --agent codex --approval-hash HASH --approved"
    refute_match(/deploy --target (?:cloudflare-pages|vercel) --approved/, live_guidance.fetch("bin/webbuilder"))
    refute_includes live_guidance.fetch("bin/webbuilder"), "setup --install --approval-hash HASH --approved"
    refute_includes live_guidance.fetch("bin/webbuilder"), "workbench --serve --approval-hash HASH --approved"
    assert_includes live_guidance.fetch("bin/webbuilder"), 'agent "improve this website" --mode supervised --dry-run'
    assert_includes live_guidance.fetch("bin/webbuilder"), "engine-run --agent codex --mode agentic_local --max-cycles 3 --dry-run"
    assert_includes live_guidance.fetch("bin/webbuilder"), '--approval-hash HASH plus --approved'

    live_guidance.reject { |relative, _text| relative.end_with?(".schema.json") }.each do |relative, text|
      assert_includes text, "approval_hash", "#{relative} should keep hash-bound approval guidance"
    end
    assert_includes live_guidance.fetch("docs/schemas/engine-run-human-review-pack.schema.json"), "import_requires_hash_bound_approval"
  end

  def test_public_product_docs_do_not_market_engine_run_with_manus_claims
    public_docs = [
      File.join(REPO_ROOT, "README.md"),
      File.join(REPO_ROOT, "docs", "contracts", "engine-run.md"),
      File.join(REPO_ROOT, "docs", "contracts", "openmanus-agent-run.md")
    ].map { |path| File.read(path) }.join("\n")

    [
      ["Manus", "-inspired"].join,
      ["Manus", "-style"].join,
      ["Manus", "-grade"].join
    ].each do |claim|
      refute_includes public_docs, claim
    end

    assert_includes public_docs, "`engine-run` is the supervised, scoped local agentic runtime for WebBuilderAgent."
    assert_includes public_docs, "it is still not an OS-level universal enforcement broker"
    assert_includes public_docs, "Workbench controls are dry-run descriptors"
    assert_includes public_docs, "aiweb engine-run --agent codex --mode agentic_local --max-cycles 3 --dry-run"
    refute_includes public_docs, 'aiweb verify-loop --max-cycles 3`, `aiweb component-map'
    refute_includes public_docs, "./bin/aiweb --path ~/Desktop/aiweb-premium-service-site verify-loop --max-cycles 3 --approval-hash HASH --approved --json"
    refute_match(%r{\./bin/aiweb(?: --path [^\n]+)? agent-run --task latest --agent (?:codex|openmanus).*--approval-hash HASH --approved}, public_docs)
    refute_match(%r{\./bin/aiweb(?: --path [^\n]+)? agent ".*" --mode supervised --approval-hash HASH --approved}, public_docs)
    refute_match(%r{aiweb agent-run --task latest --agent openmanus --sandbox docker --approval-hash HASH --approved}, public_docs)
    refute_match(%r{\./bin/aiweb(?: --path [^\n]+)? deploy --target (?:cloudflare-pages|vercel) --approved}, public_docs)
    refute_match(%r{\./bin/aiweb(?: --path [^\n]+)? setup --install --approval-hash HASH --approved}, public_docs)
    refute_match(%r{\./bin/aiweb(?: --path [^\n]+)? workbench --serve --approval-hash HASH --approved}, public_docs)
    assert_includes public_docs, "real install is a lower-level ops action"
    assert_includes public_docs, "Real serve is a lower-level localhost ops action"
    assert_includes public_docs, "Lower-level execution command intentionally omitted from public runbooks"
  end
end
