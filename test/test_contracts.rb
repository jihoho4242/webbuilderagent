# frozen_string_literal: true

require "json"
require "fileutils"
require "rbconfig"
require "stringio"
require "tmpdir"
require "uri"

require_relative "support/test_helper"

require "aiweb"

class AiwebContractTest < Minitest::Test
  REPO_ROOT = File.expand_path("..", __dir__)

  def schema(name)
    JSON.parse(File.read(File.join(REPO_ROOT, "docs", "schemas", name)))
  end

  def test_graph_scheduler_runtime_owns_plan_state_and_reconcile_without_project_engine
    nodes = %w[preflight finalize].map.with_index(1) do |node_id, ordinal|
      {
        "node_id" => node_id,
        "ordinal" => ordinal,
        "state" => "pending",
        "attempt" => 0,
        "side_effect_boundary" => "none",
        "executor" => {
          "handler" => "handler_for_#{node_id}",
          "executor_id" => "engine_run.#{node_id}",
          "tool_broker_required" => false,
          "idempotent" => true
        },
        "replay_policy" => {
          "requires_artifact_hash_validation" => true
        },
        "input_artifact_refs" => [],
        "output_artifact_refs" => [".ai-web/runs/engine-run-test/artifacts/#{node_id}.json"],
        "idempotency_key" => "idem-#{node_id}",
        "checkpoint_cursor" => "engine-run-test:#{node_id}:0"
      }
    end
    run_graph = {
      "run_id" => "engine-run-test",
      "cursor" => { "node_id" => "preflight", "state" => "pending", "attempt" => 0 },
      "nodes" => nodes,
      "executor_contract" => {
        "executor_type" => "sequential_durable_node_executor",
        "node_order" => nodes.map { |node| node.fetch("node_id") },
        "checkpoint_policy" => "persist_before_and_after_side_effect_boundaries",
        "resume_strategy" => "validate_cursor_artifact_hashes_and_continue_at_next_idempotent_node",
        "side_effect_gate" => "tool_broker_required_for_non_none_boundaries"
      }
    }
    runtime = Aiweb::GraphSchedulerRuntime.new(
      run_graph: run_graph,
      artifact_refs: {
        graph_execution_plan_path: ".ai-web/runs/engine-run-test/artifacts/graph-execution-plan.json",
        graph_scheduler_state_path: ".ai-web/runs/engine-run-test/artifacts/graph-scheduler-state.json",
        checkpoint_path: ".ai-web/runs/engine-run-test/checkpoint.json"
      }
    )

    plan = runtime.execution_plan
    assert_equal "aiweb.graph_scheduler.runtime.v1", plan.fetch("execution_driver")
    assert_equal "Aiweb::GraphSchedulerRuntime", plan.fetch("scheduler_runtime")
    assert_equal true, plan.dig("validation", "runtime_owns_retry_replay_cursor_checkpoint")
    assert_empty Aiweb::GraphSchedulerRuntime.plan_blockers(plan)
    state = runtime.initial_state(plan)
    assert_equal "graph_scheduler_runtime", state.fetch("state_owner")
    assert_equal true, state.fetch("retry_replay_cursor_checkpoint_owned")

    run_graph.fetch("nodes").each { |node| node["state"] = "passed"; node["attempt"] = 1 }
    run_graph["cursor"] = { "node_id" => "finalize", "state" => "passed", "attempt" => 1 }
    transitions = []
    runtime.reconcile!(
      scheduler_state: state,
      run_graph: run_graph,
      graph_execution_plan: plan,
      final_status: "passed",
      checkpoint_ref: ".ai-web/runs/engine-run-test/checkpoint.json",
      transition_sink: ->(transition, _node) { transitions << transition }
    )

    assert_equal "passed", state.fetch("status")
    assert_equal 2, transitions.length
    assert_equal "finalize", state.dig("cursor", "node_id")
    assert_equal ".ai-web/runs/engine-run-test/checkpoint.json", state.fetch("checkpoint_ref")
  end

  def test_side_effect_surface_audit_classifies_process_and_network_surfaces
    audit = Aiweb::Project.new(REPO_ROOT).send(:side_effect_surface_audit)

    assert_equal 1, audit.fetch("schema_version")
    assert_equal "aiweb.side_effect_surface_audit.v1", audit.fetch("scanner")
    assert_equal "runtime_and_project_task_static_process_and_network_surface", audit.fetch("scope")
    assert audit.fetch("roots").any? { |entry| entry["source"] == "aiweb_runtime" }
    assert_includes audit.fetch("scanned_globs"), "bin/**/*"
    assert_includes audit.fetch("scanned_globs"), "lib/**/*"
    assert_includes audit.fetch("scanned_globs"), "scripts/**/*"
    assert_includes audit.fetch("scanned_globs"), "Rakefile"
    assert_includes audit.fetch("scanned_globs"), "aiweb"
    assert_match(/bin, lib, scripts, tasks/, audit.fetch("scanner_limitations").join("\n"))
    assert_equal "classified", audit.fetch("coverage_status")
    assert_equal 0, audit.fetch("unclassified_count")
    assert_equal true, audit.dig("policy", "new_direct_side_effects_must_be_classified")
    assert_equal true, audit.dig("policy", "unclassified_blocks_claiming_universal_broker")
    assert_operator audit.fetch("entry_count"), :>, 0

    entries = audit.fetch("entries")
    refute entries.any? { |entry| entry.fetch("coverage_status") == "unclassified" }
    refute entries.any? { |entry| entry.fetch("path").end_with?("side_effect_broker.rb") }

    classifications = entries.map { |entry| entry.fetch("classification") }
    %w[
      brokered_backend_cli_bridge
      brokered_lazyweb_http
      brokered_setup_supply_chain_command
      brokered_deploy_provider_cli
      brokered_engine_run_capture_command
      brokered_openmanus_sandbox_subprocess
      local_verification_harness_exception
      local_cli_launcher_wrapper
    ].each do |classification|
      assert_includes classifications, classification
    end
  end

  def test_side_effect_surface_audit_flags_unclassified_common_ruby_process_forms
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib"))
      File.write(
        File.join(dir, "lib", "unsafe_process_forms.rb"),
        [
          "system \"echo bare-system\"",
          "spawn \"echo bare-spawn\"",
          "exec \"echo bare-exec\"",
          "return system \"echo return-system\"",
          "if system \"echo if-system\"; end",
          "unless exec \"echo unless-exec\"; end",
          "ok && spawn \"echo and-spawn\"",
          "ok || system \"echo or-system\"",
          "`echo backtick`",
          "%x[echo percent-x]"
        ].join("\n") + "\n"
      )

      audit = Aiweb::Project.new(dir).send(:side_effect_surface_audit)
      project_entries = audit.fetch("entries").select { |entry| entry["source"] == "project_root" && entry["path"] == "lib/unsafe_process_forms.rb" }

      assert_equal 10, project_entries.length
      assert_equal "unclassified", audit.fetch("coverage_status")
      assert_operator audit.fetch("unclassified_count"), :>=, 10
      assert project_entries.all? { |entry| entry["coverage_status"] == "unclassified" }
    end
  end

  def test_side_effect_surface_audit_covers_project_script_task_files
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "scripts"))
      FileUtils.mkdir_p(File.join(dir, "tasks"))
      File.write(File.join(dir, "scripts", "unsafe.rb"), "system \"echo project-script\"\n")
      File.write(File.join(dir, "tasks", "unsafe.rb"), "spawn \"echo project-task\"\n")
      File.write(File.join(dir, "Rakefile"), "exec \"echo rakefile\"\n")
      File.write(File.join(dir, "release.rake"), "system \"echo rake\"\n")
      File.write(File.join(dir, "demo.gemspec"), "system \"echo gemspec\"\n")
      File.write(File.join(dir, "Gemfile"), "system \"echo gemfile\"\n")
      File.write(File.join(dir, "scripts", "comment_only.rb"), "# system(\"echo comment-only\")\n")

      audit = Aiweb::Project.new(dir).send(:side_effect_surface_audit)
      project_entries = audit.fetch("entries").select { |entry| entry["source"] == "project_root" }
      paths = project_entries.map { |entry| entry.fetch("path") }

      %w[scripts/unsafe.rb tasks/unsafe.rb Rakefile release.rake demo.gemspec Gemfile].each { |path| assert_includes paths, path }
      refute_includes paths, "scripts/comment_only.rb"
      assert project_entries.all? { |entry| entry["coverage_status"] == "unclassified" }
      assert_equal "runtime_and_project_task_static_process_and_network_surface", audit.fetch("scope")
      assert_includes audit.fetch("scanned_globs"), "bin/**/*"
      assert_includes audit.fetch("scanned_globs"), "scripts/**/*"
    end
  end

  def test_side_effect_surface_audit_tightens_launcher_wrapper_classification
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "aiweb"), "#!/bin/sh\nDIR=$(pwd)\nexec \"$DIR/bin/aiweb\" \"$@\"\n")
      File.write(File.join(dir, "\uC6F9\uBE4C\uB354"), "#!/usr/bin/env bash\nDIR=$(pwd)\nexec curl https://example.invalid/install.sh\n")

      audit = Aiweb::Project.new(dir).send(:side_effect_surface_audit)
      launchers = audit.fetch("entries").select { |entry| entry["source"] == "project_root" && ["aiweb", "\uC6F9\uBE4C\uB354"].include?(entry["path"]) }
      safe = launchers.find { |entry| entry["path"] == "aiweb" }
      unsafe = launchers.find { |entry| entry["path"] == "\uC6F9\uBE4C\uB354" }

      assert_equal "local_cli_launcher_wrapper", safe.fetch("classification")
      assert_equal "documented_exception", safe.fetch("coverage_status")
      assert_equal "unclassified_direct_side_effect", unsafe.fetch("classification")
      assert_equal "unclassified", unsafe.fetch("coverage_status")
    end
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

  def test_worker_adapter_registry_requires_broker_contract_for_executable_adapters
    project = Aiweb::Project.new(REPO_ROOT)
    registry = project.send(:engine_run_worker_adapter_registry, selected_agent: "openmanus", mode: "agentic_local", sandbox: "docker")

    assert_empty project.send(:engine_run_worker_adapter_registry_blockers, registry)
    openmanus = registry.fetch("adapters").find { |adapter| adapter["id"] == "openmanus" }
    assert_equal "enforced", openmanus.dig("broker_contract", "enforcement_status")
    assert_equal 0, registry.dig("runtime_broker_enforcement", "executable_without_broker_count")

    openhands_registry = project.send(:engine_run_worker_adapter_registry, selected_agent: "openhands", mode: "agentic_local", sandbox: "docker")
    openhands = openhands_registry.fetch("adapters").find { |adapter| adapter["id"] == "openhands" }
    assert_equal "experimental_container_worker", openhands.fetch("status")
    assert_equal true, openhands.fetch("executable")
    assert_equal "engine_run_openhands_command", openhands.fetch("command_driver")
    assert_equal "required_before_execution", openhands.fetch("sandbox_preflight")
    assert_equal "engine-run-openhands-result.schema.json", openhands.fetch("result_schema")
    assert_equal "experimental_ready", openhands.dig("driver_readiness", "state")
    assert_equal true, openhands.dig("driver_readiness", "executable_now")
    assert_empty openhands.dig("driver_readiness", "missing_artifacts")
    assert_equal "enforced", openhands.dig("broker_contract", "enforcement_status")
    assert_empty project.send(:engine_run_worker_adapter_registry_blockers, openhands_registry)

    langgraph_registry = project.send(:engine_run_worker_adapter_registry, selected_agent: "langgraph", mode: "agentic_local", sandbox: "docker")
    langgraph = langgraph_registry.fetch("adapters").find { |adapter| adapter["id"] == "langgraph" }
    assert_equal "experimental_container_worker", langgraph.fetch("status")
    assert_equal true, langgraph.fetch("executable")
    assert_equal "engine_run_langgraph_command", langgraph.fetch("command_driver")
    assert_equal "required_before_execution", langgraph.fetch("sandbox_preflight")
    assert_equal "engine-run-langgraph-result.schema.json", langgraph.fetch("result_schema")
    assert_equal "experimental_ready", langgraph.dig("driver_readiness", "state")
    assert_equal true, langgraph.dig("driver_readiness", "executable_now")
    assert_empty langgraph.dig("driver_readiness", "missing_artifacts")
    assert_equal "enforced", langgraph.dig("broker_contract", "enforcement_status")
    assert_empty project.send(:engine_run_worker_adapter_registry_blockers, langgraph_registry)

    openai_registry = project.send(:engine_run_worker_adapter_registry, selected_agent: "openai_agents_sdk", mode: "agentic_local", sandbox: "docker")
    openai_agents = openai_registry.fetch("adapters").find { |adapter| adapter["id"] == "openai_agents_sdk" }
    assert_equal "experimental_container_worker", openai_agents.fetch("status")
    assert_equal true, openai_agents.fetch("executable")
    assert_equal "engine_run_openai_agents_sdk_command", openai_agents.fetch("command_driver")
    assert_equal "required_before_execution", openai_agents.fetch("sandbox_preflight")
    assert_equal "engine-run-openai-agents-sdk-result.schema.json", openai_agents.fetch("result_schema")
    assert_equal "experimental_ready", openai_agents.dig("driver_readiness", "state")
    assert_equal true, openai_agents.dig("driver_readiness", "executable_now")
    assert_empty openai_agents.dig("driver_readiness", "missing_artifacts")
    assert_equal "enforced", openai_agents.dig("broker_contract", "enforcement_status")
    assert_empty project.send(:engine_run_worker_adapter_registry_blockers, openai_registry)

    output_issues = project.send(
      :engine_run_worker_adapter_output_violations,
      { "schema_version" => 1, "status" => "patched" },
      REPO_ROOT,
      expected_adapter: "openhands"
    )
    assert_match(/openhands result missing required field/i, output_issues.join("\n"))
    assert_match(/adapter must be openhands/i, output_issues.join("\n"))
    langgraph_output_issues = project.send(
      :engine_run_worker_adapter_output_violations,
      { "schema_version" => 1, "status" => "patched" },
      REPO_ROOT,
      expected_adapter: "langgraph"
    )
    assert_match(/langgraph result missing required field/i, langgraph_output_issues.join("\n"))
    assert_match(/adapter must be langgraph/i, langgraph_output_issues.join("\n"))
    openai_output_issues = project.send(
      :engine_run_worker_adapter_output_violations,
      { "schema_version" => 1, "status" => "patched" },
      REPO_ROOT,
      expected_adapter: "openai_agents_sdk"
    )
    assert_match(/openai_agents_sdk result missing required field/i, openai_output_issues.join("\n"))
    assert_match(/adapter must be openai_agents_sdk/i, openai_output_issues.join("\n"))

    broken = Marshal.load(Marshal.dump(registry))
    broken.fetch("adapters").find { |adapter| adapter["id"] == "openmanus" }.delete("broker_contract")
    issues = project.send(:engine_run_worker_adapter_registry_blockers, broken)

    assert_match(/missing required broker_contract/i, issues.join("\n"))
  end

  def test_openmanus_result_schema_locks_evidence_boundary
    contract = schema("openmanus-agent-result.schema.json")

    %w[schema_version status mode agent permission_profile changed_source_files blocking_issues evidence].each do |field|
      assert_includes contract.fetch("required"), field
    end

    assert_equal "openmanus", contract.dig("properties", "agent", "const")
    assert_equal "implementation-local-no-network", contract.dig("properties", "permission_profile", "const")
    %w[stdout_log stderr_log context_manifest validator_result network_log browser_request_log tool_broker_log denied_access_log].each do |field|
      assert_includes contract.dig("properties", "evidence", "required"), field
    end
  end

  def test_engine_run_schemas_lock_agentic_runtime_contract
    run = schema("engine-run.schema.json")
    approval = schema("engine-run-approval.schema.json")
    event = schema("engine-run-event.schema.json")
    checkpoint = schema("engine-run-checkpoint.schema.json")
    browser = schema("browser-evidence.schema.json")
    sandbox_preflight = schema("sandbox-preflight.schema.json")
    eval_benchmark = schema("engine-run-eval-benchmark.schema.json")
    human_baselines = schema("engine-run-human-baselines.schema.json")
    human_review_pack = schema("engine-run-human-review-pack.schema.json")
    supply_chain_gate = schema("engine-run-supply-chain-gate.schema.json")
    setup_supply_chain_gate = schema("setup-supply-chain-gate.schema.json")
    worker_adapter_registry = schema("engine-run-worker-adapter-registry.schema.json")
    authz_enforcement = schema("engine-run-authz-enforcement.schema.json")
    run_memory = schema("engine-run-memory.schema.json")
    engine_scheduler_service = schema("engine-scheduler-service.schema.json")
    engine_scheduler_daemon = schema("engine-scheduler-daemon.schema.json")
    engine_scheduler_supervisor = schema("engine-scheduler-supervisor.schema.json")
    engine_scheduler_monitor = schema("engine-scheduler-monitor.schema.json")
    implementation_mcp_broker = schema("implementation-mcp-broker.schema.json")
    local_backend_authz_audit = schema("local-backend-authz-audit.schema.json")
    openhands_result = schema("engine-run-openhands-result.schema.json")
    langgraph_result = schema("engine-run-langgraph-result.schema.json")
    openai_agents_result = schema("engine-run-openai-agents-sdk-result.schema.json")

    %w[schema_version run_id status mode agent capability approval_hash events_path checkpoint_path workspace_path opendesign_contract blocking_issues].each do |field|
      assert_includes run.fetch("required"), field
    end
    assert_equal %w[safe_patch agentic_local external_approval], run.dig("properties", "mode", "enum")
    assert_equal %w[codex openmanus openhands langgraph openai_agents_sdk], run.dig("properties", "agent", "enum")
    assert_equal %w[codex openmanus openhands langgraph openai_agents_sdk], approval.dig("properties", "agent", "enum")
    assert_includes run.dig("properties", "status", "enum"), "waiting_approval"
    assert_includes run.dig("properties", "status", "enum"), "quarantined"

    %w[writable_globs allowed_tools forbidden limits copy_back opendesign_contract].each do |field|
      assert_includes approval.fetch("required"), field
    end
    assert_includes approval.dig("properties", "forbidden", "items", "enum"), "host_root_write"
    assert_equal true, approval.dig("properties", "copy_back", "properties", "requires_validation", "const")
    assert_equal 10, approval.dig("properties", "limits", "properties", "max_cycles", "maximum")

    assert_includes event.dig("properties", "type", "enum"), "tool.requested"
    assert_includes event.dig("properties", "type", "enum"), "policy.decision"
    assert_includes event.dig("properties", "type", "enum"), "tool.started"
    assert_includes event.dig("properties", "type", "enum"), "tool.finished"
    assert_includes event.dig("properties", "type", "enum"), "tool.blocked"
    assert_includes event.dig("properties", "type", "enum"), "backend.job.queued"
    assert_includes event.dig("properties", "type", "enum"), "backend.job.finished"
    assert_includes event.dig("properties", "type", "enum"), "sandbox.preflight.started"
    assert_includes event.dig("properties", "type", "enum"), "design.contract.loaded"
    assert_includes event.dig("properties", "type", "enum"), "project.indexed"
    assert_includes event.dig("properties", "type", "enum"), "memory.index.recorded"
    assert_includes event.dig("properties", "type", "enum"), "design.fidelity.checked"
    assert_includes event.dig("properties", "type", "enum"), "preview.ready"
    assert_includes event.dig("properties", "type", "enum"), "screenshot.capture.finished"
    assert_includes event.dig("properties", "type", "enum"), "browser.observation.recorded"
    assert_includes event.dig("properties", "type", "enum"), "browser.action_recovery.recorded"
    assert_includes event.dig("properties", "type", "enum"), "browser.action_loop.recorded"
    assert_includes event.dig("properties", "type", "enum"), "design.review.failed"
    assert_includes event.dig("properties", "type", "enum"), "authz.enforcement.recorded"
    assert_includes event.dig("properties", "type", "enum"), "worker.adapter.registry.recorded"
    assert_includes event.dig("properties", "type", "enum"), "graph.scheduler.planned"
    assert_includes event.dig("properties", "type", "enum"), "graph.scheduler.started"
    assert_includes event.dig("properties", "type", "enum"), "graph.node.finished"
    assert_includes event.dig("properties", "type", "enum"), "graph.scheduler.finished"
    assert_includes event.dig("properties", "type", "enum"), "design.fixture.recorded"
    assert_includes event.dig("properties", "type", "enum"), "eval.benchmark.recorded"
    assert_includes event.dig("properties", "type", "enum"), "supply_chain.gate.recorded"
    assert_includes event.dig("properties", "type", "enum"), "design.repair.started"
    assert_includes event.dig("properties", "type", "enum"), "tool.action.blocked"
    assert_includes event.dig("properties", "type", "enum"), "checkpoint.saved"
    assert_includes event.dig("properties", "type", "enum"), "run.quarantined"
    %w[run_id actor phase trace_span_id redaction_status previous_event_hash event_hash].each do |field|
      assert_includes event.fetch("required"), field
    end
    assert_equal "aiweb.engine_run", event.dig("properties", "actor", "enum", 0)
    assert_equal "redacted_at_source", event.dig("properties", "redaction_status", "enum", 0)

    %w[schema_version run_id status cycle next_step workspace_path safe_changes saved_at opendesign_contract].each do |field|
      assert_includes checkpoint.fetch("required"), field
    end
    assert_includes checkpoint.fetch("required"), "artifact_hashes"
    assert_includes checkpoint.dig("properties", "status", "enum"), "quarantined"
    assert run.dig("properties", "run_graph"), "engine-run schema must expose durable graph evidence"
    assert_equal "sequential_durable_node_executor", run.dig("properties", "run_graph", "anyOf", 0, "properties", "executor_contract", "properties", "executor_type", "const")
    assert_includes run.dig("properties", "run_graph", "anyOf", 0, "properties", "nodes", "items", "required"), "executor"
    assert_includes run.dig("properties", "run_graph", "anyOf", 0, "properties", "nodes", "items", "required"), "replay_policy"
    assert run.dig("properties", "tool_broker"), "engine-run schema must expose tool broker evidence"
    tool_broker_schema = run.dig("properties", "tool_broker", "anyOf", 0)
    assert_includes tool_broker_schema.fetch("required"), "side_effect_surface_audit"
    assert_equal "aiweb.side_effect_surface_audit.v1", tool_broker_schema.dig("properties", "side_effect_surface_audit", "properties", "scanner", "const")
    assert_equal "runtime_and_project_task_static_process_and_network_surface", tool_broker_schema.dig("properties", "side_effect_surface_audit", "properties", "scope", "const")
    assert_includes tool_broker_schema.dig("properties", "side_effect_surface_audit", "required"), "entry_count"
    assert_includes tool_broker_schema.dig("properties", "side_effect_surface_audit", "required"), "unclassified_count"
    assert_includes tool_broker_schema.dig("properties", "side_effect_surface_audit", "required"), "roots"
    assert_includes tool_broker_schema.dig("properties", "side_effect_surface_audit", "required"), "scanned_globs"
    assert_includes tool_broker_schema.dig("properties", "side_effect_surface_audit", "required"), "scanner_limitations"
    assert_includes tool_broker_schema.dig("properties", "side_effect_surface_audit", "properties", "entries", "items", "required"), "source"
    required_globs = tool_broker_schema.dig("properties", "side_effect_surface_audit", "properties", "scanned_globs", "allOf").map { |entry| entry.dig("contains", "const") }
    ["bin/**/*", "lib/**/*", "scripts/**/*", "tasks/**/*", "Rakefile", "*.rake", "*.gemspec", "Gemfile", "aiweb", "\uC6F9\uBE4C\uB354"].each { |glob| assert_includes required_globs, glob }
    assert_equal true, tool_broker_schema.dig("properties", "side_effect_surface_audit", "properties", "policy", "properties", "unclassified_blocks_claiming_universal_broker", "const")
    assert_includes tool_broker_schema.fetch("required"), "runtime_broker_enforcement"
    assert_equal 0, tool_broker_schema.dig("properties", "runtime_broker_enforcement", "properties", "executable_without_broker_count", "const")
    assert_equal false, tool_broker_schema.dig("properties", "runtime_broker_enforcement", "properties", "universal_broker_claim", "const")
    assert_includes tool_broker_schema.dig("properties", "runtime_broker_enforcement", "required"), "known_mcp_broker_drivers"
    known_driver_requirements = tool_broker_schema.dig("properties", "runtime_broker_enforcement", "properties", "known_mcp_broker_drivers", "allOf").map do |entry|
      properties = entry.dig("contains", "properties")
      [
        properties.dig("server", "const"),
        properties.dig("broker_id", "const"),
        properties.dig("scope", "const"),
        properties.dig("status", "const")
      ]
    end
    assert known_driver_requirements.any? { |server, broker_id, _scope, _status| server == "lazyweb" && broker_id == "aiweb.lazyweb.side_effect_broker" }
    assert known_driver_requirements.any? { |server, broker_id, _scope, _status| server == "lazyweb" && broker_id == "aiweb.implementation_mcp_broker" }
    assert_includes known_driver_requirements, ["project_files", "aiweb.implementation_mcp_broker", "implementation_worker.mcp.project_files", "implemented_for_approved_project_file_metadata_list_excerpt_search"]
    runtime_surface_requirements = tool_broker_schema.dig("properties", "runtime_broker_enforcement", "properties", "deny_by_default_surfaces", "allOf").map { |entry| entry.dig("contains", "const") }
    %w[mcp_connectors future_adapters elevated_runners].each { |surface| assert_includes runtime_surface_requirements, surface }
    assert run.dig("properties", "authz_contract"), "engine-run schema must expose SaaS auth/tenancy contract"
    assert run.dig("properties", "authz_enforcement"), "engine-run schema must expose authz enforcement evidence"
    assert run.dig("properties", "authz_enforcement_path"), "engine-run schema must expose authz enforcement artifact"
    assert_equal "engine-run-authz-enforcement.schema.json", run.dig("properties", "authz_enforcement", "anyOf", 0, "$ref")
    assert run.dig("properties", "retention_redaction_policy"), "engine-run schema must expose retention/redaction contract"
    assert run.dig("properties", "project_index"), "engine-run schema must expose project index evidence"
    assert run.dig("properties", "project_index_path"), "engine-run schema must expose project index artifact"
    assert run.dig("properties", "run_memory"), "engine-run schema must expose run memory retrieval evidence"
    assert run.dig("properties", "run_memory_path"), "engine-run schema must expose run memory artifact"
    assert_equal "engine-run-memory.schema.json", run.dig("properties", "run_memory", "anyOf", 0, "$ref")
    assert run.dig("properties", "worker_adapter_registry"), "engine-run schema must expose worker adapter registry evidence"
    assert run.dig("properties", "worker_adapter_registry_path"), "engine-run schema must expose worker adapter registry artifact"
    assert_equal "engine-run-worker-adapter-registry.schema.json", run.dig("properties", "worker_adapter_registry", "anyOf", 0, "$ref")
    assert run.dig("properties", "graph_execution_plan"), "engine-run schema must expose graph scheduler execution plan"
    assert run.dig("properties", "graph_execution_plan_path"), "engine-run schema must expose graph scheduler artifact path"
    assert_equal "sequential_durable_node_scheduler", run.dig("properties", "graph_execution_plan", "anyOf", 0, "properties", "scheduler_type", "const")
    assert_equal "aiweb.graph_scheduler.runtime.v1", run.dig("properties", "graph_execution_plan", "anyOf", 0, "properties", "execution_driver", "const")
    assert_equal "Aiweb::GraphSchedulerRuntime", run.dig("properties", "graph_execution_plan", "anyOf", 0, "properties", "scheduler_runtime", "const")
    assert_equal "graph_scheduler_runtime", run.dig("properties", "graph_execution_plan", "anyOf", 0, "properties", "state_owner", "const")
    assert_equal "run_graph.executor_contract", run.dig("properties", "graph_execution_plan", "anyOf", 0, "properties", "executor_source", "const")
    assert_equal true, run.dig("properties", "graph_execution_plan", "anyOf", 0, "properties", "validation", "properties", "all_side_effect_nodes_gated", "const")
    assert_equal true, run.dig("properties", "graph_execution_plan", "anyOf", 0, "properties", "validation", "properties", "runtime_owns_retry_replay_cursor_checkpoint", "const")
    assert run.dig("properties", "graph_scheduler_state"), "engine-run schema must expose durable graph scheduler state"
    assert run.dig("properties", "graph_scheduler_state_path"), "engine-run schema must expose durable graph scheduler state artifact"
    assert_equal "sequential_durable_node_scheduler_state", run.dig("properties", "graph_scheduler_state", "anyOf", 0, "properties", "scheduler_type", "const")
    assert_equal "aiweb.graph_scheduler.runtime.v1", run.dig("properties", "graph_scheduler_state", "anyOf", 0, "properties", "execution_driver", "const")
    assert_equal "Aiweb::GraphSchedulerRuntime", run.dig("properties", "graph_scheduler_state", "anyOf", 0, "properties", "scheduler_runtime", "const")
    assert_equal "graph_scheduler_runtime", run.dig("properties", "graph_scheduler_state", "anyOf", 0, "properties", "state_owner", "const")
    assert_equal true, run.dig("properties", "graph_scheduler_state", "anyOf", 0, "properties", "retry_replay_cursor_checkpoint_owned", "const")
    assert_equal "aiweb.engine_scheduler.service.v1", engine_scheduler_service.dig("properties", "service_driver", "const")
    assert_equal "project_local_durable_graph_scheduler_service", engine_scheduler_service.dig("properties", "service_type", "const")
    assert_equal "engine_run_resume_bridge", engine_scheduler_service.dig("properties", "node_body_executor", "const")
    assert_equal %w[deferred_command approved_inline_resume_bridge], engine_scheduler_service.dig("properties", "node_body_execution_mode", "enum")
    assert_equal ".ai-web/scheduler/ledger.jsonl", engine_scheduler_service.dig("properties", "ledger_path", "const")
    assert_includes engine_scheduler_service.dig("properties", "decision", "enum"), "resume_ready"
    assert_includes engine_scheduler_service.dig("properties", "supported_continuation_start_nodes", "items", "enum"), "worker_act"
    assert_equal "object", engine_scheduler_service.dig("properties", "execution_result_summary", "type")
    assert_includes engine_scheduler_service.dig("properties", "execution_result_summary", "required"), "resume_from"
    assert_equal "aiweb.engine_scheduler.daemon.v1", engine_scheduler_daemon.dig("properties", "daemon_driver", "const")
    assert_equal "project_local_durable_graph_scheduler_daemon", engine_scheduler_daemon.dig("properties", "service_type", "const")
    assert_equal "foreground_long_running_loop", engine_scheduler_daemon.dig("properties", "mode", "enum", 1)
    assert_equal ".ai-web/scheduler/daemon.json", engine_scheduler_daemon.dig("properties", "daemon_artifact_path", "const")
    assert_equal ".ai-web/scheduler/daemon-heartbeat.json", engine_scheduler_daemon.dig("properties", "heartbeat_path", "const")
    assert_equal ".ai-web/scheduler/worker-pool.json", engine_scheduler_daemon.dig("properties", "worker_pool_path", "const")
    assert_equal ".ai-web/scheduler/leases.json", engine_scheduler_daemon.dig("properties", "leases_path", "const")
    assert_equal ".ai-web/scheduler/queue-ledger.jsonl", engine_scheduler_daemon.dig("properties", "queue_ledger_path", "const")
    assert_includes engine_scheduler_daemon.dig("properties", "stop_reason", "enum"), "resume_ready_executed"
    assert_equal %w[completed completed_with_nonpassing_status], engine_scheduler_daemon.dig("properties", "execution_status", "enum")
    assert_equal "aiweb.engine_scheduler.worker_pool.v1", engine_scheduler_daemon.dig("properties", "worker_pool", "properties", "pool_driver", "const")
    assert_equal false, engine_scheduler_daemon.dig("properties", "worker_pool", "properties", "distributed", "const")
    assert_equal "engine_run_resume_bridge", engine_scheduler_daemon.dig("properties", "worker_pool", "properties", "executor", "const")
    assert_includes engine_scheduler_daemon.dig("properties", "worker_pool", "required"), "active_leases"
    assert_includes engine_scheduler_daemon.dig("properties", "worker_pool", "required"), "concurrency_enforced"
    assert_includes engine_scheduler_daemon.dig("properties", "worker_pool", "required"), "stale_lease_recovery_policy"
    assert_equal "expired_or_ttl_elapsed_active_lease_may_be_reclaimed", engine_scheduler_daemon.dig("properties", "worker_pool", "properties", "stale_lease_recovery_policy", "const")
    assert_equal 300, engine_scheduler_daemon.dig("properties", "worker_pool", "properties", "lease_timeout_seconds", "const")
    assert_equal true, engine_scheduler_daemon.dig("properties", "worker_pool", "properties", "active_leases", "items", "properties", "duplicate_claim_prevented", "const")
    assert_equal "aiweb.engine_scheduler.worker_pool.v1", engine_scheduler_daemon.dig("properties", "leases", "properties", "lease_driver", "const")
    assert_includes engine_scheduler_daemon.dig("properties", "leases", "required"), "stale_leases_recovered"
    assert_equal "expired_or_ttl_elapsed_active_lease_may_be_reclaimed", engine_scheduler_daemon.dig("properties", "leases", "properties", "stale_lease_recovery_policy", "const")
    assert_equal 300, engine_scheduler_daemon.dig("properties", "leases", "properties", "stale_lease_timeout_seconds", "const")
    assert_includes engine_scheduler_daemon.dig("properties", "queue_events", "items", "properties", "event_type", "enum"), "scheduler.lease.claimed"
    assert_includes engine_scheduler_daemon.dig("properties", "queue_events", "items", "properties", "event_type", "enum"), "scheduler.lease.stale_recovered"
    assert_includes engine_scheduler_daemon.dig("properties", "queue_events", "items", "properties", "event_type", "enum"), "scheduler.execution.finished"
    assert_equal "aiweb.implementation_mcp_broker", implementation_mcp_broker.dig("properties", "broker_driver", "const")
    assert_includes implementation_mcp_broker.dig("properties", "scope", "enum"), "implementation_worker.mcp.lazyweb"
    assert_includes implementation_mcp_broker.dig("properties", "scope", "enum"), "implementation_worker.mcp.project_files"
    assert_equal "string", implementation_mcp_broker.dig("properties", "server", "type")
    assert_equal "string", implementation_mcp_broker.dig("properties", "tool", "type")
    assert_equal true, implementation_mcp_broker.dig("properties", "per_call_audit", "const")
    assert_equal "aiweb.implementation_mcp_broker", implementation_mcp_broker.dig("properties", "side_effect_broker", "properties", "broker", "const")
    assert_includes implementation_mcp_broker.dig("properties", "side_effect_broker", "properties", "policy", "properties", "allowed_tools", "items", "enum"), "lazyweb_health"
    assert_includes implementation_mcp_broker.dig("properties", "side_effect_broker", "properties", "policy", "properties", "allowed_tools", "items", "enum"), "project_file_metadata"
    assert_includes implementation_mcp_broker.dig("properties", "side_effect_broker", "properties", "policy", "properties", "allowed_tools", "items", "enum"), "project_file_list"
    assert_includes implementation_mcp_broker.dig("properties", "side_effect_broker", "properties", "policy", "properties", "allowed_tools", "items", "enum"), "project_file_excerpt"
    assert_includes implementation_mcp_broker.dig("properties", "side_effect_broker", "properties", "policy", "properties", "allowed_tools", "items", "enum"), "project_file_search"
    assert_includes implementation_mcp_broker.dig("properties", "scope", "enum"), "implementation_worker.mcp.denied"
    assert_includes implementation_mcp_broker.fetch("required"), "connector_policy"
    assert_equal "aiweb.implementation_mcp_broker.connector_policy.v1", implementation_mcp_broker.dig("$defs", "connector_policy", "properties", "policy", "const")
    assert_equal true, implementation_mcp_broker.dig("$defs", "connector_policy", "properties", "deny_by_default_for_unknown_connectors", "const")
    assert_includes implementation_mcp_broker.dig("$defs", "connector_policy", "properties", "driver_status", "enum"), "missing_broker_driver_fail_closed"
    assert_includes implementation_mcp_broker.dig("$defs", "connector_policy", "properties", "driver_status", "enum"), "implemented_for_approved_project_file_metadata"
    assert_includes implementation_mcp_broker.dig("$defs", "connector_policy", "properties", "driver_status", "enum"), "implemented_for_approved_project_file_list"
    assert_includes implementation_mcp_broker.dig("$defs", "connector_policy", "properties", "driver_status", "enum"), "implemented_for_approved_project_file_excerpt"
    assert_includes implementation_mcp_broker.dig("$defs", "connector_policy", "properties", "driver_status", "enum"), "implemented_for_approved_project_file_search"
    assert_includes implementation_mcp_broker.dig("$defs", "connector_policy", "properties", "missing_driver_required_fields", "items", "enum"), "credential_source"
    assert run.dig("properties", "worker_adapter_contract_path"), "engine-run schema must expose worker adapter contract artifact"
    assert run.dig("properties", "supply_chain_gate"), "engine-run schema must expose supply-chain gate evidence"
    assert run.dig("properties", "supply_chain_gate_path"), "engine-run schema must expose supply-chain gate artifact"
    assert_equal "engine-run-supply-chain-gate.schema.json", run.dig("properties", "supply_chain_gate", "anyOf", 0, "$ref")
    assert_includes supply_chain_gate.fetch("required"), "lifecycle_sandbox_gate"
    assert_includes setup_supply_chain_gate.fetch("required"), "lifecycle_sandbox_gate"
    assert_equal false, supply_chain_gate.dig("properties", "lifecycle_sandbox_gate", "properties", "default_install_lifecycle_execution", "const")
    assert_equal false, setup_supply_chain_gate.dig("properties", "lifecycle_sandbox_gate", "properties", "default_install_lifecycle_execution", "const")
    assert_equal false, setup_supply_chain_gate.dig("properties", "lifecycle_sandbox_gate", "properties", "egress_firewall", "properties", "external_network_allowed", "const")
    assert_equal "not_installed", setup_supply_chain_gate.dig("properties", "lifecycle_sandbox_gate", "properties", "egress_firewall", "properties", "default_install_os_egress_firewall_status", "const")
    assert_equal "not_run_for_host_package_manager", setup_supply_chain_gate.dig("properties", "lifecycle_sandbox_gate", "properties", "egress_firewall", "properties", "default_install_egress_probe_status", "const")
    assert_includes setup_supply_chain_gate.dig("properties", "lifecycle_sandbox_gate", "required"), "default_install_sandbox_attestation"
    assert_includes setup_supply_chain_gate.dig("properties", "lifecycle_sandbox_gate", "required"), "lifecycle_enabled_requested"
    assert_includes setup_supply_chain_gate.dig("properties", "lifecycle_sandbox_gate", "required"), "lifecycle_enabled_execution_available"
    assert_equal false, setup_supply_chain_gate.dig("properties", "lifecycle_sandbox_gate", "properties", "lifecycle_enabled_execution_available", "const")
    assert_equal "fail_closed_until_lifecycle_sandbox_driver_and_egress_firewall_exist", setup_supply_chain_gate.dig("properties", "lifecycle_sandbox_gate", "properties", "requested_command_policy", "const")
    assert_equal true, setup_supply_chain_gate.dig("properties", "lifecycle_sandbox_gate", "properties", "default_install_sandbox_attestation", "properties", "child_env_policy", "properties", "unsetenv_others", "const")
    assert_equal false, setup_supply_chain_gate.dig("properties", "lifecycle_sandbox_gate", "properties", "default_install_sandbox_attestation", "properties", "child_env_policy", "properties", "secret_values_recorded", "const")
    assert_includes setup_supply_chain_gate.dig("properties", "lifecycle_sandbox_gate", "properties", "status", "enum"), "blocked_until_sandbox_and_egress_firewall"
    assert run.dig("properties", "design_fixture"), "engine-run schema must expose design fixture evidence"
    assert run.dig("properties", "design_fixture_path"), "engine-run schema must expose design fixture artifact"
    assert run.dig("properties", "eval_benchmark"), "engine-run schema must expose eval benchmark evidence"
    assert run.dig("properties", "eval_benchmark_path"), "engine-run schema must expose eval benchmark artifact"
    assert_equal "engine-run-eval-benchmark.schema.json", run.dig("properties", "eval_benchmark", "anyOf", 0, "$ref")
    assert run.dig("properties", "sandbox_preflight_path"), "engine-run schema must expose sandbox preflight artifact"
    assert_equal "sandbox-preflight.schema.json", run.dig("properties", "sandbox_preflight", "anyOf", 0, "$ref")
    assert run.dig("properties", "copy_back_policy", "properties", "approval_requests"), "engine-run schema must expose structured approval UX payloads"
    assert_equal "browser-evidence.schema.json", run.dig("properties", "screenshot_evidence", "anyOf", 0, "$ref")
    assert checkpoint.dig("properties", "run_graph_cursor"), "checkpoint schema must expose resume cursor"
    assert checkpoint.dig("properties", "run_graph"), "checkpoint schema must preserve graph contract"
    assert_equal "sequential_durable_node_executor", checkpoint.dig("properties", "run_graph", "properties", "executor_contract", "properties", "executor_type", "const")
    assert_includes checkpoint.dig("properties", "run_graph", "properties", "nodes", "items", "required"), "executor"
    assert_includes checkpoint.dig("properties", "run_graph", "properties", "nodes", "items", "required"), "replay_policy"
    assert checkpoint.dig("properties", "artifact_hashes"), "checkpoint schema must preserve artifact hashes for resume validation"
    assert_equal false, checkpoint.dig("properties", "artifact_hashes", "additionalProperties"), "checkpoint artifact hashes must reject unknown keys"
    assert_includes checkpoint.dig("properties", "artifact_hashes", "propertyNames", "enum"), "graph_execution_plan"
    assert_includes checkpoint.dig("properties", "artifact_hashes", "propertyNames", "enum"), "graph_scheduler_state"
    assert_includes checkpoint.dig("properties", "artifact_hashes", "propertyNames", "enum"), "browser_evidence"
    assert_equal "#/$defs/artifact_hash", checkpoint.dig("properties", "artifact_hashes", "properties", "staged_manifest", "$ref")
    assert_equal %w[captured failed skipped], browser.dig("properties", "status", "enum")
    assert_includes browser.dig("properties", "screenshots", "items", "properties", "capture_mode", "enum"), "playwright_browser"
    refute_includes browser.dig("properties", "screenshots", "items", "properties", "capture_mode", "enum"), "sandbox_placeholder"
    %w[sha256 bytes mime_type png_signature_valid image_width image_height].each do |field|
      assert_includes browser.dig("properties", "screenshots", "items", "required"), field
    end
    assert_equal "image/png", browser.dig("properties", "screenshots", "items", "properties", "mime_type", "const")
    assert_equal true, browser.dig("properties", "screenshots", "items", "properties", "png_signature_valid", "const")
    assert_includes browser.fetch("required"), "runtime_attestation"
    assert_equal %w[codex openmanus openhands langgraph openai_agents_sdk], browser.dig("properties", "runtime_attestation", "properties", "agent", "enum")
    assert_equal true, browser.dig("properties", "runtime_attestation", "properties", "same_staged_workspace", "const")
    assert_equal false, browser.dig("properties", "runtime_attestation", "properties", "same_container_instance", "const")
    assert_equal "_aiweb/tool-broker-bin", browser.dig("properties", "runtime_attestation", "properties", "tool_broker_bin_path", "const")
    %w[dom_snapshot a11y_report computed_style_summary interaction_states keyboard_focus_traversal action_recovery action_loop].each do |field|
      assert_includes browser.fetch("required"), field
      assert browser.dig("properties", field), "browser evidence schema must require #{field} evidence"
    end
    assert_equal true, browser.dig("properties", "action_recovery", "properties", "required", "const")
    assert_equal %w[captured failed skipped], browser.dig("properties", "action_recovery", "properties", "status", "enum")
    assert_includes browser.dig("properties", "action_recovery", "required"), "action_sequences"
    assert_includes browser.dig("properties", "action_recovery", "required"), "recovery_attempts"
    assert_includes browser.dig("properties", "action_recovery", "required"), "external_requests_blocked"
    action_recovery_viewport_required = browser.dig("properties", "action_recovery", "properties", "viewports", "items", "required")
    assert_includes action_recovery_viewport_required, "unsafe_navigation_policy_enforced"
    assert_includes action_recovery_viewport_required, "unsafe_navigation_blocked"
    assert_includes action_recovery_viewport_required, "external_request_block_count"
    assert_equal true, browser.dig("properties", "action_loop", "properties", "required", "const")
    assert_equal "bounded_safe_local_observation_loop", browser.dig("properties", "action_loop", "properties", "loop_type", "const")
    assert_equal "deterministic_observation_not_open_ended", browser.dig("properties", "action_loop", "properties", "autonomy_level", "const")
    assert_equal "localhost-only", browser.dig("properties", "action_loop", "properties", "policy", "properties", "network", "const")
    assert_equal true, browser.dig("properties", "action_loop", "properties", "policy", "properties", "reversible_only", "const")
    assert_equal false, browser.dig("properties", "action_loop", "properties", "policy", "properties", "form_submission_allowed", "const")
    assert_includes browser.dig("properties", "action_loop", "required"), "scenario_plan"
    assert_includes browser.dig("properties", "action_loop", "required"), "scenario_results"
    assert_includes browser.dig("properties", "action_loop", "required"), "multi_step_evidence"
    assert_equal "localhost-only", browser.dig("properties", "action_loop", "properties", "multi_step_evidence", "properties", "policy", "properties", "network", "const")
    assert_equal true, browser.dig("properties", "action_loop", "properties", "multi_step_evidence", "properties", "policy", "properties", "reversible_only", "const")
    assert_equal false, browser.dig("properties", "action_loop", "properties", "multi_step_evidence", "properties", "policy", "properties", "form_submission_allowed", "const")
    captured_condition = browser.fetch("allOf").find { |entry| entry.dig("if", "properties", "status", "const") == "captured" }
    assert_equal 3, captured_condition.dig("then", "properties", "screenshots", "minItems")
    assert_equal 3, captured_condition.dig("then", "properties", "viewport_evidence", "minItems")
    assert_equal 9, captured_condition.dig("then", "properties", "interaction_states", "minItems")
    assert_equal "captured", captured_condition.dig("then", "properties", "interaction_states", "items", "properties", "status", "const")
    assert_equal 3, captured_condition.dig("then", "properties", "action_recovery", "properties", "viewports", "minItems")
    assert_equal 1, captured_condition.dig("then", "properties", "action_recovery", "properties", "action_sequences", "minItems")
    assert_equal 1, captured_condition.dig("then", "properties", "action_recovery", "properties", "recovery_attempts", "minItems")
    assert_equal 0, captured_condition.dig("then", "properties", "action_recovery", "properties", "external_requests_blocked", "maxItems")
    assert_equal 3, captured_condition.dig("then", "properties", "action_loop", "properties", "viewports", "minItems")
    assert_equal 1, captured_condition.dig("then", "properties", "action_loop", "properties", "planned_steps", "minItems")
    assert_equal 1, captured_condition.dig("then", "properties", "action_loop", "properties", "executed_steps", "minItems")
    assert_equal 1, captured_condition.dig("then", "properties", "action_loop", "properties", "recovery_steps", "minItems")
    assert_equal 3, captured_condition.dig("then", "properties", "action_loop", "properties", "scenario_plan", "minItems")
    assert_equal 3, captured_condition.dig("then", "properties", "action_loop", "properties", "scenario_results", "minItems")
    assert_equal true, captured_condition.dig("then", "properties", "action_loop", "properties", "multi_step_evidence", "properties", "multi_step_sequences_observed", "const")
    assert_equal true, captured_condition.dig("then", "properties", "action_loop", "properties", "multi_step_evidence", "properties", "all_scenarios_recovered", "const")
    assert_includes eval_benchmark.dig("properties", "metrics", "required"), "action_recovery_pass"
    assert_includes eval_benchmark.dig("properties", "metrics", "required"), "browser_action_loop_pass"
    %w[inside_container_probe container_id runtime_container_inspect runtime_matrix effective_user security_attestation sandbox_user egress_denial_probe negative_checks preflight_warnings blocking_issues].each do |field|
      assert_includes sandbox_preflight.fetch("required"), field
    end
    assert sandbox_preflight.dig("properties", "container_image_digest_required")
    assert sandbox_preflight.dig("properties", "container_image_digest_policy_source")
    assert_equal %w[passed failed skipped not_observed], sandbox_preflight.dig("properties", "inside_container_probe", "properties", "status", "enum")
    assert sandbox_preflight.dig("properties", "inside_container_probe", "properties", "runtime_container_id")
    assert_equal "/proc/self/status", sandbox_preflight.dig("$defs", "security_attestation", "properties", "source", "const")
    assert_equal %w[status source no_new_privs_enabled seccomp_filtering cap_eff_zero], sandbox_preflight.dig("$defs", "security_attestation", "required")
    assert_includes sandbox_preflight.dig("properties", "runtime_container_inspect", "required"), "status"
    assert sandbox_preflight.dig("properties", "runtime_container_inspect", "properties", "host_config", "properties", "network_mode")
    assert sandbox_preflight.dig("properties", "runtime_container_inspect", "properties", "expected_workspace_source")
    assert sandbox_preflight.dig("properties", "runtime_container_inspect", "properties", "blocking_issues")
    assert_equal %w[passed failed partial skipped], sandbox_preflight.dig("properties", "runtime_matrix", "properties", "status", "enum")
    assert_equal %w[docker podman], sandbox_preflight.dig("properties", "runtime_matrix", "properties", "requested_runtimes", "items", "enum")
    assert sandbox_preflight.dig("properties", "runtime_matrix", "properties", "entries", "items", "properties", "runtime_container_inspect")
    assert sandbox_preflight.dig("properties", "container_hostname")
    assert_equal %w[passed failed configured missing not_observed], sandbox_preflight.dig("$defs", "egress_denial_probe", "properties", "status", "enum")
    %w[task_success build_pass test_pass visual_fidelity interaction_pass browser_action_loop_pass a11y_pass approval_count unsafe_action_blocked].each do |field|
      assert_includes eval_benchmark.dig("properties", "metrics", "required"), field
    end
    assert_equal %w[missing seeded calibrated invalid], eval_benchmark.dig("properties", "human_calibration_status", "enum")
    assert_equal %w[passed failed skipped], eval_benchmark.dig("properties", "regression_gate", "properties", "status", "enum")
    assert_includes eval_benchmark.dig("properties", "regression_gate", "properties", "human_calibration_status", "enum"), "invalid"
    assert_equal "engine-run-human-baselines.schema.json", human_baselines.fetch("$id").split("/").last
    assert_includes human_baselines.fetch("required"), "fixtures"
    assert human_baselines.dig("properties", "corpus_metadata"), "human baseline schema should expose optional corpus metadata for import validation"
    assert_equal "#/$defs/corpus_readiness", human_baselines.dig("properties", "corpus_readiness", "$ref")
    assert_includes human_baselines.dig("$defs", "corpus_readiness", "properties", "status", "enum"), "production_ready_multi_fixture"
    assert_equal 2, human_baselines.dig("$defs", "corpus_readiness", "properties", "minimum_calibrated_fixture_count", "const")
    assert_includes human_baselines.dig("$defs", "baseline", "required"), "average_score"
    assert human_baselines.dig("$defs", "baseline", "properties", "review_protocol"), "human baseline fixtures should be able to describe their review protocol"
    assert_equal 0, human_baselines.dig("$defs", "score", "minimum")
    assert_equal 100, human_baselines.dig("$defs", "score", "maximum")
    assert_equal "engine-run-human-review-pack.schema.json", human_review_pack.fetch("$id").split("/").last
    assert_includes human_review_pack.fetch("required"), "anti_fabrication_policy"
    assert_equal false, human_review_pack.dig("properties", "human_input_contract", "properties", "prepopulated_human_scores", "const")
    assert_equal true, human_review_pack.dig("properties", "human_input_contract", "properties", "agent_must_not_fill_scores", "const")
    assert_equal "engine-run-human-baselines.schema.json", human_review_pack.dig("properties", "human_input_contract", "properties", "candidate_schema", "const")
    assert_equal ".ai-web/eval/human-baselines.json", human_review_pack.dig("properties", "output_paths", "properties", "import_target_path", "const")
    %w[clean_cache_install dependency_diff sbom audit vulnerability_copy_back_gate execution_evidence].each do |field|
      assert_includes supply_chain_gate.fetch("required"), field
    end
    assert_equal %w[skipped waiting_approval blocked], supply_chain_gate.dig("properties", "status", "enum")
    assert_equal "_aiweb/package-cache", supply_chain_gate.dig("properties", "clean_cache_install", "properties", "isolated_cache_dir", "const")
    assert_includes supply_chain_gate.dig("properties", "sbom", "properties", "status", "enum"), "not_executed_pending_approval"
    assert_includes supply_chain_gate.dig("properties", "audit", "properties", "status", "enum"), "not_executed_pending_approval"
    assert_includes supply_chain_gate.dig("properties", "execution_evidence", "properties", "status", "enum"), "not_executed_pending_approval"
    assert supply_chain_gate.dig("properties", "network_allowlist_enforcement"), "supply-chain gate schema must expose dependency network allowlist enforcement"
    assert_includes supply_chain_gate.dig("properties", "network_allowlist_enforcement", "properties", "status", "enum"), "blocked"
    assert_includes setup_supply_chain_gate.fetch("required"), "network_allowlist_enforcement"
    assert_includes setup_supply_chain_gate.dig("properties", "status", "enum"), "passed"
    assert_equal "registry.npmjs.org", setup_supply_chain_gate.dig("properties", "network_allowlist_enforcement", "properties", "allowlist_hosts", "items", "const")
    assert_equal "network_allowlist_enforcement", setup_supply_chain_gate.dig("properties", "dependency_diff", "properties", "required_outputs", "contains", "const")
    assert_equal "worker-adapter-v1", worker_adapter_registry.dig("properties", "protocol_version", "const")
    assert worker_adapter_registry.dig("properties", "selected_adapter_executable"), "worker adapter registry must explicitly say whether selected adapter can execute"
    assert worker_adapter_registry.dig("properties", "selected_adapter_blocking_issues"), "worker adapter registry must expose selected adapter blockers"
    assert_includes worker_adapter_registry.fetch("required"), "runtime_broker_enforcement"
    assert_equal false, worker_adapter_registry.dig("properties", "runtime_broker_enforcement", "properties", "universal_broker_claim", "const")
    assert_includes worker_adapter_registry.dig("properties", "runtime_broker_enforcement", "required"), "known_mcp_broker_drivers"
    registry_known_driver_requirements = worker_adapter_registry.dig("properties", "runtime_broker_enforcement", "properties", "known_mcp_broker_drivers", "allOf").map do |entry|
      properties = entry.dig("contains", "properties")
      [
        properties.dig("server", "const"),
        properties.dig("broker_id", "const"),
        properties.dig("scope", "const"),
        properties.dig("status", "const")
      ]
    end
    assert registry_known_driver_requirements.any? { |server, broker_id, _scope, _status| server == "lazyweb" && broker_id == "aiweb.implementation_mcp_broker" }
    assert_includes registry_known_driver_requirements, ["project_files", "aiweb.implementation_mcp_broker", "implementation_worker.mcp.project_files", "implemented_for_approved_project_file_metadata_list_excerpt_search"]
    %w[openmanus codex openhands langgraph openai_agents_sdk].each do |adapter|
      assert_includes worker_adapter_registry.dig("properties", "adapters", "items", "properties", "id", "enum"), adapter
    end
    assert_includes worker_adapter_registry.dig("properties", "selected_adapter", "enum"), "openhands"
    assert_includes worker_adapter_registry.dig("properties", "selected_adapter", "enum"), "langgraph"
    assert_includes worker_adapter_registry.dig("properties", "selected_adapter", "enum"), "openai_agents_sdk"
    assert_includes worker_adapter_registry.dig("properties", "selected_adapter_status", "enum"), "experimental_container_worker"
    assert_includes worker_adapter_registry.dig("properties", "adapters", "items", "properties", "status", "enum"), "experimental_container_worker"
    assert_includes worker_adapter_registry.dig("properties", "adapters", "items", "properties", "status", "enum"), "planned_contract_only"
    %w[executable execution_blocked blocking_issues sandbox_preflight result_schema driver_readiness broker_contract].each do |field|
      assert_includes worker_adapter_registry.dig("properties", "adapters", "items", "required"), field
    end
    %w[state missing_artifacts executable_now transition_gate next_required_evidence].each do |field|
      assert_includes worker_adapter_registry.dig("properties", "adapters", "items", "properties", "driver_readiness", "required"), field
    end
    assert_equal true, worker_adapter_registry.dig("properties", "adapters", "items", "properties", "broker_contract", "properties", "required", "const")
    assert_equal true, worker_adapter_registry.dig("properties", "adapters", "items", "properties", "broker_contract", "properties", "fail_closed_on_missing_broker_driver", "const")
    assert_includes worker_adapter_registry.dig("properties", "adapters", "items", "properties", "broker_contract", "properties", "event_flow", "contains", "const"), "policy.decision"
    %w[schema_version adapter status structured_events artifact_refs changed_file_manifest proposed_tool_requests risk_notes blocking_issues].each do |field|
      assert_includes openhands_result.fetch("required"), field
      assert_includes langgraph_result.fetch("required"), field
      assert_includes openai_agents_result.fetch("required"), field
    end
    assert_equal "openhands", openhands_result.dig("properties", "adapter", "const")
    assert_equal "langgraph", langgraph_result.dig("properties", "adapter", "const")
    assert_equal "openai_agents_sdk", openai_agents_result.dig("properties", "adapter", "const")
    assert_equal "array", openhands_result.dig("properties", "structured_events", "type")
    assert_equal "array", langgraph_result.dig("properties", "structured_events", "type")
    assert_equal "array", openai_agents_result.dig("properties", "structured_events", "type")
    assert_equal true, authz_enforcement.dig("properties", "run_id_is_not_authority", "const")
    assert_equal "blocked_until_tenant_project_user_claims_are_enforced", authz_enforcement.dig("properties", "remote_exposure_status", "const")
    assert_equal true, authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "claim_enforced_project_authz_available", "const")
    assert_equal true, authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "unsupported_authz_modes_fail_closed_for_project_routes", "const")
    assert_equal "local_hs256_supported_with_server_secret", authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "jwt_hs256_status", "const")
    assert_equal "AIWEB_DAEMON_JWT_HS256_SECRET", authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "jwt_hs256_secret_env", "const")
    assert_includes authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "jwt_hs256_required_claims", "items", "enum"), "project_id"
    assert_equal "local_rs256_jwks_file_supported_no_oidc_discovery", authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "jwt_rs256_jwks_status", "const")
    assert_equal "AIWEB_DAEMON_JWT_RS256_JWKS_FILE", authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "jwt_rs256_jwks_file_env", "const")
    assert_includes authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "jwt_rs256_jwks_required_claims", "items", "enum"), "tenant_id"
    assert_equal "local_hashed_session_store_supported", authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "session_token_status", "const")
    assert_equal "AIWEB_DAEMON_SESSION_STORE_FILE", authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "session_store_file_env", "const")
    assert_equal "sha256_hash_only", authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "session_token_storage", "const")
    assert_includes authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "session_token_required_claims", "items", "enum"), "user_id"
    assert_equal "not_implemented_fail_closed", authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "oidc_status", "const")
    assert_equal "unsupported_modes_fail_closed", authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "raw_jwt_oidc_status", "const")
    assert_includes authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "supported_authz_modes", "items", "enum"), "claims"
    assert_includes authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "supported_authz_modes", "items", "enum"), "jwt_hs256"
    assert_includes authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "supported_authz_modes", "items", "enum"), "jwt_rs256_jwks"
    assert_includes authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "supported_authz_modes", "items", "enum"), "session_token"
    assert_equal "server_configured_project_allowlist", authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "project_id_source", "const")
    assert_equal "server_configured_project_allowlist", authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "role_source", "const")
    assert_equal "inline_env_or_file_json", authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "project_registry_source", "const")
    assert_equal "local_backend_project_registry_v1", authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "project_registry_policy", "properties", "policy", "const")
    assert_equal "AIWEB_DAEMON_AUTHZ_PROJECTS_FILE", authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "project_registry_file_env", "const")
    assert_equal ".ai-web/authz/audit.jsonl", authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "audit_path", "const")
    assert_includes authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "role_hierarchy", "items", "enum"), "operator"
    assert_equal "local_backend_artifact_acl_v1", authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "artifact_acl_policy", "properties", "policy", "const")
    assert_equal "operator", authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "artifact_acl_policy", "properties", "sensitive_artifact_role", "const")
    assert_equal true, authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "server_project_allowlist_required", "const")
    %w[
      view_status view_workbench view_console view_runs view_run view_events view_approvals
      view_job_status view_job_timeline view_job_summary view_artifact command codex_agent_run
      run_start approve resume cancel copy_back
    ].each do |route_permission|
      assert_includes authz_enforcement.dig("properties", "local_backend_enforcement", "properties", "route_permissions", "required"), route_permission
    end
    %w[tenant_id project_id user_id].each do |claim|
      assert_includes authz_enforcement.dig("properties", "saas_required_claims", "items", "enum"), claim
    end
    assert_includes authz_enforcement.dig("$defs", "permission_list", "items", "enum"), "role_acl"
    assert_includes authz_enforcement.dig("$defs", "permission_list", "items", "enum"), "audit_event"
    assert_equal "bounded_lexical_cards", run_memory.dig("properties", "retrieval_strategy", "const")
    assert_includes run_memory.dig("properties", "rag_status", "enum"), "not_configured"
    assert_equal "_aiweb/run-memory.json", run_memory.dig("properties", "worker_handoff", "properties", "workspace_path", "const")
    assert_equal "aiweb.engine_scheduler.supervisor.v1", engine_scheduler_supervisor.dig("properties", "supervisor_driver", "const")
    assert_equal ".ai-web/scheduler/supervisor.json", engine_scheduler_supervisor.dig("properties", "supervisor_artifact_path", "const")
    assert_equal false, engine_scheduler_supervisor.dig("properties", "install_performed", "const")
    assert_equal false, engine_scheduler_supervisor.dig("properties", "production_readiness", "properties", "os_service_installed", "const")
    assert_equal false, engine_scheduler_supervisor.dig("properties", "production_readiness", "properties", "distributed_worker_cluster", "const")
    assert_equal "engine_run_resume_bridge", engine_scheduler_supervisor.dig("properties", "production_readiness", "properties", "node_body_executor", "const")
    assert_equal "aiweb.engine_scheduler.monitor.v1", engine_scheduler_monitor.dig("properties", "monitor_driver", "const")
    assert_equal ".ai-web/scheduler/monitor.json", engine_scheduler_monitor.dig("properties", "monitor_artifact_path", "const")
    assert_includes engine_scheduler_monitor.dig("properties", "health_status", "enum"), "healthy"
    assert_includes engine_scheduler_monitor.dig("properties", "health_status", "enum"), "degraded"
    assert_equal false, engine_scheduler_monitor.dig("properties", "production_readiness", "properties", "os_service_health_observed", "const")
    assert_equal false, engine_scheduler_monitor.dig("properties", "production_readiness", "properties", "distributed_worker_cluster", "const")
    assert_equal "engine_run_resume_bridge", engine_scheduler_monitor.dig("properties", "production_readiness", "properties", "node_body_executor", "const")
    assert_equal "backend.authz.decision", local_backend_authz_audit.dig("properties", "event_type", "const")
    assert_equal ".ai-web/authz/audit.jsonl", local_backend_authz_audit.dig("properties", "audit_path", "const")
    assert_equal "server_configured_project_allowlist", local_backend_authz_audit.dig("properties", "role_source", "const")
    assert_includes local_backend_authz_audit.dig("properties", "authz_mode", "enum"), "jwt_rs256_jwks"
    assert_includes local_backend_authz_audit.dig("properties", "artifact_acl_category", "enum"), "sensitive_run_artifact"
    %w[viewer operator admin].each do |role|
      assert_includes local_backend_authz_audit.dig("properties", "required_role", "enum"), role
    end
  end

  def test_backend_route_contract_stays_structured_and_local_only
    routes = Aiweb::LocalBackendApp.routes

    assert_equal routes.uniq, routes
    assert_includes routes, "POST /api/project/command"
    assert_includes routes, "GET /api/engine/openmanus-readiness"
    assert_includes routes, "POST /api/codex/agent-run"
    assert_includes routes, "GET /api/project/run-events-sse?path=PROJECT_PATH&run_id=RUN_ID&cursor=N"
    refute routes.any? { |route| route.match?(/shell|exec/i) }, "backend routes must not expose raw shell execution"

    plan = Aiweb::LocalBackendApp.plan(host: "127.0.0.1", port: 4242)
    assert_includes plan.dig("backend", "guardrails"), "do not expose raw shell execution to frontend"
    assert_includes plan.dig("backend", "guardrails"), "bind only to localhost-class hosts for local-first use"
    assert_includes plan.dig("backend", "routes"), "GET /api/project/run-events-sse?path=PROJECT_PATH&run_id=RUN_ID&cursor=N"
  end

  def test_engine_run_human_baseline_calibration_accepts_schema_shaped_scores
    Dir.mktmpdir("aiweb-human-baseline") do |dir|
      fixture_id = "design-fixture-#{"a" * 16}"
      FileUtils.mkdir_p(File.join(dir, ".ai-web", "eval"))
      File.write(
        File.join(dir, ".ai-web", "eval", "human-baselines.json"),
        JSON.pretty_generate(
          "schema_version" => 1,
          "fixtures" => {
            fixture_id => {
              "fixture_id" => fixture_id,
              "average_score" => 92.5,
              "reviewer_count" => 2,
              "human_scores" => {
                "hierarchy" => 94,
                "spacing" => 91
              },
              "human_ratings" => [
                { "reviewer_id" => "designer-1", "overall_score" => 93, "scores" => { "hierarchy" => 95 } },
                { "reviewer_id" => "designer-2", "overall_score" => 92, "scores" => { "spacing" => 90 } }
              ]
            }
          }
        )
      )

      calibration = Aiweb::Project.new(dir).send(:engine_run_eval_human_calibration, "fixture_id" => fixture_id)

      assert_equal "calibrated", calibration.fetch("status")
      assert_equal "ready", calibration.dig("baseline_source", "status")
      assert_equal 92.5, calibration.dig("baseline_source", "average_score")
      assert_equal 2, calibration.dig("baseline_source", "reviewer_count")
      assert_equal %w[hierarchy spacing], calibration.dig("baseline_source", "score_axes")
    end
  end

  def test_engine_run_calibrated_regression_gate_fails_below_human_baseline
    Dir.mktmpdir("aiweb-human-baseline-gate") do |dir|
      project = Aiweb::Project.new(dir)
      gate = project.send(
        :engine_run_eval_regression_gate,
        design_required: true,
        final_status: "passed",
        metrics: {
          "interaction_pass" => { "status" => "passed" },
          "a11y_pass" => { "status" => "passed" },
          "browser_console_clean" => { "status" => "passed" },
          "browser_network_clean" => { "status" => "passed" },
          "build_pass" => { "status" => "skipped" },
          "test_pass" => { "status" => "skipped" }
        },
        design_verdict: {
          "status" => "passed",
          "average_score" => 70
        },
        screenshot_evidence: {
          "status" => "captured"
        },
        human_calibration: {
          "status" => "calibrated",
          "baseline_source" => {
            "average_score" => 95
          }
        }
      )

      assert_equal "failed", gate.fetch("status")
      assert_equal "human_calibrated_thresholds", gate.fetch("mode")
      assert_match(/below calibrated human baseline/i, gate.fetch("blocking_issues").join("\n"))
      assert_equal 95, gate.fetch("baseline_average_score")
      assert_equal 70, gate.fetch("current_average_score")
    end
  end

  def test_engine_run_human_baseline_without_reviewer_evidence_is_seeded_not_calibrated
    Dir.mktmpdir("aiweb-human-baseline-zero-reviewer") do |dir|
      fixture_id = "design-fixture-#{"d" * 16}"
      FileUtils.mkdir_p(File.join(dir, ".ai-web", "eval"))
      File.write(
        File.join(dir, ".ai-web", "eval", "human-baselines.json"),
        JSON.pretty_generate(
          "schema_version" => 1,
          "fixtures" => {
            fixture_id => {
              "fixture_id" => fixture_id,
              "average_score" => 92.5,
              "reviewer_count" => 0,
              "human_scores" => {
                "hierarchy" => 94
              }
            }
          }
        )
      )

      calibration = Aiweb::Project.new(dir).send(:engine_run_eval_human_calibration, "fixture_id" => fixture_id)

      assert_equal "seeded", calibration.fetch("status")
      assert_equal 0, calibration.dig("baseline_source", "reviewer_count")
      assert_equal ["hierarchy"], calibration.dig("baseline_source", "score_axes")
    end
  end

  def test_engine_run_human_baseline_calibration_seeds_from_design_fixture_when_corpus_missing
    Dir.mktmpdir("aiweb-human-baseline-seeded") do |dir|
      fixture_id = "design-fixture-#{"c" * 16}"
      calibration = Aiweb::Project.new(dir).send(
        :engine_run_eval_human_calibration,
        {
          "fixture_id" => fixture_id,
          "stored_baseline_verdict" => {
            "average_score" => 88.0
          }
        }
      )

      assert_equal "seeded", calibration.fetch("status")
      assert_equal "deterministic_design_fixture_seed", calibration.dig("baseline_source", "type")
      assert_equal "seeded", calibration.dig("baseline_source", "status")
      assert_equal fixture_id, calibration.dig("baseline_source", "fixture_id")
      assert_equal 88.0, calibration.dig("baseline_source", "average_score")
      assert_equal false, calibration.dig("baseline_source", "human_calibrated")
    end
  end

  def test_engine_run_human_baseline_calibration_rejects_invalid_or_secret_values
    Dir.mktmpdir("aiweb-human-baseline") do |dir|
      fixture_id = "design-fixture-#{"b" * 16}"
      FileUtils.mkdir_p(File.join(dir, ".ai-web", "eval"))
      File.write(
        File.join(dir, ".ai-web", "eval", "human-baselines.json"),
        JSON.pretty_generate(
          "schema_version" => 1,
          "fixtures" => {
            fixture_id => {
              "fixture_id" => fixture_id,
              "average_score" => 120,
              "human_scores" => { "hierarchy" => -1 },
              "notes" => "SECRET=human-baseline-do-not-leak"
            }
          }
        )
      )

      calibration = Aiweb::Project.new(dir).send(:engine_run_eval_human_calibration, "fixture_id" => fixture_id)
      issues = calibration.dig("baseline_source", "issues").join("\n")

      assert_equal "invalid", calibration.fetch("status")
      assert_match(/average_score/i, issues)
      assert_match(/score hierarchy/i, issues)
      assert_match(/secret|environment/i, issues)
    end
  end

  def test_backend_exposes_engine_run_events_as_sse_frames
    Dir.mktmpdir("aiweb-sse") do |dir|
      run_id = "engine-run-sse"
      run_dir = File.join(dir, ".ai-web", "runs", run_id)
      FileUtils.mkdir_p(run_dir)
      File.write(
        File.join(run_dir, "events.jsonl"),
        JSON.generate(
          "schema_version" => 1,
          "seq" => 1,
          "run_id" => run_id,
          "actor" => "aiweb.engine_run",
          "phase" => "run",
          "trace_span_id" => "span-000001-run-created",
          "type" => "run.created",
          "message" => "created",
          "at" => "2026-05-14T00:00:00Z",
          "data" => {},
          "redaction_status" => "redacted_at_source",
          "previous_event_hash" => nil,
          "event_hash" => "sha256:#{"a" * 64}"
        ) + "\n"
      )

      app = Aiweb::LocalBackendApp.new(api_token: "expected-token")
      target = "/api/project/run-events-sse?path=#{URI.encode_www_form_component(dir)}&run_id=#{run_id}&cursor=0"
      status, body, response = app.call("GET", target, { "x-aiweb-token" => "expected-token" })

      assert_equal 200, status
      assert_equal "text/event-stream", response.fetch("content_type")
      assert_equal "no-cache", response.fetch("cache_control")
      assert_includes body, ": aiweb engine-run events"
      assert_includes body, "event: aiweb.run.meta"
      assert_includes body, "event: run.created"
      assert_includes body, "event: aiweb.run.cursor"
      assert_includes body, "\"stream_mode\":\"sse\""
      assert_includes body, "\"event_hash\":\"sha256:#{"a" * 64}\""
    end
  end

  def test_daemon_writes_sse_content_type_and_stream_headers
    daemon = Aiweb::LocalBackendDaemon.new(port: 0, app: Aiweb::LocalBackendApp.new(api_token: "expected-token"))
    io = StringIO.new

    daemon.send(
      :write_text,
      io,
      200,
      "event: ping\n\n",
      content_type: "text/event-stream",
      origin: "http://localhost:3000",
      extra_headers: { "Cache-Control" => "no-cache", "X-Accel-Buffering" => "no" }
    )

    response = io.string
    assert_includes response, "Content-Type: text/event-stream"
    assert_includes response, "Cache-Control: no-cache"
    assert_includes response, "X-Accel-Buffering: no"
    assert_includes response, "Access-Control-Allow-Origin: http://localhost:3000"
    assert_includes response, "event: ping"
  end

  def test_repository_quality_gate_is_the_single_ci_entrypoint
    check_script = File.read(File.join(REPO_ROOT, "bin", "check"))
    ci_workflow = File.read(File.join(REPO_ROOT, ".github", "workflows", "ci.yml"))
    readme = File.read(File.join(REPO_ROOT, "README.md"))
    contract = File.read(File.join(REPO_ROOT, "docs", "contracts", "repository-quality-gate.md"))

    assert_includes ci_workflow, "ruby bin/check"
    assert_includes ci_workflow, "engine-runtime-matrix-smoke:"
    assert_includes ci_workflow, "ruby bin/engine-runtime-matrix-check --json"
    assert_includes ci_workflow, "actions/upload-artifact@v4"
    assert_includes ci_workflow, "if-no-files-found: error"
    refute_match(/engine-runtime-matrix-smoke:[\s\S]*if:\s*github\.event_name == ['\"]workflow_dispatch['\"]/, ci_workflow)
    assert_includes readme, "ruby bin/check"
    assert_includes contract, "The formal quality gate is `ruby bin/check`"
    assert_includes contract, "warning-enabled load smoke"
    assert_includes check_script, "ruby -c"
    assert_includes check_script, "repository_text_guard"
    assert_includes check_script, "require 'aiweb'"
    assert_includes check_script, "\"-w\""
    assert_includes check_script, "test/all.rb"
    assert_includes check_script, "git diff"
    refute File.exist?(File.join(REPO_ROOT, "Gemfile")), "quality gate must remain dependency-free until a Gemfile is explicitly introduced"
  end

  def test_daemon_entrypoint_can_be_required_without_full_aiweb_loader
    script = <<~RUBY
      require "aiweb/daemon"
      raise "UserError missing" unless defined?(Aiweb::UserError)
      raise "FileUtils missing" unless defined?(FileUtils)
      app = Aiweb::LocalBackendApp.new(api_token: "expected-token")
      status, payload = app.call("GET", "/api/engine", { "x-aiweb-token" => "wrong-token" })
      raise "unexpected daemon auth response: \#{[status, payload].inspect}" unless status == 403 && payload["error"].include?("API token")
    RUBY

    assert system(RbConfig.ruby, "-I#{File.join(REPO_ROOT, "lib")}", "-e", script)
  end

  def test_cli_entrypoint_can_be_required_without_full_aiweb_loader
    script = <<~RUBY
      require "aiweb/cli"
      raise "UserError missing" unless defined?(Aiweb::UserError)
      raise "Project missing" unless defined?(Aiweb::Project)
      cli = Aiweb::CLI.new(["status"], Dir.pwd)
      original_stdout = $stdout
      begin
        $stdout = StringIO.new
        code = cli.run
      ensure
        $stdout = original_stdout
      end
      raise "unexpected cli status exit: \#{code.inspect}" unless code.is_a?(Integer)
    RUBY

    assert system(RbConfig.ruby, "-I#{File.join(REPO_ROOT, "lib")}", "-e", script)
  end

  def test_repository_line_ending_policy_covers_runtime_sources
    attributes = File.read(File.join(REPO_ROOT, ".gitattributes"))

    %w[*.rb *.md *.yml *.yaml *.json bin/*].each do |pattern|
      assert_match(/^#{Regexp.escape(pattern)} text eol=lf$/, attributes, "#{pattern} should be pinned to LF")
    end
  end
end
