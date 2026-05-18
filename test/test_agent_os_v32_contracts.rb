# frozen_string_literal: true

require "json"
require "yaml"
require "time"

require_relative "support/test_helper"

require "aiweb"


class AgentOsV32ContractsTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)

  def test_constitution_and_agent_os_schemas_are_present_and_parseable
    constitution = YAML.safe_load(File.read(File.join(REPO_ROOT, "configs", "constitution.yaml")), permitted_classes: [], aliases: false)
    assert_equal "3.2.0", constitution.fetch("constitution_version")
    assert_equal true, constitution.fetch("immutable")
    required_rules = %w[
      NO_SELF_PERMISSION_ESCALATION
      NO_POLICY_KERNEL_BYPASS
      NO_HITL_DOWNGRADE
      NO_EVAL_THRESHOLD_DOWNGRADE
      NO_SECRET_READ
    ]
    rule_ids = constitution.fetch("rules").map { |rule| rule.fetch("id") }
    required_rules.each { |rule| assert_includes rule_ids, rule }
    constitution.fetch("rules").each { |rule| assert_equal "critical", rule.fetch("severity") }

    %w[
      agent-os-constitution.schema.json
      agent-os-decision-packet.schema.json
      agent-os-policy-decision-event.schema.json
      agent-os-tool-gateway-event.schema.json
      agent-os-hitl-approval-v2.schema.json
      agent-os-brain-context-packet.schema.json
      agent-os-memory-health-report.schema.json
      agent-os-improvement-proposal.schema.json
      agent-os-experiment-record.schema.json
      agent-os-red-team-case.schema.json
      agent-os-release-evidence-p5.schema.json
    ].each do |name|
      schema = JSON.parse(File.read(File.join(REPO_ROOT, "docs", "schemas", name)))
      assert schema["$schema"], "#{name} should declare JSON schema dialect"
      assert schema["properties"], "#{name} should expose properties"
    end
  end

  def test_contract_documents_lock_agent_os_boundaries
    %w[
      agent-os-constitution.md
      agent-os-runtime.md
      policy-kernel.md
      tool-gateway.md
      hitl-approval-v2.md
      agent-os-p5-release.md
    ].each do |name|
      text = File.read(File.join(REPO_ROOT, "docs", "contracts", name))
      assert_match(/PolicyKernel|ToolGateway|Constitution|HITL|P5|engine-run/i, text, "#{name} should mention an Agent OS boundary")
    end
  end

  def test_domain_competency_bundle_exists_for_webbuilding
    bundle = File.join(REPO_ROOT, "domain_competency_bundle", "webbuilding")
    %w[
      task_taxonomy.yaml
      domain_ontology.yaml
      source_of_truth_registry.yaml
      expert_rubric.md
      gold_case_set.jsonl
      failure_case_set.jsonl
      skill_bundle_manifest.yaml
      domain_playbook.md
      domain_expert_signoff.md
    ].each do |name|
      assert File.file?(File.join(bundle, name)), "missing #{name}"
    end
    rubric = File.read(File.join(bundle, "expert_rubric.md"))
    assert_includes rubric, "visual_hierarchy"
    assert_includes rubric, "accessibility"
    assert_includes rubric, "broken_build"
  end
end
