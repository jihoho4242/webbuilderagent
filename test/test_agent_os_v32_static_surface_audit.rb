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
    assert_equal "demoted_tool_probe", tool_registry.dig("tools", "verify_loop", "agent_engine_role")

    report_source = File.read(File.join(REPO_ROOT, "lib", "aiweb", "agent_runtime", "report_builder.rb"))
    assert_includes report_source, "demoted_compatibility_facade"
    assert_includes report_source, "deterministic_local_browser_probe"

    executor_source = File.read(File.join(REPO_ROOT, "lib", "aiweb", "agent_runtime", "executor.rb"))
    assert_includes executor_source, "Aiweb::Tools::Gateway.new"
    refute_includes executor_source, 'mode == "autonomous-local"'
  end

  def test_baseline_audit_records_inventory_and_preserved_safety_substrate
    audit = JSON.parse(File.read(File.join(REPO_ROOT, ".ai-web", "reports", "agent-os-v32-baseline-audit.json")))
    assert_equal 1, audit.fetch("schema_version")
    assert audit.fetch("script_executor_inventory").any? { |entry| entry.fetch("surface").include?("AgentRuntime") }
    assert_includes audit.fetch("preserve_safety_substrate"), "PathPolicy"
  end
end
