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
