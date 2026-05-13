# frozen_string_literal: true

require "json"

require_relative "support/test_helper"

require "aiweb"

class AiwebContractTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)

  def schema(name)
    JSON.parse(File.read(File.join(REPO_ROOT, "docs", "schemas", name)))
  end

  def test_openmanus_context_schema_locks_sandbox_boundary
    contract = schema("openmanus-agent-context.schema.json")

    %w[
      schema_version mode run_id task_path workspace_root allowed_source_paths
      denied_globs base_hashes timeout_sec permission_profile sandbox_mode
      sandbox_required forbidden_actions expected_output
    ].each do |field|
      assert_includes contract.fetch("required"), field
    end

    assert_equal "implementation-local-no-network", contract.dig("properties", "permission_profile", "const")
    assert_equal true, contract.dig("properties", "sandbox_required", "const")
    assert_equal %w[missing docker podman], contract.dig("properties", "sandbox_mode", "enum")
    assert_equal 600, contract.dig("properties", "timeout_sec", "maximum")
  end

  def test_openmanus_result_schema_locks_evidence_boundary
    contract = schema("openmanus-agent-result.schema.json")

    %w[schema_version status mode agent permission_profile changed_source_files blocking_issues evidence].each do |field|
      assert_includes contract.fetch("required"), field
    end

    assert_equal "openmanus", contract.dig("properties", "agent", "const")
    assert_equal "implementation-local-no-network", contract.dig("properties", "permission_profile", "const")
    %w[stdout_log stderr_log context_manifest validator_result network_log browser_request_log denied_access_log].each do |field|
      assert_includes contract.dig("properties", "evidence", "required"), field
    end
  end

  def test_engine_run_schemas_lock_agentic_runtime_contract
    run = schema("engine-run.schema.json")
    approval = schema("engine-run-approval.schema.json")
    event = schema("engine-run-event.schema.json")
    checkpoint = schema("engine-run-checkpoint.schema.json")

    %w[schema_version run_id status mode agent capability approval_hash events_path checkpoint_path workspace_path opendesign_contract blocking_issues].each do |field|
      assert_includes run.fetch("required"), field
    end
    assert_equal %w[safe_patch agentic_local external_approval], run.dig("properties", "mode", "enum")
    assert_equal %w[codex openmanus], run.dig("properties", "agent", "enum")
    assert_includes run.dig("properties", "status", "enum"), "waiting_approval"

    %w[writable_globs allowed_tools forbidden limits copy_back opendesign_contract].each do |field|
      assert_includes approval.fetch("required"), field
    end
    assert_includes approval.dig("properties", "forbidden", "items", "enum"), "host_root_write"
    assert_equal true, approval.dig("properties", "copy_back", "properties", "requires_validation", "const")
    assert_equal 10, approval.dig("properties", "limits", "properties", "max_cycles", "maximum")

    assert_includes event.dig("properties", "type", "enum"), "tool.started"
    assert_includes event.dig("properties", "type", "enum"), "backend.job.queued"
    assert_includes event.dig("properties", "type", "enum"), "backend.job.finished"
    assert_includes event.dig("properties", "type", "enum"), "sandbox.preflight.started"
    assert_includes event.dig("properties", "type", "enum"), "design.contract.loaded"
    assert_includes event.dig("properties", "type", "enum"), "design.fidelity.checked"
    assert_includes event.dig("properties", "type", "enum"), "preview.ready"
    assert_includes event.dig("properties", "type", "enum"), "screenshot.capture.finished"
    assert_includes event.dig("properties", "type", "enum"), "browser.observation.recorded"
    assert_includes event.dig("properties", "type", "enum"), "design.review.failed"
    assert_includes event.dig("properties", "type", "enum"), "design.repair.started"
    assert_includes event.dig("properties", "type", "enum"), "tool.action.blocked"
    assert_includes event.dig("properties", "type", "enum"), "checkpoint.saved"

    %w[schema_version run_id status cycle next_step workspace_path safe_changes saved_at opendesign_contract].each do |field|
      assert_includes checkpoint.fetch("required"), field
    end
  end

  def test_backend_route_contract_stays_structured_and_local_only
    routes = Aiweb::LocalBackendApp.routes

    assert_equal routes.uniq, routes
    assert_includes routes, "POST /api/project/command"
    assert_includes routes, "GET /api/engine/openmanus-readiness"
    assert_includes routes, "POST /api/codex/agent-run"
    refute routes.any? { |route| route.match?(/shell|exec/i) }, "backend routes must not expose raw shell execution"

    plan = Aiweb::LocalBackendApp.plan(host: "127.0.0.1", port: 4242)
    assert_includes plan.dig("backend", "guardrails"), "do not expose raw shell execution to frontend"
    assert_includes plan.dig("backend", "guardrails"), "bind only to localhost-class hosts for local-first use"
  end

  def test_repository_quality_gate_is_the_single_ci_entrypoint
    check_script = File.read(File.join(REPO_ROOT, "bin", "check"))
    ci_workflow = File.read(File.join(REPO_ROOT, ".github", "workflows", "ci.yml"))
    readme = File.read(File.join(REPO_ROOT, "README.md"))
    contract = File.read(File.join(REPO_ROOT, "docs", "contracts", "repository-quality-gate.md"))

    assert_includes ci_workflow, "ruby bin/check"
    assert_includes readme, "ruby bin/check"
    assert_includes contract, "The formal quality gate is `ruby bin/check`"
    assert_includes check_script, "ruby -c"
    assert_includes check_script, "repository_text_guard"
    assert_includes check_script, "require 'aiweb'"
    assert_includes check_script, "test/all.rb"
    assert_includes check_script, "git diff"
    refute File.exist?(File.join(REPO_ROOT, "Gemfile")), "quality gate must remain dependency-free until a Gemfile is explicitly introduced"
  end

  def test_repository_line_ending_policy_covers_runtime_sources
    attributes = File.read(File.join(REPO_ROOT, ".gitattributes"))

    %w[*.rb *.md *.yml *.yaml *.json bin/*].each do |pattern|
      assert_match(/^#{Regexp.escape(pattern)} text eol=lf$/, attributes, "#{pattern} should be pinned to LF")
    end
  end
end
