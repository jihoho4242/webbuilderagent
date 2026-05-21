# frozen_string_literal: true

require "digest"
require "shellwords"
require "time"
require_relative "engine_run/generated_sources"
require_relative "engine_run/sandbox_process"
require_relative "engine_run/preview_browser"
require_relative "engine_run/design_eval"
require_relative "engine_run/run_state"
require_relative "engine_run/eval_baseline"
require_relative "engine_run/copy_back_policy"
require_relative "engine_run/sandbox_preflight"
require_relative "engine_run/graph_workflow"
require_relative "engine_run/opendesign_contract"
require_relative "engine_run/project_index_memory"
require_relative "engine_run/adapter_commands"
require_relative "engine_run/evaluation_helpers"
require_relative "engine_run/worker_adapter_registry"
require_relative "engine_run/workspace_boundary"
require_relative "engine_run/agentic_worker"
require_relative "engine_run/verification"
require_relative "engine_run/configuration"

module Aiweb
  module ProjectEngineRun
    include ProjectEngineRunGeneratedSources
    include ProjectEngineRunVerification
    include ProjectEngineRunConfiguration
    ENGINE_RUN_STATUSES = %w[dry_run blocked running waiting_approval failed no_changes passed cancelled quarantined].freeze
    ENGINE_RUN_MODES = %w[safe_patch agentic_local external_approval].freeze
    ENGINE_RUN_AGENTS = %w[codex openmanus openhands langgraph openai_agents_sdk].freeze
    ENGINE_RUN_DEFAULT_WRITABLE_GLOBS = %w[
      src/**
      app/**
      components/**
      pages/**
      styles/**
      test/**
      tests/**
      public/**
      lib/**
      package.json
      astro.config.*
      next.config.*
      tailwind.config.*
      vite.config.*
      tsconfig.json
    ].freeze
    ENGINE_RUN_STAGE_EXCLUDES = %w[
      .git
      node_modules
      dist
      build
      coverage
      vendor/bundle
      .ssh
      .aws
      .azure
      .gcloud
      .docker
      .kube
      .vercel
      .netlify
      .config/google-chrome
      .config/chromium
      .mozilla
      .npmrc
      .yarnrc
      .pypirc
      .netrc
      .ai-web/runs
      .ai-web/tmp
      .ai-web/diffs
      .ai-web/snapshots
      .ai-web/workbench
    ].freeze
    ENGINE_RUN_HIGH_RISK_PATTERNS = [
      %r{\Apackage(?:-lock)?\.json\z},
      %r{\A(?:pnpm-lock|yarn\.lock|bun\.lockb)\z},
      %r{\A(?:vercel|netlify|wrangler)\.json\z},
      %r{\A\.github/workflows/}
    ].freeze
    ENGINE_RUN_EXTERNAL_ACTION_PATTERN = /\b(?:npm|pnpm|yarn|bun)\s+(?:add|install|i|ci|update|upgrade|up)\b|\b(?:curl|wget)\s+https?:|(?:vercel|netlify|cloudflare|wrangler)\b|\bgit\s+push\b/i.freeze
    ENGINE_RUN_SECRET_VALUE_PATTERN = Aiweb::Redaction::SECRET_VALUE_PATTERN
    def engine_run(goal: nil, agent: "codex", mode: "agentic_local", sandbox: nil, max_cycles: 3, approved: false, approval_hash: nil, resume: nil, dry_run: false, force: false, run_id: nil)
      assert_initialized!

      state = load_state
      ensure_implementation_state_defaults!(state)
      normalized_agent = engine_run_agent(agent)
      normalized_mode = engine_run_mode(mode)
      cycle_limit = engine_run_cycle_limit(max_cycles)
      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      run_id = engine_run_requested_run_id(run_id, resume: resume, timestamp: timestamp)
      run_dir = File.join(aiweb_dir, "runs", run_id)
      paths = engine_run_paths(run_id, run_dir)
      resume_context = engine_run_resume_context(resume)
      paths[:workspace_dir] = resume_context.fetch(:workspace_dir) if resume_context
      resolved_goal = engine_run_goal(goal, state, resume, resume_context)
      opendesign_contract = engine_run_opendesign_contract(state, goal: resolved_goal)
      capability = engine_run_capability_envelope(
        run_id: run_id,
        goal: resolved_goal,
        mode: normalized_mode,
        agent: normalized_agent,
        sandbox: sandbox,
        max_cycles: cycle_limit,
        resume: resume,
        opendesign_contract: opendesign_contract
      )
      expected_hash = engine_run_approval_hash(capability)
      planned_changes = engine_run_planned_changes(paths)
      run_graph = engine_run_graph_contract(run_id: run_id, capability: capability, paths: paths)
      tool_broker = engine_run_tool_broker_contract(normalized_mode)

      if dry_run
        return engine_run_dry_run_payload(
          state: state,
          run_id: run_id,
          normalized_mode: normalized_mode,
          normalized_agent: normalized_agent,
          sandbox: sandbox,
          approved: approved,
          capability: capability,
          expected_hash: expected_hash,
          paths: paths,
          planned_changes: planned_changes,
          resume: resume,
          opendesign_contract: opendesign_contract,
          run_graph: run_graph,
          tool_broker: tool_broker
        )
      end

      blockers = engine_run_initial_execution_blockers(
        approved: approved,
        approval_hash: approval_hash,
        expected_hash: expected_hash,
        opendesign_contract: opendesign_contract,
        normalized_mode: normalized_mode,
        normalized_agent: normalized_agent,
        sandbox: sandbox,
        workspace_dir: paths.fetch(:workspace_dir),
        resume: resume,
        resume_context: resume_context
      )

      unless blockers.empty?
        return engine_run_initial_blocked_payload(
          state: state,
          run_id: run_id,
          normalized_mode: normalized_mode,
          normalized_agent: normalized_agent,
          sandbox: sandbox,
          approved: approved,
          capability: capability,
          expected_hash: expected_hash,
          paths: paths,
          resume: resume,
          opendesign_contract: opendesign_contract,
          run_graph: run_graph,
          tool_broker: tool_broker,
          blockers: blockers
        )
      end

      return engine_run_safe_patch(state: state, capability: capability, normalized_agent: normalized_agent, sandbox: sandbox, approved: approved, dry_run: dry_run) if normalized_mode == "safe_patch"

      changes = []
      payload = nil
      active_record = nil
      mutation(dry_run: false) do
        active_record = active_run_begin!(
          kind: "engine-run",
          run_id: run_id,
          run_dir: run_dir,
          metadata_path: paths.fetch(:metadata_path),
          command: engine_run_command_descriptor(normalized_agent, normalized_mode, sandbox, cycle_limit, resume),
          force: force
        )

        FileUtils.mkdir_p(run_dir)
        engine_run_artifact_dirs(paths).each { |path| FileUtils.mkdir_p(path) }
        changes << relative(run_dir)
        started_at = now
        changes << write_json(paths.fetch(:job_path), engine_run_job_record(run_id: run_id, status: "running", started_at: started_at, finished_at: nil, events_path: paths.fetch(:events_path)), false)
        events = []
        engine_run_event(paths.fetch(:events_path), events, "run.created", "created engine run", run_id: run_id, mode: normalized_mode, agent: normalized_agent)
        if resume_context
          engine_run_event(paths.fetch(:events_path), events, "run.resumed", "resumed engine run from checkpoint", parent_run_id: resume_context.fetch(:run_id), parent_status: resume_context.fetch(:checkpoint).fetch("status", nil), parent_checkpoint_path: resume_context.fetch(:checkpoint_path))
        end
        engine_run_event(paths.fetch(:events_path), events, "goal.understood", "captured user goal", goal: capability.fetch("goal"))
        engine_run_opendesign_events(paths.fetch(:events_path), events, opendesign_contract, resume_context)

        changes << write_file(paths.fetch(:approval_path), json_generate(engine_run_approval_record(run_id: run_id, capability: capability, approval_hash: expected_hash, approved: approved, scope: "execute")) + "\n", false)
        engine_run_event(paths.fetch(:events_path), events, "approval.granted", "recorded approved capability envelope", approval_hash: expected_hash, approval_path: relative(paths.fetch(:approval_path)))
        stage = if resume_context
                  { manifest: resume_context.fetch(:manifest) }
                else
                  engine_run_stage_workspace(paths.fetch(:workspace_dir), events_path: paths.fetch(:events_path), events: events)
                end
        changes << relative(paths.fetch(:workspace_dir)) unless resume_context
        changes << write_json(paths.fetch(:manifest_path), stage.fetch(:manifest), false)
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded staged manifest", artifact_path: relative(paths.fetch(:manifest_path)))
        changes << write_json(paths.fetch(:opendesign_contract_path), opendesign_contract, false)
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded OpenDesign contract", artifact_path: relative(paths.fetch(:opendesign_contract_path)))
        project_index = engine_run_project_index(stage.fetch(:manifest))
        changes << write_json(paths.fetch(:project_index_path), project_index, false)
        engine_run_write_workspace_project_index(paths.fetch(:workspace_dir), project_index)
        engine_run_event(paths.fetch(:events_path), events, "project.indexed", "recorded project index for worker retrieval", artifact_path: relative(paths.fetch(:project_index_path)), route_count: project_index.dig("routes", "items").to_a.length, component_count: project_index.dig("components", "items").to_a.length)
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded project index", artifact_path: relative(paths.fetch(:project_index_path)))
        run_memory = engine_run_memory_index(run_id: run_id, goal: capability.fetch("goal"), project_index: project_index, opendesign_contract: opendesign_contract, paths: paths)
        changes << write_json(paths.fetch(:run_memory_path), run_memory, false)
        engine_run_write_workspace_run_memory(paths.fetch(:workspace_dir), run_memory)
        engine_run_event(paths.fetch(:events_path), events, "memory.index.recorded", "recorded run memory retrieval index", artifact_path: relative(paths.fetch(:run_memory_path)), record_count: Array(run_memory["memory_records"]).length, rag_status: run_memory["rag_status"])
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded run memory retrieval index", artifact_path: relative(paths.fetch(:run_memory_path)))
        authz_enforcement = engine_run_authz_enforcement(run_id: run_id, mode: normalized_mode, agent: normalized_agent, sandbox: sandbox, approved: approved, paths: paths)
        changes << write_json(paths.fetch(:authz_enforcement_path), authz_enforcement, false)
        engine_run_event(paths.fetch(:events_path), events, "authz.enforcement.recorded", "recorded authorization enforcement evidence", artifact_path: relative(paths.fetch(:authz_enforcement_path)), remote_exposure_status: authz_enforcement["remote_exposure_status"])
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded authorization enforcement evidence", artifact_path: relative(paths.fetch(:authz_enforcement_path)))
        worker_adapter_registry = engine_run_worker_adapter_registry(selected_agent: normalized_agent, mode: normalized_mode, sandbox: sandbox)
        changes << write_json(paths.fetch(:worker_adapter_registry_path), worker_adapter_registry, false)
        engine_run_write_workspace_worker_adapter_registry(paths.fetch(:workspace_dir), worker_adapter_registry)
        engine_run_event(paths.fetch(:events_path), events, "worker.adapter.registry.recorded", "recorded worker adapter registry", artifact_path: relative(paths.fetch(:worker_adapter_registry_path)), selected_adapter: worker_adapter_registry["selected_adapter"], selected_adapter_executable: worker_adapter_registry["selected_adapter_executable"], executable_adapter_count: Array(worker_adapter_registry["adapters"]).count { |adapter| adapter["executable"] == true })
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded worker adapter registry", artifact_path: relative(paths.fetch(:worker_adapter_registry_path)))
        graph_execution_plan = engine_run_graph_execution_plan(run_graph: run_graph, paths: paths, resume_context: resume_context)
        graph_execution_blockers = engine_run_graph_execution_plan_blockers(graph_execution_plan)
        unless graph_execution_blockers.empty?
          raise UserError.new("engine-run graph execution plan invalid: #{graph_execution_blockers.join(", ")}", 5)
        end
        changes << write_json(paths.fetch(:graph_execution_plan_path), graph_execution_plan, false)
        engine_run_write_workspace_graph_execution_plan(paths.fetch(:workspace_dir), graph_execution_plan)
        engine_run_event(paths.fetch(:events_path), events, "graph.scheduler.planned", "recorded graph scheduler execution plan", artifact_path: relative(paths.fetch(:graph_execution_plan_path)), start_node_id: graph_execution_plan["start_node_id"], node_count: graph_execution_plan.fetch("node_invocations").length)
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded graph scheduler execution plan", artifact_path: relative(paths.fetch(:graph_execution_plan_path)))
        graph_scheduler_state = engine_run_graph_scheduler_state(run_graph: run_graph, graph_execution_plan: graph_execution_plan, paths: paths, resume_context: resume_context)
        changes << write_json(paths.fetch(:graph_scheduler_state_path), graph_scheduler_state, false)
        engine_run_write_workspace_graph_scheduler_state(paths.fetch(:workspace_dir), graph_scheduler_state)
        engine_run_event(paths.fetch(:events_path), events, "graph.scheduler.started", "started durable graph scheduler state", artifact_path: relative(paths.fetch(:graph_scheduler_state_path)), start_node_id: graph_scheduler_state["start_node_id"], resume_from: graph_scheduler_state["resume_from"])
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded graph scheduler state", artifact_path: relative(paths.fetch(:graph_scheduler_state_path)))
        worker_adapter_contract = engine_run_worker_adapter_contract(normalized_agent).merge(
          "run_id" => run_id,
          "adapter_input_path" => "_aiweb/worker-adapter-contract.json",
          "adapter_registry_ref" => relative(paths.fetch(:worker_adapter_registry_path)),
          "graph_execution_plan_ref" => relative(paths.fetch(:graph_execution_plan_path)),
          "graph_scheduler_state_ref" => relative(paths.fetch(:graph_scheduler_state_path)),
          "result_path" => "_aiweb/engine-result.json",
          "staged_workspace_uri" => "file:///workspace",
          "capability_ref" => "engine_run.capability",
          "design_contract_ref" => relative(paths.fetch(:opendesign_contract_path)),
          "prior_evidence_refs" => [relative(paths.fetch(:project_index_path)), relative(paths.fetch(:run_memory_path)), relative(paths.fetch(:manifest_path)), relative(paths.fetch(:graph_execution_plan_path)), relative(paths.fetch(:graph_scheduler_state_path))]
        )
        changes << write_json(paths.fetch(:worker_adapter_contract_path), worker_adapter_contract, false)
        engine_run_write_workspace_worker_adapter_contract(paths.fetch(:workspace_dir), worker_adapter_contract)
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded worker adapter contract", artifact_path: relative(paths.fetch(:worker_adapter_contract_path)))

        unsupported_start_blockers = engine_run_graph_scheduler_unsupported_start_blockers(graph_execution_plan)
        unless unsupported_start_blockers.empty?
          start_node_id = graph_execution_plan.fetch("start_node_id")
          sandbox_preflight = engine_run_sandbox_preflight_skipped("unsupported graph resume start #{start_node_id}")
          changes << write_json(paths.fetch(:sandbox_preflight_path), sandbox_preflight, false)
          engine_run_mark_graph_node!(run_graph, start_node_id, "blocked", attempt: 0)
          run_graph["cursor"] = {
            "node_id" => start_node_id,
            "state" => "blocked",
            "attempt" => 0
          }
          engine_run_graph_scheduler_reconcile!(
            graph_scheduler_state,
            run_graph,
            graph_execution_plan,
            final_status: "blocked",
            paths: paths,
            events_path: paths.fetch(:events_path),
            events: events
          )
          changes << write_json(paths.fetch(:graph_scheduler_state_path), graph_scheduler_state, false)
          engine_run_write_workspace_graph_scheduler_state(paths.fetch(:workspace_dir), graph_scheduler_state)
          checkpoint = engine_run_checkpoint(
            run_id: run_id,
            status: "blocked",
            cycle: 0,
            next_step: "unsupported_graph_resume_start",
            workspace_path: paths.fetch(:workspace_dir),
            safe_changes: [],
            goal: capability.fetch("goal"),
            resume_from: resume,
            opendesign_contract: opendesign_contract,
            run_graph: run_graph,
            artifact_hashes: engine_run_checkpoint_artifact_hashes(paths)
          )
          changes << write_json(paths.fetch(:checkpoint_path), checkpoint, false)
          engine_run_event(paths.fetch(:events_path), events, "checkpoint.saved", "saved blocked graph scheduler checkpoint", status: "blocked", checkpoint_path: relative(paths.fetch(:checkpoint_path)))
          engine_run_event(paths.fetch(:events_path), events, "run.finished", "finished engine run", status: "blocked")
          metadata = engine_run_metadata(
            run_id: run_id,
            status: "blocked",
            mode: normalized_mode,
            agent: normalized_agent,
            sandbox: sandbox,
            approved: true,
            dry_run: false,
            goal: capability.fetch("goal"),
            capability: capability,
            approval_hash: expected_hash,
            paths: paths,
            started_at: started_at,
            finished_at: now,
            events: events,
            checkpoint: checkpoint,
            staged_manifest_path: relative(paths.fetch(:manifest_path)),
            opendesign_contract_path: relative(paths.fetch(:opendesign_contract_path)),
            project_index_path: relative(paths.fetch(:project_index_path)),
            run_memory_path: relative(paths.fetch(:run_memory_path)),
            authz_enforcement_path: relative(paths.fetch(:authz_enforcement_path)),
            worker_adapter_registry_path: relative(paths.fetch(:worker_adapter_registry_path)),
            graph_execution_plan_path: relative(paths.fetch(:graph_execution_plan_path)),
            graph_scheduler_state_path: relative(paths.fetch(:graph_scheduler_state_path)),
            sandbox_preflight_path: relative(paths.fetch(:sandbox_preflight_path)),
            run_graph: run_graph,
            graph_execution_plan: graph_execution_plan,
            graph_scheduler_state: graph_scheduler_state,
            tool_broker: tool_broker,
            sandbox_preflight: sandbox_preflight,
            opendesign_contract: opendesign_contract,
            project_index: project_index,
            run_memory: run_memory,
            authz_enforcement: authz_enforcement,
            worker_adapter_registry: worker_adapter_registry,
            blocking_issues: unsupported_start_blockers
          )
          changes << write_json(paths.fetch(:metadata_path), metadata, false)
          changes << write_json(paths.fetch(:job_path), engine_run_job_record(run_id: run_id, status: "blocked", started_at: started_at, finished_at: now, events_path: paths.fetch(:events_path)), false)
          state["implementation"]["latest_engine_run"] = relative(paths.fetch(:metadata_path))
          state["implementation"]["engine_run_status"] = "blocked"
          state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
          changes << write_yaml(state_path, state, false)
          payload = engine_run_payload(
            state: state,
            metadata: metadata,
            changed_files: compact_changes(changes),
            planned_changes: [],
            action_taken: "engine run blocked",
            next_action: "resume start node #{start_node_id} requires a dedicated graph continuation handler before worker execution"
          )
          active_run_finish!(active_record, "blocked")
          active_record = nil
          next
        end

        broker_workspace = engine_run_prepare_workspace_tool_broker(paths.fetch(:workspace_dir))
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "prepared staged tool-broker shims", artifact_path: relative(broker_workspace.fetch(:bin_dir)), events_path: relative(broker_workspace.fetch(:events_path)))
        engine_run_event(paths.fetch(:events_path), events, "sandbox.preflight.started", "checking enforced sandbox boundary", agent: normalized_agent, sandbox: sandbox, workspace_path: relative(paths.fetch(:workspace_dir)))
        sandbox_preflight = engine_run_sandbox_preflight_evidence(
          agent: normalized_agent,
          sandbox: sandbox,
          workspace_dir: paths.fetch(:workspace_dir),
          command: engine_run_agent_command(normalized_agent, sandbox, paths.fetch(:workspace_dir))
        )
        changes << write_json(paths.fetch(:sandbox_preflight_path), sandbox_preflight, false)
        engine_run_event(paths.fetch(:events_path), events, "sandbox.preflight.finished", sandbox_preflight["status"] == "passed" ? "sandbox boundary accepted" : "sandbox boundary rejected", agent: normalized_agent, sandbox: sandbox, network: sandbox_preflight["network_mode"], status: sandbox_preflight["status"], blocking_issues: sandbox_preflight["blocking_issues"], artifact_path: relative(paths.fetch(:sandbox_preflight_path)))
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded sandbox preflight evidence", artifact_path: relative(paths.fetch(:sandbox_preflight_path)))
        preflight_blockers = Array(sandbox_preflight["blocking_issues"])
        unless preflight_blockers.empty?
          engine_run_mark_graph_node!(run_graph, "preflight", "failed", attempt: 1)
          run_graph["cursor"] = {
            "node_id" => "preflight",
            "state" => "blocked",
            "attempt" => 1
          }
          engine_run_graph_scheduler_reconcile!(
            graph_scheduler_state,
            run_graph,
            graph_execution_plan,
            final_status: "blocked",
            paths: paths,
            events_path: paths.fetch(:events_path),
            events: events
          )
          changes << write_json(paths.fetch(:graph_scheduler_state_path), graph_scheduler_state, false)
          engine_run_write_workspace_graph_scheduler_state(paths.fetch(:workspace_dir), graph_scheduler_state)
          checkpoint = engine_run_checkpoint(
            run_id: run_id,
            status: "blocked",
            cycle: 0,
            next_step: "fix_sandbox_preflight",
            workspace_path: paths.fetch(:workspace_dir),
            safe_changes: [],
            goal: capability.fetch("goal"),
            resume_from: resume,
            opendesign_contract: opendesign_contract,
            run_graph: run_graph,
            artifact_hashes: engine_run_checkpoint_artifact_hashes(paths)
          )
          changes << write_json(paths.fetch(:checkpoint_path), checkpoint, false)
          engine_run_event(paths.fetch(:events_path), events, "checkpoint.saved", "saved blocked sandbox preflight checkpoint", status: "blocked", checkpoint_path: relative(paths.fetch(:checkpoint_path)))
          engine_run_event(paths.fetch(:events_path), events, "run.finished", "finished engine run", status: "blocked")
          metadata = engine_run_metadata(
            run_id: run_id,
            status: "blocked",
            mode: normalized_mode,
            agent: normalized_agent,
            sandbox: sandbox,
            approved: true,
            dry_run: false,
            goal: capability.fetch("goal"),
            capability: capability,
            approval_hash: expected_hash,
            paths: paths,
            started_at: started_at,
            finished_at: now,
            events: events,
            checkpoint: checkpoint,
            staged_manifest_path: relative(paths.fetch(:manifest_path)),
            opendesign_contract_path: relative(paths.fetch(:opendesign_contract_path)),
            project_index_path: relative(paths.fetch(:project_index_path)),
            run_memory_path: relative(paths.fetch(:run_memory_path)),
            authz_enforcement_path: relative(paths.fetch(:authz_enforcement_path)),
            worker_adapter_registry_path: relative(paths.fetch(:worker_adapter_registry_path)),
            graph_execution_plan_path: relative(paths.fetch(:graph_execution_plan_path)),
            graph_scheduler_state_path: relative(paths.fetch(:graph_scheduler_state_path)),
            sandbox_preflight_path: relative(paths.fetch(:sandbox_preflight_path)),
            run_graph: run_graph,
            graph_execution_plan: graph_execution_plan,
            graph_scheduler_state: graph_scheduler_state,
            tool_broker: tool_broker,
            sandbox_preflight: sandbox_preflight,
            opendesign_contract: opendesign_contract,
            project_index: project_index,
            run_memory: run_memory,
            authz_enforcement: authz_enforcement,
            worker_adapter_registry: worker_adapter_registry,
            blocking_issues: preflight_blockers
          )
          changes << write_json(paths.fetch(:metadata_path), metadata, false)
          changes << write_json(paths.fetch(:job_path), engine_run_job_record(run_id: run_id, status: "blocked", started_at: started_at, finished_at: now, events_path: paths.fetch(:events_path)), false)
          state["implementation"]["latest_engine_run"] = relative(paths.fetch(:metadata_path))
          state["implementation"]["engine_run_status"] = "blocked"
          state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
          changes << write_yaml(state_path, state, false)
          payload = engine_run_payload(
            state: state,
            metadata: metadata,
            changed_files: compact_changes(changes),
            planned_changes: [],
            action_taken: "engine run blocked",
            next_action: "inspect #{metadata["sandbox_preflight_path"]} and fix sandbox self-attestation before worker execution"
          )
          active_run_finish!(active_record, "blocked")
          active_record = nil
          next
        end

        result = engine_run_empty_agent_result
        policy = nil
        verification = nil
        design_fidelity = nil
        preview = nil
        screenshot_evidence = nil
        design_verdict = nil
        design_fixture = nil
        eval_benchmark = nil
        supply_chain_gate = nil
        agent_result = nil
        quarantine = nil
        final_status = "failed"
        while result.fetch(:cycles_completed) < cycle_limit
          cycle_result = engine_run_execute_agentic_loop(
            run_id: run_id,
            capability: capability,
            paths: paths,
            stage: stage,
            agent: normalized_agent,
            sandbox: sandbox,
            cycle_limit: 1,
            cycle_offset: result.fetch(:cycles_completed),
            events: events
          )
          result = engine_run_merge_agent_results(result, cycle_result)
          agent_result = engine_run_agent_result(paths.fetch(:workspace_dir))
          policy = engine_run_copy_back_policy(paths.fetch(:workspace_dir), stage.fetch(:manifest), result.fetch(:stdout).to_s + "\n" + result.fetch(:stderr).to_s)
          adapter_violations = if %w[openhands langgraph].include?(normalized_agent) && !agent_result
                                 ["worker adapter contract violation: #{normalized_agent} did not write _aiweb/engine-result.json"]
                               else
                                 engine_run_worker_adapter_output_violations(agent_result, paths.fetch(:workspace_dir), expected_adapter: normalized_agent)
                               end
          unless adapter_violations.empty?
            policy["status"] = "blocked"
            policy["blocking_issues"].concat(adapter_violations).uniq!
          end
          copy_back_conflicts = engine_run_copy_back_conflicts(stage.fetch(:manifest), policy.fetch("safe_changes"))
          unless copy_back_conflicts.empty?
            policy["status"] = "blocked"
            policy["blocking_issues"].concat(copy_back_conflicts).uniq!
          end
          design_fidelity = engine_run_design_fidelity_result(paths.fetch(:workspace_dir), policy, opendesign_contract)
          unless %w[passed skipped].include?(design_fidelity.fetch("status"))
            policy["status"] = design_fidelity.fetch("status") == "blocked" ? "blocked" : "repair"
            policy["blocking_issues"].concat(design_fidelity.fetch("blocking_issues")).uniq!
            policy["blocking_issues"].concat(design_fidelity.fetch("repair_issues")).uniq!
          end
          verification = engine_run_verification_result(paths.fetch(:workspace_dir), capability, paths, events, agent: normalized_agent, sandbox: sandbox)
          preview = engine_run_preview_result(paths.fetch(:workspace_dir), paths, events, agent: normalized_agent, sandbox: sandbox)
          screenshot_evidence = engine_run_screenshot_evidence(paths, preview, events, agent: normalized_agent, sandbox: sandbox)
          engine_run_apply_workspace_tool_broker_events_to_policy(policy, paths.fetch(:workspace_dir))
          design_verdict = engine_run_design_verdict_result(paths.fetch(:workspace_dir), policy, design_fidelity, screenshot_evidence, opendesign_contract, paths, events)
          engine_run_apply_design_gate_to_policy(policy, design_verdict, opendesign_contract, paths)
          quarantine = engine_run_quarantine_record(run_id: run_id, result: result, policy: policy, sandbox_preflight: sandbox_preflight)
          if quarantine.fetch("status") == "quarantined"
            policy["status"] = "quarantined"
            policy["blocking_issues"].concat(quarantine.fetch("blocking_issues")).uniq!
          end
          final_status = engine_run_final_status(result, policy)
          final_status = "failed" if final_status == "passed" && verification.fetch("status") == "failed"
          final_status = "failed" if %w[passed no_changes].include?(final_status) && preview.fetch("status") == "failed"
          final_status = "failed" if %w[passed no_changes].include?(final_status) && design_verdict.fetch("status") == "failed"

          break unless engine_run_should_repair?(final_status, result, policy, verification, preview, design_verdict, cycle_limit)

          engine_run_event(paths.fetch(:events_path), events, "qa.failed", "sandbox verification failed; recording repair observation", verification_status: verification.fetch("status"), cycle: result.fetch(:cycles_completed))
          if design_verdict.fetch("status") == "failed"
            engine_run_event(paths.fetch(:events_path), events, "design.repair.planned", "planned design repair from verdict evidence", design_verdict_status: design_verdict.fetch("status"), cycle: result.fetch(:cycles_completed))
          end
          engine_run_write_repair_observation(paths.fetch(:workspace_dir), verification, policy, preview: preview, screenshot_evidence: screenshot_evidence, design_verdict: design_verdict, opendesign_contract: opendesign_contract)
          engine_run_event(paths.fetch(:events_path), events, "repair.planned", "planned another agent cycle from sandbox verification evidence", next_cycle: result.fetch(:cycles_completed) + 1)
        end

        if agent_result
          changes << write_json(paths.fetch(:agent_result_path), agent_result, false)
          engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded agent result", artifact_path: relative(paths.fetch(:agent_result_path)))
        end
        diff_patch = engine_run_workspace_diff(paths.fetch(:workspace_dir), policy.fetch("safe_changes") + policy.fetch("approval_changes") + policy.fetch("blocked_changes"))
        changes << write_file(paths.fetch(:diff_path), diff_patch, false)
        engine_run_event(paths.fetch(:events_path), events, "patch.generated", "generated sandbox diff", diff_path: relative(paths.fetch(:diff_path)))
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded sandbox diff", artifact_path: relative(paths.fetch(:diff_path)))

        changes << write_json(paths.fetch(:verification_path), verification, false)
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded sandbox verification evidence", artifact_path: relative(paths.fetch(:verification_path)))
        changes << write_json(paths.fetch(:preview_path), preview, false)
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded sandbox preview evidence", artifact_path: relative(paths.fetch(:preview_path)))
        changes.concat(Array(screenshot_evidence["screenshots"]).map { |shot| shot["path"] })
        changes << write_json(paths.fetch(:screenshot_evidence_path), screenshot_evidence, false)
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded screenshot evidence", artifact_path: relative(paths.fetch(:screenshot_evidence_path)))
        changes << write_json(paths.fetch(:design_verdict_path), design_verdict, false)
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded design verdict", artifact_path: relative(paths.fetch(:design_verdict_path)))
        changes << write_json(paths.fetch(:design_fidelity_path), design_fidelity, false)
        engine_run_event(paths.fetch(:events_path), events, "design.fidelity.checked", "checked selected design fidelity", status: design_fidelity.fetch("status"), selected_design_fidelity: design_fidelity["selected_design_fidelity"], artifact_path: relative(paths.fetch(:design_fidelity_path)))
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded design fidelity evidence", artifact_path: relative(paths.fetch(:design_fidelity_path)))
        design_fixture = engine_run_design_fixture(opendesign_contract, design_verdict, screenshot_evidence, paths)
        changes << write_json(paths.fetch(:design_fixture_path), design_fixture, false)
        engine_run_event(paths.fetch(:events_path), events, "design.fixture.recorded", "recorded design eval fixture baseline", artifact_path: relative(paths.fetch(:design_fixture_path)), fixture_id: design_fixture["fixture_id"])
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded design eval fixture", artifact_path: relative(paths.fetch(:design_fixture_path)))
        supply_chain_gate = engine_run_supply_chain_gate(policy: policy, workspace_dir: paths.fetch(:workspace_dir), manifest: stage.fetch(:manifest), paths: paths)
        if supply_chain_gate.fetch("status") == "blocked" && %w[passed no_changes].include?(final_status)
          policy["status"] = "blocked"
          policy["blocking_issues"].concat(supply_chain_gate.fetch("blocking_issues")).uniq!
          final_status = "failed"
        end
        policy["supply_chain_gate_status"] = supply_chain_gate["status"]
        policy["supply_chain_gate_artifact"] = relative(paths.fetch(:supply_chain_gate_path))
        engine_run_supply_chain_pending_artifacts(supply_chain_gate, paths).each do |artifact_path, artifact|
          changes << write_json(artifact_path, artifact, false)
          engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded pending supply-chain evidence", artifact_path: relative(artifact_path), status: artifact["status"], artifact_kind: artifact["artifact_kind"])
        end
        changes << write_json(paths.fetch(:supply_chain_gate_path), supply_chain_gate, false)
        engine_run_event(paths.fetch(:events_path), events, "supply_chain.gate.recorded", "recorded supply-chain approval gate", artifact_path: relative(paths.fetch(:supply_chain_gate_path)), status: supply_chain_gate["status"], package_request_count: supply_chain_gate.dig("package_install_requests", "items").to_a.length)
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded supply-chain approval gate", artifact_path: relative(paths.fetch(:supply_chain_gate_path)))
        eval_benchmark = engine_run_eval_benchmark(
          final_status: final_status,
          result: result,
          policy: policy,
          verification: verification,
          preview: preview,
          screenshot_evidence: screenshot_evidence,
          design_verdict: design_verdict,
          design_fixture: design_fixture,
          opendesign_contract: opendesign_contract,
          paths: paths,
          events: events
        )
        if engine_run_eval_benchmark_blocks?(eval_benchmark) && %w[passed no_changes].include?(final_status)
          policy["status"] = "blocked"
          policy["blocking_issues"].concat(eval_benchmark.fetch("blocking_issues")).uniq!
          final_status = "failed"
          eval_benchmark = engine_run_eval_benchmark(
            final_status: final_status,
            result: result,
            policy: policy,
            verification: verification,
            preview: preview,
            screenshot_evidence: screenshot_evidence,
            design_verdict: design_verdict,
            design_fixture: design_fixture,
            opendesign_contract: opendesign_contract,
            paths: paths,
            events: events
          )
        end
        policy["eval_benchmark_required"] = true
        policy["eval_benchmark_status"] = eval_benchmark["status"]
        policy["eval_benchmark_artifact"] = relative(paths.fetch(:eval_benchmark_path))
        changes << write_json(paths.fetch(:eval_benchmark_path), eval_benchmark, false)
        engine_run_event(paths.fetch(:events_path), events, "eval.benchmark.recorded", "recorded repeatable eval benchmark", artifact_path: relative(paths.fetch(:eval_benchmark_path)), status: eval_benchmark["status"], regression_gate_status: eval_benchmark.dig("regression_gate", "status"), human_calibration_status: eval_benchmark["human_calibration_status"])
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded eval benchmark", artifact_path: relative(paths.fetch(:eval_benchmark_path)))
        if quarantine && quarantine.fetch("status") == "quarantined"
          changes << write_json(paths.fetch(:quarantine_path), quarantine, false)
          engine_run_event(paths.fetch(:events_path), events, "run.quarantined", "quarantined engine run evidence after suspicious sandbox output", quarantine_path: relative(paths.fetch(:quarantine_path)), reasons: quarantine.fetch("reasons"))
          engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded quarantine evidence", artifact_path: relative(paths.fetch(:quarantine_path)))
        end
        Array(policy["requested_actions"]).each do |action|
          engine_run_event(paths.fetch(:events_path), events, "tool.action.requested", "sandbox worker requested elevated action", action: action)
          engine_run_event(paths.fetch(:events_path), events, "tool.action.blocked", "elevated action blocked pending explicit approval", action: action)
        end
        if final_status == "waiting_approval"
          engine_run_event(paths.fetch(:events_path), events, "approval.requested", "engine run requires elevated approval before copy-back", approval_issues: policy.fetch("approval_issues"), approval_changes: policy.fetch("approval_changes"), approval_requests: policy.fetch("approval_requests", []))
        end
        if final_status == "passed" || final_status == "no_changes"
          engine_run_apply_safe_changes(paths.fetch(:workspace_dir), policy.fetch("safe_changes"))
          changes.concat(policy.fetch("safe_changes"))
        end

        engine_run_update_graph_state!(
          run_graph,
          final_status: final_status,
          result: result,
          policy: policy,
          verification: verification,
          preview: preview,
          screenshot_evidence: screenshot_evidence,
          design_verdict: design_verdict,
          design_fidelity: design_fidelity,
          quarantine: quarantine
        )
        run_graph["cursor"] = {
          "node_id" => engine_run_graph_cursor_node(final_status),
          "state" => final_status,
          "attempt" => result.fetch(:cycles_completed)
        }
        engine_run_graph_scheduler_reconcile!(
          graph_scheduler_state,
          run_graph,
          graph_execution_plan,
          final_status: final_status,
          paths: paths,
          events_path: paths.fetch(:events_path),
          events: events
        )
        changes << write_json(paths.fetch(:graph_scheduler_state_path), graph_scheduler_state, false)
        engine_run_write_workspace_graph_scheduler_state(paths.fetch(:workspace_dir), graph_scheduler_state)
        checkpoint = engine_run_checkpoint(
          run_id: run_id,
          status: final_status,
          cycle: result.fetch(:cycles_completed),
          next_step: engine_run_checkpoint_next_step(final_status),
          workspace_path: paths.fetch(:workspace_dir),
          safe_changes: policy.fetch("safe_changes"),
          goal: capability.fetch("goal"),
          resume_from: resume,
          opendesign_contract: opendesign_contract,
          run_graph: run_graph,
          artifact_hashes: engine_run_checkpoint_artifact_hashes(paths)
        )
        changes << write_file(paths.fetch(:stdout_path), agent_run_redact_process_output(result.fetch(:stdout).to_s), false)
        changes << write_file(paths.fetch(:stderr_path), agent_run_redact_process_output(result.fetch(:stderr).to_s), false)
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded sandbox stdout log", artifact_path: relative(paths.fetch(:stdout_path)))
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded sandbox stderr log", artifact_path: relative(paths.fetch(:stderr_path)))
        changes << write_json(paths.fetch(:checkpoint_path), checkpoint, false)
        engine_run_event(paths.fetch(:events_path), events, "checkpoint.saved", "saved engine-run checkpoint", status: final_status, checkpoint_path: relative(paths.fetch(:checkpoint_path)))
        engine_run_event(paths.fetch(:events_path), events, "run.finished", "finished engine run", status: final_status)

        blocking_issues = (result.fetch(:blocking_issues) + policy.fetch("blocking_issues") + verification.fetch("blocking_issues") + preview.fetch("blocking_issues") + design_fidelity.fetch("blocking_issues") + design_fidelity.fetch("repair_issues") + design_verdict.fetch("blocking_issues") + Array(supply_chain_gate["blocking_issues"]) + Array(eval_benchmark["blocking_issues"])).uniq
        metadata = engine_run_metadata(
          run_id: run_id,
          status: final_status,
          mode: normalized_mode,
          agent: normalized_agent,
          sandbox: sandbox,
          approved: true,
          dry_run: false,
          goal: capability.fetch("goal"),
          capability: capability,
          approval_hash: expected_hash,
          paths: paths,
          started_at: started_at,
          finished_at: now,
          exit_code: result.fetch(:exit_code),
          events: events,
          checkpoint: checkpoint,
          staged_manifest_path: relative(paths.fetch(:manifest_path)),
          diff_path: relative(paths.fetch(:diff_path)),
          stdout_log: relative(paths.fetch(:stdout_path)),
          stderr_log: relative(paths.fetch(:stderr_path)),
          verification_path: relative(paths.fetch(:verification_path)),
          preview_path: relative(paths.fetch(:preview_path)),
          screenshot_evidence_path: relative(paths.fetch(:screenshot_evidence_path)),
          design_verdict_path: relative(paths.fetch(:design_verdict_path)),
          design_fidelity_path: relative(paths.fetch(:design_fidelity_path)),
          design_fixture_path: relative(paths.fetch(:design_fixture_path)),
          eval_benchmark_path: relative(paths.fetch(:eval_benchmark_path)),
          supply_chain_gate_path: relative(paths.fetch(:supply_chain_gate_path)),
          opendesign_contract_path: relative(paths.fetch(:opendesign_contract_path)),
          project_index_path: relative(paths.fetch(:project_index_path)),
          run_memory_path: relative(paths.fetch(:run_memory_path)),
          authz_enforcement_path: relative(paths.fetch(:authz_enforcement_path)),
          worker_adapter_registry_path: relative(paths.fetch(:worker_adapter_registry_path)),
          graph_execution_plan_path: relative(paths.fetch(:graph_execution_plan_path)),
          graph_scheduler_state_path: relative(paths.fetch(:graph_scheduler_state_path)),
          sandbox_preflight_path: relative(paths.fetch(:sandbox_preflight_path)),
          quarantine_path: quarantine && quarantine.fetch("status") == "quarantined" ? relative(paths.fetch(:quarantine_path)) : nil,
          agent_result_path: agent_result ? relative(paths.fetch(:agent_result_path)) : nil,
          run_graph: run_graph,
          graph_execution_plan: graph_execution_plan,
          graph_scheduler_state: graph_scheduler_state,
          tool_broker: tool_broker,
          sandbox_preflight: sandbox_preflight,
          copy_back_policy: policy,
          verification: verification,
          preview: preview,
          screenshot_evidence: screenshot_evidence,
          design_verdict: design_verdict,
          design_fidelity: design_fidelity,
          design_fixture: design_fixture,
          eval_benchmark: eval_benchmark,
          supply_chain_gate: supply_chain_gate,
          quarantine: quarantine,
          opendesign_contract: opendesign_contract,
          project_index: project_index,
          run_memory: run_memory,
          authz_enforcement: authz_enforcement,
          worker_adapter_registry: worker_adapter_registry,
          blocking_issues: blocking_issues
        )
        changes << write_json(paths.fetch(:metadata_path), metadata, false)
        changes << write_json(paths.fetch(:job_path), engine_run_job_record(run_id: run_id, status: final_status, started_at: started_at, finished_at: now, events_path: paths.fetch(:events_path)), false)

        state["implementation"]["latest_engine_run"] = relative(paths.fetch(:metadata_path))
        state["implementation"]["engine_run_status"] = final_status
        state["implementation"]["last_diff"] = relative(paths.fetch(:diff_path)) unless diff_patch.to_s.empty?
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)

        payload = engine_run_payload(
          state: state,
          metadata: metadata,
          changed_files: compact_changes(changes),
          planned_changes: [],
          action_taken: engine_run_action_taken(final_status),
          next_action: engine_run_next_action(metadata)
        )
        active_run_finish!(active_record, final_status)
        active_record = nil
      end
      payload
    ensure
      active_run_finish!(active_record, "failed") if active_record
    end

    def engine_run_dry_run_payload(state:, run_id:, normalized_mode:, normalized_agent:, sandbox:, approved:, capability:, expected_hash:, paths:, planned_changes:, resume:, opendesign_contract:, run_graph:, tool_broker:)
      dry_blockers = opendesign_contract.fetch("blocking_issues", [])
      dry_status = dry_blockers.empty? ? "dry_run" : "blocked"
      metadata = engine_run_metadata(
        run_id: run_id,
        status: dry_status,
        mode: normalized_mode,
        agent: normalized_agent,
        sandbox: sandbox,
        approved: approved,
        dry_run: true,
        goal: capability.fetch("goal"),
        capability: capability,
        approval_hash: expected_hash,
        paths: paths,
        events: engine_run_planned_events,
        checkpoint: engine_run_checkpoint(run_id: run_id, status: dry_status, cycle: 0, next_step: dry_status == "blocked" ? "select_design" : "await_approval", workspace_path: paths.fetch(:workspace_dir), goal: capability.fetch("goal"), resume_from: resume, opendesign_contract: opendesign_contract, run_graph: run_graph),
        run_graph: run_graph,
        tool_broker: tool_broker,
        opendesign_contract: opendesign_contract,
        blocking_issues: dry_blockers
      )
      engine_run_payload(
        state: state,
        metadata: metadata,
        changed_files: [],
        planned_changes: planned_changes,
        action_taken: dry_status == "blocked" ? "engine run blocked" : "planned engine run",
        next_action: dry_status == "blocked" ? "select a design candidate before running UI/source engine work" : "rerun aiweb engine-run --agent #{normalized_agent} --mode #{normalized_mode}#{engine_run_sandbox_suffix(normalized_agent, sandbox)} --approval-hash #{expected_hash} --approved to execute inside the staged sandbox"
      )
    end

    def engine_run_initial_blocked_payload(state:, run_id:, normalized_mode:, normalized_agent:, sandbox:, approved:, capability:, expected_hash:, paths:, resume:, opendesign_contract:, run_graph:, tool_broker:, blockers:)
      metadata = engine_run_metadata(
        run_id: run_id,
        status: "blocked",
        mode: normalized_mode,
        agent: normalized_agent,
        sandbox: sandbox,
        approved: approved,
        dry_run: false,
        goal: capability.fetch("goal"),
        capability: capability,
        approval_hash: expected_hash,
        paths: paths,
        events: [],
        checkpoint: engine_run_checkpoint(run_id: run_id, status: "blocked", cycle: 0, next_step: opendesign_contract.fetch("blocking_issues", []).empty? ? "resolve_blockers" : "select_design", workspace_path: paths.fetch(:workspace_dir), goal: capability.fetch("goal"), resume_from: resume, opendesign_contract: opendesign_contract, run_graph: run_graph),
        run_graph: run_graph,
        tool_broker: tool_broker,
        opendesign_contract: opendesign_contract,
        blocking_issues: blockers
      )
      engine_run_payload(
        state: state,
        metadata: metadata,
        changed_files: [],
        planned_changes: [],
        action_taken: "engine run blocked",
        next_action: "resolve engine-run blockers or inspect aiweb engine-run --dry-run"
      )
    end

    def engine_run_capability_envelope(run_id:, goal:, mode:, agent:, sandbox:, max_cycles:, resume:, opendesign_contract:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "goal" => goal,
        "constitution_hash" => Aiweb::Constitution::Loader.new.content_hash,
        "policy_kernel_version" => Aiweb::Tools::DecisionPacket::POLICY_KERNEL_VERSION,
        "mode" => mode,
        "agent" => agent,
        "sandbox" => sandbox,
        "resume_from" => resume,
        "opendesign_contract" => engine_run_capability_opendesign_contract(opendesign_contract),
        "writable_globs" => ENGINE_RUN_DEFAULT_WRITABLE_GLOBS,
        "allowed_tools" => mode == "agentic_local" ? %w[sandbox_shell build test preview local_qa screenshot] : %w[source_patch],
        "forbidden" => %w[env credentials external_network deploy provider_cli git_push host_root_write],
        "context_refs" => %w[project_index opendesign_contract worker_adapter_registry staged_manifest prior_evidence],
        "limits" => {
          "max_cycles" => max_cycles,
          "timeout_sec" => 600,
          "max_output_bytes" => 200_000
        },
        "worker_adapter" => engine_run_worker_adapter_contract(agent),
        "tool_broker" => engine_run_tool_broker_contract(mode),
        "authz_contract" => engine_run_authz_contract,
        "retention_redaction_policy" => engine_run_retention_redaction_policy,
        "copy_back" => {
          "requires_validation" => true,
          "secret_scan" => true,
          "risk_classifier" => true
        }
      }
    end

    def engine_run_local_backend_route_permissions
      {
        "view_status" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "view_workbench" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "view_console" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "view_runs" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "view_run" => %w[api_token project_path run_id tenant_claim project_claim user_claim role_acl audit_event],
        "view_events" => %w[api_token project_path run_id tenant_claim project_claim user_claim role_acl audit_event],
        "view_approvals" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "view_job_status" => %w[api_token project_path run_id tenant_claim project_claim user_claim role_acl audit_event],
        "view_job_timeline" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "view_job_summary" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "view_artifact" => %w[api_token project_path artifact_path tenant_claim project_claim user_claim role_acl audit_event],
        "command" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "codex_agent_run" => %w[api_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "run_start" => %w[api_token approval_token project_path tenant_claim project_claim user_claim role_acl audit_event],
        "approve" => %w[api_token approval_token project_path run_id capability_hash tenant_claim project_claim user_claim role_acl audit_event],
        "resume" => %w[api_token approval_token project_path run_id tenant_claim project_claim user_claim role_acl audit_event],
        "cancel" => %w[api_token approval_token project_path run_id tenant_claim project_claim user_claim role_acl audit_event],
        "copy_back" => %w[capability_hash safe_change_policy approval_record role_acl audit_event]
      }
    end

    def engine_run_local_backend_route_required_roles
      Aiweb::AuthzContract.copy(Aiweb::AuthzContract::AUTHZ_ACTION_REQUIRED_ROLES)
    end

    def engine_run_local_backend_artifact_acl_policy
      Aiweb::AuthzContract.copy(Aiweb::AuthzContract::ARTIFACT_ACL_POLICY)
    end

    def engine_run_authz_contract
      {
        "schema_version" => 1,
        "mode" => "local_project",
        "local_api_token_required" => true,
        "run_id_is_not_authority" => true,
        "saas_required_claims" => Aiweb::AuthzContract.copy(Aiweb::AuthzContract::REQUIRED_CLAIMS),
        "local_backend_claim_enforced_mode" => Aiweb::AuthzContract.local_backend_claim_enforced_mode(route_required_roles: engine_run_local_backend_route_required_roles),
        "permission_checks" => engine_run_local_backend_route_permissions.keys,
        "approval_scope_binds" => %w[approver_identity tenant_id project_id run_id capability_hash expiry single_use exact_capability],
        "tenant_scoped_artifacts" => %w[events artifacts screenshots logs diffs approvals checkpoints],
        "note" => "Local engine-run is project-scoped; a SaaS workbench must add tenant/project/user authz before exposing these APIs remotely."
      }
    end

    def engine_run_authz_enforcement(run_id:, mode:, agent:, sandbox:, approved:, paths:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "recorded_at" => now,
        "mode" => "local_project",
        "run_id_is_not_authority" => true,
        "project_scope" => {
          "project_root" => relative(root),
          "workspace_path" => relative(paths.fetch(:workspace_dir)),
          "run_dir" => relative(paths.fetch(:run_dir)),
          "artifact_scope" => relative(paths.fetch(:run_dir)),
          "diff_scope" => ".ai-web/diffs"
        },
        "local_backend_enforcement" => Aiweb::AuthzContract.local_backend_enforcement(route_required_roles: engine_run_local_backend_route_required_roles, route_permissions: engine_run_local_backend_route_permissions),
        "current_execution" => {
          "agent" => agent,
          "engine_mode" => mode,
          "sandbox" => sandbox,
          "approved_flag" => approved,
          "approval_scope" => "single_run_single_capability"
        },
        "saas_required_claims" => Aiweb::AuthzContract.copy(Aiweb::AuthzContract::REQUIRED_CLAIMS),
        "saas_claims_observed" => [],
        "remote_exposure_status" => "blocked_until_tenant_project_user_claims_are_enforced",
        "blocking_issues" => [
          "remote SaaS exposure requires tenant_id, project_id, and user_id authz enforcement outside local engine-run"
        ]
      }
    end

    def engine_run_retention_redaction_policy
      {
        "schema_version" => 1,
        "events" => {
          "append_only" => true,
          "tamper_evident_hash_chain" => true,
          "redaction_status" => "redacted_at_source"
        },
        "artifact_classes" => {
          "logs" => { "retention" => "project_local_until_user_deletes_run", "redaction" => "secret_patterns_and_env_paths" },
          "prompts" => { "retention" => "project_local_until_user_deletes_run", "redaction" => "no_raw_env_or_provider_credentials" },
          "screenshots" => { "retention" => "project_local_until_user_deletes_run", "redaction" => "local_preview_only_no_external_urls" },
          "dom_snapshots" => { "retention" => "project_local_until_user_deletes_run", "redaction" => "local_preview_only_secret_pattern_scan" },
          "diffs" => { "retention" => "project_local_until_user_deletes_run", "redaction" => "copy_back_secret_scan_before_acceptance" },
          "command_output" => { "retention" => "project_local_until_user_deletes_run", "redaction" => "agent_run_redact_process_output" }
        }
      }
    end

    def engine_run_approval_hash(capability)
      stable = capability.to_h.reject { |key, _value| key == "run_id" }
      Digest::SHA256.hexdigest(json_generate(stable))
    end

    def engine_run_tool_broker_contract(mode)
      {
        "schema_version" => 1,
        "mode" => mode,
        "event_flow" => %w[tool.requested policy.decision tool.started tool.finished tool.blocked],
        "request_fields" => %w[tool_name args working_dir capability_scope risk_class expected_outputs idempotency_key approval_hash],
        "deny_by_default" => %w[external_network package_install deploy provider_cli git_push mcp_connectors env_read host_root_write],
        "pre_guardrail" => true,
        "post_guardrail" => true,
        "side_effect_surface_audit" => side_effect_surface_audit,
        "runtime_broker_enforcement" => engine_run_runtime_broker_enforcement(selected_adapter: nil),
        "mcp_connectors" => {
          "default" => "denied_for_implementation_workers_except_approved_brokered_lazyweb_health_search_and_project_files_metadata_list",
          "known_brokered_design_research_driver" => "aiweb.lazyweb.side_effect_broker",
          "known_brokered_implementation_worker_driver" => "aiweb.implementation_mcp_broker",
          "elevated_approval_requires" => %w[mcp_server tool_names allowed_args_schema credential_source delegated_identity network_destinations output_redaction per_call_audit]
        }
      }
    end

    def engine_run_tool_request(tool_name, command, working_dir, capability, risk_class:, expected_outputs:)
      args = Array(command).map(&:to_s)
      idempotency_key = Digest::SHA256.hexdigest([tool_name, args.join("\0"), relative(working_dir), capability["goal"]].join("\0"))
      {
        "schema_version" => 1,
        "request_id" => "tool-#{idempotency_key[0, 16]}",
        "tool_name" => tool_name,
        "args" => args,
        "working_dir" => relative(working_dir),
        "capability_scope" => capability["mode"],
        "risk_class" => risk_class,
        "expected_outputs" => expected_outputs,
        "idempotency_key" => idempotency_key,
        "trace_span_id" => "span-tool-#{idempotency_key[0, 16]}",
        "approval_hash" => engine_run_approval_hash(capability)
      }
    end

    def engine_run_approval_record(run_id:, capability:, approval_hash:, approved:, scope:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "scope" => scope,
        "status" => approved ? "approved" : "planned",
        "approved_at" => approved ? now : nil,
        "approval_hash" => approval_hash,
        "capability_hash" => approval_hash,
        "single_use" => true,
        "capability" => capability
      }
    end

    def engine_run_checkpoint(run_id:, status:, cycle:, next_step:, workspace_path:, safe_changes: [], goal: nil, resume_from: nil, opendesign_contract: nil, run_graph: nil, artifact_hashes: nil)
      record = {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "cycle" => cycle,
        "next_step" => next_step,
        "workspace_path" => relative(workspace_path),
        "safe_changes" => safe_changes,
        "saved_at" => now
      }
      record["goal"] = goal unless goal.to_s.strip.empty?
      record["resume_from"] = resume_from unless resume_from.to_s.strip.empty?
      record["opendesign_contract"] = engine_run_checkpoint_opendesign_contract(opendesign_contract) if opendesign_contract
      record["artifact_hashes"] = artifact_hashes.is_a?(Hash) ? artifact_hashes : {}
      if run_graph
        record["run_graph_cursor"] = run_graph["cursor"]
        record["run_graph"] = run_graph.slice("schema_version", "run_id", "constitution_hash", "agent_os_goal_runtime_nodes", "nodes", "executor_contract", "resume_policy", "side_effects_must_use_tool_broker")
      end
      record
    end

    def engine_run_checkpoint_artifact_hashes(paths)
      {
        "staged_manifest" => paths.fetch(:manifest_path),
        "graph_execution_plan" => paths.fetch(:graph_execution_plan_path),
        "graph_scheduler_state" => paths.fetch(:graph_scheduler_state_path),
        "opendesign_contract" => paths.fetch(:opendesign_contract_path),
        "project_index" => paths.fetch(:project_index_path),
        "run_memory" => paths.fetch(:run_memory_path),
        "authz_enforcement" => paths.fetch(:authz_enforcement_path),
        "worker_adapter_registry" => paths.fetch(:worker_adapter_registry_path),
        "sandbox_preflight" => paths.fetch(:sandbox_preflight_path),
        "supply_chain_gate" => paths.fetch(:supply_chain_gate_path),
        "supply_chain_sbom" => paths.fetch(:supply_chain_sbom_path),
        "supply_chain_audit" => paths.fetch(:supply_chain_audit_path),
        "verification" => paths.fetch(:verification_path),
        "preview" => paths.fetch(:preview_path),
        "browser_evidence" => paths.fetch(:screenshot_evidence_path),
        "design_verdict" => paths.fetch(:design_verdict_path),
        "design_fidelity" => paths.fetch(:design_fidelity_path),
        "design_fixture" => paths.fetch(:design_fixture_path),
        "eval_benchmark" => paths.fetch(:eval_benchmark_path),
        "quarantine" => paths.fetch(:quarantine_path),
        "diff" => paths.fetch(:diff_path)
      }.each_with_object({}) do |(name, path), memo|
        next unless File.file?(path)

        memo[name] = {
          "path" => relative(path),
          "sha256" => "sha256:#{Digest::SHA256.file(path).hexdigest}",
          "bytes" => File.size(path)
        }
      end
    end

    def engine_run_mode_blockers(mode, agent, sandbox, workspace_dir)
      blockers = []
      if mode == "external_approval"
        blockers << "external_approval mode is a capability escalation record only; package install, network, deploy, provider CLI, and git push require a dedicated approved command"
      end
      if agent == "codex"
        if mode == "agentic_local"
          blockers << "unsandboxed codex is not allowed for real agentic_local engine-run; use --mode safe_patch or run a sandboxed OpenManus worker with --agent openmanus --sandbox docker|podman"
        end
        blockers << "codex executable is missing from PATH" unless executable_path("codex")
      elsif engine_run_container_worker_agent?(agent)
        blockers << "engine-run #{agent} requires --sandbox docker or --sandbox podman" if sandbox.to_s.strip.empty?
        blockers << "engine-run --sandbox must be docker or podman" unless sandbox.to_s.strip.empty? || %w[docker podman].include?(sandbox.to_s)
        blockers << "#{sandbox} executable is missing from PATH" if !sandbox.to_s.strip.empty? && executable_path(sandbox.to_s).nil?
        if !sandbox.to_s.strip.empty? && executable_path(sandbox.to_s)
          command = engine_run_agent_container_command(agent, sandbox.to_s, workspace_dir)
          blockers.concat(engine_run_agent_sandbox_command_blockers(agent, command, sandbox: sandbox.to_s, workspace_dir: workspace_dir))
          blockers.concat(engine_run_agent_image_blockers(agent, sandbox.to_s))
        end
      end
      blockers
    end


    def engine_run_safe_patch(state:, capability:, normalized_agent:, sandbox:, approved:, dry_run:)
      if approved && !dry_run
        preflight = agent_run(task: "latest", agent: normalized_agent, sandbox: sandbox, approved: false, dry_run: true)
        unless preflight.dig("agent_run", "status") == "planned"
          preflight["engine_run"] = {
            "schema_version" => 1,
            "status" => preflight.dig("agent_run", "status"),
            "mode" => "safe_patch",
            "agent" => normalized_agent,
            "capability" => capability,
            "delegated_to" => "agent-run",
            "blocking_issues" => preflight["blocking_issues"] || []
          }
          return preflight
        end
        delegated_hash = preflight.dig("agent_run", "approval_hash")
        return agent_run(task: "latest", agent: normalized_agent, sandbox: sandbox, approved: approved, approval_hash: delegated_hash, dry_run: false).tap do |result|
          result["engine_run"] = {
            "schema_version" => 1,
            "status" => result.dig("agent_run", "status"),
            "mode" => "safe_patch",
            "agent" => normalized_agent,
            "capability" => capability,
            "delegated_to" => "agent-run",
            "delegated_approval_hash" => delegated_hash,
            "blocking_issues" => result["blocking_issues"] || []
          }
        end
      end

      agent_run(task: "latest", agent: normalized_agent, sandbox: sandbox, approved: approved, dry_run: dry_run).tap do |result|
        result["engine_run"] = {
          "schema_version" => 1,
          "status" => result.dig("agent_run", "status"),
          "mode" => "safe_patch",
          "agent" => normalized_agent,
          "capability" => capability,
          "delegated_to" => "agent-run",
          "blocking_issues" => result["blocking_issues"] || []
        }
      end
    end

    def engine_run_initial_execution_blockers(approved:, approval_hash:, expected_hash:, opendesign_contract:, normalized_mode:, normalized_agent:, sandbox:, workspace_dir:, resume:, resume_context:)
      blockers = []
      blockers << "--approved is required for real engine-run execution" unless approved
      if approved && approval_hash.to_s.strip.empty?
        blockers << "--approval-hash is required for real engine-run execution"
      elsif !approval_hash.to_s.strip.empty? && approval_hash.to_s.strip != expected_hash
        blockers << "approval hash does not match the current capability envelope"
      end
      blockers.concat(opendesign_contract.fetch("blocking_issues", []))
      blockers.concat(engine_run_mode_blockers(normalized_mode, normalized_agent, sandbox, workspace_dir))
      if resume && !resume_context
        blockers << "engine-run resume target has no readable checkpoint: #{resume}"
      elsif resume_context
        blockers.concat(engine_run_resume_blockers(resume_context))
      end
      blockers
    end





  end
end
