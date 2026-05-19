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

module Aiweb
  module ProjectEngineRun
    include ProjectEngineRunGeneratedSources
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

        changes << write_file(paths.fetch(:approval_path), JSON.generate(engine_run_approval_record(run_id: run_id, capability: capability, approval_hash: expected_hash, approved: approved, scope: "execute")) + "\n", false)
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

    def engine_run_agent(value)
      text = value.to_s.strip.empty? ? "codex" : value.to_s.strip
      raise UserError.new("engine-run --agent must be codex, openmanus, openhands, langgraph, or openai_agents_sdk", 1) unless ENGINE_RUN_AGENTS.include?(text)

      text
    end

    def engine_run_mode(value)
      text = value.to_s.strip.empty? ? "agentic_local" : value.to_s.strip.tr("-", "_")
      raise UserError.new("engine-run --mode must be safe_patch, agentic_local, or external_approval", 1) unless ENGINE_RUN_MODES.include?(text)

      text
    end

    def engine_run_cycle_limit(value)
      number = value.to_i
      number = 3 unless number.positive?
      [number, 10].min
    end

    def engine_run_requested_run_id(value, resume:, timestamp:)
      text = value.to_s.strip
      unless text.empty?
        safe = validate_run_id!(text)
        unless safe.match?(/\Aengine-run-[A-Za-z0-9_.-]+\z/)
          raise UserError.new("engine-run --run-id must start with engine-run- and contain only letters, numbers, dot, underscore, or dash", 1)
        end
        return safe
      end

      resume.to_s.strip.empty? ? "engine-run-#{timestamp}" : "engine-run-resume-#{timestamp}"
    end

    def engine_run_goal(goal, state, resume, resume_context = nil)
      text = goal.to_s.strip
      return text unless text.empty?
      if resume
        checkpoint = resume_context ? resume_context.fetch(:checkpoint) : engine_run_resume_checkpoint(resume)
        return checkpoint["goal"].to_s unless checkpoint.to_h["goal"].to_s.empty?
        metadata = resume_context && resume_context[:metadata]
        return metadata["goal"].to_s unless metadata.to_h["goal"].to_s.empty?
      end
      state.dig("project", "idea").to_s.strip.empty? ? "complete the current web-building task autonomously inside the sandbox" : state.dig("project", "idea").to_s
    end

    def engine_run_paths(run_id, run_dir)
      {
        run_id: run_id,
        run_dir: run_dir,
        metadata_path: File.join(run_dir, "engine-run.json"),
        job_path: File.join(run_dir, "job.json"),
        events_path: File.join(run_dir, "events.jsonl"),
        approval_path: File.join(run_dir, "approvals.jsonl"),
        checkpoint_path: File.join(run_dir, "checkpoint.json"),
        stdout_path: File.join(run_dir, "logs", "stdout.log"),
        stderr_path: File.join(run_dir, "logs", "stderr.log"),
        diff_path: File.join(aiweb_dir, "diffs", "#{run_id}.patch"),
        manifest_path: File.join(run_dir, "artifacts", "staged-manifest.json"),
        graph_execution_plan_path: File.join(run_dir, "artifacts", "graph-execution-plan.json"),
        graph_scheduler_state_path: File.join(run_dir, "artifacts", "graph-scheduler-state.json"),
        opendesign_contract_path: File.join(run_dir, "artifacts", "opendesign-contract.json"),
        project_index_path: File.join(run_dir, "artifacts", "project-index.json"),
        run_memory_path: File.join(run_dir, "artifacts", "run-memory.json"),
        authz_enforcement_path: File.join(run_dir, "artifacts", "authz-enforcement.json"),
        worker_adapter_registry_path: File.join(run_dir, "artifacts", "worker-adapter-registry.json"),
        worker_adapter_contract_path: File.join(run_dir, "artifacts", "worker-adapter-contract.json"),
        agent_result_path: File.join(run_dir, "artifacts", "agent-result.json"),
        sandbox_preflight_path: File.join(run_dir, "artifacts", "sandbox-preflight.json"),
        supply_chain_gate_path: File.join(run_dir, "artifacts", "supply-chain-gate.json"),
        supply_chain_sbom_path: File.join(run_dir, "artifacts", "sbom.json"),
        supply_chain_audit_path: File.join(run_dir, "artifacts", "package-audit.json"),
        quarantine_path: File.join(run_dir, "artifacts", "quarantine.json"),
        verification_path: File.join(run_dir, "qa", "verification.json"),
        preview_path: File.join(run_dir, "qa", "preview.json"),
        screenshot_evidence_path: File.join(run_dir, "qa", "screenshots.json"),
        design_verdict_path: File.join(run_dir, "qa", "design-verdict.json"),
        design_fidelity_path: File.join(run_dir, "qa", "design-fidelity.json"),
        design_fixture_path: File.join(run_dir, "qa", "design-fixture.json"),
        eval_benchmark_path: File.join(run_dir, "qa", "eval-benchmark.json"),
        workspace_dir: File.join(aiweb_dir, "tmp", "agentic", run_id, "workspace"),
        artifacts_dir: File.join(run_dir, "artifacts"),
        logs_dir: File.join(run_dir, "logs"),
        qa_dir: File.join(run_dir, "qa"),
        screenshots_dir: File.join(run_dir, "screenshots")
      }
    end

    def engine_run_artifact_dirs(paths)
      [paths.fetch(:artifacts_dir), paths.fetch(:logs_dir), paths.fetch(:qa_dir), paths.fetch(:screenshots_dir), File.dirname(paths.fetch(:diff_path))]
    end

    def engine_run_planned_changes(paths)
      [
        relative(paths.fetch(:run_dir)),
        relative(paths.fetch(:metadata_path)),
        relative(paths.fetch(:job_path)),
        relative(paths.fetch(:events_path)),
        relative(paths.fetch(:approval_path)),
        relative(paths.fetch(:checkpoint_path)),
        relative(paths.fetch(:manifest_path)),
        relative(paths.fetch(:graph_execution_plan_path)),
        relative(paths.fetch(:graph_scheduler_state_path)),
        relative(paths.fetch(:opendesign_contract_path)),
        relative(paths.fetch(:project_index_path)),
        relative(paths.fetch(:run_memory_path)),
        relative(paths.fetch(:authz_enforcement_path)),
        relative(paths.fetch(:worker_adapter_registry_path)),
        relative(paths.fetch(:worker_adapter_contract_path)),
        relative(paths.fetch(:agent_result_path)),
        relative(paths.fetch(:sandbox_preflight_path)),
        relative(paths.fetch(:supply_chain_gate_path)),
        relative(paths.fetch(:supply_chain_sbom_path)),
        relative(paths.fetch(:supply_chain_audit_path)),
        relative(paths.fetch(:quarantine_path)),
        relative(paths.fetch(:verification_path)),
        relative(paths.fetch(:preview_path)),
        relative(paths.fetch(:screenshot_evidence_path)),
        relative(paths.fetch(:design_verdict_path)),
        relative(paths.fetch(:design_fidelity_path)),
        relative(paths.fetch(:design_fixture_path)),
        relative(paths.fetch(:eval_benchmark_path)),
        relative(paths.fetch(:diff_path)),
        relative(paths.fetch(:workspace_dir))
      ]
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
      Digest::SHA256.hexdigest(JSON.generate(stable))
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

    def engine_run_sandbox_runtime_matrix_evidence(agent:, selected_sandbox:, workspace_dir:, selected_runtime_info:, selected_inside_probe:, selected_image_inspect:)
      unless engine_run_container_worker_agent?(agent) && !selected_sandbox.to_s.strip.empty?
        return {
          "schema_version" => 1,
          "status" => "skipped",
          "required" => false,
          "policy_source" => [],
          "selected_runtime" => nil,
          "requested_runtimes" => [],
          "entries" => [],
          "blocking_issues" => [],
          "reason" => "missing_sandbox_or_non_container_agent"
        }
      end

      requested = engine_run_required_sandbox_runtime_matrix
      policy_sources = engine_run_required_sandbox_runtime_matrix_policy_sources
      invalid_requested = engine_run_invalid_sandbox_runtime_matrix
      required = !policy_sources.empty?
      runtimes = (required && !requested.empty? ? requested : [selected_sandbox.to_s]).uniq
      entries = runtimes.map do |runtime|
        engine_run_sandbox_runtime_matrix_entry(
          runtime: runtime,
          selected_sandbox: selected_sandbox.to_s,
          workspace_dir: workspace_dir,
          selected_runtime_info: selected_runtime_info,
          selected_inside_probe: selected_inside_probe,
          selected_image_inspect: selected_image_inspect,
          agent: agent
        )
      end
      blockers = entries.flat_map do |entry|
        entry.fetch("blocking_issues", []).map { |issue| "#{entry.fetch("runtime")} runtime matrix: #{issue}" }
      end.uniq
      invalid_requested.each do |runtime|
        blockers << "unsupported runtime matrix entry: #{runtime.inspect}; expected docker or podman"
      end
      blockers << "runtime matrix policy configured but no valid runtimes were requested" if required && requested.empty?
      {
        "schema_version" => 1,
        "status" => blockers.empty? ? "passed" : (required ? "failed" : "partial"),
        "required" => required,
        "policy_source" => policy_sources,
        "selected_runtime" => selected_sandbox.to_s,
        "requested_runtimes" => requested,
        "invalid_requested_runtimes" => invalid_requested,
        "entries" => entries,
        "blocking_issues" => blockers
      }
    end

    def engine_run_sandbox_runtime_matrix_entry(runtime:, selected_sandbox:, workspace_dir:, selected_runtime_info:, selected_inside_probe:, selected_image_inspect:, agent: "openmanus")
      image = engine_run_agent_container_image(agent)
      command = executable_path(runtime) ? engine_run_agent_container_command(agent, runtime, workspace_dir) : []
      command_blockers = executable_path(runtime) ? engine_run_agent_sandbox_command_blockers(agent, command, sandbox: runtime, workspace_dir: workspace_dir) : ["#{runtime} executable is missing from PATH"]
      image_inspect = runtime == selected_sandbox ? selected_image_inspect : engine_run_container_image_inspect(runtime, image)
      runtime_info = runtime == selected_sandbox ? selected_runtime_info : engine_run_sandbox_runtime_info(runtime)
      inside_probe = if command_blockers.empty?
                       runtime == selected_sandbox ? selected_inside_probe : engine_run_sandbox_self_attestation_probe(agent: agent, sandbox: runtime, workspace_dir: workspace_dir)
                     else
                       engine_run_failed_sandbox_self_attestation(reason: "runtime_matrix_command_blocked")
                     end
      inspect = inside_probe["runtime_container_inspect"] || { "status" => "not_observed", "reason" => "runtime_matrix_missing_container_inspect" }
      security = inside_probe["security_attestation"] || engine_run_failed_security_attestation("runtime_matrix_missing_security_attestation")
      egress = inside_probe["egress_denial_probe"] || engine_run_failed_egress_denial_probe("runtime_matrix_missing_egress_denial_probe")
      effective_user = inside_probe["effective_user"]

      blockers = []
      blockers.concat(command_blockers)
      blockers << "image inspect did not pass" unless image_inspect.fetch("status", "failed") == "passed"
      blockers << "runtime info did not pass" unless runtime_info.fetch("status", "failed") == "passed"
      blockers << "inside-container self-attestation did not pass" unless inside_probe.fetch("status", "failed") == "passed"
      blockers << "inside-container security attestation did not pass" unless security.fetch("status", "failed") == "passed"
      blockers << "inside-container egress denial did not pass" unless egress.fetch("status", "failed") == "passed"
      blockers << "runtime container inspect did not pass" unless inspect.fetch("status", "failed") == "passed"
      if effective_user.is_a?(Hash)
        blockers << "effective user id was not observed" if effective_user["uid"].nil?
        blockers << "effective user is root" if effective_user["uid"].to_i == 0
      else
        blockers << "effective user id was not observed"
      end

      {
        "runtime" => runtime,
        "status" => blockers.empty? ? "passed" : "failed",
        "command" => command,
        "resolved_executable_path" => executable_path(runtime),
        "image_inspect" => image_inspect,
        "runtime_info" => runtime_info,
        "inside_container_probe_status" => inside_probe["status"],
        "runtime_container_id" => inside_probe["runtime_container_id"],
        "runtime_container_inspect" => inspect,
        "security_attestation" => security,
        "egress_denial_probe" => egress,
        "effective_user" => effective_user,
        "blocking_issues" => blockers.uniq
      }
    end

    def engine_run_sandbox_self_attestation_probe(agent:, sandbox:, workspace_dir:)
      return { "schema_version" => 1, "status" => "skipped", "reason" => "missing_sandbox_or_non_container_agent" } unless engine_run_container_worker_agent?(agent) && !sandbox.to_s.strip.empty?

      FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb", "home"))
      FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb", "tmp"))
      script = <<~'SH'
        if command -v python3 >/dev/null 2>&1; then PY=python3; elif command -v python >/dev/null 2>&1; then PY=python; else echo '{"schema_version":1,"status":"not_observed","reason":"python_unavailable"}'; exit 0; fi
        "$PY" - <<'PY'
        import getpass, json, os, socket

        def write_probe(path, content):
            try:
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(content)
                try:
                    os.remove(path)
                except OSError:
                    pass
                return True
            except OSError:
                return False

        def root_write_blocked():
            path = "/aiweb-root-write-probe"
            try:
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write("probe")
                try:
                    os.remove(path)
                except OSError:
                    pass
                return False
            except OSError:
                return True

        def read_text(path, limit=12000):
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as handle:
                    return handle.read(limit)
            except OSError:
                return ""

        def proc_status_fields():
            fields = {}
            for line in read_text("/proc/self/status").splitlines():
                if ":" not in line:
                    continue
                key, value = line.split(":", 1)
                if key in ["NoNewPrivs", "Seccomp", "Seccomp_filters", "CapEff", "CapPrm", "CapBnd"]:
                    fields[key] = value.strip()
            no_new_privs = fields.get("NoNewPrivs") == "1"
            seccomp_filtering = fields.get("Seccomp") in ["2", "1"]
            cap_eff = fields.get("CapEff", "")
            try:
                cap_eff_zero = int(cap_eff, 16) == 0
            except ValueError:
                cap_eff_zero = False
            status = "passed" if no_new_privs and seccomp_filtering and cap_eff_zero else "failed"
            return {
                "status": status,
                "source": "/proc/self/status",
                "no_new_privs": fields.get("NoNewPrivs"),
                "no_new_privs_enabled": no_new_privs,
                "seccomp": fields.get("Seccomp"),
                "seccomp_filtering": seccomp_filtering,
                "seccomp_filters": fields.get("Seccomp_filters"),
                "cap_eff": cap_eff,
                "cap_eff_zero": cap_eff_zero,
                "cap_prm": fields.get("CapPrm"),
                "cap_bnd": fields.get("CapBnd")
            }

        egress = {
            "status": "not_observed",
            "method": "inside_container_python_socket_connect_93_184_216_34_80",
            "target": "93.184.216.34:80"
        }
        try:
            socket.create_connection(("93.184.216.34", 80), timeout=2).close()
            egress.update({"status": "failed", "observed": "unexpected_connect"})
        except OSError as error:
            egress.update({"status": "passed", "observed": "connection_denied", "error_class": error.__class__.__name__, "error": str(error)[:160]})

        env_guards = {
            key: os.environ.get(key)
            for key in ["AIWEB_NETWORK_ALLOWED", "AIWEB_MCP_ALLOWED", "AIWEB_ENV_ACCESS_ALLOWED", "AIWEB_ENGINE_RUN_TOOL"]
        }
        uid = os.getuid() if hasattr(os, "getuid") else None
        gid = os.getgid() if hasattr(os, "getgid") else None
        try:
            user_name = getpass.getuser()
        except Exception:
            user_name = str(uid) if uid is not None else None
        security = proc_status_fields()
        cgroup_lines = read_text("/proc/self/cgroup", 4000).splitlines()[:20]
        mountinfo_lines = read_text("/proc/self/mountinfo", 8000).splitlines()[:40]
        workspace_writable = write_probe("/workspace/_aiweb/self-attestation-write-probe", "ok")
        root_blocked = root_write_blocked()
        probe = {
            "schema_version": 1,
            "status": "passed" if egress["status"] == "passed" and workspace_writable and root_blocked and security["status"] == "passed" else "failed",
            "container_id": socket.gethostname(),
            "effective_user": {
                "uid": uid,
                "gid": gid,
                "name": user_name
            },
            "cwd": os.getcwd(),
            "home": os.environ.get("HOME"),
            "env_guards": env_guards,
            "workspace_writable": workspace_writable,
            "root_filesystem_write_blocked": root_blocked,
            "security_attestation": security,
            "cgroup": {
                "source": "/proc/self/cgroup",
                "lines": cgroup_lines
            },
            "mountinfo_excerpt": {
                "source": "/proc/self/mountinfo",
                "lines": mountinfo_lines
            },
            "egress_denial_probe": egress
        }
        print(json.dumps(probe, sort_keys=True))
        PY
      SH
      cidfile = File.join(workspace_dir, "_aiweb", "sandbox-preflight.cid")
      FileUtils.rm_f(cidfile)
      command = engine_run_sandbox_tool_command(sandbox, workspace_dir, ["sh", "-lc", script], tool: "sandbox_preflight_probe", agent: agent)
      command = engine_run_preflight_probe_command(command, cidfile)
      stdout, stderr, status = engine_run_capture_command(command, workspace_dir, 30, env: engine_run_clean_env(workspace_dir, { events_path: File.join(workspace_dir, "_aiweb", "preflight-events.jsonl") }, sandbox))
      runtime_container_id = File.file?(cidfile) ? File.read(cidfile, 512).to_s.strip : nil
      runtime_container_inspect = runtime_container_id.to_s.empty? ? { "status" => "not_observed", "reason" => "cidfile was not written" } : engine_run_runtime_container_inspect(sandbox, runtime_container_id, expected_workspace_dir: workspace_dir)
      engine_run_remove_runtime_container(sandbox, runtime_container_id) unless runtime_container_id.to_s.empty?
      unless status == 0
        return engine_run_failed_sandbox_self_attestation(
          reason: "self_attestation_probe_command_failed",
          runtime_container_id: runtime_container_id,
          runtime_container_inspect: runtime_container_inspect,
          exit_code: status,
          stderr: stderr
        )
      end

      parsed = JSON.parse(stdout.to_s)
      unless parsed.is_a?(Hash)
        return engine_run_failed_sandbox_self_attestation(
          reason: "self_attestation_probe_output_not_object",
          runtime_container_id: runtime_container_id,
          runtime_container_inspect: runtime_container_inspect
        )
      end
      parsed["schema_version"] ||= 1
      parsed["runtime_container_id"] = runtime_container_id unless runtime_container_id.to_s.empty?
      parsed["runtime_container_inspect"] = runtime_container_inspect
      parsed["effective_user"] = { "uid" => nil, "gid" => nil, "name" => nil } unless parsed["effective_user"].is_a?(Hash)
      parsed["security_attestation"] = engine_run_failed_security_attestation("self_attestation_probe_missing_security_attestation") unless parsed["security_attestation"].is_a?(Hash)
      parsed["egress_denial_probe"] = engine_run_failed_egress_denial_probe("self_attestation_probe_missing_egress_denial_probe") unless parsed["egress_denial_probe"].is_a?(Hash)
      parsed
    rescue JSON::ParserError
      engine_run_failed_sandbox_self_attestation(reason: "self_attestation_probe_output_parse_failed", runtime_container_id: runtime_container_id, runtime_container_inspect: runtime_container_inspect)
    rescue SystemCallError => e
      engine_run_failed_sandbox_self_attestation(reason: e.message, runtime_container_id: runtime_container_id, runtime_container_inspect: runtime_container_inspect)
    end

    def engine_run_failed_sandbox_self_attestation(reason:, runtime_container_id: nil, runtime_container_inspect: nil, exit_code: nil, stderr: nil)
      record = {
        "schema_version" => 1,
        "status" => "failed",
        "reason" => reason.to_s,
        "runtime_container_id" => runtime_container_id,
        "container_id" => nil,
        "effective_user" => {
          "uid" => nil,
          "gid" => nil,
          "name" => nil
        },
        "env_guards" => {},
        "workspace_writable" => false,
        "root_filesystem_write_blocked" => false,
        "security_attestation" => engine_run_failed_security_attestation(reason),
        "cgroup" => {
          "source" => "/proc/self/cgroup",
          "lines" => []
        },
        "mountinfo_excerpt" => {
          "source" => "/proc/self/mountinfo",
          "lines" => []
        },
        "egress_denial_probe" => engine_run_failed_egress_denial_probe(reason),
        "runtime_container_inspect" => runtime_container_inspect || { "status" => "not_observed", "reason" => "runtime container id was not observed" }
      }
      record["exit_code"] = exit_code if exit_code
      record["stderr"] = agent_run_redact_process_output(stderr.to_s)[0, 1000] unless stderr.to_s.empty?
      record
    end

    def engine_run_failed_security_attestation(reason = "security_attestation_not_observed")
      {
        "status" => "failed",
        "source" => "/proc/self/status",
        "reason" => reason.to_s,
        "no_new_privs" => nil,
        "no_new_privs_enabled" => false,
        "seccomp" => nil,
        "seccomp_filtering" => false,
        "seccomp_filters" => nil,
        "cap_eff" => nil,
        "cap_eff_zero" => false,
        "cap_prm" => nil,
        "cap_bnd" => nil
      }
    end

    def engine_run_not_observed_security_attestation(reason = "security_attestation_not_observed")
      engine_run_failed_security_attestation(reason).merge(
        "status" => "not_observed",
        "no_new_privs_enabled" => false,
        "seccomp_filtering" => false,
        "cap_eff_zero" => false
      )
    end

    def engine_run_failed_egress_denial_probe(reason = "egress_denial_probe_not_observed")
      {
        "status" => "failed",
        "method" => "inside_container_socket_probe",
        "observed" => reason.to_s
      }
    end

    def engine_run_safe_patch(state:, capability:, normalized_agent:, sandbox:, approved:, dry_run:)
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

    def engine_run_stage_workspace(workspace_dir, events_path:, events:)
      raise UserError.new("engine-run workspace already exists and will not be reused: #{relative(workspace_dir)}", 5) if File.exist?(workspace_dir) || File.symlink?(workspace_dir)

      base_dir = File.dirname(workspace_dir)
      FileUtils.mkdir_p(base_dir)
      Dir.mkdir(workspace_dir)
      manifest = {
        "schema_version" => 1,
        "workspace_root" => relative(workspace_dir),
        "created_at" => now,
        "files" => {},
        "excluded" => []
      }
      engine_run_event(events_path, events, "preflight.started", "staging filtered project workspace")

      Find.find(root) do |path|
        rel = relative(path).tr("\\", "/")
        next if rel.empty? || rel == "."

        if File.directory?(path)
          if engine_run_stage_excluded?(rel)
            manifest["excluded"] << rel
            Find.prune
          end
          next
        end

        if engine_run_stage_excluded?(rel) || engine_run_secret_surface_path?(rel) || File.symlink?(path)
          manifest["excluded"] << rel
          next
        end
        if File.file?(path) && File.lstat(path).nlink.to_i > 1
          manifest["excluded"] << rel
          next
        end
        next unless File.file?(path)

        target = File.join(workspace_dir, rel)
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(path, target)
        manifest["files"][rel] = {
          "sha256" => Digest::SHA256.file(path).hexdigest,
          "bytes" => File.size(path)
        }
      end
      engine_run_event(events_path, events, "preflight.finished", "staged filtered project workspace", file_count: manifest.fetch("files").length, excluded_count: manifest.fetch("excluded").length)
      { manifest: manifest }
    rescue SystemCallError => e
      raise UserError.new("engine-run staging failed: #{e.message}", 1)
    end

    def engine_run_prepare_workspace_tool_broker(workspace_dir)
      bin_dir = File.join(workspace_dir, "_aiweb", "tool-broker-bin")
      events_path = engine_run_tool_broker_events_path(workspace_dir)
      FileUtils.mkdir_p(bin_dir)
      FileUtils.mkdir_p(File.dirname(events_path))
      engine_run_tool_broker_blocking_shims.each do |name, config|
        path = File.join(bin_dir, name)
        File.write(path, engine_run_tool_broker_shim_source(name, config))
        FileUtils.chmod("+x", path)
      end
      { bin_dir: bin_dir, events_path: events_path }
    end

    def engine_run_tool_broker_events_path(workspace_dir)
      File.join(workspace_dir, "_aiweb", "tool-broker-events.jsonl")
    end

    def engine_run_tool_broker_blocking_shims
      {
        "npm" => { "risk" => "package_install", "mode" => "package_manager", "reason" => "Package installation requires explicit approval" },
        "pnpm" => { "risk" => "package_install", "mode" => "package_manager", "reason" => "Package installation requires explicit approval" },
        "yarn" => { "risk" => "package_install", "mode" => "package_manager", "reason" => "Package installation requires explicit approval" },
        "bun" => { "risk" => "package_install", "mode" => "package_manager", "reason" => "Package installation requires explicit approval" },
        "curl" => { "risk" => "external_network", "mode" => "always_block", "reason" => "External network access requires explicit approval" },
        "wget" => { "risk" => "external_network", "mode" => "always_block", "reason" => "External network access requires explicit approval" },
        "git" => { "risk" => "git_push", "mode" => "git", "reason" => "git push requires explicit approval" },
        "vercel" => { "risk" => "deploy", "mode" => "always_block", "reason" => "Deploy/provider CLI execution requires explicit approval" },
        "netlify" => { "risk" => "deploy", "mode" => "always_block", "reason" => "Deploy/provider CLI execution requires explicit approval" },
        "wrangler" => { "risk" => "deploy", "mode" => "always_block", "reason" => "Deploy/provider CLI execution requires explicit approval" },
        "cloudflare" => { "risk" => "deploy", "mode" => "always_block", "reason" => "Deploy/provider CLI execution requires explicit approval" },
        "env" => { "risk" => "env_read", "mode" => "always_block", "reason" => "Raw environment reads require explicit approval" },
        "printenv" => { "risk" => "env_read", "mode" => "always_block", "reason" => "Raw environment reads require explicit approval" }
      }
    end

    def engine_run_tool_broker_event_count(workspace_dir)
      engine_run_workspace_tool_broker_events(workspace_dir).length
    end

    def engine_run_workspace_tool_broker_events(workspace_dir)
      path = engine_run_tool_broker_events_path(workspace_dir)
      return [] unless File.file?(path)

      File.readlines(path, chomp: true).filter_map do |line|
        parsed = JSON.parse(line)
        parsed.is_a?(Hash) ? parsed : nil
      rescue JSON::ParserError
        nil
      end
    end

    def engine_run_emit_workspace_tool_broker_events(workspace_dir, events_path, events, cycle:, offset:)
      engine_run_workspace_tool_broker_events(workspace_dir).drop(offset.to_i).each do |event|
        engine_run_event(events_path, events, "tool.blocked", "tool broker blocked prohibited staged action", event.merge("cycle" => cycle))
      end
    end

    def engine_run_stage_excluded?(relative_path)
      normalized = relative_path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
      ENGINE_RUN_STAGE_EXCLUDES.any? do |entry|
        normalized == entry || normalized.start_with?("#{entry}/")
      end
    end

    def engine_run_secret_surface_path?(relative_path)
      normalized = relative_path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
      return true if unsafe_env_path?(normalized)
      return true if secret_looking_path?(normalized)

      parts = normalized.split("/")
      return true if parts.any? { |part| %w[.ssh .aws .azure .gcloud .docker .kube .vercel .netlify].include?(part) }
      return true if parts.any? { |part| %w[.npmrc .yarnrc .pypirc .netrc].include?(part) }
      return true if normalized.match?(%r{(?:\A|/)\.config/(?:google-chrome|chromium)(?:/|\z)})
      return true if normalized.match?(%r{(?:\A|/)\.mozilla(?:/|\z)})
      return true if normalized.match?(%r{(?:\A|/)(?:Cookies|Login Data|Local State|Local Storage|Session Storage)(?:/|\z)})

      false
    end

    def engine_run_empty_agent_result
      {
        stdout: +"",
        stderr: +"",
        exit_code: nil,
        success: false,
        cycles_completed: 0,
        blocking_issues: []
      }
    end

    def engine_run_merge_agent_results(previous, current)
      {
        stdout: previous.fetch(:stdout).to_s + current.fetch(:stdout).to_s,
        stderr: previous.fetch(:stderr).to_s + current.fetch(:stderr).to_s,
        exit_code: current[:exit_code],
        success: current.fetch(:success),
        cycles_completed: previous.fetch(:cycles_completed).to_i + current.fetch(:cycles_completed).to_i,
        blocking_issues: (previous.fetch(:blocking_issues) + current.fetch(:blocking_issues)).uniq
      }
    end

    def engine_run_execute_agentic_loop(run_id:, capability:, paths:, stage:, agent:, sandbox:, cycle_limit:, events:, cycle_offset: 0)
      stdout = +""
      stderr = +""
      exit_code = nil
      success = false
      blocking_issues = []
      cycles_completed = 0
      engine_run_event(paths.fetch(:events_path), events, "plan.created", "created sandbox task plan", max_cycles: cycle_limit)

      cycle_limit.times do |index|
        cycles_completed = index + 1
        event_cycle = cycle_offset.to_i + cycles_completed
        break if run_cancel_requested?(run_id)

        broker_event_offset = engine_run_tool_broker_event_count(paths.fetch(:workspace_dir))
        engine_run_event(paths.fetch(:events_path), events, "step.started", "starting agentic cycle", cycle: event_cycle)
        design_repair_cycle = File.file?(File.join(paths.fetch(:workspace_dir), "_aiweb", "repair-observation.json"))
        engine_run_event(paths.fetch(:events_path), events, "design.repair.started", "starting design repair cycle", cycle: event_cycle) if design_repair_cycle
        command = engine_run_agent_command(agent, sandbox, paths.fetch(:workspace_dir))
        prompt = engine_run_agent_prompt(capability, stage.fetch(:manifest), paths)
        tool_request = engine_run_tool_request("worker.act", command, paths.fetch(:workspace_dir), capability, risk_class: "sandbox_worker", expected_outputs: [relative(paths.fetch(:agent_result_path)), relative(paths.fetch(:diff_path))])
        engine_run_event(paths.fetch(:events_path), events, "tool.requested", "worker requested sandbox action", tool_request)
        engine_run_event(paths.fetch(:events_path), events, "policy.decision", "tool broker approved sandbox worker action", tool_request.merge("decision" => "approved", "reason" => "inside approved sandbox capability envelope"))
        engine_run_event(paths.fetch(:events_path), events, "tool.started", "starting #{agent} inside staged sandbox", cycle: event_cycle, command: command.join(" "))
        captured = engine_run_capture_agent(command: command, prompt: prompt, workspace_dir: paths.fetch(:workspace_dir), paths: paths, agent: agent, sandbox: sandbox)
        engine_run_emit_workspace_tool_broker_events(paths.fetch(:workspace_dir), paths.fetch(:events_path), events, cycle: event_cycle, offset: broker_event_offset)
        stdout << captured.fetch(:stdout).to_s
        stderr << captured.fetch(:stderr).to_s
        exit_code = captured[:exit_code]
        success = captured.fetch(:success)
        blocking_issues.concat(captured.fetch(:blocking_issues))
        engine_run_event(paths.fetch(:events_path), events, "tool.finished", "finished #{agent} sandbox cycle", cycle: event_cycle, exit_code: exit_code, success: success)
        engine_run_event(paths.fetch(:events_path), events, "design.repair.finished", "finished design repair cycle", cycle: event_cycle, success: success) if design_repair_cycle
        break if success

        engine_run_event(paths.fetch(:events_path), events, "repair.planned", "agent cycle failed; scheduling another sandbox attempt", cycle: event_cycle, exit_code: exit_code) if index + 1 < cycle_limit && !run_cancel_requested?(run_id)
      end

      if run_cancel_requested?(run_id)
        blocking_issues << "engine-run cancellation requested for #{run_id}"
      elsif !success
        blocking_issues << "#{agent} did not complete successfully inside the staged sandbox" if blocking_issues.empty?
      end
      {
        stdout: agent_run_redact_process_output(stdout),
        stderr: agent_run_redact_process_output(stderr),
        exit_code: exit_code,
        success: success,
        cycles_completed: cycles_completed,
        blocking_issues: blocking_issues.uniq
      }
    end

    def engine_run_should_repair?(final_status, result, policy, verification, preview, design_verdict, cycle_limit)
      return false unless final_status == "failed"
      return false unless result.fetch(:success)
      return false unless policy.fetch("blocking_issues").empty? && policy.fetch("approval_issues").empty?
      repairable = verification.fetch("status") == "failed" ||
                   preview.fetch("status") == "failed" ||
                   design_verdict.fetch("status") == "failed"
      return false unless repairable

      result.fetch(:cycles_completed).to_i < cycle_limit.to_i
    end

    def engine_run_agent_prompt(capability, manifest, paths)
      [
        "You are the agentic WebBuilderAgent sandbox worker.",
        "You own the staged workspace only. The host project is protected by aiweb copy-back validation.",
        "Work like a careful human developer: inspect the project, plan, edit, run local build/test/preview/QA when useful, observe failures, and retry within the approved capability envelope.",
        "If _aiweb/repair-observation.json exists, read it first; it contains the previous verification failure and copy-back state for the next repair attempt.",
        "Do not read .env, credentials, provider auth stores, browser profiles, or any path excluded from the staged manifest.",
        "Do not use external network, package install, provider CLI, deploy, or git push. If needed, report that as waiting_approval in the result JSON.",
        "Write a short JSON result to _aiweb/engine-result.json when possible.",
        "",
        "## Capability",
        JSON.pretty_generate(capability),
        "",
        "## Staged Manifest Summary",
        JSON.pretty_generate(
          "workspace_root" => manifest["workspace_root"],
          "file_count" => manifest.fetch("files").length,
          "excluded_count" => manifest.fetch("excluded").length,
          "writable_globs" => capability["writable_globs"],
          "result_path" => "_aiweb/engine-result.json"
        ),
        "",
        "## Evidence Paths",
        JSON.pretty_generate(
          "stdout_log" => relative(paths.fetch(:stdout_path)),
          "stderr_log" => relative(paths.fetch(:stderr_path)),
          "worker_adapter_contract_path" => "_aiweb/worker-adapter-contract.json",
          "project_index_path" => relative(paths.fetch(:project_index_path)),
          "diff_path" => relative(paths.fetch(:diff_path)),
          "events_path" => relative(paths.fetch(:events_path)),
          "verification_path" => relative(paths.fetch(:verification_path)),
          "agent_result_path" => relative(paths.fetch(:agent_result_path))
        )
      ].join("\n")
    end

    def engine_run_agent_result(workspace_dir)
      path = File.join(workspace_dir, "_aiweb", "engine-result.json")
      return nil unless File.file?(path)

      text = File.read(path, 200_000)
      if text.match?(ENGINE_RUN_SECRET_VALUE_PATTERN)
        return {
          "schema_version" => 1,
          "status" => "redacted",
          "blocking_issues" => ["agent result contained secret-like content and was not persisted verbatim"]
        }
      end
      parsed = JSON.parse(agent_run_redact_process_output(text))
      parsed.is_a?(Hash) ? parsed : { "schema_version" => 1, "status" => "reported", "value" => parsed }
    rescue JSON::ParserError
      { "schema_version" => 1, "status" => "reported", "raw" => agent_run_redact_process_output(text.to_s)[0, 20_000] }
    rescue SystemCallError, ArgumentError => e
      { "schema_version" => 1, "status" => "unreadable", "blocking_issues" => ["agent result could not be read: #{e.message}"] }
    end

    def engine_run_worker_adapter_output_violations(agent_result, workspace_dir, expected_adapter: nil)
      return [] unless agent_result.is_a?(Hash)

      issues = Array(agent_result["blocking_issues"]).map(&:to_s)
      if %w[openhands langgraph openai_agents_sdk].include?(expected_adapter.to_s)
        required = %w[schema_version adapter status structured_events artifact_refs changed_file_manifest proposed_tool_requests risk_notes blocking_issues]
        missing = required.reject { |field| agent_result.key?(field) }
        issues << "worker adapter contract violation: #{expected_adapter} result missing required field(s): #{missing.join(", ")}" unless missing.empty?
        issues << "worker adapter contract violation: #{expected_adapter} result adapter must be #{expected_adapter}" unless agent_result["adapter"].to_s == expected_adapter.to_s
        %w[structured_events artifact_refs changed_file_manifest proposed_tool_requests risk_notes blocking_issues].each do |field|
          issues << "worker adapter contract violation: #{expected_adapter} result #{field} must be an array" if agent_result.key?(field) && !agent_result[field].is_a?(Array)
        end
      end
      if agent_result["status"].to_s == "reported" && agent_result.key?("raw")
        issues << "worker adapter contract violation: output was not structured JSON or was redacted before parsing"
      end
      strings = engine_run_collect_json_strings(agent_result)
      strings.each do |value|
        next if value.strip.empty?

        if engine_run_worker_adapter_host_absolute_path?(value, workspace_dir)
          issues << "worker adapter contract violation: output contained host absolute path"
        end
        if value.match?(ENGINE_RUN_SECRET_VALUE_PATTERN) || value.match?(/\b(?:OPENAI_API_KEY|ANTHROPIC_API_KEY|AWS_SECRET_ACCESS_KEY|SECRET|TOKEN|PASSWORD)=/i)
          issues << "worker adapter contract violation: output contained raw secret or environment value"
        end
      end
      if agent_result.key?("raw_env") || agent_result.key?("environment") || agent_result.key?("env")
        issues << "worker adapter contract violation: output included raw environment payload"
      end
      issues.map(&:to_s).reject(&:empty?).uniq
    end

    def engine_run_collect_json_strings(value)
      case value
      when Hash
        value.flat_map { |key, child| [key.to_s, *engine_run_collect_json_strings(child)] }
      when Array
        value.flat_map { |child| engine_run_collect_json_strings(child) }
      when String
        [value]
      else
        []
      end
    end

    def engine_run_worker_adapter_host_absolute_path?(value, workspace_dir)
      text = value.to_s.strip
      return false if text.empty?
      return false if text.start_with?("/workspace", "file:///workspace")

      if text.match?(%r{\A[A-Za-z]:[\\/]})
        workspace = File.expand_path(workspace_dir).tr("\\", "/").downcase
        candidate = text.tr("\\", "/").downcase
        return !candidate.start_with?(workspace)
      end
      return true if text.start_with?("/") && !text.start_with?("/workspace/")
      return true if text.start_with?("file:///") && !text.start_with?("file:///workspace")

      false
    end

    def engine_run_write_repair_observation(workspace_dir, verification, policy, preview: nil, screenshot_evidence: nil, design_verdict: nil, opendesign_contract: nil)
      path = File.join(workspace_dir, "_aiweb", "repair-observation.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(
        path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "written_at" => now,
          "verification" => verification,
          "copy_back_policy" => {
            "status" => policy["status"],
            "safe_changes" => policy["safe_changes"],
            "approval_changes" => policy["approval_changes"],
            "blocked_changes" => policy["blocked_changes"],
            "blocking_issues" => policy["blocking_issues"],
            "approval_issues" => policy["approval_issues"]
          },
          "preview" => preview,
          "screenshot_evidence" => screenshot_evidence,
          "design_verdict" => design_verdict,
          "opendesign_contract" => engine_run_checkpoint_opendesign_contract(opendesign_contract),
          "design_repair_instructions" => Array(design_verdict && design_verdict["repair_instructions"])
        )
      )
      path
    end

    def engine_run_capture_agent(command:, prompt:, workspace_dir:, paths:, agent:, sandbox:)
      FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb", "home"))
      FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb", "tmp"))
      if agent.to_s == "openhands"
        task_path = File.join(workspace_dir, "_aiweb", "openhands-task.md")
        FileUtils.mkdir_p(File.dirname(task_path))
        File.write(task_path, prompt)
      elsif agent.to_s == "langgraph"
        FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb"))
        File.write(File.join(workspace_dir, "_aiweb", "langgraph-task.md"), prompt)
        File.write(File.join(workspace_dir, "_aiweb", "langgraph-worker.py"), engine_run_langgraph_worker_source)
      elsif agent.to_s == "openai_agents_sdk"
        FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb"))
        File.write(File.join(workspace_dir, "_aiweb", "openai-agents-task.md"), prompt)
        File.write(File.join(workspace_dir, "_aiweb", "openai-agents-worker.py"), engine_run_openai_agents_sdk_worker_source)
      end
      env = engine_run_clean_env(workspace_dir, paths, sandbox)
      stdout_data = +""
      stderr_data = +""
      exit_code = nil
      success = false
      result = runtime_process_runner.capture(
        Aiweb::Runtime::CommandSpec.new(
          argv: Array(command).map(&:to_s),
          cwd: workspace_dir,
          env: env,
          stdin_data: prompt,
          timeout: 600,
          max_output_bytes: 200_000,
          risk_class: "engine_run_agent_worker",
          description: "engine-run agent worker"
        )
      )
      stdout_data = agent_run_limit_process_output(result.stdout)
      stderr_data = agent_run_limit_process_output(result.stderr)
      exit_code = result.exit_code
      success = result.success?
      blockers = []
      blockers << "#{agent} timed out after 600s" if result.status == "timeout"
      blockers << "#{agent} exited with status #{exit_code || "unknown"}" if result.status != "timeout" && !success
      blockers << "quarantine: agent output contained secret-like content" if stdout_data.match?(ENGINE_RUN_SECRET_VALUE_PATTERN) || stderr_data.match?(ENGINE_RUN_SECRET_VALUE_PATTERN)
      {
        stdout: stdout_data,
        stderr: stderr_data,
        exit_code: exit_code,
        success: success,
        blocking_issues: blockers
      }
    rescue ArgumentError, SystemCallError => e
      {
        stdout: stdout_data,
        stderr: "#{stderr_data}#{e.message}\n",
        exit_code: exit_code,
        success: false,
        blocking_issues: ["engine-run subprocess failed: #{e.message}"]
      }
    end

    def engine_run_clean_env(workspace_dir, paths, sandbox)
      allowed = subprocess_path_env
      allowed.merge(
        "AIWEB_ENGINE_RUN_WORKSPACE" => workspace_dir,
        "AIWEB_ENGINE_RUN_RESULT_PATH" => File.join(workspace_dir, "_aiweb", "engine-result.json"),
        "AIWEB_OPENMANUS_RESULT_PATH" => File.join(workspace_dir, "_aiweb", "engine-result.json"),
        "AIWEB_ENGINE_RUN_EVENTS_PATH" => paths.fetch(:events_path),
        "AIWEB_OPENMANUS_SANDBOX" => sandbox.to_s,
        "AIWEB_NETWORK_ALLOWED" => "0",
        "AIWEB_MCP_ALLOWED" => "0",
        "AIWEB_ENV_ACCESS_ALLOWED" => "0",
        "AIWEB_TOOL_BROKER_EVENTS_PATH" => "/workspace/_aiweb/tool-broker-events.jsonl",
        "AIWEB_TOOL_BROKER_REAL_PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME" => File.join(workspace_dir, "_aiweb", "home"),
        "USERPROFILE" => File.join(workspace_dir, "_aiweb", "home"),
        "TMPDIR" => File.join(workspace_dir, "_aiweb", "tmp"),
        "TMP" => File.join(workspace_dir, "_aiweb", "tmp"),
        "TEMP" => File.join(workspace_dir, "_aiweb", "tmp")
      )
    end

    def engine_run_verification_result(workspace_dir, capability, paths, events, agent:, sandbox:)
      package_path = File.join(workspace_dir, "package.json")
      return { "schema_version" => 1, "status" => "skipped", "checks" => [], "blocking_issues" => [], "reason" => "package.json is missing in staged workspace" } unless File.file?(package_path)

      package = JSON.parse(File.read(package_path))
      scripts = package["scripts"].is_a?(Hash) ? package["scripts"] : {}
      checks = []
      blockers = []
      %w[build test].each do |script|
        next unless scripts.key?(script)
        command = engine_run_package_command(workspace_dir, script, agent: agent, sandbox: sandbox)
        unless command
          checks << { "name" => script, "status" => "skipped", "reason" => "package manager executable missing" }
          next
        end
        tool_request = engine_run_tool_request("package.#{script}", command, workspace_dir, capability, risk_class: "local_verification", expected_outputs: [relative(paths.fetch(:verification_path))])
        engine_run_event(paths.fetch(:events_path), events, "tool.requested", "verification requested sandbox #{script}", tool_request)
        engine_run_event(paths.fetch(:events_path), events, "policy.decision", "tool broker approved sandbox #{script}", tool_request.merge("decision" => "approved", "reason" => "package script exists in staged workspace"))
        engine_run_event(paths.fetch(:events_path), events, "tool.started", "starting sandbox #{script}", command: command.join(" "))
        broker_event_offset = engine_run_tool_broker_event_count(workspace_dir)
        stdout, stderr, status = engine_run_capture_command(command, workspace_dir, 120, env: engine_run_verification_env(workspace_dir, paths, sandbox))
        engine_run_emit_workspace_tool_broker_events(workspace_dir, paths.fetch(:events_path), events, cycle: "verification:#{script}", offset: broker_event_offset)
        check_status = status == 0 ? "passed" : "failed"
        checks << {
          "name" => script,
          "status" => check_status,
          "command" => command.join(" "),
          "exit_code" => status,
          "stdout" => agent_run_redact_process_output(stdout)[0, 2000],
          "stderr" => agent_run_redact_process_output(stderr)[0, 2000]
        }
        blockers << "#{script} failed with exit code #{status}" unless status == 0
        engine_run_event(paths.fetch(:events_path), events, "tool.finished", "finished sandbox #{script}", status: check_status, exit_code: status)
      end
      {
        "schema_version" => 1,
        "status" => if !blockers.empty?
                       "failed"
                     elsif checks.empty?
                       "skipped"
                     else
                       "passed"
                     end,
        "checks" => checks,
        "blocking_issues" => blockers,
        "reason" => checks.empty? ? "package.json has no build or test script" : nil
      }
    rescue JSON::ParserError => e
      { "schema_version" => 1, "status" => "failed", "checks" => [], "blocking_issues" => ["package.json is malformed in staged workspace: #{e.message}"] }
    end

    def engine_run_package_command(workspace_dir, script, agent:, sandbox:)
      manager = if File.file?(File.join(workspace_dir, "pnpm-lock.yaml"))
                  "pnpm"
                elsif File.file?(File.join(workspace_dir, "yarn.lock"))
                  "yarn"
                else
                  "npm"
                end
      return nil if sandbox.to_s.strip.empty? && executable_path(manager).nil?

      command = case manager
                when "npm" then [manager, "run", script]
                else [manager, script]
                end
      if engine_run_container_worker_agent?(agent) && !sandbox.to_s.strip.empty?
        return engine_run_sandbox_tool_command(sandbox, workspace_dir, command, agent: agent)
      end
      command
    end


  end
end
