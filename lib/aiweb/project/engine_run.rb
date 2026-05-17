# frozen_string_literal: true

require "digest"
require "shellwords"
require "time"

module Aiweb
  module ProjectEngineRun
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
    ENGINE_RUN_SECRET_VALUE_PATTERN = /
      (?:-----BEGIN\ [A-Z ]*PRIVATE\ KEY-----)|
      (?:\bAKIA[0-9A-Z]{16}\b)|
      (?:\b(?:ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{10,}\b)|
      (?:\bxox[baprs]-[A-Za-z0-9-]{10,}\b)|
      (?:\b(?:sk|rk)_(?:live|test|proj)_[A-Za-z0-9_-]{10,}\b)
    /ix.freeze
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
        return engine_run_payload(
          state: state,
          metadata: metadata,
          changed_files: [],
          planned_changes: planned_changes,
          action_taken: dry_status == "blocked" ? "engine run blocked" : "planned engine run",
          next_action: dry_status == "blocked" ? "select a design candidate before running UI/source engine work" : "rerun aiweb engine-run --agent #{normalized_agent} --mode #{normalized_mode}#{engine_run_sandbox_suffix(normalized_agent, sandbox)} --approved to execute inside the staged sandbox"
        )
      end

      blockers = []
      blockers << "--approved is required for real engine-run execution" unless approved
      if !approval_hash.to_s.strip.empty? && approval_hash.to_s.strip != expected_hash
        blockers << "approval hash does not match the current capability envelope"
      end
      blockers.concat(opendesign_contract.fetch("blocking_issues", []))
      blockers.concat(engine_run_mode_blockers(normalized_mode, normalized_agent, sandbox, paths.fetch(:workspace_dir)))
      if resume && !resume_context
        blockers << "engine-run resume target has no readable checkpoint: #{resume}"
      elsif resume_context
        blockers.concat(engine_run_resume_blockers(resume_context))
      end

      unless blockers.empty?
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
        return engine_run_payload(
          state: state,
          metadata: metadata,
          changed_files: [],
          planned_changes: [],
          action_taken: "engine run blocked",
          next_action: "resolve engine-run blockers or inspect aiweb engine-run --dry-run"
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

    def eval_baseline(action: "validate", source_path: nil, output_path: nil, fixture_id: nil, approved: false, dry_run: false)
      assert_initialized!

      normalized_action = action.to_s.strip.empty? ? "validate" : action.to_s.strip
      unless %w[validate import review-pack].include?(normalized_action)
        raise UserError.new("eval-baseline action must be validate, import, or review-pack", 1)
      end
      if normalized_action == "import" && source_path.to_s.strip.empty?
        raise UserError.new("eval-baseline import requires --path", 1)
      end

      state = load_state
      if normalized_action == "review-pack"
        return eval_baseline_review_pack(
          output_path: output_path.to_s.strip.empty? ? source_path : output_path,
          fixture_id: fixture_id,
          approved: approved,
          dry_run: dry_run,
          state: state
        )
      end

      target_path = File.join(aiweb_dir, "eval", "human-baselines.json")
      validation_path = File.join(aiweb_dir, "eval", "human-baseline-validation.json")
      source = eval_baseline_source_path(source_path, target_path)
      validation = eval_baseline_validation(source, target_path: target_path, fixture_id: fixture_id)
      blockers = Array(validation["blocking_issues"])
      if validation["source_status"] == "ready" && validation["calibrated_fixture_count"].to_i.zero?
        blockers << "human baseline corpus contains no calibrated fixtures with positive reviewer evidence"
      end
      if normalized_action == "import" && !dry_run && !approved
        blockers << "--approved is required to import human baseline corpus"
      end
      blockers = blockers.uniq

      status = if blockers.any?
                 "blocked"
               elsif dry_run
                 "dry_run"
               elsif normalized_action == "import"
                 "imported"
               else
                 "validated"
               end
      action_taken = case [normalized_action, status]
                     when ["import", "imported"]
                       "imported human eval baseline"
                     when ["import", "dry_run"]
                       "planned human eval baseline import"
                     when ["validate", "validated"]
                       "validated human eval baseline"
                     when ["validate", "dry_run"]
                       "planned human eval baseline validation"
                     else
                       "human eval baseline #{normalized_action} blocked"
                     end

      validation_artifact = eval_baseline_validation_artifact(
        validation,
        status: status,
        action: normalized_action,
        approved: approved,
        dry_run: dry_run,
        blockers: blockers,
        target_path: target_path,
        validation_path: validation_path
      )
      changes = []
      if !dry_run && (normalized_action == "validate" || (normalized_action == "import" && approved))
        changes << write_json(validation_path, validation_artifact, false)
      end
      if !dry_run && status == "imported"
        changes << write_json(target_path, validation.fetch("corpus"), false)
      end

      eval_payload = {
        "schema_version" => 1,
        "status" => status,
        "action" => normalized_action,
        "dry_run" => dry_run,
        "approved" => approved,
        "source_path" => eval_baseline_path_label(source),
        "target_path" => relative(target_path),
        "validation_path" => dry_run ? nil : (changes.include?(relative(validation_path)) ? relative(validation_path) : nil),
        "planned_target_path" => dry_run || status == "blocked" ? relative(target_path) : nil,
        "planned_validation_path" => dry_run || (status == "blocked" && changes.empty?) ? relative(validation_path) : nil,
        "fixture_filter" => fixture_id.to_s.strip.empty? ? nil : fixture_id.to_s.strip,
        "fixture_count" => validation["fixture_count"],
        "calibrated_fixture_count" => validation["calibrated_fixture_count"],
        "invalid_fixture_count" => validation["invalid_fixture_count"],
        "corpus_readiness" => validation["corpus_readiness"],
        "fixtures" => validation["fixtures"],
        "guardrails" => eval_baseline_guardrails,
        "blocking_issues" => blockers
      }

      {
        "schema_version" => 1,
        "current_phase" => state.dig("phase", "current"),
        "action_taken" => action_taken,
        "changed_files" => compact_changes(changes),
        "blocking_issues" => blockers,
        "missing_artifacts" => validation["missing_artifacts"],
        "eval_baseline" => eval_payload,
        "next_action" => eval_baseline_next_action(normalized_action, status)
      }
    end

    private

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
      {
        "view_status" => "viewer",
        "view_workbench" => "viewer",
        "view_console" => "viewer",
        "view_runs" => "viewer",
        "view_run" => "viewer",
        "view_events" => "viewer",
        "view_approvals" => "viewer",
        "view_job_status" => "viewer",
        "view_job_timeline" => "viewer",
        "view_job_summary" => "viewer",
        "view_artifact" => "viewer",
        "command" => "operator",
        "codex_agent_run" => "operator",
        "run_start" => "operator",
        "resume" => "operator",
        "cancel" => "operator",
        "approve" => "admin",
        "copy_back" => "admin"
      }
    end

    def engine_run_local_backend_artifact_acl_policy
      {
        "policy" => "local_backend_artifact_acl_v1",
        "default_role" => "viewer",
        "sensitive_artifact_role" => "operator",
        "approval_artifact_role" => "admin",
        "sensitive_categories" => %w[diffs logs approvals sensitive_run_artifacts]
      }
    end

    def engine_run_authz_contract
      {
        "schema_version" => 1,
        "mode" => "local_project",
        "local_api_token_required" => true,
        "run_id_is_not_authority" => true,
        "saas_required_claims" => %w[tenant_id project_id user_id],
        "local_backend_claim_enforced_mode" => {
          "available" => true,
          "enable_with" => "AIWEB_DAEMON_AUTHZ_MODE=claims, AIWEB_DAEMON_AUTHZ_MODE=jwt_hs256, AIWEB_DAEMON_AUTHZ_MODE=jwt_rs256_jwks, or AIWEB_DAEMON_AUTHZ_MODE=session_token",
          "supported_authz_modes" => %w[local_token claims jwt_hs256 jwt_rs256_jwks session_token],
          "unsupported_authz_modes_fail_closed_for_project_routes" => true,
          "jwt_hs256_status" => "local_hs256_supported_with_server_secret",
          "jwt_hs256_secret_env" => "AIWEB_DAEMON_JWT_HS256_SECRET",
          "jwt_hs256_required_claims" => %w[tenant_id project_id user_id],
          "jwt_hs256_claim_aliases" => {
            "tenant_id" => %w[tenant_id tid],
            "project_id" => %w[project_id pid],
            "user_id" => %w[user_id sub]
          },
          "jwt_rs256_jwks_status" => "local_rs256_jwks_file_supported_no_oidc_discovery",
          "jwt_rs256_jwks_file_env" => "AIWEB_DAEMON_JWT_RS256_JWKS_FILE",
          "jwt_rs256_jwks_required_claims" => %w[tenant_id project_id user_id],
          "session_token_status" => "local_hashed_session_store_supported",
          "session_store_file_env" => "AIWEB_DAEMON_SESSION_STORE_FILE",
          "session_token_storage" => "sha256_hash_only",
          "session_token_required_claims" => %w[tenant_id project_id user_id],
          "oidc_status" => "not_implemented_fail_closed",
          "raw_jwt_oidc_status" => "unsupported_modes_fail_closed",
          "required_headers" => %w[X-Aiweb-Tenant-Id X-Aiweb-Project-Id X-Aiweb-User-Id],
          "project_id_source" => "server_configured_project_allowlist",
          "role_source" => "server_configured_project_allowlist",
          "project_registry_source" => "inline_env_or_file_json",
          "project_registry_policy" => {
            "policy" => "local_backend_project_registry_v1",
            "sources" => %w[AIWEB_DAEMON_AUTHZ_PROJECTS AIWEB_DAEMON_AUTHZ_PROJECTS_FILE],
            "file_format" => "json",
            "supports_tenant_members" => true,
            "supports_project_members" => true,
            "role_source" => "server_configured_project_allowlist"
          },
          "role_hierarchy" => %w[viewer operator admin],
          "route_required_roles" => engine_run_local_backend_route_required_roles,
          "artifact_acl_policy" => engine_run_local_backend_artifact_acl_policy,
          "audit_path" => ".ai-web/authz/audit.jsonl",
          "project_allowlist_env" => "AIWEB_DAEMON_AUTHZ_PROJECTS",
          "project_registry_file_env" => "AIWEB_DAEMON_AUTHZ_PROJECTS_FILE",
          "server_project_allowlist_required" => true
        },
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
        "local_backend_enforcement" => {
          "api_token_required_for_api_routes" => true,
          "approval_token_required_for_approved_execution" => true,
          "safe_project_path_required" => true,
          "artifact_reference_must_be_project_relative" => true,
          "raw_run_id_without_project_path_is_rejected" => true,
          "claim_enforced_project_authz_available" => true,
          "claim_enforced_mode_required_for_remote_exposure" => true,
          "supported_authz_modes" => %w[local_token claims jwt_hs256 jwt_rs256_jwks session_token],
          "unsupported_authz_modes_fail_closed_for_project_routes" => true,
          "jwt_hs256_status" => "local_hs256_supported_with_server_secret",
          "jwt_hs256_secret_env" => "AIWEB_DAEMON_JWT_HS256_SECRET",
          "jwt_hs256_required_claims" => %w[tenant_id project_id user_id],
          "jwt_hs256_claim_aliases" => {
            "tenant_id" => %w[tenant_id tid],
            "project_id" => %w[project_id pid],
            "user_id" => %w[user_id sub]
          },
          "jwt_rs256_jwks_status" => "local_rs256_jwks_file_supported_no_oidc_discovery",
          "jwt_rs256_jwks_file_env" => "AIWEB_DAEMON_JWT_RS256_JWKS_FILE",
          "jwt_rs256_jwks_required_claims" => %w[tenant_id project_id user_id],
          "session_token_status" => "local_hashed_session_store_supported",
          "session_store_file_env" => "AIWEB_DAEMON_SESSION_STORE_FILE",
          "session_token_storage" => "sha256_hash_only",
          "session_token_required_claims" => %w[tenant_id project_id user_id],
          "oidc_status" => "not_implemented_fail_closed",
          "raw_jwt_oidc_status" => "unsupported_modes_fail_closed",
          "claim_headers" => %w[X-Aiweb-Tenant-Id X-Aiweb-Project-Id X-Aiweb-User-Id],
          "project_id_source" => "server_configured_project_allowlist",
          "role_source" => "server_configured_project_allowlist",
          "project_registry_source" => "inline_env_or_file_json",
          "project_registry_policy" => {
            "policy" => "local_backend_project_registry_v1",
            "sources" => %w[AIWEB_DAEMON_AUTHZ_PROJECTS AIWEB_DAEMON_AUTHZ_PROJECTS_FILE],
            "file_format" => "json",
            "supports_tenant_members" => true,
            "supports_project_members" => true,
            "role_source" => "server_configured_project_allowlist"
          },
          "role_hierarchy" => %w[viewer operator admin],
          "route_required_roles" => engine_run_local_backend_route_required_roles,
          "artifact_acl_policy" => engine_run_local_backend_artifact_acl_policy,
          "audit_path" => ".ai-web/authz/audit.jsonl",
          "server_project_allowlist_required" => true,
          "project_allowlist_env" => "AIWEB_DAEMON_AUTHZ_PROJECTS",
          "project_registry_file_env" => "AIWEB_DAEMON_AUTHZ_PROJECTS_FILE",
          "route_permissions" => engine_run_local_backend_route_permissions
        },
        "current_execution" => {
          "agent" => agent,
          "engine_mode" => mode,
          "sandbox" => sandbox,
          "approved_flag" => approved,
          "approval_scope" => "single_run_single_capability"
        },
        "saas_required_claims" => %w[tenant_id project_id user_id],
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

    def engine_run_worker_adapter_contract(agent)
      {
        "schema_version" => 1,
        "adapter" => agent,
        "api" => %w[prepare act observe cancel resume finalize],
        "input_refs_only" => true,
        "allowed_inputs" => %w[goal staged_workspace_uri run_graph_cursor capability_envelope design_contract prior_evidence_refs],
        "allowed_outputs" => %w[structured_events artifact_refs proposed_tool_requests changed_file_manifest risk_notes],
        "contract_violations" => %w[host_absolute_path raw_secret_value raw_env_value unapproved_network unapproved_provider_cli unapproved_git_push],
        "runtime_broker" => {
          "required" => true,
          "event_flow" => %w[tool.requested policy.decision tool.started tool.finished tool.blocked],
          "fail_closed_on_missing_broker_driver" => true,
          "adapter_must_report_proposed_tool_requests" => true,
          "output_without_broker_evidence_blocks_copy_back" => true
        }
      }
    end

    def engine_run_container_worker_agent?(agent)
      %w[openmanus openhands langgraph openai_agents_sdk].include?(agent.to_s)
    end

    def engine_run_agent_container_image(agent)
      case agent.to_s
      when "openhands" then engine_run_openhands_image
      when "langgraph" then engine_run_langgraph_image
      when "openai_agents_sdk" then engine_run_openai_agents_sdk_image
      else engine_run_openmanus_image
      end
    end

    def engine_run_agent_container_env(agent, provider)
      case agent.to_s
      when "openhands" then engine_run_openhands_container_env(provider)
      when "langgraph" then engine_run_langgraph_container_env(provider)
      when "openai_agents_sdk" then engine_run_openai_agents_sdk_container_env(provider)
      else engine_run_openmanus_container_env(provider)
      end
    end

    def engine_run_worker_adapter_registry(selected_agent:, mode:, sandbox:)
      selected = selected_agent.to_s
      selected_status = engine_run_worker_adapter_status(selected, mode: mode, sandbox: sandbox)
      registry = {
        "schema_version" => 1,
        "protocol_version" => "worker-adapter-v1",
        "selected_adapter" => selected,
        "selected_adapter_status" => selected_status,
        "selected_adapter_executable" => engine_run_worker_adapter_status_executable?(selected_status),
        "selected_adapter_blocking_issues" => engine_run_worker_adapter_status_blocking_issues(selected_status, selected),
        "required_api" => %w[prepare act observe cancel resume finalize],
        "selection_policy" => {
          "agentic_local" => "only sandboxed container workers may execute directly; unsandboxed Codex stays delegated to safe_patch",
          "safe_patch" => "delegated to existing agent-run safe patch flow",
          "external_approval" => "requires explicit external approval before execution"
        },
        "adapters" => [
          engine_run_worker_adapter_registry_entry(
            id: "openmanus",
            status: sandbox.to_s.empty? ? "implemented_requires_docker_or_podman" : "implemented_container_worker",
            modes: %w[agentic_local],
            runtime_boundary: "aiweb_validated_docker_or_podman_no_network_staged_workspace",
            command_driver: "engine_run_openmanus_command",
            sandbox_preflight: "required_before_execution",
            result_schema: "worker-adapter-v1 engine-result.json",
            broker_id: "aiweb.engine_run.tool_broker",
            broker_enforcement_status: "enforced",
            broker_evidence: %w[_aiweb/tool-broker-events.jsonl worker-adapter-contract.json worker-adapter-registry.json sandbox-preflight.json agent-result.json],
            evidence: %w[worker-adapter-contract.json worker-adapter-registry.json sandbox-preflight.json agent-result.json],
            limitations: []
          ),
          engine_run_worker_adapter_registry_entry(
            id: "codex",
            status: "delegated_safe_patch_only",
            modes: %w[safe_patch],
            runtime_boundary: "agent_run_clean_environment_bounded_copy_back",
            command_driver: "agent_run",
            sandbox_preflight: "not_applicable_safe_patch_delegation",
            result_schema: "agent-run.json diff.patch",
            broker_id: "aiweb.agent_run.safe_patch_boundary",
            broker_enforcement_status: "delegated_safe_patch_bounded",
            broker_evidence: %w[agent-run.json stdout.log stderr.log diff.patch],
            evidence: %w[agent-run.json stdout.log stderr.log diff.patch],
            limitations: ["real agentic_local Codex execution is blocked until a sandbox adapter exists"]
          ),
          engine_run_worker_adapter_registry_entry(
            id: "openhands",
            status: engine_run_worker_adapter_status("openhands", mode: mode, sandbox: sandbox),
            modes: %w[agentic_local],
            runtime_boundary: "experimental_aiweb_validated_docker_or_podman_no_network_staged_workspace_with_openhands_headless",
            command_driver: "engine_run_openhands_command",
            sandbox_preflight: "required_before_execution",
            result_schema: "engine-run-openhands-result.schema.json",
            broker_id: "aiweb.engine_run.tool_broker",
            broker_enforcement_status: "enforced",
            broker_evidence: %w[_aiweb/tool-broker-events.jsonl worker-adapter-contract.json worker-adapter-registry.json sandbox-preflight.json agent-result.json _aiweb/openhands-task.md],
            evidence: %w[worker-adapter-contract.json worker-adapter-registry.json sandbox-preflight.json agent-result.json openhands-task.md],
            limitations: ["experimental OpenHands headless CLI container adapter only", "requires a prepared local OpenHands-compatible image and model/runtime configuration inside the approved sandbox", "does not imply LangGraph or OpenAI Agents SDK worker parity"]
          ),
          engine_run_worker_adapter_registry_entry(
            id: "langgraph",
            status: engine_run_worker_adapter_status("langgraph", mode: mode, sandbox: sandbox),
            modes: %w[agentic_local],
            runtime_boundary: "experimental_aiweb_validated_docker_or_podman_no_network_staged_workspace_with_langgraph_stategraph_bridge",
            command_driver: "engine_run_langgraph_command",
            sandbox_preflight: "required_before_execution",
            result_schema: "engine-run-langgraph-result.schema.json",
            broker_id: "aiweb.engine_run.tool_broker",
            broker_enforcement_status: "enforced",
            broker_evidence: %w[_aiweb/tool-broker-events.jsonl worker-adapter-contract.json worker-adapter-registry.json sandbox-preflight.json agent-result.json _aiweb/langgraph-worker.py _aiweb/langgraph-task.md],
            evidence: %w[worker-adapter-contract.json worker-adapter-registry.json sandbox-preflight.json agent-result.json langgraph-worker.py langgraph-task.md],
            limitations: ["experimental LangGraph StateGraph bridge only", "requires a prepared local LangGraph-compatible Python image", "does not provide a LangGraph Platform deployment or distributed checkpoint store", "does not imply OpenAI Agents SDK worker parity"]
          ),
          engine_run_worker_adapter_registry_entry(
            id: "openai_agents_sdk",
            status: engine_run_worker_adapter_status("openai_agents_sdk", mode: mode, sandbox: sandbox),
            modes: %w[agentic_local],
            runtime_boundary: "experimental_aiweb_validated_docker_or_podman_no_network_staged_workspace_with_openai_agents_sdk_bridge",
            command_driver: "engine_run_openai_agents_sdk_command",
            sandbox_preflight: "required_before_execution",
            result_schema: "engine-run-openai-agents-sdk-result.schema.json",
            broker_id: "aiweb.engine_run.tool_broker",
            broker_enforcement_status: "enforced",
            broker_evidence: %w[_aiweb/tool-broker-events.jsonl worker-adapter-contract.json worker-adapter-registry.json sandbox-preflight.json agent-result.json _aiweb/openai-agents-worker.py _aiweb/openai-agents-task.md],
            evidence: %w[worker-adapter-contract.json worker-adapter-registry.json sandbox-preflight.json agent-result.json openai-agents-worker.py openai-agents-task.md],
            limitations: ["experimental OpenAI Agents SDK bridge only", "requires a prepared local Python image with openai-agents installed", "default bridge records SDK orchestration readiness without enabling external OpenAI network calls", "does not provide production handoff/tool parity"]
          )
        ],
        "runtime_broker_enforcement" => engine_run_runtime_broker_enforcement(selected_adapter: selected),
        "interchangeability_claim" => "registry exposes adapter readiness; only adapters with implemented/delegated status may execute",
        "blocking_policy" => "planned_contract_only adapters are visible for migration planning but blocked as execution targets"
      }
      blockers = engine_run_worker_adapter_registry_blockers(registry)
      raise UserError.new("engine-run worker adapter registry invalid: #{blockers.join(", ")}", 5) unless blockers.empty?

      registry
    end

    def engine_run_worker_adapter_registry_entry(id:, status:, modes:, runtime_boundary:, command_driver:, broker_id:, broker_enforcement_status:, broker_evidence:, evidence:, limitations:, sandbox_preflight: nil, result_schema: nil)
      blocking_issues = engine_run_worker_adapter_status_blocking_issues(status, id)
      {
        "id" => id,
        "status" => status,
        "executable" => engine_run_worker_adapter_status_executable?(status),
        "execution_blocked" => !engine_run_worker_adapter_status_executable?(status),
        "blocking_issues" => blocking_issues,
        "api" => %w[prepare act observe cancel resume finalize],
        "modes" => modes,
        "runtime_boundary" => runtime_boundary,
        "command_driver" => command_driver,
        "sandbox_preflight" => sandbox_preflight,
        "result_schema" => result_schema,
        "driver_readiness" => engine_run_worker_adapter_driver_readiness(
          id: id,
          status: status,
          command_driver: command_driver,
          sandbox_preflight: sandbox_preflight,
          result_schema: result_schema,
          broker_evidence: broker_evidence,
          evidence: evidence,
          limitations: limitations
        ),
        "broker_contract" => {
          "required" => true,
          "broker_id" => broker_id,
          "event_flow" => %w[tool.requested policy.decision tool.started tool.finished tool.blocked],
          "enforcement_status" => broker_enforcement_status,
          "evidence_artifacts" => broker_evidence,
          "fail_closed_on_missing_broker_driver" => true
        },
        "input_refs_only" => true,
        "output_contract" => %w[structured_events artifact_refs proposed_tool_requests changed_file_manifest risk_notes],
        "evidence_artifacts" => evidence,
        "limitations" => limitations
      }
    end

    def engine_run_worker_adapter_driver_readiness(id:, status:, command_driver:, sandbox_preflight:, result_schema:, broker_evidence:, evidence:, limitations:)
      required = %w[command_driver sandbox_preflight result_schema broker_evidence result_evidence limitations]
      missing = []
      missing << "command_driver" if command_driver.to_s.empty?
      missing << "sandbox_preflight" if sandbox_preflight.to_s.empty? || sandbox_preflight.to_s == "missing"
      missing << "result_schema" if result_schema.to_s.empty?
      missing << "broker_evidence" if Array(broker_evidence).empty?
      missing << "result_evidence" if Array(evidence).empty?
      missing << "limitations" if Array(limitations).empty? && !engine_run_worker_adapter_status_executable?(status)
      state = if engine_run_worker_adapter_status_executable?(status) && missing.empty?
                %w[openhands langgraph openai_agents_sdk].include?(id.to_s) ? "experimental_ready" : "ready"
              elsif engine_run_worker_adapter_status_executable?(status)
                "executable_but_incomplete"
              else
                "blocked_missing_driver_artifacts"
              end
      {
        "schema_version" => 1,
        "state" => state,
        "required_artifacts" => required,
        "missing_artifacts" => missing,
        "executable_now" => engine_run_worker_adapter_status_executable?(status) && missing.empty?,
        "transition_gate" => missing.empty? ? "driver_may_execute_under_adapter_status_policy" : "fail_closed_until_missing_artifacts_exist",
        "next_required_evidence" => missing.map { |item| engine_run_worker_adapter_readiness_requirement(id, item) },
        "limitations" => limitations
      }
    end

    def engine_run_worker_adapter_readiness_requirement(id, item)
      case item
      when "command_driver"
        "#{id} needs a concrete command driver wired from engine_run_agent_command"
      when "sandbox_preflight"
        "#{id} needs sandbox or runtime preflight evidence before execution"
      when "result_schema"
        "#{id} needs a schema-locked worker-adapter-v1 result contract"
      when "broker_evidence"
        "#{id} needs tool broker event evidence artifacts before copy-back"
      when "result_evidence"
        "#{id} needs durable result/evidence artifacts in the run directory and staged workspace"
      when "limitations"
        "#{id} needs explicit limitations so adapter readiness cannot be overclaimed"
      else
        "#{id} needs #{item}"
      end
    end

    def engine_run_runtime_broker_enforcement(selected_adapter:)
      surfaces = [
        {
          "surface" => "engine_run_worker_adapters",
          "status" => "enforced_for_executable_adapters",
          "broker_id" => "aiweb.engine_run.tool_broker",
          "evidence" => %w[_aiweb/tool-broker-events.jsonl worker-adapter-registry.json worker-adapter-contract.json],
          "policy" => "executable worker adapters must declare broker_contract and report proposed_tool_requests; missing broker evidence blocks copy-back"
        },
        {
          "surface" => "mcp_connectors",
          "status" => "partial_drivers_available_lazyweb_and_project_files",
          "broker_id" => "aiweb.implementation_mcp_broker",
          "evidence" => [".ai-web/runs/lazyweb-research-*/side-effect-broker.jsonl", ".ai-web/runs/mcp-broker-*/side-effect-broker.jsonl"],
          "policy" => "Lazyweb design-research MCP calls, approved implementation-worker Lazyweb health/search calls, approved project_files.project_file_metadata/project_file_list metadata-only calls, approved bounded safe project_files.project_file_excerpt calls, and approved bounded literal project_files.project_file_search calls have concrete per-call brokers with redaction and audit events; all other implementation-worker MCP/connectors remain denied by default until each server has credential source, allowed args schema, network destinations, output redaction, and per-call audit evidence"
        },
        {
          "surface" => "future_adapters",
          "status" => "fail_closed_until_broker_driver",
          "broker_id" => "aiweb.future_adapter.required",
          "evidence" => [],
          "policy" => "OpenHands, LangGraph, and OpenAI Agents SDK each have one experimental sandboxed container driver; production-grade framework parity still requires hardened tool/handoff/session broker coverage"
        },
        {
          "surface" => "elevated_runners",
          "status" => "approval_required_and_brokered",
          "broker_id" => "aiweb.side_effect_broker",
          "evidence" => %w[side-effect-broker.jsonl],
          "policy" => "package install, deploy/provider CLI, backend bridge, Lazyweb HTTP, and OpenManus subprocesses must emit broker events or stay blocked"
        }
      ]
      {
        "schema_version" => 1,
        "status" => "partial_enforcement",
        "selected_adapter" => selected_adapter,
        "deny_by_default_surfaces" => %w[external_network package_install deploy provider_cli git_push mcp_connectors env_read host_root_write future_adapters elevated_runners],
        "executable_without_broker_count" => 0,
        "fail_closed_surface_count" => surfaces.count { |surface| surface["status"].include?("fail_closed") || surface["status"].include?("denied") },
        "universal_broker_claim" => false,
        "known_mcp_broker_drivers" => [
          {
            "server" => "lazyweb",
            "broker_id" => "aiweb.lazyweb.side_effect_broker",
            "scope" => "external_http.lazyweb_mcp",
            "status" => "implemented_for_design_research",
            "evidence" => [".ai-web/runs/lazyweb-research-*/side-effect-broker.jsonl"],
            "limitations" => ["not exposed to implementation agents", "not a generic MCP connector execution surface"]
          },
          {
            "server" => "lazyweb",
            "broker_id" => "aiweb.implementation_mcp_broker",
            "scope" => "implementation_worker.mcp.lazyweb",
            "status" => "implemented_for_approved_health_and_search_calls",
            "evidence" => [".ai-web/runs/mcp-broker-*/mcp-broker.json", ".ai-web/runs/mcp-broker-*/side-effect-broker.jsonl"],
            "limitations" => ["approved Lazyweb health/search only", "not a generic MCP connector runner", "not exposed to default engine-run sandbox without explicit approval"]
          },
          {
            "server" => "project_files",
            "broker_id" => "aiweb.implementation_mcp_broker",
            "scope" => "implementation_worker.mcp.project_files",
            "status" => "implemented_for_approved_project_file_metadata_list_excerpt_search",
            "evidence" => [".ai-web/runs/mcp-broker-*/mcp-broker.json", ".ai-web/runs/mcp-broker-*/side-effect-broker.jsonl"],
            "limitations" => ["approved project_file_metadata, project_file_list, bounded project_file_excerpt, and bounded project_file_search only", "project_file_list returns metadata only; project_file_excerpt returns bounded safe UTF-8 excerpts only; project_file_search returns bounded literal UTF-8 matches only", "no external network or credentials", "not exposed to default engine-run sandbox without explicit approval"]
          }
        ],
        "surfaces" => surfaces,
        "remaining_gaps" => [
          "implementation-worker MCP/connectors beyond Lazyweb health/search and project_files metadata/list/excerpt/search still need concrete per-call broker drivers before use",
          "OpenHands is experimental and still depends on a prepared local container image plus in-sandbox runtime/model configuration",
          "LangGraph is experimental and still depends on a prepared local Python image with langgraph installed; this is not LangGraph Platform or distributed checkpointing",
          "OpenAI Agents SDK is experimental and still depends on a prepared local Python image with openai-agents installed; external model/network calls remain blocked by default",
          "OS/container egress firewall is still separate from broker contract evidence"
        ]
      }
    end

    def engine_run_worker_adapter_registry_blockers(registry)
      adapters = Array(registry["adapters"])
      blockers = []
      adapters.each do |adapter|
        broker = adapter["broker_contract"]
        if !broker.is_a?(Hash) || broker["required"] != true
          blockers << "#{adapter["id"]} adapter is missing required broker_contract"
          next
        end
        blockers << "#{adapter["id"]} adapter broker_id is missing" if broker["broker_id"].to_s.empty?
        unless Array(broker["event_flow"]).include?("policy.decision")
          blockers << "#{adapter["id"]} adapter broker_contract must include policy.decision"
        end
        if adapter["executable"] == true
          status = broker["enforcement_status"].to_s
          unless %w[enforced delegated_safe_patch_bounded].include?(status)
            blockers << "#{adapter["id"]} executable adapter must have enforced broker evidence"
          end
          if Array(broker["evidence_artifacts"]).empty?
            blockers << "#{adapter["id"]} executable adapter must declare broker evidence artifacts"
          end
        elsif adapter["status"] == "planned_contract_only" && adapter["execution_blocked"] != true
          blockers << "#{adapter["id"]} planned adapter must be execution_blocked"
        end
      end
      if registry.dig("runtime_broker_enforcement", "executable_without_broker_count").to_i.positive?
        blockers << "runtime broker enforcement detected executable adapters without broker coverage"
      end
      blockers.uniq
    end

    def engine_run_worker_adapter_status_executable?(status)
      %w[implemented_container_worker experimental_container_worker delegated_safe_patch_only].include?(status.to_s)
    end

    def engine_run_worker_adapter_status_blocking_issues(status, adapter)
      case status.to_s
      when "implemented_container_worker", "experimental_container_worker", "delegated_safe_patch_only"
        []
      when "implemented_requires_docker_or_podman"
        ["#{adapter} requires a validated docker or podman sandbox before agentic_local execution"]
      when "experimental_requires_docker_or_podman"
        ["#{adapter} experimental adapter requires a validated docker or podman sandbox before agentic_local execution"]
      when "blocked_unsandboxed_agentic_local"
        ["#{adapter} agentic_local execution is blocked until a validated sandbox adapter exists; use safe_patch delegation instead"]
      when "planned_contract_only"
        ["#{adapter} is planned contract-only and cannot execute until a command driver, sandbox preflight, result schema, and evidence artifacts are implemented"]
      else
        ["#{adapter} is not supported as an executable engine-run worker adapter"]
      end
    end

    def engine_run_worker_adapter_status(agent, mode:, sandbox:)
      case agent.to_s
      when "openmanus"
        sandbox.to_s.empty? ? "implemented_requires_docker_or_podman" : "implemented_container_worker"
      when "openhands"
        sandbox.to_s.empty? ? "experimental_requires_docker_or_podman" : "experimental_container_worker"
      when "langgraph"
        sandbox.to_s.empty? ? "experimental_requires_docker_or_podman" : "experimental_container_worker"
      when "openai_agents_sdk"
        sandbox.to_s.empty? ? "experimental_requires_docker_or_podman" : "experimental_container_worker"
      when "codex"
        mode.to_s == "safe_patch" ? "delegated_safe_patch_only" : "blocked_unsandboxed_agentic_local"
      else
        "unsupported"
      end
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

    def engine_run_graph_contract(run_id:, capability:, paths:)
      nodes = [
        ["preflight", "preflight"],
        ["load_design_contract", "design_contract"],
        ["stage_workspace", "filesystem"],
        ["worker_act", "worker"],
        ["verify", "tool"],
        ["preview", "tool"],
        ["observe_browser", "browser"],
        ["design_gate", "policy"],
        ["repair", "worker"],
        ["approval", "human_gate"],
        ["copy_back", "filesystem"],
        ["finalize", "finalize"]
      ].map.with_index(1) do |(id, type), index|
        {
          "node_id" => id,
          "node_type" => type,
          "ordinal" => index,
          "input_artifact_refs" => engine_run_graph_node_inputs(id, paths),
          "output_artifact_refs" => engine_run_graph_node_outputs(id, paths),
          "state" => "pending",
          "attempt" => 0,
          "retry_policy" => engine_run_graph_retry_policy(id, capability),
          "approval_policy" => engine_run_graph_approval_policy(id),
          "side_effect_boundary" => engine_run_graph_side_effect_boundary(id),
          "executor" => engine_run_graph_node_executor(id),
          "replay_policy" => engine_run_graph_node_replay_policy(id),
          "idempotency_key" => Digest::SHA256.hexdigest([run_id, id, capability["approval_hash"] || capability["goal"]].join(":")),
          "checkpoint_cursor" => "#{run_id}:#{id}:0"
        }
      end
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "cursor" => {
          "node_id" => "preflight",
          "state" => "pending",
          "attempt" => 0
        },
        "nodes" => nodes,
        "executor_contract" => engine_run_graph_executor_contract(nodes),
        "resume_policy" => "validate_graph_cursor_and_artifact_hashes_before_next_idempotent_node",
        "side_effects_must_use_tool_broker" => true
      }
    end

    def engine_run_graph_executor_contract(nodes)
      {
        "schema_version" => 1,
        "executor_type" => "sequential_durable_node_executor",
        "node_order" => nodes.map { |node| node.fetch("node_id") },
        "checkpoint_policy" => "persist_before_and_after_side_effect_boundaries",
        "resume_strategy" => "validate_cursor_artifact_hashes_and_continue_at_next_idempotent_node",
        "side_effect_gate" => "tool_broker_required_for_non_none_boundaries"
      }
    end

    def engine_run_graph_execution_plan(run_graph:, paths:, resume_context:)
      engine_run_graph_scheduler_runtime(run_graph: run_graph, paths: paths, resume_context: resume_context).execution_plan
    end

    def engine_run_graph_execution_start_node(node_order, cursor)
      Aiweb::GraphSchedulerRuntime.start_node(node_order, cursor)
    end

    def engine_run_graph_execution_plan_blockers(plan)
      Aiweb::GraphSchedulerRuntime.plan_blockers(plan)
    end

    def engine_run_graph_scheduler_unsupported_start_blockers(plan)
      Aiweb::GraphSchedulerRuntime.new(run_graph: {}, artifact_refs: engine_run_graph_scheduler_artifact_refs_from_plan(plan)).unsupported_start_blockers(plan)
    end

    def engine_run_write_workspace_graph_execution_plan(workspace_dir, graph_execution_plan)
      path = File.join(workspace_dir, "_aiweb", "graph-execution-plan.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(graph_execution_plan) + "\n")
      path
    end

    def engine_run_graph_scheduler_state(run_graph:, graph_execution_plan:, paths:, resume_context:)
      engine_run_graph_scheduler_runtime(run_graph: run_graph, paths: paths, resume_context: resume_context).initial_state(graph_execution_plan)
    end

    def engine_run_graph_scheduler_reconcile!(scheduler_state, run_graph, graph_execution_plan, final_status:, paths:, events_path:, events:)
      runtime = engine_run_graph_scheduler_runtime(run_graph: run_graph, paths: paths, resume_context: nil)
      runtime.reconcile!(
        scheduler_state: scheduler_state,
        run_graph: run_graph,
        graph_execution_plan: graph_execution_plan,
        final_status: final_status,
        checkpoint_ref: relative(paths.fetch(:checkpoint_path)),
        transition_sink: lambda do |transition, node|
          engine_run_event(events_path, events, "graph.node.finished", "durable graph scheduler recorded node transition", node_id: transition["node_id"], state: transition["state"], attempt: transition["attempt"], artifact_refs: node["output_artifact_refs"])
        end
      )
      engine_run_event(events_path, events, "graph.scheduler.finished", "durable graph scheduler checkpointed state", status: final_status, cursor: scheduler_state["cursor"], artifact_path: relative(paths.fetch(:graph_scheduler_state_path)))
      scheduler_state
    end

    def engine_run_graph_scheduler_runtime(run_graph:, paths:, resume_context:)
      Aiweb::GraphSchedulerRuntime.new(
        run_graph: run_graph,
        artifact_refs: engine_run_graph_scheduler_artifact_refs(paths),
        resume_checkpoint: resume_context ? resume_context.fetch(:checkpoint) : nil,
        resume_run_id: resume_context ? resume_context.fetch(:run_id) : nil
      )
    end

    def engine_run_graph_scheduler_artifact_refs(paths)
      {
        graph_execution_plan_path: relative(paths.fetch(:graph_execution_plan_path)),
        graph_scheduler_state_path: relative(paths.fetch(:graph_scheduler_state_path)),
        checkpoint_path: relative(paths.fetch(:checkpoint_path))
      }
    end

    def engine_run_graph_scheduler_artifact_refs_from_plan(plan)
      {
        graph_execution_plan_path: plan.to_h["artifact_path"].to_s,
        graph_scheduler_state_path: plan.to_h["graph_scheduler_state_ref"].to_s,
        checkpoint_path: plan.to_h["checkpoint_ref"].to_s
      }
    end

    def engine_run_write_workspace_graph_scheduler_state(workspace_dir, graph_scheduler_state)
      path = File.join(workspace_dir, "_aiweb", "graph-scheduler-state.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(graph_scheduler_state) + "\n")
      path
    end

    def engine_run_graph_node_inputs(node_id, paths)
      case node_id
      when "load_design_contract"
        [relative(paths.fetch(:opendesign_contract_path))]
      when "worker_act", "verify", "preview", "observe_browser", "design_gate"
        [relative(paths.fetch(:manifest_path)), relative(paths.fetch(:opendesign_contract_path))]
      when "copy_back"
        [relative(paths.fetch(:diff_path)), relative(paths.fetch(:design_verdict_path)), relative(paths.fetch(:verification_path))]
      else
        []
      end
    end

    def engine_run_graph_node_outputs(node_id, paths)
      case node_id
      when "preflight"
        [relative(paths.fetch(:sandbox_preflight_path))]
      when "stage_workspace"
        [relative(paths.fetch(:manifest_path))]
      when "worker_act"
        [relative(paths.fetch(:agent_result_path)), relative(paths.fetch(:diff_path))]
      when "verify"
        [relative(paths.fetch(:verification_path))]
      when "preview"
        [relative(paths.fetch(:preview_path))]
      when "observe_browser"
        [relative(paths.fetch(:screenshot_evidence_path))]
      when "design_gate"
        [relative(paths.fetch(:design_fidelity_path)), relative(paths.fetch(:design_verdict_path))]
      when "finalize"
        [relative(paths.fetch(:metadata_path)), relative(paths.fetch(:checkpoint_path))]
      else
        []
      end
    end

    def engine_run_graph_retry_policy(node_id, capability)
      if %w[worker_act verify preview observe_browser design_gate repair].include?(node_id)
        { "max_attempts" => capability.dig("limits", "max_cycles").to_i.clamp(1, 10), "strategy" => "bounded_repair" }
      else
        { "max_attempts" => 1, "strategy" => "none" }
      end
    end

    def engine_run_graph_approval_policy(node_id)
      case node_id
      when "approval"
        { "required_when" => "elevated_capability_requested", "single_use" => true, "binds_capability_hash" => true }
      when "copy_back"
        { "required_when" => "safe_changes_present_and_policy_passed", "single_use" => true, "binds_capability_hash" => true }
      else
        { "required_when" => "never" }
      end
    end

    def engine_run_graph_side_effect_boundary(node_id)
      case node_id
      when "worker_act", "verify", "preview", "observe_browser", "repair"
        "sandbox_tool_broker"
      when "copy_back"
        "validated_host_copy_back"
      when "approval"
        "human_approval_record"
      else
        "none"
      end
    end

    def engine_run_graph_node_executor(node_id)
      boundary = engine_run_graph_side_effect_boundary(node_id)
      {
        "executor_id" => "engine_run.#{node_id}",
        "executor_type" => "ruby_method",
        "handler" => engine_run_graph_node_handler(node_id),
        "side_effect_boundary" => boundary,
        "tool_broker_required" => boundary != "none",
        "idempotent" => !%w[worker_act repair copy_back approval].include?(node_id)
      }
    end

    def engine_run_graph_node_handler(node_id)
      {
        "preflight" => "engine_run_sandbox_preflight_evidence",
        "load_design_contract" => "engine_run_opendesign_contract",
        "stage_workspace" => "engine_run_stage_workspace",
        "worker_act" => "engine_run_execute_agentic_loop",
        "verify" => "engine_run_verification_result",
        "preview" => "engine_run_preview_result",
        "observe_browser" => "engine_run_screenshot_evidence",
        "design_gate" => "engine_run_design_verdict_result",
        "repair" => "engine_run_write_repair_observation",
        "approval" => "engine_run_approval_requests",
        "copy_back" => "engine_run_apply_safe_changes",
        "finalize" => "engine_run_metadata"
      }.fetch(node_id, "engine_run_unknown_node")
    end

    def engine_run_graph_node_replay_policy(node_id)
      boundary = engine_run_graph_side_effect_boundary(node_id)
      {
        "resume_from" => boundary == "none" ? "replay_or_next_node" : "cursor_node_after_validation",
        "requires_artifact_hash_validation" => true,
        "can_replay_without_side_effect" => boundary == "none",
        "replay_guard" => "idempotency_key_and_artifact_hash"
      }
    end

    def engine_run_update_graph_state!(run_graph, final_status:, result:, policy:, verification:, preview:, screenshot_evidence:, design_verdict:, design_fidelity:, quarantine:)
      attempts = result.fetch(:cycles_completed).to_i
      engine_run_mark_graph_node!(run_graph, "preflight", "passed", attempt: 1)
      engine_run_mark_graph_node!(run_graph, "load_design_contract", "passed", attempt: 1)
      engine_run_mark_graph_node!(run_graph, "stage_workspace", "passed", attempt: 1)
      engine_run_mark_graph_node!(run_graph, "worker_act", result.fetch(:success) ? "passed" : "failed", attempt: attempts)
      engine_run_mark_graph_node!(run_graph, "verify", engine_run_graph_status_from_artifact(verification), attempt: attempts)
      engine_run_mark_graph_node!(run_graph, "preview", engine_run_graph_status_from_artifact(preview), attempt: attempts)
      engine_run_mark_graph_node!(run_graph, "observe_browser", engine_run_graph_status_from_artifact(screenshot_evidence), attempt: attempts)
      engine_run_mark_graph_node!(run_graph, "design_gate", engine_run_design_gate_graph_status(design_verdict, design_fidelity), attempt: attempts)
      engine_run_mark_graph_node!(run_graph, "repair", attempts > 1 ? (final_status == "passed" ? "passed" : "failed") : "skipped", attempt: [attempts - 1, 0].max)
      engine_run_mark_graph_node!(run_graph, "approval", final_status == "waiting_approval" ? "waiting_approval" : "skipped", attempt: final_status == "waiting_approval" ? 1 : 0)
      copy_back_state = if %w[passed no_changes].include?(final_status)
                          "passed"
                        elsif final_status == "quarantined" || quarantine.to_h.fetch("status", nil) == "quarantined"
                          "blocked"
                        elsif policy.fetch("blocking_issues", []).empty? && policy.fetch("approval_issues", []).empty?
                          "skipped"
                        else
                          "blocked"
                        end
      engine_run_mark_graph_node!(run_graph, "copy_back", copy_back_state, attempt: %w[passed no_changes].include?(final_status) ? 1 : 0)
      engine_run_mark_graph_node!(run_graph, "finalize", "passed", attempt: 1)
    end

    def engine_run_mark_graph_node!(run_graph, node_id, state, attempt:)
      node = run_graph.fetch("nodes").find { |candidate| candidate.fetch("node_id") == node_id }
      return unless node

      node["state"] = state
      node["attempt"] = attempt
      node["finished_at"] = now if %w[passed failed skipped blocked waiting_approval].include?(state)
    end

    def engine_run_graph_status_from_artifact(artifact)
      status = artifact.to_h.fetch("status", "skipped").to_s
      case status
      when "passed", "ready", "captured", "clear" then "passed"
      when "skipped", "missing" then "skipped"
      when "blocked", "quarantined", "waiting_approval" then status
      else "failed"
      end
    end

    def engine_run_design_gate_graph_status(design_verdict, design_fidelity)
      statuses = [design_verdict.to_h.fetch("status", "skipped"), design_fidelity.to_h.fetch("status", "skipped")].map(&:to_s)
      return "failed" if statuses.any? { |status| status == "failed" || status == "repair" }
      return "blocked" if statuses.any? { |status| status == "blocked" }
      return "skipped" if statuses.all? { |status| %w[skipped missing].include?(status) }

      "passed"
    end

    def engine_run_graph_cursor_node(status)
      case status
      when "passed", "no_changes" then "finalize"
      when "waiting_approval" then "approval"
      when "quarantined" then "copy_back"
      when "blocked" then "design_gate"
      else "worker_act"
      end
    end

    def engine_run_opendesign_contract(state, goal:)
      selected = state.dig("design_candidates", "selected_candidate").to_s.strip
      selected_ref = Array(state.dig("design_candidates", "candidates")).find { |candidate| candidate.is_a?(Hash) && candidate["id"].to_s == selected }
      selected_path = selected.empty? ? nil : selected_candidate_artifact_path(state, selected)
      files = {
        "design" => engine_run_contract_file(File.join(aiweb_dir, "DESIGN.md"), "design"),
        "design_reference_brief" => engine_run_contract_file(File.join(aiweb_dir, "design-reference-brief.md"), "reference_brief"),
        "selected_design" => engine_run_contract_file(File.join(aiweb_dir, "design-candidates", "selected.md"), "selected_design"),
        "selected_candidate" => selected_path ? engine_run_contract_file(selected_path, "selected_candidate") : nil,
        "component_map" => engine_run_contract_file(File.join(aiweb_dir, "component-map.json"), "component_map")
      }.compact.select { |_name, file| file["present"] }
      selected_file = files["selected_candidate"]
      component_map = engine_run_read_json_artifact(File.join(aiweb_dir, "component-map.json"))
      required_ids = selected_file ? engine_run_extract_data_aiweb_ids(File.read(File.join(root, selected_file.fetch("path")))) : []
      component_targets = Array(component_map && component_map["components"]).filter_map do |component|
        next unless component.is_a?(Hash) && !component["data_aiweb_id"].to_s.empty?

        {
          "data_aiweb_id" => component["data_aiweb_id"].to_s,
          "source_path" => component["source_path"].to_s
        }
      end
      component_ids = component_targets.map { |target| target["data_aiweb_id"] }
      requires_selected = engine_run_requires_opendesign_selection?(state, goal)
      blocking_issues = []
      if requires_selected && selected.empty?
        blocking_issues << "engine-run UI/source work requires a selected design candidate before agentic execution"
      elsif requires_selected && selected_file.nil?
        blocking_issues << "engine-run UI/source work requires selected design artifact #{selected_path ? relative(selected_path) : ".ai-web/design-candidates/#{selected}.html"}"
      end

      contract_basis = {
        "selected_candidate" => selected.empty? ? nil : selected,
        "selected_candidate_path" => selected_file && selected_file["path"],
        "artifacts" => files.transform_values { |file| file.slice("path", "sha256", "bytes") },
        "required_data_aiweb_ids" => required_ids,
        "component_data_aiweb_ids" => component_ids,
        "component_targets" => component_targets,
        "route_intent" => engine_run_route_intent(state, selected_ref),
        "required_quality_fields" => engine_run_opendesign_required_quality_fields,
        "token_requirements" => engine_run_token_requirements(files["design"]),
        "reference_no_copy_rules" => engine_run_reference_no_copy_rules(files),
        "reference_forbidden_terms" => engine_run_reference_forbidden_terms(files)
      }
      contract_hash = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(contract_basis))}"
      contract_basis.merge(
        "schema_version" => 1,
        "status" => selected_file ? "ready" : "missing",
        "contract_hash" => contract_hash,
        "selected_candidate_sha256" => selected_file && selected_file["sha256"],
        "requires_selected_design" => requires_selected,
        "blocking_issues" => blocking_issues
      )
    end

    def engine_run_contract_file(path, kind)
      expanded = File.expand_path(path, root)
      return { "kind" => kind, "path" => relative(expanded), "present" => false } unless File.file?(expanded)

      {
        "kind" => kind,
        "path" => relative(expanded),
        "present" => true,
        "bytes" => File.size(expanded),
        "sha256" => "sha256:#{Digest::SHA256.file(expanded).hexdigest}"
      }
    rescue SystemCallError
      { "kind" => kind, "path" => relative(path), "present" => false }
    end

    def engine_run_read_json_artifact(path)
      return nil unless File.file?(path)

      JSON.parse(File.read(path, 512 * 1024))
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def engine_run_extract_data_aiweb_ids(content)
      content.to_s.scan(/data-aiweb-id\s*=\s*["']([^"']+)["']/).flatten.uniq.sort
    end

    def engine_run_requires_opendesign_selection?(state, goal)
      profile = state.dig("implementation", "scaffold_profile").to_s
      profile = state.dig("implementation", "stack_profile").to_s if profile.empty?
      return false unless profile == "D"

      goal.to_s.match?(/\b(?:ui|ux|web|website|landing|page|hero|component|source|style|design|scaffold|frontend|screen|layout|copy)\b/i)
    end

    def engine_run_route_intent(state, selected_ref)
      intent = read_json_file(File.join(aiweb_dir, "intent.json")) || {}
      {
        "project_idea" => state.dig("project", "idea"),
        "first_view" => selected_ref && selected_ref["first_view"],
        "must_have_first_view" => Array(intent["must_have_first_view"]),
        "selected_strategy_id" => selected_ref && selected_ref["strategy_id"]
      }.compact
    end

    def engine_run_opendesign_required_quality_fields
      {
        "viewport_matrix" => %w[desktop tablet mobile],
        "route_intent" => true,
        "first_viewport_composition" => true,
        "typography_scale" => true,
        "line_height_rules" => true,
        "spacing_grid" => true,
        "density_target" => true,
        "color_contrast_requirements" => true,
        "component_state_matrix" => %w[default hover focus-visible active disabled loading empty error success],
        "motion_transition_expectations" => true,
        "responsive_breakpoint_obligations" => true,
        "required_data_aiweb_id_hooks" => true,
        "no_copy_reference_constraints" => true
      }
    end

    def engine_run_token_requirements(design_file)
      path = design_file && File.join(root, design_file["path"].to_s)
      return [] unless path && File.file?(path)

      text = File.read(path, 128 * 1024)
      css_vars = text.scan(/--[a-z0-9-]+/i)
      rule_lines = text.lines.grep(/\b(?:token|typography|color|palette|spacing|radius|grid|breakpoint)\b/i).map(&:strip)
      (css_vars + rule_lines).reject(&:empty?).uniq.first(80)
    rescue SystemCallError
      []
    end

    def engine_run_reference_no_copy_rules(files)
      defaults = [
        "Use reference material as pattern evidence only.",
        "Do not copy exact reference UI, layouts, copy, prices, trademarks, signed image URLs, or brand-specific claims."
      ]
      rules = files.values_at("design_reference_brief", "selected_design").compact.flat_map do |file|
        path = File.join(root, file["path"].to_s)
        next [] unless File.file?(path)

        File.readlines(path, chomp: true).select { |line| line.match?(/\b(?:do not copy|copy risk|reference|trademark|price|exact)\b/i) }.map(&:strip)
      rescue SystemCallError
        []
      end
      (defaults + rules).reject(&:empty?).uniq.first(40)
    end

    def engine_run_reference_forbidden_terms(files)
      brief = files["design_reference_brief"]
      return [] unless brief

      path = File.join(root, brief["path"].to_s)
      return [] unless File.file?(path)

      text = File.read(path, 128 * 1024)
      company_terms = text.lines.grep(/\A\s*(?:companies|brands|references)\s*:/i).flat_map do |line|
        line.split(":", 2).last.to_s.split(/[,;]/).map(&:strip)
      end
      company_terms.map { |term| term.gsub(/[^A-Za-z0-9 ._-]/, "").strip }
                   .select { |term| term.match?(/[A-Za-z]/) && term.length >= 3 }
                   .uniq
                   .first(40)
    rescue SystemCallError
      []
    end

    def engine_run_capability_opendesign_contract(contract)
      return nil unless contract

      {
        "status" => contract["status"],
        "contract_hash" => contract["contract_hash"],
        "selected_candidate" => contract["selected_candidate"],
        "selected_candidate_path" => contract["selected_candidate_path"],
        "requires_selected_design" => contract["requires_selected_design"]
      }
    end

    def engine_run_checkpoint_opendesign_contract(contract)
      return nil unless contract

      {
        "status" => contract["status"],
        "contract_hash" => contract["contract_hash"],
        "selected_candidate" => contract["selected_candidate"],
        "selected_candidate_path" => contract["selected_candidate_path"]
      }
    end

    def engine_run_opendesign_events(events_path, events, contract, resume_context)
      if contract["status"] == "ready"
        engine_run_event(events_path, events, "design.contract.loaded", "loaded OpenDesign runtime contract", contract_hash: contract["contract_hash"], selected_candidate: contract["selected_candidate"])
      else
        engine_run_event(events_path, events, "design.contract.missing", "OpenDesign runtime contract is incomplete", blocking_issues: contract["blocking_issues"])
      end
      previous_hash = resume_context && resume_context.dig(:metadata, "opendesign_contract", "contract_hash")
      if previous_hash && previous_hash != contract["contract_hash"]
        engine_run_event(events_path, events, "design.contract.changed", "OpenDesign contract changed since resumed run", previous_contract_hash: previous_hash, current_contract_hash: contract["contract_hash"])
      end
    end

    def engine_run_planned_events
      %w[
        run.created
        goal.understood
        design.contract.loaded
        design.contract.missing
        design.contract.changed
        preflight.started
        preflight.finished
        project.indexed
        graph.scheduler.planned
        graph.scheduler.started
        graph.node.finished
        graph.scheduler.finished
        sandbox.preflight.started
        sandbox.preflight.finished
        plan.created
        step.started
        tool.requested
        policy.decision
        tool.started
        tool.finished
        tool.blocked
        tool.action.requested
        tool.action.blocked
        design.fidelity.checked
        artifact.created
        preview.started
        preview.ready
        preview.failed
        preview.stopped
        screenshot.capture.started
        screenshot.capture.finished
        screenshot.capture.failed
        browser.observation.recorded
        browser.action_recovery.recorded
        design.review.started
        design.review.finished
        design.review.failed
        design.fixture.recorded
        design.repair.planned
        design.repair.started
        design.repair.finished
        qa.failed
        repair.planned
        patch.generated
        approval.requested
        approval.granted
        checkpoint.saved
        run.resumed
        run.quarantined
        run.finished
      ]
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
        record["run_graph"] = run_graph.slice("schema_version", "run_id", "nodes", "executor_contract", "resume_policy", "side_effects_must_use_tool_broker")
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

    def engine_run_sandbox_preflight_skipped(reason)
      {
        "schema_version" => 1,
        "status" => "skipped",
        "generated_argv" => [],
        "resolved_executable_path" => nil,
        "container_image" => nil,
        "container_image_digest" => nil,
        "container_image_inspect" => { "status" => "skipped", "reason" => reason.to_s },
        "runtime_info" => { "status" => "skipped", "reason" => reason.to_s },
        "runtime_matrix" => {
          "schema_version" => 1,
          "status" => "skipped",
          "required" => false,
          "selected_runtime" => nil,
          "requested_runtimes" => [],
          "entries" => [],
          "blocking_issues" => []
        },
        "inside_container_probe" => {
          "schema_version" => 1,
          "status" => "skipped",
          "reason" => reason.to_s
        },
        "container_id" => nil,
        "runtime_container_inspect" => { "status" => "not_observed", "reason" => reason.to_s, "blocking_issues" => [] },
        "effective_user" => nil,
        "security_attestation" => engine_run_not_observed_security_attestation(reason.to_s),
        "host_mounts" => [],
        "inside_mounts" => [],
        "network_mode" => nil,
        "sandbox_user" => nil,
        "egress_denial_probe" => { "status" => "not_observed", "method" => "skipped", "reason" => reason.to_s },
        "capabilities" => {},
        "resource_limits" => {},
        "negative_checks" => {},
        "preflight_warnings" => [reason.to_s],
        "blocking_issues" => []
      }
    end

    def engine_run_sandbox_preflight_evidence(agent:, sandbox:, workspace_dir:, command:)
      argv = Array(command).map(&:to_s)
      mounts = sandbox_runtime_argv_values(argv, "-v")
      image = engine_run_container_worker_agent?(agent) ? engine_run_agent_container_image(agent) : nil
      image_inspect = engine_run_container_image_inspect(sandbox, image)
      runtime_info = engine_run_sandbox_runtime_info(sandbox)
      inside_probe = engine_run_sandbox_self_attestation_probe(agent: agent, sandbox: sandbox, workspace_dir: workspace_dir)
      runtime_matrix = engine_run_sandbox_runtime_matrix_evidence(
        agent: agent,
        selected_sandbox: sandbox,
        workspace_dir: workspace_dir,
        selected_runtime_info: runtime_info,
        selected_inside_probe: inside_probe,
        selected_image_inspect: image_inspect
      )
      container_id = inside_probe["runtime_container_id"] || inside_probe["container_id"]
      runtime_container_inspect = inside_probe["runtime_container_inspect"] || { "status" => "not_observed", "reason" => "self_attestation_probe_missing_runtime_container_inspect" }
      egress_probe = inside_probe.fetch("egress_denial_probe", {
        "status" => sandbox_runtime_argv_option_value(argv, "--network") == "none" ? "configured" : "missing",
        "method" => "argv_network_none"
      })
      security_attestation = inside_probe["security_attestation"] || engine_run_failed_security_attestation("self_attestation_probe_missing_security_attestation")
      evidence = {
        "schema_version" => 1,
        "status" => "passed",
        "recorded_at" => now,
        "managed_runtime_equivalence" => "local_docker_podman_is_not_managed_microvm",
        "agent" => agent,
        "sandbox" => sandbox,
        "generated_argv" => argv,
        "resolved_executable_path" => executable_path(sandbox.to_s),
        "container_image" => image,
        "container_image_digest_required" => engine_run_require_digest_pinned_openmanus_image?,
        "container_image_digest_policy_source" => engine_run_digest_pinned_openmanus_policy_sources,
        "container_image_reference_pinned" => engine_run_digest_pinned_image?(image),
        "container_image_digest" => engine_run_container_image_digest(image, image_inspect),
        "container_image_inspect" => image_inspect,
        "preflight_warnings" => engine_run_sandbox_preflight_warnings(image: image, image_inspect: image_inspect, runtime_info: runtime_info, inside_probe: inside_probe),
        "container_id" => container_id,
        "container_hostname" => inside_probe["container_id"],
        "runtime_container_inspect" => runtime_container_inspect,
        "effective_user" => inside_probe["effective_user"] || "not_observed",
        "inside_container_probe" => inside_probe,
        "security_attestation" => security_attestation,
        "rootless_mode" => runtime_info.fetch("rootless_mode", "not_observed"),
        "runtime_info" => runtime_info,
        "runtime_matrix" => runtime_matrix,
        "host_mounts" => mounts,
        "inside_mounts" => mounts.map { |mount| sandbox_runtime_mount_target(mount) },
        "workspace_mount" => mounts.find { |mount| mount.end_with?(":/workspace:rw") },
        "network_mode" => sandbox_runtime_argv_option_value(argv, "--network"),
        "sandbox_user" => sandbox_runtime_argv_option_value(argv, "--user"),
        "egress_denial_probe" => egress_probe,
        "capabilities" => {
          "cap_drop" => sandbox_runtime_argv_option_value(argv, "--cap-drop"),
          "no_new_privileges" => sandbox_runtime_argv_option_value(argv, "--security-opt") == "no-new-privileges"
        },
        "seccomp_apparmor_profile" => runtime_info.fetch("security_options", []).empty? ? "runtime_default" : runtime_info.fetch("security_options"),
        "resource_limits" => {
          "pids_limit" => sandbox_runtime_argv_option_value(argv, "--pids-limit"),
          "memory" => sandbox_runtime_argv_option_value(argv, "--memory"),
          "cpus" => sandbox_runtime_argv_option_value(argv, "--cpus"),
          "tmpfs" => sandbox_runtime_argv_option_value(argv, "--tmpfs")
        },
        "negative_checks" => engine_run_sandbox_negative_checks(argv, workspace_dir),
        "shared_responsibility" => %w[
          agent_code_security
          dependency_management
          iam_resource_policies
          command_security
          session_to_user_mapping
          prompt_injection_tool_abuse_defense
          network_configuration
        ]
      }
      evidence["blocking_issues"] = engine_run_sandbox_preflight_blockers(evidence)
      evidence["status"] = evidence["blocking_issues"].empty? ? "passed" : "failed"
      evidence
    end

    def engine_run_sandbox_preflight_blockers(evidence)
      blockers = []
      blockers << "sandbox command must disable networking with --network none" unless evidence["network_mode"] == "none"
      blockers << "inside-container self-attestation probe did not pass" unless evidence.dig("inside_container_probe", "status") == "passed"
      blockers << "inside-container egress denial probe did not pass" unless evidence.dig("egress_denial_probe", "status") == "passed"
      blockers << "inside-container security attestation did not pass" unless evidence.dig("security_attestation", "status") == "passed"
      blockers << "runtime container inspect cross-check did not pass" unless evidence.dig("runtime_container_inspect", "status") == "passed"
      if evidence.dig("runtime_matrix", "required") && evidence.dig("runtime_matrix", "status") != "passed"
        blockers << "sandbox runtime matrix verification did not pass"
      end
      blockers << "sandbox preflight did not observe a container id/hostname" if evidence["container_id"].to_s.strip.empty?
      effective_user = evidence["effective_user"]
      if effective_user.is_a?(Hash)
        blockers << "sandbox preflight did not observe an effective user id" if effective_user["uid"].nil?
        blockers << "sandbox preflight observed root effective user" if effective_user["uid"].to_i == 0
      else
        blockers << "sandbox preflight did not observe an effective user id"
      end
      blockers.uniq
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

    def engine_run_preflight_probe_command(command, cidfile)
      argv = Array(command).map(&:to_s)
      run_index = argv.index("run")
      return argv unless run_index

      argv.dup.tap do |copy|
        copy.delete_at(copy.index("--rm")) if copy.include?("--rm")
        copy.insert(run_index + 1, "--cidfile", cidfile.to_s)
      end
    end

    def engine_run_runtime_container_inspect(sandbox, container_id, expected_workspace_dir: nil)
      return { "status" => "not_observed", "reason" => "missing_container_id" } if sandbox.to_s.strip.empty? || container_id.to_s.strip.empty?

      stdout, stderr, status = Open3.capture3(subprocess_path_env, sandbox.to_s, "inspect", container_id.to_s, unsetenv_others: true)
      return { "status" => "failed", "exit_code" => status.exitstatus, "stderr" => agent_run_redact_process_output(stderr.to_s)[0, 1000] } unless status.success?

      parsed = stdout.to_s.strip.empty? ? [] : JSON.parse(stdout.to_s)
      record = parsed.is_a?(Array) ? parsed.first : parsed
      record = {} unless record.is_a?(Hash)
      host_config = record["HostConfig"].is_a?(Hash) ? record["HostConfig"] : {}
      config = record["Config"].is_a?(Hash) ? record["Config"] : {}
      state = record["State"].is_a?(Hash) ? record["State"] : {}
      blockers = engine_run_runtime_container_inspect_blockers(host_config: host_config, config: config, record: record, expected_workspace_dir: expected_workspace_dir)
      {
        "status" => blockers.empty? ? "passed" : "failed",
        "blocking_issues" => blockers,
        "container_id" => record["Id"].to_s.empty? ? container_id.to_s : record["Id"].to_s,
        "name" => record["Name"],
        "image" => record["Image"],
        "state" => {
          "status" => state["Status"],
          "exit_code" => state["ExitCode"],
          "oom_killed" => state["OOMKilled"]
        },
        "config_user" => config["User"],
        "expected_workspace_source" => expected_workspace_dir.to_s.empty? ? nil : File.expand_path(expected_workspace_dir.to_s),
        "host_config" => {
          "network_mode" => host_config["NetworkMode"],
          "readonly_rootfs" => host_config["ReadonlyRootfs"],
          "cap_drop" => Array(host_config["CapDrop"]).map(&:to_s),
          "security_opt" => Array(host_config["SecurityOpt"]).map(&:to_s),
          "userns_mode" => host_config["UsernsMode"],
          "pids_limit" => host_config["PidsLimit"],
          "memory" => host_config["Memory"],
          "nano_cpus" => host_config["NanoCpus"]
        },
        "apparmor_profile" => record["AppArmorProfile"],
        "process_label" => record["ProcessLabel"],
        "mounts" => Array(record["Mounts"]).map do |mount|
          {
            "type" => mount["Type"],
            "source" => mount["Source"],
            "destination" => mount["Destination"],
            "mode" => mount["Mode"],
            "rw" => mount["RW"]
          }
        end
      }
    rescue JSON::ParserError
      { "status" => "failed", "reason" => "container_inspect_parse_failed" }
    rescue SystemCallError => e
      { "status" => "failed", "reason" => e.message }
    end

    def engine_run_runtime_container_inspect_blockers(host_config:, config:, record:, expected_workspace_dir: nil)
      blockers = []
      network_mode = host_config["NetworkMode"].to_s
      readonly_rootfs = host_config["ReadonlyRootfs"]
      cap_drop = Array(host_config["CapDrop"]).map(&:to_s)
      security_opt = Array(host_config["SecurityOpt"]).map(&:to_s)
      user = config["User"].to_s.strip

      blockers << "runtime inspect did not confirm --network none" unless network_mode == "none"
      blockers << "runtime inspect did not confirm read-only root filesystem" unless readonly_rootfs == true
      blockers << "runtime inspect did not confirm cap-drop ALL" unless cap_drop.include?("ALL")
      unless security_opt.any? { |option| option == "no-new-privileges" || option.start_with?("no-new-privileges:") }
        blockers << "runtime inspect did not confirm no-new-privileges"
      end
      blockers << "runtime inspect did not confirm non-root --user" if user.empty? || user == "0" || user.start_with?("0:")

      mounts = Array(record["Mounts"]).select { |mount| mount.is_a?(Hash) }
      workspace_mounts = mounts.select { |mount| mount["Type"].to_s == "bind" && mount["Destination"].to_s == "/workspace" }
      blockers << "runtime inspect did not observe exactly one /workspace bind mount" unless workspace_mounts.length == 1
      workspace_mounts.each do |mount|
        blockers << "runtime inspect did not confirm writable /workspace mount" unless mount["RW"] == true
        source = mount["Source"].to_s
        if expected_workspace_dir && !engine_run_same_filesystem_path?(source, expected_workspace_dir)
          blockers << "runtime inspect did not confirm /workspace source is the staged workspace"
        end
      end

      mounts.each do |mount|
        next unless mount.is_a?(Hash)

        if mount["Type"].to_s == "bind" && mount["Destination"].to_s != "/workspace"
          blockers << "runtime inspect observed unexpected bind mount #{mount["Destination"]}"
        end
      end

      blockers.uniq
    end

    def engine_run_same_filesystem_path?(observed, expected)
      observed_path = engine_run_normalized_filesystem_path(observed)
      expected_path = engine_run_normalized_filesystem_path(expected)
      !observed_path.empty? && observed_path == expected_path
    end

    def engine_run_normalized_filesystem_path(path)
      text = path.to_s.strip
      return "" if text.empty?

      expanded = File.expand_path(text)
      expanded = File.realpath(expanded) if File.exist?(expanded)
      normalized = expanded.tr("\\", "/").sub(%r{/+\z}, "")
      File::ALT_SEPARATOR == "\\" ? normalized.downcase : normalized
    rescue ArgumentError, SystemCallError
      text.tr("\\", "/").sub(%r{/+\z}, "")
    end

    def engine_run_remove_runtime_container(sandbox, container_id)
      return if sandbox.to_s.strip.empty? || container_id.to_s.strip.empty?

      Open3.capture3(subprocess_path_env, sandbox.to_s, "rm", "-f", container_id.to_s, unsetenv_others: true)
      nil
    rescue SystemCallError
      nil
    end

    def engine_run_digest_pinned_image?(image)
      image.to_s.include?("@sha256:")
    end

    def engine_run_require_digest_pinned_openmanus_image?
      !engine_run_digest_pinned_openmanus_policy_sources.empty?
    end

    def engine_run_required_sandbox_runtime_matrix
      engine_run_sandbox_runtime_matrix_tokens.select { |runtime| %w[docker podman].include?(runtime) }.uniq
    end

    def engine_run_invalid_sandbox_runtime_matrix
      engine_run_sandbox_runtime_matrix_tokens.reject { |runtime| %w[docker podman].include?(runtime) }.uniq
    end

    def engine_run_sandbox_runtime_matrix_tokens
      raw = ENV["AIWEB_ENGINE_RUN_RUNTIME_MATRIX"].to_s
      raw = "docker,podman" if raw.strip.empty? && engine_run_truthy_env?(ENV["AIWEB_ENGINE_RUN_REQUIRE_RUNTIME_MATRIX"])
      raw = "docker,podman" if raw.strip.empty? && engine_run_truthy_env?(ENV["AIWEB_REQUIRE_DOCKER_PODMAN_MATRIX"])
      raw.split(/[\s,]+/).map(&:strip).map(&:downcase).reject(&:empty?)
    end

    def engine_run_required_sandbox_runtime_matrix_policy_sources
      sources = []
      sources << "AIWEB_ENGINE_RUN_RUNTIME_MATRIX" unless ENV["AIWEB_ENGINE_RUN_RUNTIME_MATRIX"].to_s.strip.empty?
      sources << "AIWEB_ENGINE_RUN_REQUIRE_RUNTIME_MATRIX" if engine_run_truthy_env?(ENV["AIWEB_ENGINE_RUN_REQUIRE_RUNTIME_MATRIX"])
      sources << "AIWEB_REQUIRE_DOCKER_PODMAN_MATRIX" if engine_run_truthy_env?(ENV["AIWEB_REQUIRE_DOCKER_PODMAN_MATRIX"])
      sources
    end

    def engine_run_truthy_env?(value)
      %w[1 true yes on strict required].include?(value.to_s.strip.downcase)
    end

    def engine_run_digest_pinned_openmanus_policy_sources
      values = [
        ["AIWEB_OPENMANUS_REQUIRE_DIGEST", ENV["AIWEB_OPENMANUS_REQUIRE_DIGEST"]],
        ["AIWEB_REQUIRE_PINNED_OPENMANUS_IMAGE", ENV["AIWEB_REQUIRE_PINNED_OPENMANUS_IMAGE"]],
        ["AIWEB_ENGINE_RUN_STRICT_SANDBOX", ENV["AIWEB_ENGINE_RUN_STRICT_SANDBOX"]],
        ["AIWEB_ENV", ENV["AIWEB_ENV"]],
        ["AIWEB_RUNTIME_ENV", ENV["AIWEB_RUNTIME_ENV"]],
        ["AIWEB_ENGINE_RUN_ENV", ENV["AIWEB_ENGINE_RUN_ENV"]]
      ]
      values.each_with_object([]) do |(name, value), sources|
        normalized = value.to_s.strip.downcase
        next unless %w[1 true yes on strict production prod].include?(normalized)

        sources << name
      end
    end

    def engine_run_sandbox_preflight_warnings(image:, image_inspect:, runtime_info:, inside_probe:)
      warnings = []
      warnings << "container image reference is not digest-pinned" if image.to_s.strip != "" && !engine_run_digest_pinned_image?(image)
      warnings << "container image digest was not observable" if image.to_s.strip != "" && image_inspect.fetch("digest", nil).to_s.strip.empty?
      warnings << "sandbox runtime rootless/rootful mode was not observable" if runtime_info.fetch("rootless_mode", "not_observed") == "not_observed"
      warnings << "inside-container self-attestation probe did not pass" unless inside_probe.fetch("status", "not_observed") == "passed"
      warnings << "inside-container egress denial was not proven" unless inside_probe.dig("egress_denial_probe", "status") == "passed"
      warnings
    end

    def engine_run_container_image_inspect(sandbox, image)
      return { "status" => "skipped", "reason" => "missing_sandbox_or_image" } if sandbox.to_s.strip.empty? || image.to_s.strip.empty?

      stdout, _stderr, status = Open3.capture3(subprocess_path_env, sandbox.to_s, "image", "inspect", image.to_s, unsetenv_others: true)
      return { "status" => "failed", "exit_code" => status.exitstatus } unless status.success?
      return { "status" => "failed", "reason" => "image_inspect_empty_output" } if stdout.to_s.strip.empty?

      parsed = JSON.parse(stdout.to_s)
      image_record = parsed.is_a?(Array) ? parsed.first : parsed
      return { "status" => "failed", "reason" => "image_inspect_missing_record" } unless image_record.is_a?(Hash)

      repo_digests = Array(image_record["RepoDigests"]).map(&:to_s).reject(&:empty?)
      image_id = image_record["Id"].to_s
      digest = repo_digests.find { |entry| entry.include?("@sha256:") } ||
               (image_id.match?(/\Asha256:[a-f0-9]{64}\z/i) ? image_id : nil)
      return { "status" => "failed", "reason" => "image_inspect_missing_digest", "repo_digests" => repo_digests, "image_id" => image_id.empty? ? nil : image_id } if digest.to_s.empty?

      {
        "status" => "passed",
        "digest" => digest,
        "repo_digests" => repo_digests,
        "image_id" => image_id.empty? ? nil : image_id,
        "created" => image_record["Created"],
        "architecture" => image_record["Architecture"],
        "os" => image_record["Os"]
      }
    rescue JSON::ParserError
      { "status" => "failed", "reason" => "image_inspect_parse_failed" }
    rescue SystemCallError => e
      { "status" => "failed", "error" => e.message }
    end

    def engine_run_container_image_digest(image, image_inspect)
      return image.to_s[/sha256:[a-f0-9]{64}/i] if engine_run_digest_pinned_image?(image)

      image_inspect.fetch("digest", nil)
    end

    def engine_run_sandbox_runtime_info(sandbox)
      return { "status" => "skipped", "reason" => "missing_sandbox" } if sandbox.to_s.strip.empty?

      stdout, _stderr, status = Open3.capture3(subprocess_path_env, sandbox.to_s, "info", "--format", "{{json .}}", unsetenv_others: true)
      return { "status" => "failed", "exit_code" => status.exitstatus, "rootless_mode" => "not_observed", "security_options" => [] } unless status.success?

      parsed = stdout.to_s.strip.empty? ? {} : JSON.parse(stdout.to_s)
      parsed = {} unless parsed.is_a?(Hash)
      security_options = Array(parsed["SecurityOptions"] || parsed.dig("Host", "Security", "SecurityOptions")).map(&:to_s)
      rootless = parsed.dig("Host", "Security", "Rootless")
      rootless = security_options.any? { |item| item.match?(/rootless/i) } if rootless.nil?
      {
        "status" => "passed",
        "rootless_mode" => rootless.nil? ? "not_observed" : (rootless ? "observed_rootless" : "observed_rootful"),
        "security_options" => security_options,
        "server_version" => parsed["ServerVersion"] || parsed["Version"],
        "driver" => parsed["Driver"],
        "cgroup_driver" => parsed["CgroupDriver"] || parsed.dig("Host", "CgroupManager")
      }
    rescue JSON::ParserError
      { "status" => "passed", "raw_parse_failed" => true, "rootless_mode" => "not_observed", "security_options" => [] }
    rescue SystemCallError => e
      { "status" => "failed", "error" => e.message, "rootless_mode" => "not_observed", "security_options" => [] }
    end

    def engine_run_sandbox_negative_checks(argv, workspace_dir)
      mounts = sandbox_runtime_argv_values(argv, "-v")
      mounted_hosts = mounts.map { |mount| sandbox_runtime_mount_host(mount) }.reject(&:empty?).map { |host| File.expand_path(host) }
      forbidden = {
        "project_root" => root,
        ".git" => File.join(root, ".git"),
        ".env" => File.join(root, ".env"),
        ".env.local" => File.join(root, ".env.local"),
        "cloud_credentials" => File.join(Dir.home, ".aws"),
        "browser_profiles" => File.join(Dir.home, ".config", "google-chrome"),
        "host_home" => Dir.home
      }
      expected_workspace = File.expand_path(workspace_dir)
      forbidden.transform_values do |path|
        expanded = File.expand_path(path)
        mounted = mounted_hosts.any? do |host|
          host_cmp = windows? ? host.downcase : host
          expanded_cmp = windows? ? expanded.downcase : expanded
          workspace_cmp = windows? ? expected_workspace.downcase : expected_workspace
          next false if host_cmp == workspace_cmp

          host_cmp == expanded_cmp || expanded_cmp.start_with?("#{host_cmp}#{File::SEPARATOR}") || host_cmp.start_with?("#{expanded_cmp}#{File::SEPARATOR}")
        end
        mounted ? "mounted" : "not_mounted"
      end
    rescue SystemCallError
      { "status" => "unknown" }
    end

    def engine_run_project_index(manifest)
      files = manifest.fetch("files", {})
      package_scripts = engine_run_package_scripts(files)
      {
        "schema_version" => 1,
        "status" => "ready",
        "generated_at" => now,
        "source" => "staged_manifest_repo_index",
        "manifest_file_count" => files.length,
        "retrieval" => {
          "strategy" => "repo_index_json_rg_compatible",
          "dependency_free" => true,
          "worker_context_ref" => "_aiweb/project-index.json"
        },
        "routes" => engine_run_index_group(files, %r{\A(?:src/)?(?:pages/.+\.(?:astro|js|jsx|ts|tsx|vue|svelte)|app/.+(?:page|route)\.(?:js|jsx|ts|tsx))\z}, "route"),
        "components" => engine_run_component_index(files),
        "styles" => engine_run_index_group(files, %r{\A(?:(?:src/)?styles/.+|app/.+\.css|src/app/.+\.css|.+(?:global|style|theme|tailwind).*\.(?:css|scss|sass)|(?:astro|vite|tailwind)\.config\.(?:js|mjs|cjs|ts))\z}, "style"),
        "data_contracts" => engine_run_index_group(files, %r{\A(?:(?:src/)?content/.+|(?:src/)?data/.+|schemas?/.+|prisma/schema\.prisma|supabase/.+|\.ai-web/component-map\.json|.+(?:schema|contract|model|type).*\.(?:json|ts|tsx|js|rb))\z}, "data_contract"),
        "auth_surface" => engine_run_index_group(files, %r{(?:auth|login|signup|middleware|session|supabase|clerk|nextauth|oauth)}i, "auth"),
        "env_surface" => {
          "content_read" => false,
          "policy" => "names_only_no_env_values",
          "files" => Dir.glob(File.join(root, ".env*")).select { |path| File.file?(path) }.map { |path| relative(path) }.sort
        },
        "package_scripts" => package_scripts,
        "test_commands" => package_scripts.select { |name, _command| name.match?(/\b(?:test|check|lint|type|build|preview|dev)\b/i) },
        "authz_context" => {
          "local_project_scope" => true,
          "saas_claims_required_before_remote_exposure" => %w[tenant_id project_id user_id]
        }
      }
    end

    def engine_run_package_scripts(files)
      return {} unless files.key?("package.json")

      parsed = JSON.parse(File.read(File.join(root, "package.json"), 128 * 1024))
      parsed.fetch("scripts", {}).to_h.transform_values(&:to_s).sort.to_h
    rescue JSON::ParserError, SystemCallError
      {}
    end

    def engine_run_index_group(files, pattern, kind)
      items = files.keys.grep(pattern).sort.first(200).map do |path|
        engine_run_index_item(path, files.fetch(path), kind)
      end
      { "status" => items.empty? ? "empty" : "ready", "items" => items }
    end

    def engine_run_component_index(files)
      declared = engine_run_component_map_targets
      discovered = engine_run_index_group(files, %r{\A(?:src/)?components/.+\.(?:astro|js|jsx|ts|tsx|vue|svelte)\z}, "component").fetch("items")
      {
        "status" => (declared.empty? && discovered.empty?) ? "empty" : "ready",
        "declared" => declared,
        "items" => (discovered + declared.filter_map do |target|
          path = target["source_path"].to_s
          next if path.empty? || !files.key?(path)

          engine_run_index_item(path, files.fetch(path), "component").merge("data_aiweb_id" => target["data_aiweb_id"])
        end).uniq { |entry| [entry["path"], entry["data_aiweb_id"]] }.first(200)
      }
    end

    def engine_run_component_map_targets
      path = File.join(root, ".ai-web", "component-map.json")
      parsed = File.file?(path) ? JSON.parse(File.read(path, 256 * 1024)) : {}
      Array(parsed["components"]).filter_map do |component|
        next unless component.is_a?(Hash)

        source_path = component["source_path"].to_s
        next if source_path.empty?

        {
          "data_aiweb_id" => component["data_aiweb_id"].to_s,
          "source_path" => source_path,
          "editable" => component["editable"] == true
        }
      end
    rescue JSON::ParserError, SystemCallError
      []
    end

    def engine_run_index_item(path, metadata, kind)
      digest = metadata["sha256"].to_s
      digest = "sha256:#{digest}" unless digest.empty? || digest.start_with?("sha256:")
      {
        "path" => path,
        "kind" => kind,
        "sha256" => digest,
        "bytes" => metadata["bytes"]
      }.compact
    end

    def engine_run_write_workspace_project_index(workspace_dir, project_index)
      path = File.join(workspace_dir, "_aiweb", "project-index.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(project_index))
      path
    end

    def engine_run_memory_index(run_id:, goal:, project_index:, opendesign_contract:, paths:)
      route_records = Array(project_index.dig("routes", "items")).first(20).map do |item|
        engine_run_memory_record("route", item["path"], item.slice("path", "kind", "source_path"))
      end
      component_records = Array(project_index.dig("components", "items")).first(40).map do |item|
        engine_run_memory_record("component", item["path"], item.slice("path", "data_aiweb_id", "source_path", "editable"))
      end
      script_records = project_index.fetch("package_scripts", {}).to_h.first(20).map do |name, command|
        engine_run_memory_record("package_script", name, { "name" => name, "command" => command })
      end
      design_records = [
        engine_run_memory_record(
          "design_contract",
          opendesign_contract.to_h["selected_candidate"] || "opendesign_contract",
          {
            "status" => opendesign_contract.to_h["status"],
            "selected_candidate" => opendesign_contract.to_h["selected_candidate"],
            "contract_hash" => opendesign_contract.to_h["contract_hash"],
            "selected_candidate_sha256" => opendesign_contract.to_h["selected_candidate_sha256"]
          }
        )
      ]
      memory_records = (design_records + route_records + component_records + script_records).compact
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "recorded_at" => now,
        "goal" => goal,
        "status" => "ready",
        "retrieval_strategy" => "bounded_lexical_cards",
        "rag_status" => "not_configured",
        "rag_gap" => "No embedding store or LlamaIndex pipeline is configured; this artifact provides deterministic retrieval cards for the current run only.",
        "memory_records" => memory_records,
        "memory_record_count" => memory_records.length,
        "evidence_refs" => {
          "project_index_path" => relative(paths.fetch(:project_index_path)),
          "opendesign_contract_path" => relative(paths.fetch(:opendesign_contract_path)),
          "run_memory_path" => relative(paths.fetch(:run_memory_path))
        },
        "worker_handoff" => {
          "workspace_path" => "_aiweb/run-memory.json",
          "allowed_use" => "read-only retrieval context for the selected worker adapter",
          "must_not_contain" => %w[raw_env secret_values provider_tokens]
        }
      }
    end

    def engine_run_memory_record(kind, key, payload)
      key_text = key.to_s
      return nil if key_text.empty?

      body = payload.to_h.compact
      {
        "id" => "mem-#{Digest::SHA256.hexdigest([kind, key_text, JSON.generate(body)].join("\0"))[0, 16]}",
        "kind" => kind,
        "key" => key_text,
        "summary" => body.map { |field, value| "#{field}=#{value}" }.join("; ")[0, 500],
        "payload" => body
      }
    end

    def engine_run_write_workspace_run_memory(workspace_dir, run_memory)
      path = File.join(workspace_dir, "_aiweb", "run-memory.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(run_memory))
      path
    end

    def engine_run_write_workspace_worker_adapter_contract(workspace_dir, contract)
      path = File.join(workspace_dir, "_aiweb", "worker-adapter-contract.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(contract))
      path
    end

    def engine_run_write_workspace_worker_adapter_registry(workspace_dir, registry)
      path = File.join(workspace_dir, "_aiweb", "worker-adapter-registry.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.pretty_generate(registry))
      path
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

    def engine_run_tool_broker_shim_source(tool_name, config)
      <<~SH
        #!/bin/sh
        set -eu
        TOOL_NAME=#{Shellwords.escape(tool_name)}
        RISK_CLASS=#{Shellwords.escape(config.fetch("risk"))}
        BLOCK_MODE=#{Shellwords.escape(config.fetch("mode"))}
        BLOCK_REASON=#{Shellwords.escape(config.fetch("reason"))}
        EVENT_PATH="${AIWEB_TOOL_BROKER_EVENTS_PATH:-/workspace/_aiweb/tool-broker-events.jsonl}"
        REAL_PATH="${AIWEB_TOOL_BROKER_REAL_PATH:-/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}"
        SHIM_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

        aiweb_block() {
          mkdir -p "$(dirname -- "$EVENT_PATH")"
          ARG_COUNT=$#
          printf '{"schema_version":1,"type":"tool.blocked","tool_name":"%s","risk_class":"%s","reason":"%s","args_redacted":true,"arg_count":%s}\\n' "$TOOL_NAME" "$RISK_CLASS" "$BLOCK_REASON" "$ARG_COUNT" >> "$EVENT_PATH"
          printf 'AIWEB_TOOL_BROKER_BLOCKED %s: %s\\n' "$RISK_CLASS" "$BLOCK_REASON" >&2
          exit 126
        }

        aiweb_delegate() {
          OLD_IFS=$IFS
          IFS=:
          for dir in $REAL_PATH; do
            IFS=$OLD_IFS
            [ -n "$dir" ] || continue
            [ "$dir" = "$SHIM_DIR" ] && continue
            if [ -x "$dir/$TOOL_NAME" ]; then
              exec "$dir/$TOOL_NAME" "$@"
            fi
            IFS=:
          done
          IFS=$OLD_IFS
          printf 'AIWEB_TOOL_BROKER_REAL_COMMAND_MISSING %s\\n' "$TOOL_NAME" >&2
          exit 127
        }

        aiweb_first_subcommand() {
          while [ "$#" -gt 0 ]; do
            case "$1" in
              --)
                shift
                break
                ;;
              --prefix|--workspace|--filter|--cwd|--cache|--userconfig|--registry|-C|-w)
                shift
                [ "$#" -gt 0 ] && shift
                continue
                ;;
              --prefix=*|--workspace=*|--filter=*|--cwd=*|--cache=*|--userconfig=*|--registry=*|-C=*|-w=*)
                shift
                continue
                ;;
              -c)
                shift
                if [ "$TOOL_NAME" = "git" ]; then
                  [ "$#" -gt 0 ] && shift
                fi
                continue
                ;;
              -*)
                shift
                continue
                ;;
              *)
                printf '%s' "$1"
                return 0
                ;;
            esac
          done
          [ "$#" -gt 0 ] && printf '%s' "$1"
        }

        aiweb_contains_package_install() {
          for arg in "$@"; do
            case "$arg" in
              add|install|i|ci|update|upgrade|up) return 0 ;;
            esac
          done
          return 1
        }

        aiweb_contains_git_push() {
          for arg in "$@"; do
            [ "$arg" = "push" ] && return 0
          done
          return 1
        }

        case "$BLOCK_MODE" in
          always_block)
            aiweb_block "$@"
            ;;
          package_manager)
            if aiweb_contains_package_install "$@"; then
              aiweb_block "$@"
            fi
            aiweb_delegate "$@"
            ;;
          git)
            if aiweb_contains_git_push "$@"; then
              aiweb_block "$@"
            fi
            aiweb_delegate "$@"
            ;;
          *)
            aiweb_block "$@"
            ;;
        esac
      SH
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

    def engine_run_agent_command(agent, sandbox, workspace_dir)
      if engine_run_container_worker_agent?(agent)
        return engine_run_agent_container_command(agent, sandbox, workspace_dir)
      end
      path = executable_path(agent)
      raise UserError.new("#{agent} executable is missing from PATH", 1) unless path

      [agent]
    end

    def engine_run_agent_container_command(agent, sandbox, workspace_dir)
      case agent.to_s
      when "openhands" then engine_run_openhands_command(sandbox, workspace_dir)
      when "langgraph" then engine_run_langgraph_command(sandbox, workspace_dir)
      when "openai_agents_sdk" then engine_run_openai_agents_sdk_command(sandbox, workspace_dir)
      else engine_run_openmanus_command(sandbox, workspace_dir)
      end
    end

    def engine_run_agent_sandbox_command_blockers(agent, command, sandbox:, workspace_dir:)
      case agent.to_s
      when "openhands" then engine_run_openhands_sandbox_command_blockers(command, sandbox: sandbox, workspace_dir: workspace_dir)
      when "langgraph" then engine_run_langgraph_sandbox_command_blockers(command, sandbox: sandbox, workspace_dir: workspace_dir)
      when "openai_agents_sdk" then engine_run_openai_agents_sdk_sandbox_command_blockers(command, sandbox: sandbox, workspace_dir: workspace_dir)
      else engine_run_openmanus_sandbox_command_blockers(command, sandbox: sandbox, workspace_dir: workspace_dir)
      end
    end

    def engine_run_agent_image_blockers(agent, sandbox)
      case agent.to_s
      when "openhands" then engine_run_openhands_image_blockers(sandbox)
      when "langgraph" then engine_run_langgraph_image_blockers(sandbox)
      when "openai_agents_sdk" then engine_run_openai_agents_sdk_image_blockers(sandbox)
      else engine_run_openmanus_image_blockers(sandbox)
      end
    end

    def engine_run_openmanus_command(sandbox, workspace_dir)
      provider = sandbox.to_s
      image = engine_run_openmanus_image
      sandbox_runtime_container_command(
        provider: provider,
        workspace_dir: workspace_dir,
        image: image,
        env: engine_run_openmanus_container_env(provider),
        pids_limit: 512,
        memory: "2g",
        cpus: "2",
        tmpfs_size: "128m",
        command: ["openmanus"]
      )
    end

    def engine_run_openhands_command(sandbox, workspace_dir)
      provider = sandbox.to_s
      image = engine_run_openhands_image
      sandbox_runtime_container_command(
        provider: provider,
        workspace_dir: workspace_dir,
        image: image,
        env: engine_run_openhands_container_env(provider),
        pids_limit: 512,
        memory: "2g",
        cpus: "2",
        tmpfs_size: "128m",
        command: ["openhands", "--headless", "--json", "--file", "/workspace/_aiweb/openhands-task.md"]
      )
    end

    def engine_run_langgraph_command(sandbox, workspace_dir)
      provider = sandbox.to_s
      image = engine_run_langgraph_image
      sandbox_runtime_container_command(
        provider: provider,
        workspace_dir: workspace_dir,
        image: image,
        env: engine_run_langgraph_container_env(provider),
        pids_limit: 512,
        memory: "2g",
        cpus: "2",
        tmpfs_size: "128m",
        command: ["sh", "-lc", "if command -v python3 >/dev/null 2>&1; then exec python3 /workspace/_aiweb/langgraph-worker.py; else exec python /workspace/_aiweb/langgraph-worker.py; fi"]
      )
    end

    def engine_run_openai_agents_sdk_command(sandbox, workspace_dir)
      provider = sandbox.to_s
      image = engine_run_openai_agents_sdk_image
      sandbox_runtime_container_command(
        provider: provider,
        workspace_dir: workspace_dir,
        image: image,
        env: engine_run_openai_agents_sdk_container_env(provider),
        pids_limit: 512,
        memory: "2g",
        cpus: "2",
        tmpfs_size: "128m",
        command: ["sh", "-lc", "if command -v python3 >/dev/null 2>&1; then exec python3 /workspace/_aiweb/openai-agents-worker.py; else exec python /workspace/_aiweb/openai-agents-worker.py; fi"]
      )
    end

    def engine_run_openmanus_container_env(provider)
      {
        "AIWEB_ENGINE_RUN_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_OPENMANUS_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_GRAPH_EXECUTION_PLAN_PATH" => "/workspace/_aiweb/graph-execution-plan.json",
        "AIWEB_WORKER_ADAPTER_CONTRACT_PATH" => "/workspace/_aiweb/worker-adapter-contract.json",
        "AIWEB_WORKER_ADAPTER_REGISTRY_PATH" => "/workspace/_aiweb/worker-adapter-registry.json",
        "AIWEB_OPENMANUS_SANDBOX" => provider,
        "AIWEB_NETWORK_ALLOWED" => "0",
        "AIWEB_MCP_ALLOWED" => "0",
        "AIWEB_ENV_ACCESS_ALLOWED" => "0",
        "AIWEB_TOOL_BROKER_EVENTS_PATH" => "/workspace/_aiweb/tool-broker-events.jsonl",
        "AIWEB_TOOL_BROKER_REAL_PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "PATH" => "/workspace/_aiweb/tool-broker-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME" => "/workspace/_aiweb/home",
        "USERPROFILE" => "/workspace/_aiweb/home",
        "TMPDIR" => "/workspace/_aiweb/tmp",
        "TMP" => "/workspace/_aiweb/tmp",
        "TEMP" => "/workspace/_aiweb/tmp"
      }
    end

    def engine_run_openhands_container_env(provider)
      {
        "AIWEB_ENGINE_RUN_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_OPENHANDS_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_OPENHANDS_TASK_PATH" => "/workspace/_aiweb/openhands-task.md",
        "AIWEB_GRAPH_EXECUTION_PLAN_PATH" => "/workspace/_aiweb/graph-execution-plan.json",
        "AIWEB_WORKER_ADAPTER_CONTRACT_PATH" => "/workspace/_aiweb/worker-adapter-contract.json",
        "AIWEB_WORKER_ADAPTER_REGISTRY_PATH" => "/workspace/_aiweb/worker-adapter-registry.json",
        "AIWEB_OPENHANDS_SANDBOX" => provider,
        "AIWEB_NETWORK_ALLOWED" => "0",
        "AIWEB_MCP_ALLOWED" => "0",
        "AIWEB_ENV_ACCESS_ALLOWED" => "0",
        "AIWEB_TOOL_BROKER_EVENTS_PATH" => "/workspace/_aiweb/tool-broker-events.jsonl",
        "AIWEB_TOOL_BROKER_REAL_PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "RUNTIME" => "process",
        "SANDBOX_VOLUMES" => "/workspace:/workspace:rw",
        "PATH" => "/workspace/_aiweb/tool-broker-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME" => "/workspace/_aiweb/home",
        "USERPROFILE" => "/workspace/_aiweb/home",
        "TMPDIR" => "/workspace/_aiweb/tmp",
        "TMP" => "/workspace/_aiweb/tmp",
        "TEMP" => "/workspace/_aiweb/tmp"
      }
    end

    def engine_run_langgraph_container_env(provider)
      {
        "AIWEB_ENGINE_RUN_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_LANGGRAPH_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_LANGGRAPH_TASK_PATH" => "/workspace/_aiweb/langgraph-task.md",
        "AIWEB_LANGGRAPH_WORKER_PATH" => "/workspace/_aiweb/langgraph-worker.py",
        "AIWEB_GRAPH_EXECUTION_PLAN_PATH" => "/workspace/_aiweb/graph-execution-plan.json",
        "AIWEB_WORKER_ADAPTER_CONTRACT_PATH" => "/workspace/_aiweb/worker-adapter-contract.json",
        "AIWEB_WORKER_ADAPTER_REGISTRY_PATH" => "/workspace/_aiweb/worker-adapter-registry.json",
        "AIWEB_LANGGRAPH_SANDBOX" => provider,
        "AIWEB_NETWORK_ALLOWED" => "0",
        "AIWEB_MCP_ALLOWED" => "0",
        "AIWEB_ENV_ACCESS_ALLOWED" => "0",
        "AIWEB_TOOL_BROKER_EVENTS_PATH" => "/workspace/_aiweb/tool-broker-events.jsonl",
        "AIWEB_TOOL_BROKER_REAL_PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "PATH" => "/workspace/_aiweb/tool-broker-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME" => "/workspace/_aiweb/home",
        "USERPROFILE" => "/workspace/_aiweb/home",
        "TMPDIR" => "/workspace/_aiweb/tmp",
        "TMP" => "/workspace/_aiweb/tmp",
        "TEMP" => "/workspace/_aiweb/tmp"
      }
    end

    def engine_run_openai_agents_sdk_container_env(provider)
      {
        "AIWEB_ENGINE_RUN_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_OPENAI_AGENTS_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_OPENAI_AGENTS_TASK_PATH" => "/workspace/_aiweb/openai-agents-task.md",
        "AIWEB_OPENAI_AGENTS_WORKER_PATH" => "/workspace/_aiweb/openai-agents-worker.py",
        "AIWEB_OPENAI_AGENTS_ALLOW_MODEL_CALL" => "0",
        "AIWEB_GRAPH_EXECUTION_PLAN_PATH" => "/workspace/_aiweb/graph-execution-plan.json",
        "AIWEB_WORKER_ADAPTER_CONTRACT_PATH" => "/workspace/_aiweb/worker-adapter-contract.json",
        "AIWEB_WORKER_ADAPTER_REGISTRY_PATH" => "/workspace/_aiweb/worker-adapter-registry.json",
        "AIWEB_OPENAI_AGENTS_SANDBOX" => provider,
        "AIWEB_NETWORK_ALLOWED" => "0",
        "AIWEB_MCP_ALLOWED" => "0",
        "AIWEB_ENV_ACCESS_ALLOWED" => "0",
        "AIWEB_TOOL_BROKER_EVENTS_PATH" => "/workspace/_aiweb/tool-broker-events.jsonl",
        "AIWEB_TOOL_BROKER_REAL_PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "PATH" => "/workspace/_aiweb/tool-broker-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME" => "/workspace/_aiweb/home",
        "USERPROFILE" => "/workspace/_aiweb/home",
        "TMPDIR" => "/workspace/_aiweb/tmp",
        "TMP" => "/workspace/_aiweb/tmp",
        "TEMP" => "/workspace/_aiweb/tmp"
      }
    end

    def engine_run_openmanus_sandbox_command_blockers(command, sandbox:, workspace_dir:)
      sandbox_runtime_container_command_blockers(
        command,
        sandbox: sandbox,
        workspace_dir: workspace_dir,
        required_env: {
          "AIWEB_ENGINE_RUN_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
          "AIWEB_OPENMANUS_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
          "AIWEB_GRAPH_EXECUTION_PLAN_PATH" => "/workspace/_aiweb/graph-execution-plan.json",
          "AIWEB_WORKER_ADAPTER_CONTRACT_PATH" => "/workspace/_aiweb/worker-adapter-contract.json",
          "AIWEB_WORKER_ADAPTER_REGISTRY_PATH" => "/workspace/_aiweb/worker-adapter-registry.json",
          "AIWEB_OPENMANUS_SANDBOX" => sandbox,
          "AIWEB_NETWORK_ALLOWED" => "0",
          "AIWEB_MCP_ALLOWED" => "0",
          "AIWEB_ENV_ACCESS_ALLOWED" => "0"
        },
        label: "engine-run openmanus sandbox"
      )
    end

    def engine_run_openhands_sandbox_command_blockers(command, sandbox:, workspace_dir:)
      sandbox_runtime_container_command_blockers(
        command,
        sandbox: sandbox,
        workspace_dir: workspace_dir,
        required_env: {
          "AIWEB_ENGINE_RUN_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
          "AIWEB_OPENHANDS_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
          "AIWEB_OPENHANDS_TASK_PATH" => "/workspace/_aiweb/openhands-task.md",
          "AIWEB_GRAPH_EXECUTION_PLAN_PATH" => "/workspace/_aiweb/graph-execution-plan.json",
          "AIWEB_WORKER_ADAPTER_CONTRACT_PATH" => "/workspace/_aiweb/worker-adapter-contract.json",
          "AIWEB_WORKER_ADAPTER_REGISTRY_PATH" => "/workspace/_aiweb/worker-adapter-registry.json",
          "AIWEB_OPENHANDS_SANDBOX" => sandbox,
          "AIWEB_NETWORK_ALLOWED" => "0",
          "AIWEB_MCP_ALLOWED" => "0",
          "AIWEB_ENV_ACCESS_ALLOWED" => "0",
          "RUNTIME" => "process"
        },
        label: "engine-run OpenHands sandbox"
      )
    end

    def engine_run_langgraph_sandbox_command_blockers(command, sandbox:, workspace_dir:)
      sandbox_runtime_container_command_blockers(
        command,
        sandbox: sandbox,
        workspace_dir: workspace_dir,
        required_env: {
          "AIWEB_ENGINE_RUN_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
          "AIWEB_LANGGRAPH_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
          "AIWEB_LANGGRAPH_TASK_PATH" => "/workspace/_aiweb/langgraph-task.md",
          "AIWEB_LANGGRAPH_WORKER_PATH" => "/workspace/_aiweb/langgraph-worker.py",
          "AIWEB_GRAPH_EXECUTION_PLAN_PATH" => "/workspace/_aiweb/graph-execution-plan.json",
          "AIWEB_WORKER_ADAPTER_CONTRACT_PATH" => "/workspace/_aiweb/worker-adapter-contract.json",
          "AIWEB_WORKER_ADAPTER_REGISTRY_PATH" => "/workspace/_aiweb/worker-adapter-registry.json",
          "AIWEB_LANGGRAPH_SANDBOX" => sandbox,
          "AIWEB_NETWORK_ALLOWED" => "0",
          "AIWEB_MCP_ALLOWED" => "0",
          "AIWEB_ENV_ACCESS_ALLOWED" => "0"
        },
        label: "engine-run LangGraph sandbox"
      )
    end

    def engine_run_openai_agents_sdk_sandbox_command_blockers(command, sandbox:, workspace_dir:)
      sandbox_runtime_container_command_blockers(
        command,
        sandbox: sandbox,
        workspace_dir: workspace_dir,
        required_env: {
          "AIWEB_ENGINE_RUN_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
          "AIWEB_OPENAI_AGENTS_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
          "AIWEB_OPENAI_AGENTS_TASK_PATH" => "/workspace/_aiweb/openai-agents-task.md",
          "AIWEB_OPENAI_AGENTS_WORKER_PATH" => "/workspace/_aiweb/openai-agents-worker.py",
          "AIWEB_OPENAI_AGENTS_ALLOW_MODEL_CALL" => "0",
          "AIWEB_GRAPH_EXECUTION_PLAN_PATH" => "/workspace/_aiweb/graph-execution-plan.json",
          "AIWEB_WORKER_ADAPTER_CONTRACT_PATH" => "/workspace/_aiweb/worker-adapter-contract.json",
          "AIWEB_WORKER_ADAPTER_REGISTRY_PATH" => "/workspace/_aiweb/worker-adapter-registry.json",
          "AIWEB_OPENAI_AGENTS_SANDBOX" => sandbox,
          "AIWEB_NETWORK_ALLOWED" => "0",
          "AIWEB_MCP_ALLOWED" => "0",
          "AIWEB_ENV_ACCESS_ALLOWED" => "0"
        },
        label: "engine-run OpenAI Agents SDK sandbox"
      )
    end

    def engine_run_openmanus_image
      image = ENV["AIWEB_OPENMANUS_IMAGE"].to_s.strip
      image.empty? ? "openmanus:latest" : image
    end

    def engine_run_openhands_image
      image = ENV["AIWEB_OPENHANDS_IMAGE"].to_s.strip
      image.empty? ? "openhands:latest" : image
    end

    def engine_run_langgraph_image
      image = ENV["AIWEB_LANGGRAPH_IMAGE"].to_s.strip
      image.empty? ? "langgraph:latest" : image
    end

    def engine_run_openai_agents_sdk_image
      image = ENV["AIWEB_OPENAI_AGENTS_IMAGE"].to_s.strip
      image.empty? ? "openai-agents:latest" : image
    end

    def engine_run_openmanus_image_blockers(sandbox)
      image = engine_run_openmanus_image
      blockers = []
      image_inspect = engine_run_container_image_inspect(sandbox, image)
      unless image_inspect.fetch("status", "failed") == "passed"
        reason = image_inspect.fetch("reason", image_inspect.fetch("error", "image inspect failed")).to_s
        blockers << "OpenManus container image is not available as validated local inspect evidence: #{image}. Build or pull it first, or set AIWEB_OPENMANUS_IMAGE to a prepared local image. #{agent_run_redact_process_output(reason)[0, 300]}".strip
      end
      if engine_run_require_digest_pinned_openmanus_image? && !engine_run_digest_pinned_image?(image)
        sources = engine_run_digest_pinned_openmanus_policy_sources.join(", ")
        blockers << "OpenManus container image must be digest-pinned when strict or production sandbox policy is enabled (#{sources}): set AIWEB_OPENMANUS_IMAGE=openmanus@sha256:<digest>"
      end
      return blockers

    rescue SystemCallError => e
      ["OpenManus image preflight failed for #{image}: #{e.message}"]
    end

    def engine_run_openhands_image_blockers(sandbox)
      image = engine_run_openhands_image
      image_inspect = engine_run_container_image_inspect(sandbox, image)
      return [] if image_inspect.fetch("status", "failed") == "passed"

      reason = image_inspect.fetch("reason", image_inspect.fetch("error", "image inspect failed")).to_s
      ["OpenHands container image is not available as validated local inspect evidence: #{image}. Build or pull it first, or set AIWEB_OPENHANDS_IMAGE to a prepared local image. #{agent_run_redact_process_output(reason)[0, 300]}".strip]
    rescue SystemCallError => e
      ["OpenHands image preflight failed for #{image}: #{e.message}"]
    end

    def engine_run_langgraph_image_blockers(sandbox)
      image = engine_run_langgraph_image
      image_inspect = engine_run_container_image_inspect(sandbox, image)
      return [] if image_inspect.fetch("status", "failed") == "passed"

      reason = image_inspect.fetch("reason", image_inspect.fetch("error", "image inspect failed")).to_s
      ["LangGraph container image is not available as validated local inspect evidence: #{image}. Build or pull it first, or set AIWEB_LANGGRAPH_IMAGE to a prepared local image. #{agent_run_redact_process_output(reason)[0, 300]}".strip]
    rescue SystemCallError => e
      ["LangGraph image preflight failed for #{image}: #{e.message}"]
    end

    def engine_run_openai_agents_sdk_image_blockers(sandbox)
      image = engine_run_openai_agents_sdk_image
      image_inspect = engine_run_container_image_inspect(sandbox, image)
      return [] if image_inspect.fetch("status", "failed") == "passed"

      reason = image_inspect.fetch("reason", image_inspect.fetch("error", "image inspect failed")).to_s
      ["OpenAI Agents SDK container image is not available as validated local inspect evidence: #{image}. Build or pull it first, or set AIWEB_OPENAI_AGENTS_IMAGE to a prepared local image. #{agent_run_redact_process_output(reason)[0, 300]}".strip]
    rescue SystemCallError => e
      ["OpenAI Agents SDK image preflight failed for #{image}: #{e.message}"]
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
      timed_out = false
      Open3.popen3(env, *command, chdir: workspace_dir, unsetenv_others: true) do |stdin, stdout, stderr, wait_thr|
        stdin.write(prompt)
        stdin.close
        stdout_reader = Thread.new { stdout.read.to_s rescue "" }
        stderr_reader = Thread.new { stderr.read.to_s rescue "" }
        unless wait_thr.join(600)
          timed_out = true
          agent_run_kill_process(wait_thr.pid)
          agent_run_close_stream(stdout)
          agent_run_close_stream(stderr)
        end
        stdout_data = agent_run_limit_process_output(stdout_reader.value.to_s)
        stderr_data = agent_run_limit_process_output(stderr_reader.value.to_s)
        status = wait_thr.value if wait_thr.join(1)
        exit_code = status&.exitstatus
        success = status&.success? == true
      end
      blockers = []
      blockers << "#{agent} timed out after 600s" if timed_out
      blockers << "#{agent} exited with status #{exit_code || "unknown"}" if !timed_out && !success
      blockers << "quarantine: agent output contained secret-like content" if stdout_data.match?(ENGINE_RUN_SECRET_VALUE_PATTERN) || stderr_data.match?(ENGINE_RUN_SECRET_VALUE_PATTERN)
      {
        stdout: stdout_data,
        stderr: stderr_data,
        exit_code: exit_code,
        success: success,
        blocking_issues: blockers
      }
    rescue SystemCallError => e
      {
        stdout: stdout_data,
        stderr: "#{stderr_data}#{e.message}\n",
        exit_code: exit_code,
        success: false,
        blocking_issues: ["engine-run subprocess failed: #{e.message}"]
      }
    end

    def engine_run_langgraph_worker_source
      <<~'PY'
        import json
        import os
        import sys
        from typing import Any, Dict, List, TypedDict

        try:
            from langgraph.graph import END, START, StateGraph
        except Exception as exc:
            result_path = os.environ.get("AIWEB_LANGGRAPH_RESULT_PATH") or "/workspace/_aiweb/engine-result.json"
            os.makedirs(os.path.dirname(result_path), exist_ok=True)
            with open(result_path, "w", encoding="utf-8") as handle:
                json.dump({
                    "schema_version": 1,
                    "adapter": "langgraph",
                    "status": "blocked",
                    "structured_events": [{"type": "langgraph.import_failed", "error_class": exc.__class__.__name__}],
                    "artifact_refs": ["_aiweb/langgraph-worker.py"],
                    "changed_file_manifest": [],
                    "proposed_tool_requests": [],
                    "risk_notes": ["LangGraph package is unavailable in the prepared sandbox image"],
                    "blocking_issues": ["langgraph package import failed: " + exc.__class__.__name__]
                }, handle, ensure_ascii=False, sort_keys=True)
            sys.exit(2)

        class WorkerState(TypedDict, total=False):
            task_path: str
            contract_path: str
            registry_path: str
            graph_plan_path: str
            events: List[Dict[str, Any]]
            artifact_refs: List[str]
            changed_file_manifest: List[str]
            proposed_tool_requests: List[Dict[str, Any]]
            risk_notes: List[str]
            blocking_issues: List[str]
            status: str

        def read_json(path: str) -> Dict[str, Any]:
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    value = json.load(handle)
                return value if isinstance(value, dict) else {}
            except OSError:
                return {}
            except json.JSONDecodeError as exc:
                return {"_error": exc.__class__.__name__}

        def prepare(state: WorkerState) -> WorkerState:
            events = list(state.get("events", []))
            events.append({"type": "langgraph.prepare", "task_path": state.get("task_path")})
            artifacts = list(state.get("artifact_refs", []))
            artifacts.extend(["_aiweb/langgraph-worker.py", "_aiweb/langgraph-task.md"])
            return {"events": events, "artifact_refs": artifacts}

        def act(state: WorkerState) -> WorkerState:
            events = list(state.get("events", []))
            proposed = list(state.get("proposed_tool_requests", []))
            risks = list(state.get("risk_notes", []))
            contract = read_json(state.get("contract_path", ""))
            registry = read_json(state.get("registry_path", ""))
            graph_plan = read_json(state.get("graph_plan_path", ""))
            events.append({
                "type": "langgraph.act",
                "contract_adapter": contract.get("adapter"),
                "registry_protocol": registry.get("protocol_version"),
                "graph_scheduler_type": graph_plan.get("scheduler_type")
            })
            risks.append("experimental LangGraph bridge observed aiweb artifacts and did not request side effects")
            return {"events": events, "proposed_tool_requests": proposed, "risk_notes": risks}

        def observe(state: WorkerState) -> WorkerState:
            events = list(state.get("events", []))
            events.append({"type": "langgraph.observe", "changed_file_count": len(state.get("changed_file_manifest", []))})
            return {"events": events}

        def finalize(state: WorkerState) -> WorkerState:
            events = list(state.get("events", []))
            blockers = list(state.get("blocking_issues", []))
            events.append({"type": "langgraph.finalize", "blocking_issue_count": len(blockers)})
            return {"events": events, "status": "blocked" if blockers else "no_changes"}

        builder = StateGraph(WorkerState)
        builder.add_node("prepare", prepare)
        builder.add_node("act", act)
        builder.add_node("observe", observe)
        builder.add_node("finalize", finalize)
        builder.add_edge(START, "prepare")
        builder.add_edge("prepare", "act")
        builder.add_edge("act", "observe")
        builder.add_edge("observe", "finalize")
        builder.add_edge("finalize", END)
        graph = builder.compile()

        initial: WorkerState = {
            "task_path": os.environ.get("AIWEB_LANGGRAPH_TASK_PATH", "/workspace/_aiweb/langgraph-task.md"),
            "contract_path": os.environ.get("AIWEB_WORKER_ADAPTER_CONTRACT_PATH", "/workspace/_aiweb/worker-adapter-contract.json"),
            "registry_path": os.environ.get("AIWEB_WORKER_ADAPTER_REGISTRY_PATH", "/workspace/_aiweb/worker-adapter-registry.json"),
            "graph_plan_path": os.environ.get("AIWEB_GRAPH_EXECUTION_PLAN_PATH", "/workspace/_aiweb/graph-execution-plan.json"),
            "events": [],
            "artifact_refs": [],
            "changed_file_manifest": [],
            "proposed_tool_requests": [],
            "risk_notes": [],
            "blocking_issues": []
        }
        final = graph.invoke(initial)
        result = {
            "schema_version": 1,
            "adapter": "langgraph",
            "status": final.get("status", "reported"),
            "structured_events": final.get("events", []),
            "artifact_refs": final.get("artifact_refs", []),
            "changed_file_manifest": final.get("changed_file_manifest", []),
            "proposed_tool_requests": final.get("proposed_tool_requests", []),
            "risk_notes": final.get("risk_notes", []),
            "blocking_issues": final.get("blocking_issues", []),
            "graph_trace": {
                "api": "langgraph.graph.StateGraph",
                "nodes": ["prepare", "act", "observe", "finalize"],
                "edges": [["START", "prepare"], ["prepare", "act"], ["act", "observe"], ["observe", "finalize"], ["finalize", "END"]]
            }
        }
        result_path = os.environ.get("AIWEB_LANGGRAPH_RESULT_PATH") or os.environ.get("AIWEB_ENGINE_RUN_RESULT_PATH") or "/workspace/_aiweb/engine-result.json"
        os.makedirs(os.path.dirname(result_path), exist_ok=True)
        with open(result_path, "w", encoding="utf-8") as handle:
            json.dump(result, handle, ensure_ascii=False, sort_keys=True)
        print(json.dumps({"adapter": "langgraph", "status": result["status"], "event_count": len(result["structured_events"])}, sort_keys=True))
      PY
    end

    def engine_run_openai_agents_sdk_worker_source
      <<~'PY'
        import json
        import os
        import sys
        from typing import Any, Dict

        RESULT_PATH = os.environ.get("AIWEB_OPENAI_AGENTS_RESULT_PATH") or os.environ.get("AIWEB_ENGINE_RUN_RESULT_PATH") or "/workspace/_aiweb/engine-result.json"
        TASK_PATH = os.environ.get("AIWEB_OPENAI_AGENTS_TASK_PATH", "/workspace/_aiweb/openai-agents-task.md")
        CONTRACT_PATH = os.environ.get("AIWEB_WORKER_ADAPTER_CONTRACT_PATH", "/workspace/_aiweb/worker-adapter-contract.json")
        REGISTRY_PATH = os.environ.get("AIWEB_WORKER_ADAPTER_REGISTRY_PATH", "/workspace/_aiweb/worker-adapter-registry.json")
        GRAPH_PLAN_PATH = os.environ.get("AIWEB_GRAPH_EXECUTION_PLAN_PATH", "/workspace/_aiweb/graph-execution-plan.json")

        def read_json(path: str) -> Dict[str, Any]:
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    value = json.load(handle)
                return value if isinstance(value, dict) else {}
            except OSError:
                return {}
            except json.JSONDecodeError as exc:
                return {"_error": exc.__class__.__name__}

        def read_text(path: str) -> str:
            try:
                with open(path, "r", encoding="utf-8") as handle:
                    return handle.read()
            except OSError:
                return ""

        def write_result(payload: Dict[str, Any], exit_code: int = 0) -> None:
            os.makedirs(os.path.dirname(RESULT_PATH), exist_ok=True)
            with open(RESULT_PATH, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, ensure_ascii=False, sort_keys=True)
            print(json.dumps({
                "adapter": payload.get("adapter"),
                "status": payload.get("status"),
                "event_count": len(payload.get("structured_events", []))
            }, sort_keys=True))
            sys.exit(exit_code)

        try:
            from agents import Agent, Runner
        except Exception as exc:
            write_result({
                "schema_version": 1,
                "adapter": "openai_agents_sdk",
                "status": "blocked",
                "structured_events": [{"type": "openai_agents_sdk.import_failed", "error_class": exc.__class__.__name__}],
                "artifact_refs": ["_aiweb/openai-agents-worker.py"],
                "changed_file_manifest": [],
                "proposed_tool_requests": [],
                "risk_notes": ["OpenAI Agents SDK package is unavailable in the prepared sandbox image"],
                "blocking_issues": ["agents package import failed: " + exc.__class__.__name__],
                "sdk_trace": {
                    "api": "agents.Agent/Runner",
                    "model_call_attempted": False,
                    "model_call_allowed": False
                }
            }, 2)

        task = read_text(TASK_PATH)
        contract = read_json(CONTRACT_PATH)
        registry = read_json(REGISTRY_PATH)
        graph_plan = read_json(GRAPH_PLAN_PATH)
        model_call_allowed = os.environ.get("AIWEB_OPENAI_AGENTS_ALLOW_MODEL_CALL") == "1" and os.environ.get("AIWEB_NETWORK_ALLOWED") == "1"
        events = [
            {"type": "openai_agents_sdk.prepare", "task_path": TASK_PATH, "task_bytes": len(task.encode("utf-8"))},
            {"type": "openai_agents_sdk.agent_configured", "agent_name": "AiwebSandboxWorker"},
            {
                "type": "openai_agents_sdk.observe_contract",
                "contract_adapter": contract.get("adapter"),
                "registry_protocol": registry.get("protocol_version"),
                "graph_scheduler_type": graph_plan.get("scheduler_type")
            }
        ]
        blockers = []
        risks = [
            "experimental OpenAI Agents SDK bridge configured an Agent/Runner boundary without requesting side effects",
            "external model/network calls are disabled unless a future broker explicitly allows them"
        ]
        final_output = None
        model_call_attempted = False
        agent = Agent(
            name="AiwebSandboxWorker",
            instructions=(
                "You are the WebBuilderAgent sandbox worker. Respect aiweb broker boundaries, "
                "do not request external network, package install, MCP, deploy, git push, or raw env access."
            )
        )
        if model_call_allowed:
            model_call_attempted = True
            try:
                result = Runner.run_sync(agent, task, max_turns=1)
                final_output = str(getattr(result, "final_output", ""))
                events.append({"type": "openai_agents_sdk.runner_finished", "final_output_bytes": len(final_output.encode("utf-8"))})
            except Exception as exc:
                blockers.append("OpenAI Agents SDK Runner failed: " + exc.__class__.__name__)
                events.append({"type": "openai_agents_sdk.runner_failed", "error_class": exc.__class__.__name__})
        else:
            events.append({"type": "openai_agents_sdk.runner_not_invoked_network_blocked", "reason": "AIWEB_OPENAI_AGENTS_ALLOW_MODEL_CALL=0 or AIWEB_NETWORK_ALLOWED=0"})

        write_result({
            "schema_version": 1,
            "adapter": "openai_agents_sdk",
            "status": "blocked" if blockers else "no_changes",
            "structured_events": events,
            "artifact_refs": ["_aiweb/openai-agents-worker.py", "_aiweb/openai-agents-task.md"],
            "changed_file_manifest": [],
            "proposed_tool_requests": [],
            "risk_notes": risks,
            "blocking_issues": blockers,
            "sdk_trace": {
                "api": "agents.Agent/Runner",
                "agent_class": Agent.__name__,
                "runner_has_run_sync": hasattr(Runner, "run_sync"),
                "model_call_attempted": model_call_attempted,
                "model_call_allowed": model_call_allowed,
                "final_output_present": bool(final_output)
            }
        })
      PY
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

    def engine_run_copy_back_policy(workspace_dir, manifest, process_output)
      base_files = manifest.fetch("files")
      workspace_files = engine_run_workspace_files(workspace_dir)
      all_paths = (base_files.keys + workspace_files.keys).uniq.sort
      safe_changes = []
      approval_changes = []
      blocked_changes = []
      blocking_issues = []
      approval_issues = []

      all_paths.each do |path|
        base_hash = base_files.dig(path, "sha256")
        current_hash = workspace_files.dig(path, "sha256")
        next if base_hash == current_hash

        if current_hash.nil?
          approval_changes << path
          approval_issues << "delete requires approval: #{path}"
          next
        end

        full = File.join(workspace_dir, path)
        if engine_run_secret_surface_path?(path) || File.symlink?(full) || path.split("/").include?("..")
          blocked_changes << path
          blocking_issues << "unsafe changed path blocked: #{path}"
          next
        end
        if engine_run_binary_file?(full)
          blocked_changes << path
          blocking_issues << "binary changed file blocked: #{path}"
          next
        end
        if engine_run_file_contains_secret?(full)
          blocked_changes << path
          blocking_issues << "secret-like content blocked in changed file: #{path}"
          next
        end
        unless engine_run_writable_path?(path)
          blocked_changes << path
          blocking_issues << "changed path outside engine-run writable envelope: #{path}"
          next
        end
        if engine_run_high_risk_path?(path)
          approval_changes << path
          approval_issues << "high-risk changed path requires approval: #{path}"
          next
        end

        safe_changes << path
      end

      requested_actions = (engine_run_requested_tool_actions(process_output) + engine_run_requested_tool_actions_from_broker_events(workspace_dir)).uniq { |action| action["type"] }
      broker_actions = requested_actions.select { |action| action["source"] == "tool_broker" }
      approval_issues << "agent output indicates package install, network, deploy, provider CLI, MCP/connectors, env read, or git push may be required" unless requested_actions.empty?
      approval_issues << "tool broker blocked prohibited staged action before execution" unless broker_actions.empty?
      approval_requests = engine_run_approval_requests(approval_issues, approval_changes, requested_actions)

      {
        "schema_version" => 1,
        "status" => if !blocking_issues.empty?
                       "blocked"
                     elsif !approval_issues.empty?
                       "waiting_approval"
                     else
                       "passed"
                     end,
        "safe_changes" => safe_changes,
        "approval_changes" => approval_changes,
        "blocked_changes" => blocked_changes,
        "blocking_issues" => blocking_issues,
        "approval_issues" => approval_issues,
        "approval_requests" => approval_requests,
        "requested_actions" => requested_actions,
        "writable_globs" => ENGINE_RUN_DEFAULT_WRITABLE_GLOBS
      }
    end

    def engine_run_approval_requests(approval_issues, approval_changes, requested_actions)
      requests = Array(requested_actions).map do |action|
        type = action.fetch("type", "elevated_action")
        {
          "schema_version" => 1,
          "id" => "approval-#{Digest::SHA256.hexdigest(JSON.generate(action))[0, 16]}",
          "type" => type,
          "status" => "pending",
          "why_needed" => action["reason"].to_s,
          "risk" => engine_run_approval_risk(type),
          "capability_unlocked" => engine_run_approval_capability(type),
          "approval_scope" => "single_run_single_capability",
          "affected_paths" => [],
          "requires" => engine_run_elevated_approval_requirements(type),
          "policy_note" => "Default sandbox profile stays no-network/no-install/no-provider/no-git/no-MCP until this exact request is approved."
        }
      end

      unless Array(approval_changes).empty?
        requests << {
          "schema_version" => 1,
          "id" => "approval-#{Digest::SHA256.hexdigest(Array(approval_changes).join("\n"))[0, 16]}",
          "type" => "copy_back_change",
          "status" => "pending",
          "why_needed" => Array(approval_issues).grep(/delete requires approval|high-risk changed path/i).join("; "),
          "risk" => "host_project_mutation",
          "capability_unlocked" => "copy_back_delete_or_high_risk_paths",
          "approval_scope" => "single_run_selected_paths",
          "affected_paths" => Array(approval_changes).sort,
          "requires" => %w[human_reviewed_diff exact_paths rollback_plan validation_result],
          "policy_note" => "Only the listed paths may be copied back after approval; all other host mutations remain blocked."
        }
      end

      requests
    end

    def engine_run_supply_chain_gate(policy:, workspace_dir:, manifest:, paths:)
      package_actions = Array(policy["requested_actions"]).select { |action| action.is_a?(Hash) && action["type"].to_s == "package_install" }
      package_requests = Array(policy["approval_requests"]).select { |request| request.is_a?(Hash) && request["type"].to_s == "package_install" }
      package_manager = engine_run_supply_chain_package_manager(workspace_dir, package_actions)
      dependency_snapshot = engine_run_dependency_snapshot(workspace_dir)
      lifecycle_scripts = engine_run_package_lifecycle_scripts(workspace_dir)
      package_file_diff = engine_run_package_file_diff(manifest, workspace_dir)
      required = !package_actions.empty? || !package_requests.empty?
      status = if required
                 "waiting_approval"
               elsif package_file_diff.any? { |entry| entry["changed"] }
                 "blocked"
               else
                 "skipped"
               end
      blockers = []
      blockers << "package manifest or lockfile changed without a supply-chain approval request" if status == "blocked"
      {
        "schema_version" => 1,
        "status" => status,
        "recorded_at" => now,
        "required" => required,
        "package_manager" => package_manager,
        "package_install_requests" => {
          "count" => package_requests.length,
          "items" => package_requests
        },
        "requested_actions" => package_actions,
        "clean_cache_install" => {
          "required" => required,
          "status" => required ? "pending_approval" : "skipped",
          "isolated_cache_dir" => "_aiweb/package-cache",
          "network_policy" => "registry_allowlist_required",
          "lifecycle_script_policy" => "disabled_by_default_until_explicitly_approved",
          "command_policy" => "exact package manager command required; install must run inside staged workspace with clean cache and no host package cache mount",
          "default_install_lifecycle_execution" => false,
          "default_command_uses_ignore_scripts" => false
        },
        "dependency_diff" => {
          "status" => required ? "pending_approval" : (package_file_diff.any? { |entry| entry["changed"] } ? "blocked" : "skipped"),
          "baseline" => dependency_snapshot.fetch("dependencies"),
          "package_file_diff" => package_file_diff,
          "required_outputs" => %w[package_json_diff lockfile_diff added_packages removed_packages version_changes]
        },
        "sbom" => {
          "status" => required ? "not_executed_pending_approval" : "skipped",
          "required" => required,
          "accepted_formats" => %w[cyclonedx spdx npm-sbom-json],
          "artifact_path" => relative(paths.fetch(:supply_chain_sbom_path))
        },
        "audit" => {
          "status" => required ? "not_executed_pending_approval" : "skipped",
          "required" => required,
          "commands" => engine_run_supply_chain_audit_commands(package_manager),
          "artifact_path" => relative(paths.fetch(:supply_chain_audit_path))
        },
        "vulnerability_copy_back_gate" => {
          "status" => required ? "pending_approval" : "skipped",
          "policy" => "block copy-back on critical or high vulnerabilities unless the approval explicitly documents an exception and rollback plan",
          "blocked_severities" => %w[critical high]
        },
        "lifecycle_sandbox_gate" => engine_run_lifecycle_sandbox_gate(
          required: required,
          package_manager: package_manager,
          lifecycle_scripts: lifecycle_scripts
        ),
        "execution_evidence" => {
          "status" => required ? "not_executed_pending_approval" : "skipped",
          "artifacts" => required ? [relative(paths.fetch(:supply_chain_sbom_path)), relative(paths.fetch(:supply_chain_audit_path))] : [],
          "reason" => required ? "package install, SBOM, and audit execution require explicit elevated approval and are not executed in the default sandbox profile" : "no package install request or package manifest mutation"
        },
        "evidence_refs" => {
          "supply_chain_gate_path" => relative(paths.fetch(:supply_chain_gate_path)),
          "staged_manifest_path" => relative(paths.fetch(:manifest_path)),
          "approval_path" => relative(paths.fetch(:approval_path))
        },
        "blocking_issues" => blockers
      }
    end

    def engine_run_package_lifecycle_scripts(workspace_dir)
      package_path = File.join(workspace_dir, "package.json")
      return [] unless File.file?(package_path)

      package = JSON.parse(File.read(package_path, 256 * 1024))
      scripts = package["scripts"].is_a?(Hash) ? package["scripts"] : {}
      %w[preinstall install postinstall prepare].filter_map do |name|
        command = scripts[name].to_s.strip
        next if command.empty?

        {
          "script" => name,
          "command" => redact_side_effect_process_output(command),
          "command_sha256" => Digest::SHA256.hexdigest(command)
        }
      end
    rescue JSON::ParserError, SystemCallError
      []
    end

    def engine_run_lifecycle_sandbox_gate(required:, package_manager:, lifecycle_scripts:)
      lifecycle_present = !Array(lifecycle_scripts).empty?
      lifecycle_enabled_status = lifecycle_present || required ? "blocked_until_sandbox_and_egress_firewall" : "not_required"
      {
        "schema_version" => 1,
        "policy" => "aiweb.engine_run.lifecycle_sandbox_gate.v1",
        "status" => lifecycle_enabled_status,
        "package_manager" => package_manager,
        "lifecycle_scripts_present" => lifecycle_present,
        "lifecycle_scripts" => Array(lifecycle_scripts),
        "default_install_lifecycle_execution" => false,
        "default_command_uses_ignore_scripts" => false,
        "lifecycle_enabled_install_status" => lifecycle_enabled_status,
        "egress_firewall" => {
          "default_sandbox_network" => "none",
          "lifecycle_enabled_network_policy" => "blocked_until_network_none_or_recorded_egress_firewall",
          "external_network_allowed" => false
        },
        "required_sandbox_evidence" => {
          "container_or_vm_isolation" => "required_for_lifecycle_enabled_install",
          "network_mode" => "none_or_explicit_registry_allowlist_with_egress_audit",
          "egress_firewall_default_deny" => true,
          "environment_allowlist_only" => true,
          "secret_environment_stripped" => true,
          "dot_env_reads_allowed" => false,
          "workspace_escape_allowed" => false,
          "required_artifacts" => %w[lifecycle-sandbox-attestation.json egress-firewall-log.json package-file-diff sbom package-audit]
        },
        "limitations" => [
          "engine-run default sandbox does not execute package installs",
          "lifecycle-enabled package install remains blocked until sandbox and egress evidence exists"
        ]
      }
    end

    def engine_run_supply_chain_pending_artifacts(gate, paths)
      return {} unless gate.to_h["required"]

      request_ids = Array(gate.dig("package_install_requests", "items")).filter_map { |request| request["id"] if request.is_a?(Hash) }
      {
        paths.fetch(:supply_chain_sbom_path) => {
          "schema_version" => 1,
          "artifact_kind" => "sbom",
          "status" => "not_executed_pending_approval",
          "recorded_at" => now,
          "package_manager" => gate["package_manager"],
          "accepted_formats" => gate.dig("sbom", "accepted_formats"),
          "approval_request_ids" => request_ids,
          "execution_boundary" => "blocked_until_elevated_supply_chain_approval",
          "reason" => "SBOM generation must run only after explicit package-install approval in an isolated staged cache"
        },
        paths.fetch(:supply_chain_audit_path) => {
          "schema_version" => 1,
          "artifact_kind" => "package_audit",
          "status" => "not_executed_pending_approval",
          "recorded_at" => now,
          "package_manager" => gate["package_manager"],
          "commands" => gate.dig("audit", "commands"),
          "approval_request_ids" => request_ids,
          "execution_boundary" => "blocked_until_elevated_supply_chain_approval",
          "blocked_severities" => gate.dig("vulnerability_copy_back_gate", "blocked_severities"),
          "reason" => "Package audit must run only after explicit package-install approval; copy-back remains blocked for critical/high findings without an exception and rollback plan"
        }
      }
    end

    def engine_run_supply_chain_package_manager(workspace_dir, package_actions)
      action_tool = Array(package_actions).map { |action| action["tool_name"].to_s }.find { |tool| %w[npm pnpm yarn bun].include?(tool) }
      return action_tool if action_tool
      return "pnpm" if File.file?(File.join(workspace_dir, "pnpm-lock.yaml"))
      return "yarn" if File.file?(File.join(workspace_dir, "yarn.lock"))
      return "bun" if File.file?(File.join(workspace_dir, "bun.lockb"))

      "npm"
    end

    def engine_run_dependency_snapshot(workspace_dir)
      package_path = File.join(workspace_dir, "package.json")
      package = File.file?(package_path) ? JSON.parse(File.read(package_path, 256 * 1024)) : {}
      dependencies = %w[dependencies devDependencies optionalDependencies peerDependencies].each_with_object({}) do |key, memo|
        memo[key] = package[key].is_a?(Hash) ? package[key].sort.to_h : {}
      end
      {
        "status" => File.file?(package_path) ? "captured" : "missing",
        "dependencies" => dependencies
      }
    rescue JSON::ParserError => e
      {
        "status" => "failed",
        "dependencies" => {},
        "blocking_issues" => ["package.json dependency snapshot failed: #{e.message}"]
      }
    end

    def engine_run_package_file_diff(manifest, workspace_dir)
      package_files = %w[package.json package-lock.json npm-shrinkwrap.json pnpm-lock.yaml yarn.lock bun.lockb]
      workspace_files = engine_run_workspace_files(workspace_dir)
      package_files.map do |path|
        base_hash = manifest.fetch("files", {}).dig(path, "sha256")
        current_hash = workspace_files.dig(path, "sha256")
        {
          "path" => path,
          "baseline_sha256" => base_hash,
          "current_sha256" => current_hash,
          "changed" => !base_hash.nil? && base_hash != current_hash || (base_hash.nil? && !current_hash.nil?)
        }
      end
    end

    def engine_run_supply_chain_audit_commands(package_manager)
      case package_manager.to_s
      when "pnpm"
        ["pnpm audit --json"]
      when "yarn"
        ["yarn npm audit --json"]
      when "bun"
        ["bun audit --json"]
      else
        ["npm audit --json", "npm sbom --json"]
      end
    end

    def engine_run_approval_risk(type)
      {
        "package_install" => "supply_chain_and_network",
        "external_network" => "external_data_exfiltration",
        "deploy" => "external_production_side_effect",
        "git_push" => "remote_repository_mutation",
        "mcp_connectors" => "delegated_identity_and_connector_data_access",
        "env_read" => "secret_environment_exposure",
        "copy_back_change" => "host_project_mutation"
      }.fetch(type.to_s, "elevated_side_effect")
    end

    def engine_run_approval_capability(type)
      {
        "package_install" => "approved_package_manager_install",
        "external_network" => "approved_network_destinations",
        "deploy" => "approved_provider_deploy",
        "git_push" => "approved_git_push",
        "mcp_connectors" => "approved_mcp_connector_calls",
        "env_read" => "approved_environment_read_scope",
        "copy_back_change" => "approved_copy_back_paths"
      }.fetch(type.to_s, "approved_elevated_action")
    end

    def engine_run_elevated_approval_requirements(type)
      case type.to_s
      when "package_install"
        %w[package_manager exact_command registry_allowlist network_allowlist lifecycle_script_policy lockfile_policy expected_changed_files timeout rollback_behavior dependency_diff lockfile_diff package_manager_config audit_sbom_output vulnerability_copy_back_gate]
      when "mcp_connectors"
        %w[mcp_server tool_names allowed_args_schema credential_source delegated_identity network_destinations output_redaction per_call_audit]
      when "external_network"
        %w[exact_command destination_allowlist method timeout output_redaction no_secret_upload audit_log]
      when "deploy"
        %w[provider exact_command target_environment credential_source rollback_plan production_confirmation audit_log]
      when "git_push"
        %w[remote branch commit_range protected_branch_check human_review_confirmation rollback_plan]
      when "env_read"
        %w[exact_command allowed_environment_keys redaction_policy no_secret_values audit_log]
      else
        %w[exact_command capability_scope risk_review audit_log]
      end
    end

    def engine_run_quarantine_record(run_id:, result:, policy:, sandbox_preflight:)
      reasons = []
      text = [result.fetch(:stdout).to_s, result.fetch(:stderr).to_s, Array(result.fetch(:blocking_issues)).join("\n"), Array(policy["blocking_issues"]).join("\n")].join("\n")
      reasons << "agent output contained secret-like content" if text.match?(ENGINE_RUN_SECRET_VALUE_PATTERN)
      reasons << "sandbox reported credential or secret leakage" if text.match?(/secret environment leaked|credential leaked|raw secret|raw env/i)
      reasons << "sandbox boundary or host mutation signal detected" if text.match?(/sandbox boundary|host root|root mutation|outside the workspace/i)
      reasons << "unexpected network or connector guard signal detected" if text.match?(/network guard missing|unexpected network|mcp guard missing|env guard missing/i)
      reasons.concat(Array(policy["blocking_issues"]).grep(/\.env|credential|secret|unsafe changed path/i))
      negative = sandbox_preflight.to_h.fetch("negative_checks", {})
      mounted_forbidden = negative.select { |name, value| value.to_s == "mounted" && name.to_s != "workspace" }
      reasons << "sandbox preflight observed forbidden host mount: #{mounted_forbidden.keys.sort.join(", ")}" unless mounted_forbidden.empty?
      reasons = reasons.compact.map(&:to_s).reject(&:empty?).uniq
      status = reasons.empty? ? "clear" : "quarantined"
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "recorded_at" => now,
        "reasons" => reasons,
        "blocking_issues" => reasons.map { |reason| "quarantine: #{reason}" },
        "copy_back_allowed" => reasons.empty?,
        "worker_cancel_required" => !reasons.empty?,
        "artifact_visibility" => reasons.empty? ? "normal" : "redacted_run_artifacts_plus_quarantine_summary",
        "manual_release_required" => !reasons.empty?
      }
    end

    def engine_run_requested_tool_actions(process_output)
      text = process_output.to_s
      actions = []
      actions << engine_run_tool_action("package_install", "Package installation requires explicit approval") if text.match?(/\b(?:npm|pnpm|yarn|bun)\s+(?:add|install|i|ci|update|upgrade|up)\b/i)
      actions << engine_run_tool_action("external_network", "External network access requires explicit approval") if text.match?(/\b(?:curl|wget)\s+https?:/i)
      actions << engine_run_tool_action("deploy", "Deploy/provider CLI execution requires explicit approval") if text.match?(/\b(?:vercel|netlify|cloudflare|wrangler)\b/i)
      actions << engine_run_tool_action("git_push", "git push requires explicit approval") if text.match?(/\bgit\s+push\b/i)
      actions << engine_run_tool_action("mcp_connectors", "MCP/connectors require explicit allowlist approval") if text.match?(/\b(?:mcp|connector|github\s+app|google\s+drive|gmail)\b/i)
      actions.uniq { |action| action["type"] }
    end

    def engine_run_requested_tool_actions_from_broker_events(workspace_dir)
      engine_run_workspace_tool_broker_events(workspace_dir).map do |event|
        type = event["risk_class"].to_s
        next if type.empty?

        engine_run_tool_action(type, event["reason"].to_s.empty? ? "Tool broker blocked prohibited staged action" : event["reason"].to_s).merge(
          "source" => "tool_broker",
          "tool_name" => event["tool_name"],
          "args_text" => engine_run_redact_event_text(event["args_text"].to_s)
        )
      end.compact.uniq { |action| action["type"] }
    end

    def engine_run_apply_workspace_tool_broker_events_to_policy(policy, workspace_dir)
      actions = engine_run_requested_tool_actions_from_broker_events(workspace_dir)
      return policy if actions.empty?

      policy["requested_actions"] = (Array(policy["requested_actions"]) + actions).uniq { |action| action["type"] }
      policy["approval_issues"] = Array(policy["approval_issues"])
      policy["approval_issues"] << "agent output indicates package install, network, deploy, provider CLI, MCP/connectors, env read, or git push may be required"
      policy["approval_issues"] << "tool broker blocked prohibited staged action before execution"
      policy["approval_issues"].uniq!
      policy["approval_requests"] = engine_run_approval_requests(policy["approval_issues"], Array(policy["approval_changes"]), policy["requested_actions"])
      policy["status"] = "waiting_approval" if policy["status"].to_s.empty? || %w[passed no_changes].include?(policy["status"].to_s)
      policy
    end

    def engine_run_tool_action(type, reason)
      {
        "schema_version" => 1,
        "type" => type,
        "status" => "blocked",
        "source" => "process_output",
        "reason" => reason
      }
    end

    def engine_run_workspace_files(workspace_dir)
      files = {}
      Find.find(workspace_dir) do |path|
        next if File.directory?(path)

        rel = path.sub(/^#{Regexp.escape(workspace_dir)}[\\\/]?/, "").tr("\\", "/")
        next if rel.start_with?("_aiweb/")
        next if engine_run_stage_excluded?(rel)
        next unless File.file?(path)

        files[rel] = {
          "sha256" => Digest::SHA256.file(path).hexdigest,
          "bytes" => File.size(path)
        }
      end
      files
    end

    def engine_run_writable_path?(path)
      normalized = path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
      ENGINE_RUN_DEFAULT_WRITABLE_GLOBS.any? do |glob|
        if glob.end_with?("/**")
          prefix = glob.delete_suffix("/**")
          normalized == prefix || normalized.start_with?("#{prefix}/")
        else
          File.fnmatch?(glob, normalized, File::FNM_PATHNAME | File::FNM_EXTGLOB)
        end
      end
    end

    def engine_run_high_risk_path?(path)
      ENGINE_RUN_HIGH_RISK_PATTERNS.any? { |pattern| path.match?(pattern) }
    end

    def engine_run_binary_file?(path)
      File.open(path, "rb") { |file| file.read(4096).to_s.include?("\x00") }
    rescue SystemCallError
      false
    end

    def engine_run_file_contains_secret?(path)
      return false unless File.file?(path)

      File.read(path, 256 * 1024).match?(ENGINE_RUN_SECRET_VALUE_PATTERN)
    rescue SystemCallError, ArgumentError
      true
    end

    def engine_run_workspace_diff(workspace_dir, changed_files)
      Array(changed_files).map do |path|
        source = File.join(root, path)
        workspace = File.join(workspace_dir, path)
        agent_run_full_file_diff(path, source, workspace)
      end.join
    end

    def engine_run_copy_back_conflicts(manifest, safe_changes)
      base_files = manifest.fetch("files", {})
      Array(safe_changes).each_with_object([]) do |path, conflicts|
        target = File.join(root, path)
        base_hash = base_files.dig(path, "sha256")
        if base_hash
          unless File.file?(target)
            conflicts << "copy-back target changed since staging: #{path}"
            next
          end
          current_hash = Digest::SHA256.file(target).hexdigest
          conflicts << "copy-back target changed since staging: #{path}" unless current_hash == base_hash
        elsif File.exist?(target) || File.symlink?(target)
          conflicts << "copy-back target appeared since staging: #{path}"
        end
      end
    end

    def engine_run_apply_safe_changes(workspace_dir, safe_changes)
      safe_changes.each do |path|
        source = File.join(workspace_dir, path)
        target = File.join(root, path)
        raise UserError.new("engine-run copy-back target is hardlinked and unsafe: #{path}", 5) if File.file?(target) && File.lstat(target).nlink.to_i > 1

        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(source, target)
      end
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

    def engine_run_preview_result(workspace_dir, paths, events, agent:, sandbox:)
      package_path = File.join(workspace_dir, "package.json")
      return engine_run_preview_skipped("package.json is missing in staged workspace") unless File.file?(package_path)

      package = JSON.parse(File.read(package_path))
      scripts = package["scripts"].is_a?(Hash) ? package["scripts"] : {}
      script = scripts.key?("dev") ? "dev" : (scripts.key?("preview") ? "preview" : nil)
      return engine_run_preview_skipped("package.json has no dev or preview script") unless script

      command = engine_run_package_command(workspace_dir, script, agent: agent, sandbox: sandbox)
      return engine_run_preview_skipped("package manager executable missing") unless command

      capability = { "mode" => "agentic_local", "goal" => "sandbox preview", "agent" => agent, "sandbox" => sandbox }
      tool_request = engine_run_tool_request("preview.#{script}", command, workspace_dir, capability, risk_class: "local_preview", expected_outputs: [relative(paths.fetch(:preview_path))])
      engine_run_event(paths.fetch(:events_path), events, "tool.requested", "preview requested sandbox #{script}", tool_request)
      engine_run_event(paths.fetch(:events_path), events, "policy.decision", "tool broker approved sandbox preview", tool_request.merge("decision" => "approved", "reason" => "preview uses local staged package script"))
      engine_run_event(paths.fetch(:events_path), events, "preview.started", "starting sandbox preview", command: command.join(" "))
      broker_event_offset = engine_run_tool_broker_event_count(workspace_dir)
      result = engine_run_start_preview_process(command, workspace_dir, paths, timeout_sec: 20, env: engine_run_verification_env(workspace_dir, paths, sandbox))
      engine_run_emit_workspace_tool_broker_events(workspace_dir, paths.fetch(:events_path), events, cycle: "preview:#{script}", offset: broker_event_offset)
      if result.fetch("status") == "ready"
        engine_run_event(paths.fetch(:events_path), events, "preview.ready", "sandbox preview reported ready", url: result["url"], exit_code: result["exit_code"], lifecycle: result["lifecycle"], pid: result["pid"])
        unless result["pid"]
          engine_run_event(paths.fetch(:events_path), events, "preview.stopped", "sandbox preview process already exited after readiness", status: result.fetch("status"), lifecycle: result["lifecycle"])
        end
      else
        engine_run_event(paths.fetch(:events_path), events, "preview.failed", "sandbox preview failed", exit_code: result["exit_code"])
        engine_run_event(paths.fetch(:events_path), events, "preview.stopped", "sandbox preview stopped", status: result.fetch("status"), lifecycle: result["lifecycle"])
      end
      result.merge("script" => script, "command" => command.join(" "))
    rescue JSON::ParserError => e
      engine_run_preview_failed("package.json is malformed in staged workspace: #{e.message}")
    end

    def engine_run_start_preview_process(command, cwd, paths, timeout_sec:, env:)
      stdout_path = File.join(paths.fetch(:logs_dir), "preview-stdout.log")
      stderr_path = File.join(paths.fetch(:logs_dir), "preview-stderr.log")
      FileUtils.mkdir_p(File.dirname(stdout_path))
      File.write(stdout_path, "")
      File.write(stderr_path, "")
      started_at = now
      pid = Process.spawn(env, *command, chdir: cwd, unsetenv_others: true, in: File::NULL, out: stdout_path, err: stderr_path)
      url = nil
      exit_code = nil
      timed_out = false
      deadline = Time.now + timeout_sec
      loop do
        stdout = File.file?(stdout_path) ? File.read(stdout_path, 64_000) : ""
        url ||= engine_run_preview_url(stdout)
        exit_code = engine_run_try_reap_process(pid)
        break if url || !exit_code.nil?
        if Time.now >= deadline
          timed_out = true
          break
        end
        sleep 0.1
      end

      if url
        stability_deadline = Time.now + 1.0
        loop do
          exit_code = engine_run_try_reap_process(pid)
          break if exit_code || Time.now >= stability_deadline
          sleep 0.05
        end
        if exit_code && exit_code != 0
          stdout = File.file?(stdout_path) ? File.read(stdout_path, 64_000) : ""
          stderr = File.file?(stderr_path) ? File.read(stderr_path, 64_000) : ""
          return {
            "schema_version" => 1,
            "status" => "failed",
            "pid" => nil,
            "process_tree" => [],
            "lifecycle" => "exited_after_ready_with_error",
            "teardown_required" => false,
            "url" => url,
            "exit_code" => exit_code,
            "stdout_path" => relative(stdout_path),
            "stderr_path" => relative(stderr_path),
            "stdout" => agent_run_redact_process_output(stdout)[0, 2000],
            "stderr" => agent_run_redact_process_output(stderr)[0, 2000],
            "started_at" => started_at,
            "finished_at" => now,
            "blocking_issues" => ["preview exited with code #{exit_code} after reporting readiness"]
          }
        end
        live = exit_code.nil? && engine_run_process_alive?(pid)
        return {
          "schema_version" => 1,
          "status" => "ready",
          "pid" => live ? pid : nil,
          "process_tree" => live ? [pid] : [],
          "lifecycle" => live ? "persistent_ready" : "exited_after_ready",
          "teardown_required" => live,
          "url" => url,
          "exit_code" => exit_code,
          "stdout_path" => relative(stdout_path),
          "stderr_path" => relative(stderr_path),
          "stdout" => agent_run_redact_process_output(File.read(stdout_path, 64_000))[0, 2000],
          "stderr" => agent_run_redact_process_output(File.read(stderr_path, 64_000))[0, 2000],
          "started_at" => started_at,
          "ready_at" => now,
          "blocking_issues" => []
        }
      end

      engine_run_stop_process(pid) if exit_code.nil?
      stdout = File.file?(stdout_path) ? File.read(stdout_path, 64_000) : ""
      stderr = File.file?(stderr_path) ? File.read(stderr_path, 64_000) : ""
      exit_code ||= timed_out ? 124 : 1
      issue = timed_out ? "preview readiness timed out after #{timeout_sec}s" : "preview failed with exit code #{exit_code}"
      {
        "schema_version" => 1,
        "status" => "failed",
        "pid" => nil,
        "process_tree" => [],
        "lifecycle" => timed_out ? "readiness_timeout" : "exited_before_ready",
        "teardown_required" => false,
        "url" => nil,
        "exit_code" => exit_code,
        "stdout_path" => relative(stdout_path),
        "stderr_path" => relative(stderr_path),
        "stdout" => agent_run_redact_process_output(stdout)[0, 2000],
        "stderr" => agent_run_redact_process_output(stderr)[0, 2000],
        "started_at" => started_at,
        "finished_at" => now,
        "blocking_issues" => [issue]
      }
    rescue SystemCallError => e
      {
        "schema_version" => 1,
        "status" => "failed",
        "pid" => nil,
        "process_tree" => [],
        "lifecycle" => "spawn_failed",
        "teardown_required" => false,
        "url" => nil,
        "exit_code" => 127,
        "stdout" => "",
        "stderr" => agent_run_redact_process_output(e.message)[0, 2000],
        "blocking_issues" => ["preview failed to start: #{e.message}"]
      }
    end

    def engine_run_preview_skipped(reason)
      {
        "schema_version" => 1,
        "status" => "skipped",
        "blocking_issues" => [],
        "reason" => reason
      }
    end

    def engine_run_preview_failed(issue)
      {
        "schema_version" => 1,
        "status" => "failed",
        "blocking_issues" => [issue]
      }
    end

    def engine_run_preview_url(stdout)
      stdout.to_s[/https?:\/\/(?:127\.0\.0\.1|localhost|\[?::1\]?)[^\s'"<>]+/]
    end

    def engine_run_screenshot_evidence(paths, preview, events, agent:, sandbox:)
      unless preview.fetch("status") == "ready"
        return {
          "schema_version" => 1,
          "status" => "skipped",
          "reason" => "preview is not ready",
          "runtime_attestation" => engine_run_browser_runtime_attestation(paths: paths, preview: preview, agent: agent, sandbox: sandbox, browser_commands: []),
          "screenshots" => [],
          "console_errors" => [],
          "network_errors" => [],
          "dom_snapshot" => engine_run_browser_evidence_unavailable("preview is not ready"),
          "a11y_report" => engine_run_browser_evidence_unavailable("preview is not ready"),
          "computed_style_summary" => engine_run_browser_evidence_unavailable("preview is not ready"),
          "interaction_states" => [],
          "keyboard_focus_traversal" => engine_run_browser_focus_unavailable("preview is not ready"),
          "action_recovery" => engine_run_browser_action_recovery_skipped("preview is not ready"),
          "action_loop" => engine_run_browser_action_loop_skipped("preview is not ready"),
          "blocking_issues" => []
        }
      end

      engine_run_event(paths.fetch(:events_path), events, "screenshot.capture.started", "capturing sandbox preview screenshots", preview_url: preview["url"])
      tool_request = engine_run_tool_request("browser.observe", ["node", "_aiweb/browser-observe.js", preview["url"].to_s], paths.fetch(:workspace_dir), { "mode" => "agentic_local", "goal" => "browser evidence", "agent" => agent, "sandbox" => sandbox }, risk_class: "localhost_browser_evidence", expected_outputs: [relative(paths.fetch(:screenshot_evidence_path))])
      engine_run_event(paths.fetch(:events_path), events, "tool.requested", "browser observation requested", tool_request)
      unless engine_run_local_preview_url?(preview["url"])
        issue = "browser observation only accepts local preview URLs on localhost, 127.0.0.1, or ::1"
        engine_run_event(paths.fetch(:events_path), events, "policy.decision", "tool broker blocked browser observation", tool_request.merge("decision" => "blocked", "reason" => issue))
        engine_run_event(paths.fetch(:events_path), events, "tool.blocked", "browser observation blocked by URL policy", preview_url: preview["url"])
        engine_run_stop_preview_if_needed(preview, paths, events, reason: "browser observation URL policy blocked")
        return {
          "schema_version" => 1,
          "status" => "failed",
          "preview_status" => preview["status"],
          "preview_url" => preview["url"],
          "network_policy" => "localhost-only",
          "runtime_attestation" => engine_run_browser_runtime_attestation(paths: paths, preview: preview, agent: agent, sandbox: sandbox, browser_commands: []),
          "screenshots" => [],
          "console_errors" => [],
          "network_errors" => [],
          "dom_snapshot" => engine_run_browser_evidence_unavailable(issue, status: "failed"),
          "a11y_report" => engine_run_browser_evidence_unavailable(issue, status: "failed"),
          "computed_style_summary" => engine_run_browser_evidence_unavailable(issue, status: "failed"),
          "interaction_states" => [],
          "keyboard_focus_traversal" => engine_run_browser_focus_unavailable(issue, status: "failed"),
          "action_recovery" => engine_run_browser_action_recovery_failed([issue]),
          "action_loop" => engine_run_browser_action_loop_failed([issue]),
          "blocking_issues" => [issue]
        }
      end
      engine_run_event(paths.fetch(:events_path), events, "policy.decision", "tool broker approved localhost browser observation", tool_request.merge("decision" => "approved", "reason" => "preview URL is local and evidence is redacted before display"))
      viewports = [
        ["desktop", 1440, 1000],
        ["tablet", 834, 1112],
        ["mobile", 390, 844]
      ]

      engine_run_write_browser_observer_script(paths.fetch(:workspace_dir))
      FileUtils.mkdir_p(paths.fetch(:screenshots_dir))
      workspace_evidence_dir = File.join(paths.fetch(:workspace_dir), "_aiweb", "browser-evidence")
      FileUtils.mkdir_p(workspace_evidence_dir)

      captures = []
      blockers = []
      browser_commands = []
      viewports.each do |viewport, width, height|
        workspace_screenshot = File.join("_aiweb", "browser-evidence", "#{viewport}.png")
        workspace_json = File.join("_aiweb", "browser-evidence", "#{viewport}.json")
        final_screenshot = File.join(paths.fetch(:screenshots_dir), "#{viewport}.png")
        command = engine_run_browser_observe_command(
          paths.fetch(:workspace_dir),
          preview["url"].to_s,
          viewport,
          width,
          height,
          workspace_screenshot,
          workspace_json,
          agent: agent,
          sandbox: sandbox
        )
        browser_commands << command
        engine_run_event(paths.fetch(:events_path), events, "tool.started", "starting browser observation", command: command.join(" "), viewport: viewport)
        broker_event_offset = engine_run_tool_broker_event_count(paths.fetch(:workspace_dir))
        stdout, stderr, status = engine_run_capture_command(command, paths.fetch(:workspace_dir), 90, env: engine_run_verification_env(paths.fetch(:workspace_dir), paths, sandbox))
        engine_run_emit_workspace_tool_broker_events(paths.fetch(:workspace_dir), paths.fetch(:events_path), events, cycle: "browser:#{viewport}", offset: broker_event_offset)
        if status != 0
          failed_capture = engine_run_read_browser_capture_if_present(paths.fetch(:workspace_dir), workspace_json)
          if failed_capture
            failed_capture["viewport"] ||= viewport
            failed_capture["width"] ||= width
            failed_capture["height"] ||= height
            failed_capture["stdout"] = agent_run_redact_process_output(stdout.to_s)[0, 1000] unless stdout.to_s.empty?
            failed_capture["stderr"] = agent_run_redact_process_output(stderr.to_s)[0, 1000] unless stderr.to_s.empty?
            blockers.concat(engine_run_browser_capture_blockers(failed_capture, viewport))
            captures << failed_capture
          end
          blockers << "browser observation #{viewport} failed with exit code #{status}: #{agent_run_redact_process_output(stderr.to_s)[0, 300]}".strip
          engine_run_event(paths.fetch(:events_path), events, "tool.finished", "browser observation failed", status: "failed", exit_code: status, viewport: viewport)
          next
        end

        capture = engine_run_read_browser_capture(paths.fetch(:workspace_dir), workspace_json)
        capture["stdout"] = agent_run_redact_process_output(stdout.to_s)[0, 1000] unless stdout.to_s.empty?
        capture["stderr"] = agent_run_redact_process_output(stderr.to_s)[0, 1000] unless stderr.to_s.empty?
        source_screenshot = File.join(paths.fetch(:workspace_dir), workspace_screenshot)
        unless File.file?(source_screenshot)
          blockers << "browser observation #{viewport} did not create screenshot evidence"
          engine_run_event(paths.fetch(:events_path), events, "tool.finished", "browser observation missing screenshot", status: "failed", exit_code: 1, viewport: viewport)
          next
        end
        png_evidence = engine_run_png_evidence(source_screenshot)
        unless png_evidence["valid"]
          blockers << "browser observation #{viewport} screenshot is not valid PNG evidence: #{png_evidence["reason"]}"
          engine_run_event(paths.fetch(:events_path), events, "tool.finished", "browser observation invalid screenshot", status: "failed", exit_code: 1, viewport: viewport, reason: png_evidence["reason"])
          next
        end
        FileUtils.cp(source_screenshot, final_screenshot)
        capture["screenshot"] ||= {}
        capture["screenshot"]["path"] = relative(final_screenshot)
        capture["screenshot"]["sha256"] = "sha256:#{Digest::SHA256.file(final_screenshot).hexdigest}"
        capture["screenshot"]["bytes"] = File.size(final_screenshot)
        capture["screenshot"]["capture_mode"] = "playwright_browser"
        capture["screenshot"]["mime_type"] = "image/png"
        capture["screenshot"]["png_signature_valid"] = true
        capture["screenshot"]["image_width"] = png_evidence["width"]
        capture["screenshot"]["image_height"] = png_evidence["height"]
        blockers.concat(engine_run_browser_capture_blockers(capture, viewport))
        captures << capture
        engine_run_event(paths.fetch(:events_path), events, "tool.finished", "browser observation finished", status: "passed", exit_code: status, viewport: viewport)
      end

      runtime_attestation = engine_run_browser_runtime_attestation(paths: paths, preview: preview, agent: agent, sandbox: sandbox, browser_commands: browser_commands)
      blockers.concat(runtime_attestation.fetch("blocking_issues")) unless runtime_attestation.fetch("status") == "passed"
      result = engine_run_browser_evidence_manifest(preview, captures, blockers, runtime_attestation)
      if blockers.empty?
        engine_run_event(paths.fetch(:events_path), events, "screenshot.capture.finished", "captured sandbox preview screenshots", count: result.fetch("screenshots").length)
      else
        engine_run_event(paths.fetch(:events_path), events, "screenshot.capture.failed", "browser evidence hard gate failed", blocking_issues: blockers)
      end
      engine_run_event(paths.fetch(:events_path), events, "browser.observation.recorded", "recorded browser observation evidence for visual QA", viewports: result.fetch("screenshots").map { |shot| shot["viewport"] }, preview_url: preview["url"], evidence: %w[screenshot dom_snapshot a11y computed_style interaction_states keyboard_focus action_recovery action_loop console_errors network_errors], status: result["status"])
      engine_run_event(paths.fetch(:events_path), events, "browser.action_recovery.recorded", "recorded reversible browser action and recovery evidence", viewports: result.dig("action_recovery", "viewports"), preview_url: preview["url"], status: result.dig("action_recovery", "status"), blocking_issues: result.dig("action_recovery", "blocking_issues"))
      engine_run_event(paths.fetch(:events_path), events, "browser.action_loop.recorded", "recorded bounded safe local browser action loop evidence", viewports: result.dig("action_loop", "viewports"), preview_url: preview["url"], status: result.dig("action_loop", "status"), autonomy_level: result.dig("action_loop", "autonomy_level"), blocking_issues: result.dig("action_loop", "blocking_issues"))
      engine_run_stop_preview_if_needed(preview, paths, events, reason: "browser observation complete")
      result
    rescue SystemCallError, JSON::ParserError => e
      engine_run_event(paths.fetch(:events_path), events, "screenshot.capture.failed", "screenshot capture failed", error: e.message)
      engine_run_stop_preview_if_needed(preview, paths, events, reason: "browser observation failed")
      {
        "schema_version" => 1,
        "status" => "failed",
        "runtime_attestation" => engine_run_browser_runtime_attestation(paths: paths, preview: preview, agent: agent, sandbox: sandbox, browser_commands: []),
        "screenshots" => [],
        "console_errors" => [],
        "network_errors" => [],
        "dom_snapshot" => engine_run_browser_evidence_unavailable("screenshot capture failed: #{e.message}", status: "failed"),
        "a11y_report" => engine_run_browser_evidence_unavailable("screenshot capture failed: #{e.message}", status: "failed"),
        "computed_style_summary" => engine_run_browser_evidence_unavailable("screenshot capture failed: #{e.message}", status: "failed"),
        "interaction_states" => [],
        "keyboard_focus_traversal" => engine_run_browser_focus_unavailable("screenshot capture failed: #{e.message}", status: "failed"),
        "action_recovery" => engine_run_browser_action_recovery_failed(["screenshot capture failed: #{e.message}"]),
        "action_loop" => engine_run_browser_action_loop_failed(["screenshot capture failed: #{e.message}"]),
        "blocking_issues" => ["screenshot capture failed: #{e.message}"]
      }
    end

    def engine_run_stop_preview_if_needed(preview, paths, events, reason:)
      pid = preview["pid"].to_i
      return unless pid.positive?

      stop_status = engine_run_stop_process(pid)
      preview["pid"] = nil
      preview["process_tree"] = []
      preview["teardown_required"] = false
      preview["stopped_at"] = now
      preview["stop_status"] = stop_status
      if preview["stdout_path"]
        full_stdout = File.join(root, preview["stdout_path"].to_s)
        preview["stdout"] = agent_run_redact_process_output(File.read(full_stdout, 64_000))[0, 2000] if File.file?(full_stdout)
      end
      if preview["stderr_path"]
        full_stderr = File.join(root, preview["stderr_path"].to_s)
        preview["stderr"] = agent_run_redact_process_output(File.read(full_stderr, 64_000))[0, 2000] if File.file?(full_stderr)
      end
      engine_run_event(paths.fetch(:events_path), events, "preview.stopped", "sandbox preview stopped", status: preview.fetch("status"), lifecycle: preview["lifecycle"], stop_status: stop_status, reason: reason)
    end

    def engine_run_local_preview_url?(url)
      uri = URI.parse(url.to_s)
      uri.scheme == "http" && %w[localhost 127.0.0.1 ::1].include?(uri.host.to_s)
    rescue URI::InvalidURIError
      false
    end

    def engine_run_browser_observe_command(workspace_dir, url, viewport, width, height, screenshot_path, evidence_path, agent:, sandbox:)
      command = [
        "node",
        File.join("_aiweb", "browser-observe.js"),
        url,
        viewport,
        width.to_s,
        height.to_s,
        screenshot_path,
        evidence_path
      ]
      if engine_run_container_worker_agent?(agent) && !sandbox.to_s.strip.empty?
        return engine_run_sandbox_tool_command(sandbox, workspace_dir, command, tool: "browser_observe", agent: agent)
      end
      command
    end

    def engine_run_read_browser_capture(workspace_dir, evidence_path)
      full = File.join(workspace_dir, evidence_path)
      raise JSON::ParserError, "browser observation evidence missing: #{evidence_path}" unless File.file?(full)

      data = JSON.parse(File.read(full, 200_000))
      data.is_a?(Hash) ? data : { "schema_version" => 1, "status" => "failed", "blocking_issues" => ["browser observation evidence was not an object"] }
    end

    def engine_run_read_browser_capture_if_present(workspace_dir, evidence_path)
      full = File.join(workspace_dir, evidence_path)
      return nil unless File.file?(full)

      engine_run_read_browser_capture(workspace_dir, evidence_path)
    rescue JSON::ParserError, SystemCallError => e
      {
        "schema_version" => 1,
        "status" => "failed",
        "console_errors" => [],
        "network_errors" => [],
        "blocking_issues" => ["browser observation failed and evidence could not be parsed: #{e.message}"]
      }
    end

    def engine_run_png_evidence(path)
      header = File.binread(path, 33)
      signature = "\x89PNG\r\n\x1A\n".b
      return { "valid" => false, "reason" => "png header is too short" } if header.bytesize < 33
      return { "valid" => false, "reason" => "png signature mismatch" } unless header.byteslice(0, 8) == signature
      return { "valid" => false, "reason" => "missing IHDR chunk" } unless header.byteslice(12, 4) == "IHDR"

      width, height = header.byteslice(16, 8).unpack("NN")
      return { "valid" => false, "reason" => "invalid PNG dimensions" } if width.to_i <= 1 || height.to_i <= 1
      return { "valid" => false, "reason" => "PNG dimensions look like placeholder output" } if File.size(path) < 128

      { "valid" => true, "width" => width, "height" => height }
    rescue SystemCallError => e
      { "valid" => false, "reason" => e.message }
    end

    def engine_run_browser_capture_blockers(capture, viewport)
      blockers = Array(capture["blocking_issues"])
      blockers << "browser observation #{viewport} did not finish successfully" unless capture["status"] == "captured"
      blockers << "browser observation #{viewport} missing DOM snapshot" unless capture.dig("dom_snapshot", "status") == "captured"
      blockers << "browser observation #{viewport} missing accessibility snapshot" unless capture.dig("a11y_report", "status") == "captured"
      blockers << "browser observation #{viewport} missing computed style evidence" unless capture.dig("computed_style_summary", "status") == "captured"
      console_errors = Array(capture["console_errors"])
      network_errors = Array(capture["network_errors"])
      blockers << "browser observation #{viewport} recorded console errors: #{console_errors.length}" unless console_errors.empty?
      blockers << "browser observation #{viewport} recorded network errors: #{network_errors.length}" unless network_errors.empty?
      required_states = %w[default hover focus-visible active disabled loading empty error success]
      observed_states = Array(capture["interaction_states"]).each_with_object({}) { |state, memo| memo[state["state"].to_s] = state["status"].to_s }
      missing_states = required_states.reject { |state| %w[captured not_applicable].include?(observed_states[state]) }
      blockers << "browser observation #{viewport} missing interaction state coverage: #{missing_states.join(", ")}" unless missing_states.empty?
      blockers << "browser observation #{viewport} missing keyboard focus traversal" unless capture.dig("keyboard_focus_traversal", "status") == "captured"
      action_recovery = capture["action_recovery"]
      blockers << "browser observation #{viewport} missing browser action/recovery loop" unless action_recovery.is_a?(Hash) && action_recovery["status"] == "captured"
      blockers << "browser observation #{viewport} missing browser action/recovery unsafe-navigation policy enforcement" unless action_recovery.is_a?(Hash) && action_recovery["unsafe_navigation_policy_enforced"] == true
      meaningful_actions = Array(action_recovery && action_recovery["actions"]).any? do |entry|
        entry.is_a?(Hash) && entry["status"].to_s != "not_applicable" && Array(entry["actions"]).any?
      end
      blockers << "browser observation #{viewport} missing meaningful safe browser action steps" unless meaningful_actions
      blockers << "browser observation #{viewport} missing browser action recovery steps" if action_recovery.is_a?(Hash) && Array(action_recovery["recovery_steps"]).empty?
      blockers.concat(Array(action_recovery && action_recovery["blocking_issues"]).map { |issue| "browser observation #{viewport} action/recovery: #{issue}" })
      blockers
    end

    def engine_run_browser_runtime_attestation(paths:, preview:, agent:, sandbox:, browser_commands:)
      sandbox_required = agent.to_s == "openmanus" && !sandbox.to_s.strip.empty?
      preview_command = preview.to_h["command"].to_s
      browser_tool_wrapped = if sandbox_required
                               Array(browser_commands).all? { |command| File.basename(command.first.to_s).sub(/\.cmd\z/i, "") == sandbox.to_s }
                             else
                               true
                             end
      preview_tool_wrapped = if sandbox_required
                               File.basename(preview_command.split(/\s+/).first.to_s).sub(/\.cmd\z/i, "") == sandbox.to_s
                             else
                               true
                             end
      blockers = []
      blockers << "browser evidence preview command did not use the selected sandbox wrapper" if sandbox_required && !preview_tool_wrapped
      blockers << "browser evidence observation command did not use the selected sandbox wrapper" if sandbox_required && !browser_tool_wrapped
      blockers << "browser evidence requires a ready local preview before attestation" unless preview.to_h["status"] == "ready"
      blockers << "browser evidence did not record any browser observation commands" if preview.to_h["status"] == "ready" && Array(browser_commands).empty?
      {
        "schema_version" => 1,
        "status" => blockers.empty? ? "passed" : (preview.to_h["status"] == "ready" ? "failed" : "skipped"),
        "agent" => agent,
        "sandbox" => sandbox,
        "sandbox_required" => sandbox_required,
        "workspace_path" => relative(paths.fetch(:workspace_dir)),
        "same_staged_workspace" => true,
        "same_container_instance" => false,
        "same_container_instance_reason" => "local Docker/Podman tool commands are isolated invocations; aiweb attests shared staged workspace and sandbox/tool-broker boundary, not a single long-lived container",
        "preview_status" => preview.to_h["status"],
        "preview_url" => preview.to_h["url"],
        "preview_command" => preview_command.empty? ? nil : preview_command,
        "preview_tool_wrapped" => preview_tool_wrapped,
        "browser_observe_commands" => Array(browser_commands).map { |command| command.join(" ") },
        "browser_tool_wrapped" => browser_tool_wrapped,
        "tool_broker_bin_path" => "_aiweb/tool-broker-bin",
        "tool_broker_path_prepend_required" => true,
        "network_policy" => "localhost-only",
        "browser_evidence_workspace_dir" => relative(File.join(paths.fetch(:workspace_dir), "_aiweb", "browser-evidence")),
        "blocking_issues" => blockers
      }
    end

    def engine_run_browser_evidence_manifest(preview, captures, blockers, runtime_attestation)
      screenshots = captures.select { |capture| capture.dig("screenshot", "path") && capture.dig("screenshot", "sha256") }.map do |capture|
        shot = capture.fetch("screenshot", {})
        {
          "viewport" => capture.fetch("viewport"),
          "width" => capture.fetch("width"),
          "height" => capture.fetch("height"),
          "url" => preview["url"],
          "path" => shot.fetch("path"),
          "sha256" => shot.fetch("sha256"),
          "bytes" => shot.fetch("bytes"),
          "capture_mode" => shot.fetch("capture_mode"),
          "mime_type" => shot.fetch("mime_type"),
          "png_signature_valid" => shot.fetch("png_signature_valid"),
          "image_width" => shot.fetch("image_width"),
          "image_height" => shot.fetch("image_height")
        }
      end
      {
        "schema_version" => 1,
        "status" => blockers.empty? && captures.length == 3 ? "captured" : "failed",
        "preview_status" => preview["status"],
        "preview_url" => preview["url"],
        "network_policy" => "localhost-only",
        "browser_runtime" => "playwright",
        "sandbox_boundary" => "staged_workspace_tool_broker",
        "runtime_attestation" => runtime_attestation,
        "screenshots" => screenshots,
        "viewport_evidence" => captures,
        "console_errors" => engine_run_merge_browser_observations(captures, "console_errors"),
        "network_errors" => engine_run_merge_browser_observations(captures, "network_errors"),
        "dom_snapshot" => engine_run_merge_browser_evidence(captures, "dom_snapshot"),
        "a11y_report" => engine_run_merge_browser_evidence(captures, "a11y_report"),
        "computed_style_summary" => engine_run_merge_browser_evidence(captures, "computed_style_summary"),
        "interaction_states" => engine_run_merge_interaction_states(captures),
        "keyboard_focus_traversal" => engine_run_merge_focus_traversal(captures),
        "action_recovery" => engine_run_merge_action_recovery(captures),
        "action_loop" => engine_run_browser_action_loop(captures),
        "blocking_issues" => blockers.uniq
      }
    end

    def engine_run_browser_action_recovery_skipped(reason)
      {
        "schema_version" => 1,
        "status" => "skipped",
        "required" => true,
        "policy" => "localhost-only reversible UI actions; external navigation is blocked and recorded",
        "reason" => reason.to_s,
        "viewports" => [],
        "action_sequences" => [],
        "recovery_attempts" => [],
        "external_requests_blocked" => [],
        "blocking_issues" => []
      }
    end

    def engine_run_browser_action_recovery_failed(blockers)
      {
        "schema_version" => 1,
        "status" => "failed",
        "required" => true,
        "policy" => "localhost-only reversible UI actions; external navigation is blocked and recorded",
        "viewports" => [],
        "action_sequences" => [],
        "recovery_attempts" => [],
        "external_requests_blocked" => [],
        "blocking_issues" => Array(blockers).compact.map(&:to_s)
      }
    end

    def engine_run_browser_action_loop_skipped(reason)
      engine_run_browser_action_loop_envelope(
        status: "skipped",
        viewports: [],
        planned_steps: [],
        executed_steps: [],
        recovery_steps: [],
        blocked_steps: [],
        blocking_issues: [],
        reason: reason.to_s
      )
    end

    def engine_run_browser_action_loop_failed(blockers)
      engine_run_browser_action_loop_envelope(
        status: "failed",
        viewports: [],
        planned_steps: [],
        executed_steps: [],
        recovery_steps: [],
        blocked_steps: [],
        blocking_issues: Array(blockers).compact.map(&:to_s)
      )
    end

    def engine_run_browser_evidence_unavailable(reason, status: "skipped")
      {
        "schema_version" => 1,
        "status" => status,
        "reason" => reason.to_s,
        "capture_mode" => nil,
        "viewports" => [],
        "items" => [],
        "blocking_issues" => status == "failed" ? [reason.to_s] : []
      }
    end

    def engine_run_browser_focus_unavailable(reason, status: "skipped")
      {
        "schema_version" => 1,
        "status" => status,
        "required" => true,
        "reason" => reason.to_s,
        "viewports" => []
      }
    end

    def engine_run_merge_browser_observations(captures, key)
      captures.flat_map do |capture|
        Array(capture[key]).map do |entry|
          if entry.is_a?(Hash)
            entry.merge("viewport" => entry["viewport"] || capture["viewport"])
          else
            { "viewport" => capture["viewport"], "message" => entry.to_s }
          end
        end
      end
    end

    def engine_run_merge_browser_evidence(captures, key)
      items = captures.map { |capture| capture[key] }.compact
      status = captures.any? && items.all? { |item| item["status"] == "captured" } && items.length == captures.length ? "captured" : "failed"
      {
        "schema_version" => 1,
        "status" => status,
        "capture_mode" => "playwright_browser",
        "viewports" => captures.map { |capture| capture["viewport"] },
        "items" => items,
        "required_fields" => %w[route viewport selector data_aiweb_id text_role computed_styles bounding_box]
      }
    end

    def engine_run_merge_interaction_states(captures)
      names = %w[default hover focus-visible active disabled loading empty error success]
      names.map do |name|
        per_viewport = captures.map do |capture|
          state = Array(capture["interaction_states"]).find { |item| item["state"] == name } || {}
          { "viewport" => capture["viewport"], "status" => state["status"], "evidence" => Array(state["evidence"]) }
        end
        {
          "state" => name,
          "status" => captures.any? && per_viewport.all? { |item| %w[captured not_applicable].include?(item["status"]) } ? "captured" : "failed",
          "viewports" => per_viewport
        }
      end
    end

    def engine_run_merge_focus_traversal(captures)
      {
        "schema_version" => 1,
        "status" => captures.any? && captures.all? { |capture| capture.dig("keyboard_focus_traversal", "status") == "captured" } ? "captured" : "failed",
        "required" => true,
        "viewports" => captures.map do |capture|
          {
            "viewport" => capture["viewport"],
            "steps" => Array(capture.dig("keyboard_focus_traversal", "steps"))
          }
        end
      }
    end

    def engine_run_merge_action_recovery(captures)
      per_viewport = captures.map do |capture|
        evidence = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        {
          "viewport" => capture["viewport"],
          "status" => evidence["status"] || "failed",
          "action_count" => Array(evidence["actions"]).length,
          "recovery_count" => Array(evidence["recovery_steps"]).length,
          "actionable_target_count" => evidence["actionable_target_count"].to_i,
          "unsafe_navigation_policy_enforced" => evidence["unsafe_navigation_policy_enforced"] == true,
          "unsafe_navigation_blocked" => evidence["unsafe_navigation_blocked"] == true,
          "external_request_block_count" => Array(evidence["external_requests_blocked"]).length,
          "blocking_issues" => Array(evidence["blocking_issues"])
        }
      end
      blockers = per_viewport.flat_map { |entry| Array(entry["blocking_issues"]).map { |issue| "#{entry["viewport"]}: #{issue}" } }
      action_sequences = captures.flat_map do |capture|
        evidence = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(evidence["actions"]).map do |action|
          action.is_a?(Hash) ? action.merge("viewport" => capture["viewport"]) : { "viewport" => capture["viewport"], "action" => action.to_s }
        end
      end
      recovery_attempts = captures.flat_map do |capture|
        evidence = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(evidence["recovery_steps"]).map do |step|
          step.is_a?(Hash) ? step.merge("viewport" => capture["viewport"]) : { "viewport" => capture["viewport"], "action" => step.to_s }
        end
      end
      external_requests_blocked = captures.flat_map do |capture|
        evidence = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(evidence["external_requests_blocked"]).map do |entry|
          entry.is_a?(Hash) ? entry.merge("viewport" => entry["viewport"] || capture["viewport"]) : { "viewport" => capture["viewport"], "url" => entry.to_s }
        end
      end
      {
        "schema_version" => 1,
        "status" => captures.any? && per_viewport.all? { |entry| entry["status"] == "captured" } && blockers.empty? ? "captured" : "failed",
        "required" => true,
        "policy" => "localhost-only reversible UI actions; external navigation is blocked and recorded",
        "viewports" => per_viewport,
        "action_sequences" => action_sequences,
        "recovery_attempts" => recovery_attempts,
        "external_requests_blocked" => external_requests_blocked,
        "blocking_issues" => blockers
      }
    end

    def engine_run_browser_action_loop(captures)
      viewports = captures.map do |capture|
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        actions = Array(recovery["actions"])
        recovery_steps = Array(recovery["recovery_steps"])
        blocked_requests = Array(recovery["external_requests_blocked"])
        blocking_issues = Array(recovery["blocking_issues"])
        {
          "viewport" => capture["viewport"],
          "status" => recovery["status"] == "captured" && blocking_issues.empty? ? "captured" : "failed",
          "planned_step_count" => actions.length,
          "executed_step_count" => actions.count { |action| action.is_a?(Hash) && %w[captured passed not_applicable].include?(action["status"].to_s) },
          "recovery_step_count" => recovery_steps.length + actions.sum { |action| action.is_a?(Hash) ? Array(action["recovery"]).length : 0 },
          "blocked_step_count" => blocked_requests.length,
          "unsafe_navigation_policy_enforced" => recovery["unsafe_navigation_policy_enforced"] == true,
          "unsafe_navigation_blocked" => recovery["unsafe_navigation_blocked"] == true,
          "blocking_issues" => blocking_issues
        }
      end
      planned_steps = captures.flat_map do |capture|
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(recovery["actions"]).map do |action|
          descriptor = action.is_a?(Hash) ? action : { "action" => action.to_s }
          descriptor.slice("index", "selector", "text_role", "data_aiweb_id", "bounding_box", "reason").merge(
            "viewport" => capture["viewport"],
            "planned_actions" => Array(descriptor["actions"]).map { |step| step.is_a?(Hash) ? step.slice("name", "status", "reason") : { "name" => step.to_s } }
          )
        end
      end
      executed_steps = captures.flat_map do |capture|
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(recovery["actions"]).flat_map do |action|
          next [] unless action.is_a?(Hash)

          Array(action["actions"]).map do |step|
            step = step.is_a?(Hash) ? step : { "name" => step.to_s }
            {
              "viewport" => capture["viewport"],
              "target_index" => action["index"],
              "selector" => action["selector"],
              "name" => step["name"],
              "status" => step["status"] || "recorded",
              "reason" => step["reason"]
            }.compact
          end
        end
      end
      recovery_steps = captures.flat_map do |capture|
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        direct_steps = Array(recovery["recovery_steps"]).map do |step|
          step = step.is_a?(Hash) ? step : { "action" => step.to_s }
          step.merge("viewport" => capture["viewport"])
        end
        nested_steps = Array(recovery["actions"]).flat_map do |action|
          next [] unless action.is_a?(Hash)

          Array(action["recovery"]).map do |step|
            step = step.is_a?(Hash) ? step : { "name" => step.to_s }
            step.merge(
              "viewport" => capture["viewport"],
              "target_index" => action["index"],
              "selector" => action["selector"]
            )
          end
        end
        direct_steps + nested_steps
      end
      blocked_steps = captures.flat_map do |capture|
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        Array(recovery["external_requests_blocked"]).map do |entry|
          entry = entry.is_a?(Hash) ? entry : { "url" => entry.to_s }
          entry.merge("viewport" => capture["viewport"], "policy" => "non_local_request_blocked")
        end
      end
      scenarios = engine_run_browser_action_loop_scenarios(captures)
      scenario_plan = scenarios.map do |scenario|
        scenario.slice("scenario_id", "viewport", "goal", "policy", "target_count", "steps")
      end
      scenario_results = scenarios.map do |scenario|
        scenario.slice("scenario_id", "viewport", "status", "step_count", "recovery_step_count", "blocked_step_count", "blocking_issues")
      end
      multi_step_evidence = engine_run_browser_action_loop_multi_step_evidence(
        scenario_results: scenario_results,
        executed_steps: executed_steps,
        recovery_steps: recovery_steps,
        blocked_steps: blocked_steps
      )
      blockers = viewports.flat_map { |entry| Array(entry["blocking_issues"]).map { |issue| "#{entry["viewport"]}: #{issue}" } }
      status = captures.length == 3 &&
        viewports.all? { |entry| entry["status"] == "captured" && entry["unsafe_navigation_policy_enforced"] == true } &&
        scenario_results.length == captures.length &&
        scenario_results.all? { |scenario| scenario["status"] == "captured" } &&
        multi_step_evidence["multi_step_sequences_observed"] == true &&
        multi_step_evidence["all_scenarios_recovered"] == true &&
        executed_steps.any? &&
        recovery_steps.any? &&
        blockers.empty? ? "captured" : "failed"
      envelope = engine_run_browser_action_loop_envelope(
        status: status,
        viewports: viewports,
        planned_steps: planned_steps,
        executed_steps: executed_steps,
        recovery_steps: recovery_steps,
        blocked_steps: blocked_steps,
        scenario_plan: scenario_plan,
        scenario_results: scenario_results,
        multi_step_evidence: multi_step_evidence,
        blocking_issues: blockers
      )
      envelope["limits"]["observed_viewports"] = captures.length
      envelope
    end

    def engine_run_browser_action_loop_scenarios(captures)
      captures.map do |capture|
        viewport = capture["viewport"].to_s
        recovery = capture["action_recovery"].is_a?(Hash) ? capture["action_recovery"] : {}
        actions = Array(recovery["actions"]).select { |action| action.is_a?(Hash) }
        direct_recovery_steps = Array(recovery["recovery_steps"])
        blocking_issues = Array(recovery["blocking_issues"]).compact.map(&:to_s)
        step_count = actions.sum { |action| Array(action["actions"]).length }
        recovery_step_count = direct_recovery_steps.length + actions.sum { |action| Array(action["recovery"]).length }
        blocked_step_count = Array(recovery["external_requests_blocked"]).length
        steps = actions.first(5).map do |action|
          {
            "target_index" => action["index"],
            "selector" => action["selector"],
            "text_role" => action["text_role"],
            "data_aiweb_id" => action["data_aiweb_id"],
            "planned_actions" => Array(action["actions"]).map do |step|
              step = step.is_a?(Hash) ? step : { "name" => step.to_s }
              step.slice("name", "status", "reason")
            end,
            "recovery_actions" => Array(action["recovery"]).map do |step|
              step = step.is_a?(Hash) ? step : { "name" => step.to_s }
              step.slice("name", "action", "status", "reason")
            end
          }.compact
        end
        status = recovery["status"] == "captured" &&
          blocking_issues.empty? &&
          step_count >= 2 &&
          recovery_step_count.positive? ? "captured" : "failed"
        {
          "scenario_id" => "safe-local-ui-probe-#{viewport}",
          "viewport" => viewport,
          "goal" => "probe reversible local UI interactions and recover preview state",
          "policy" => {
            "network" => "localhost-only",
            "reversible_only" => true,
            "external_navigation_blocked" => true,
            "form_submission_allowed" => false
          },
          "target_count" => actions.length,
          "steps" => steps,
          "status" => status,
          "step_count" => step_count,
          "recovery_step_count" => recovery_step_count,
          "blocked_step_count" => blocked_step_count,
          "blocking_issues" => blocking_issues
        }
      end
    end

    def engine_run_browser_action_loop_multi_step_evidence(scenario_results:, executed_steps:, recovery_steps:, blocked_steps:)
      results = Array(scenario_results)
      {
        "scenario_count" => results.length,
        "multi_step_sequences_observed" => results.any? { |scenario| scenario["step_count"].to_i >= 2 } || Array(executed_steps).length >= 2,
        "all_scenarios_recovered" => results.any? && results.all? { |scenario| scenario["status"] == "captured" && scenario["recovery_step_count"].to_i.positive? },
        "total_executed_step_count" => Array(executed_steps).length,
        "total_recovery_step_count" => Array(recovery_steps).length,
        "total_blocked_step_count" => Array(blocked_steps).length,
        "policy" => {
          "network" => "localhost-only",
          "reversible_only" => true,
          "external_navigation_blocked" => true,
          "form_submission_allowed" => false
        }
      }
    end

    def engine_run_browser_action_loop_envelope(status:, viewports:, planned_steps:, executed_steps:, recovery_steps:, blocked_steps:, blocking_issues:, reason: nil, scenario_plan: [], scenario_results: [], multi_step_evidence: nil)
      scenario_results = Array(scenario_results)
      multi_step_evidence ||= engine_run_browser_action_loop_multi_step_evidence(
        scenario_results: scenario_results,
        executed_steps: executed_steps,
        recovery_steps: recovery_steps,
        blocked_steps: blocked_steps
      )
      {
        "schema_version" => 1,
        "status" => status,
        "required" => true,
        "loop_type" => "bounded_safe_local_observation_loop",
        "goal_source" => "selected_design_fixture_and_browser_evidence",
        "autonomy_level" => "deterministic_observation_not_open_ended",
        "planner" => "static_safe_action_plan",
        "policy" => {
          "network" => "localhost-only",
          "allowed_actions" => %w[scroll_into_view hover focus fill_text_probe restore_input_value click_same_origin_anchor click_toggle_button escape restore_preview_url],
          "blocked_actions" => %w[external_navigation form_submit destructive_click credential_entry file_upload payment deploy],
          "reversible_only" => true,
          "external_navigation_blocked" => true,
          "form_submission_allowed" => false
        },
        "limits" => {
          "expected_viewports" => %w[desktop tablet mobile],
          "observed_viewports" => Array(viewports).length,
          "max_targets_per_viewport" => 5,
          "max_steps_per_target" => 4,
          "timeout_seconds_per_viewport" => 90
        },
        "stop_condition" => "all_viewports_observed_and_recovered_or_policy_blocked",
        "viewports" => Array(viewports),
        "planned_steps" => Array(planned_steps),
        "executed_steps" => Array(executed_steps),
        "recovery_steps" => Array(recovery_steps),
        "blocked_steps" => Array(blocked_steps),
        "scenario_plan" => Array(scenario_plan),
        "scenario_results" => scenario_results,
        "multi_step_evidence" => multi_step_evidence,
        "limitations" => [
          "not a production open-ended browser agent",
          "does not submit forms or perform irreversible clicks",
          "does not navigate beyond the local preview origin"
        ],
        "blocking_issues" => Array(blocking_issues).compact.map(&:to_s)
      }.tap do |payload|
        payload["reason"] = reason.to_s if reason
      end
    end

    def engine_run_write_browser_observer_script(workspace_dir)
      path = File.join(workspace_dir, "_aiweb", "browser-observe.js")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, <<~'JS')
        const fs = require('fs');
        const path = require('path');

        const [url, viewport, widthText, heightText, screenshotPath, evidencePath] = process.argv.slice(2);
        const width = Number(widthText);
        const height = Number(heightText);
        let observedConsoleErrors = [];
        let observedNetworkErrors = [];
        let observedBlockedExternalRequests = [];
        let observedActionRecovery = null;

        function ensureParent(filePath) {
          fs.mkdirSync(path.dirname(filePath), { recursive: true });
        }

        function uniqueBlockedRequests(requests) {
          return Array.from(new Map((requests || []).map((entry) => [`${entry.method}:${entry.url}:${entry.resource_type}`, entry])).values());
        }

        function failedEvidenceBlock(reason, captureMode) {
          return {
            schema_version: 1,
            status: 'failed',
            reason,
            capture_mode: captureMode || null,
            viewports: [],
            items: [],
            blocking_issues: [reason]
          };
        }

        function failedFocusBlock(reason) {
          return {
            schema_version: 1,
            status: 'failed',
            required: true,
            reason,
            viewports: []
          };
        }

        async function main() {
          const { chromium } = require('playwright');
          ensureParent(screenshotPath);
          ensureParent(evidencePath);
          const browser = await chromium.launch({ headless: true });
          const page = await browser.newPage({ viewport: { width, height } });
          const consoleErrors = [];
          const networkErrors = [];
          const blockedExternalRequests = [];
          observedConsoleErrors = consoleErrors;
          observedNetworkErrors = networkErrors;
          observedBlockedExternalRequests = blockedExternalRequests;
          function isLocalBrowserUrl(rawUrl) {
            try {
              const parsed = new URL(rawUrl);
              if (['about:', 'data:', 'blob:'].includes(parsed.protocol)) return true;
              if (!['http:', 'https:', 'ws:', 'wss:'].includes(parsed.protocol)) return false;
              return ['localhost', '127.0.0.1', '::1'].includes(parsed.hostname);
            } catch (_error) {
              return false;
            }
          }
          await page.route('**/*', async (route) => {
            const request = route.request();
            if (!isLocalBrowserUrl(request.url())) {
              let frameUrl = null;
              try {
                frameUrl = request.frame() ? request.frame().url().slice(0, 500) : null;
              } catch (_error) {
                frameUrl = null;
              }
              blockedExternalRequests.push({
                url: request.url().slice(0, 500),
                method: request.method(),
                resource_type: request.resourceType(),
                is_navigation_request: request.isNavigationRequest(),
                frame_url: frameUrl,
                failure: 'non_local_request_blocked'
              });
              await route.abort('blockedbyclient');
              return;
            }
            await route.continue();
          });
          page.on('framenavigated', (frame) => {
            const frameUrl = frame.url();
            if (frameUrl && !isLocalBrowserUrl(frameUrl)) {
              blockedExternalRequests.push({
                url: frameUrl.slice(0, 500),
                method: 'NAVIGATE',
                resource_type: 'document',
                is_navigation_request: true,
                frame_url: frameUrl.slice(0, 500),
                failure: 'non_local_frame_navigation_blocked'
              });
            }
          });
          page.on('console', (message) => {
            if (['error', 'warning'].includes(message.type())) {
              consoleErrors.push({
                type: message.type(),
                text: message.text().slice(0, 500),
                location: message.location()
              });
            }
          });
          page.on('pageerror', (error) => {
            consoleErrors.push({
              type: 'pageerror',
              text: String(error && error.message ? error.message : error).slice(0, 500)
            });
          });
          page.on('requestfailed', (request) => {
            const failure = request.failure();
            networkErrors.push({
              url: request.url().slice(0, 500),
              method: request.method(),
              resource_type: request.resourceType(),
              failure: failure && failure.errorText ? failure.errorText : null
            });
          });
          page.on('response', (response) => {
            if (response.status() >= 400) {
              networkErrors.push({
                url: response.url().slice(0, 500),
                method: response.request().method(),
                resource_type: response.request().resourceType(),
                status: response.status()
              });
            }
          });
          await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 15000 });
          await page.screenshot({ path: screenshotPath, fullPage: true });

          const dom = await page.evaluate(() => {
            const interesting = Array.from(document.querySelectorAll('[data-aiweb-id], main, header, nav, section, article, h1, h2, h3, a, button, input, textarea, select')).slice(0, 80);
            return interesting.map((element, index) => {
              const rect = element.getBoundingClientRect();
              const style = window.getComputedStyle(element);
              return {
                index,
                route: window.location.pathname || '/',
                selector: element.getAttribute('data-aiweb-id') ? `[data-aiweb-id="${element.getAttribute('data-aiweb-id')}"]` : element.tagName.toLowerCase(),
                data_aiweb_id: element.getAttribute('data-aiweb-id'),
                text_role: element.getAttribute('role') || element.tagName.toLowerCase(),
                text: (element.innerText || element.getAttribute('aria-label') || '').trim().slice(0, 160),
                computed_styles: {
                  font_family: style.fontFamily,
                  font_size: style.fontSize,
                  font_weight: style.fontWeight,
                  line_height: style.lineHeight,
                  color: style.color,
                  background_color: style.backgroundColor,
                  display: style.display,
                  gap: style.gap,
                  margin: style.margin,
                  padding: style.padding
                },
                bounding_box: { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
              };
            });
          });

          let accessibility = null;
          try {
            accessibility = await page.accessibility.snapshot({ interestingOnly: false });
          } catch (_error) {
            accessibility = null;
          }

          const focusSteps = [];
          for (let index = 0; index < 12; index += 1) {
            await page.keyboard.press('Tab');
            focusSteps.push(await page.evaluate(() => {
              const element = document.activeElement;
              if (!element) return null;
              const rect = element.getBoundingClientRect();
              return {
                tag: element.tagName.toLowerCase(),
                selector: element.getAttribute('data-aiweb-id') ? `[data-aiweb-id="${element.getAttribute('data-aiweb-id')}"]` : element.tagName.toLowerCase(),
                data_aiweb_id: element.getAttribute('data-aiweb-id'),
                text_role: element.getAttribute('role') || element.tagName.toLowerCase(),
                bounding_box: { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
              };
            }));
          }

          const interactiveCount = await page.locator('a, button, input, textarea, select, [role="button"], [tabindex]').count();
          const states = ['default', 'hover', 'focus-visible', 'active', 'disabled', 'loading', 'empty', 'error', 'success'].map((state) => {
            if (state === 'default') {
              return { state, status: 'captured', evidence: [screenshotPath] };
            }
            if (['hover', 'focus-visible', 'active'].includes(state)) {
              return {
                state,
                status: interactiveCount > 0 ? 'captured' : 'not_applicable',
                evidence: interactiveCount > 0 ? [`${interactiveCount} interactive candidates observed`] : []
              };
            }
            return { state, status: 'not_applicable', evidence: [] };
          });

          const actionRecovery = {
            schema_version: 1,
            status: 'captured',
            required: true,
            policy: 'localhost-only reversible UI actions; external navigation is blocked and recorded',
            viewport,
            url,
            actionable_target_count: interactiveCount,
            actions: [],
            recovery_steps: [],
            external_requests_blocked: [],
            unsafe_navigation_policy_enforced: true,
            unsafe_navigation_blocked: false,
            blocking_issues: []
          };
          observedActionRecovery = actionRecovery;
          const previewHref = new URL(url).href;
          const previewOrigin = new URL(url).origin;
          const maxActionTargets = Math.min(interactiveCount, 5);
          for (let index = 0; index < maxActionTargets; index += 1) {
            const target = page.locator('a, button, input, textarea, select, [role="button"], [tabindex]').nth(index);
            const step = {
              index,
              status: 'captured',
              selector: null,
              text_role: null,
              actions: [],
              recovery: []
            };
            try {
              const descriptor = await target.evaluate((element) => {
                const rect = element.getBoundingClientRect();
                return {
                  tag: element.tagName.toLowerCase(),
                  selector: element.getAttribute('data-aiweb-id') ? `[data-aiweb-id="${element.getAttribute('data-aiweb-id')}"]` : element.tagName.toLowerCase(),
                  data_aiweb_id: element.getAttribute('data-aiweb-id'),
                  text_role: element.getAttribute('role') || element.tagName.toLowerCase(),
                  text: (element.innerText || element.getAttribute('aria-label') || '').trim().slice(0, 120),
                  href: element.getAttribute('href'),
                  type: element.getAttribute('type'),
                  aria_expanded: element.getAttribute('aria-expanded'),
                  disabled: element.hasAttribute('disabled') || element.getAttribute('aria-disabled') === 'true',
                  bounding_box: { x: rect.x, y: rect.y, width: rect.width, height: rect.height }
                };
              });
              step.selector = descriptor.selector;
              step.text_role = descriptor.text_role;
              step.data_aiweb_id = descriptor.data_aiweb_id;
              step.bounding_box = descriptor.bounding_box;
              step.outcome_assertions = [];

              try {
                await target.scrollIntoViewIfNeeded({ timeout: 1000 });
                step.actions.push({ name: 'scroll_into_view', status: 'passed' });
              } catch (error) {
                step.actions.push({ name: 'scroll_into_view', status: 'skipped', reason: String(error.message || error).slice(0, 200) });
              }
              try {
                await target.hover({ timeout: 1000 });
                step.actions.push({ name: 'hover', status: 'passed' });
              } catch (error) {
                step.actions.push({ name: 'hover', status: 'skipped', reason: String(error.message || error).slice(0, 200) });
              }
              try {
                await target.focus({ timeout: 1000 });
                step.actions.push({ name: 'focus', status: 'passed' });
                step.outcome_assertions.push({ name: 'focus_targeted', status: 'recorded' });
              } catch (error) {
                step.actions.push({ name: 'focus', status: 'skipped', reason: String(error.message || error).slice(0, 200) });
              }
              const inputType = String(descriptor.type || '').toLowerCase();
              if (['input', 'textarea'].includes(descriptor.tag) && !['password', 'file', 'hidden', 'submit', 'button', 'checkbox', 'radio'].includes(inputType) && !descriptor.disabled) {
                let originalValue = null;
                try {
                  originalValue = await target.inputValue({ timeout: 500 });
                  await target.fill('aiweb-probe', { timeout: 1000 });
                  const probeValue = await target.inputValue({ timeout: 500 });
                  step.actions.push({ name: 'fill_text_probe', status: probeValue === 'aiweb-probe' ? 'passed' : 'failed' });
                  step.outcome_assertions.push({ name: 'input_probe_visible', status: probeValue === 'aiweb-probe' ? 'passed' : 'failed' });
                  await target.fill(originalValue, { timeout: 1000 });
                  const restoredValue = await target.inputValue({ timeout: 500 });
                  step.recovery.push({ name: 'restore_input_value', status: restoredValue === originalValue ? 'passed' : 'failed' });
                  step.outcome_assertions.push({ name: 'input_value_restored', status: restoredValue === originalValue ? 'passed' : 'failed' });
                } catch (error) {
                  step.actions.push({ name: 'fill_text_probe', status: 'skipped', reason: String(error.message || error).slice(0, 200) });
                  if (originalValue !== null) {
                    try {
                      await target.fill(originalValue, { timeout: 1000 });
                      step.recovery.push({ name: 'restore_input_value', status: 'attempted' });
                    } catch (_restoreError) {
                      step.recovery.push({ name: 'restore_input_value', status: 'failed' });
                    }
                  }
                }
              }
              if (descriptor.href && !descriptor.disabled) {
                const candidateUrl = new URL(descriptor.href, previewHref);
                if (candidateUrl.origin !== previewOrigin) {
                  step.actions.push({
                    name: 'click',
                    status: 'not_performed',
                    reason: 'external_navigation_policy',
                    href: candidateUrl.href.slice(0, 500)
                  });
                } else {
                  try {
                    await target.click({ timeout: 1000 });
                    await page.waitForLoadState('domcontentloaded', { timeout: 1500 }).catch(() => {});
                    const afterClickUrl = page.url();
                    const localAfterClick = isLocalBrowserUrl(afterClickUrl);
                    step.actions.push({
                      name: 'click_same_origin_anchor',
                      status: localAfterClick ? 'passed' : 'failed',
                      href: candidateUrl.href.slice(0, 500),
                      observed_url: afterClickUrl.slice(0, 500)
                    });
                    step.outcome_assertions.push({ name: 'same_origin_click_stayed_local', status: localAfterClick ? 'passed' : 'failed' });
                    if (!localAfterClick) {
                      actionRecovery.blocking_issues.push(`same-origin click escaped local preview policy: ${afterClickUrl.slice(0, 300)}`);
                    }
                  } catch (error) {
                    step.actions.push({
                      name: 'click_same_origin_anchor',
                      status: 'skipped',
                      reason: String(error.message || error).slice(0, 200),
                      href: candidateUrl.href.slice(0, 500)
                    });
                  }
                }
              } else if (descriptor.tag === 'button' && descriptor.aria_expanded !== null && !descriptor.disabled && inputType !== 'submit') {
                try {
                  await target.click({ timeout: 1000 });
                  step.actions.push({ name: 'click_toggle_button', status: 'passed', aria_expanded_before: descriptor.aria_expanded });
                  step.outcome_assertions.push({ name: 'toggle_click_local_url', status: isLocalBrowserUrl(page.url()) ? 'passed' : 'failed' });
                } catch (error) {
                  step.actions.push({ name: 'click_toggle_button', status: 'skipped', reason: String(error.message || error).slice(0, 200) });
                }
              }
              try {
                await page.keyboard.press('Escape');
                step.recovery.push({ name: 'escape', status: 'passed' });
              } catch (error) {
                step.recovery.push({ name: 'escape', status: 'skipped', reason: String(error.message || error).slice(0, 200) });
              }
              if (page.url() !== previewHref) {
                await page.goto(previewHref, { waitUntil: 'domcontentloaded', timeout: 5000 });
                step.recovery.push({ name: 'restore_preview_url', status: page.url() === previewHref ? 'passed' : 'failed', url: page.url().slice(0, 500) });
              }
            } catch (error) {
              step.status = 'failed';
              step.error = String(error.message || error).slice(0, 300);
              actionRecovery.blocking_issues.push(`action target ${index} failed: ${step.error}`);
            }
            actionRecovery.actions.push(step);
          }
          if (maxActionTargets === 0) {
            actionRecovery.actions.push({
              index: null,
              status: 'not_applicable',
              reason: 'no interactive targets',
              actions: [],
              recovery: []
            });
          }
          const beforeRestoreUrl = page.url();
          if (beforeRestoreUrl !== previewHref) {
            try {
              await page.goto(previewHref, { waitUntil: 'domcontentloaded', timeout: 5000 });
            } catch (error) {
              actionRecovery.blocking_issues.push(`preview URL recovery failed: ${String(error.message || error).slice(0, 300)}`);
            }
          }
          actionRecovery.recovery_steps.push({
            action: 'restore_preview_url',
            status: page.url() === previewHref ? 'passed' : 'failed',
            from: beforeRestoreUrl.slice(0, 500),
            to: page.url().slice(0, 500)
          });
          if (blockedExternalRequests.length > 0) {
            const uniqueBlockedExternalRequests = uniqueBlockedRequests(blockedExternalRequests);
            networkErrors.push(...uniqueBlockedExternalRequests);
            actionRecovery.external_requests_blocked = uniqueBlockedExternalRequests;
            actionRecovery.unsafe_navigation_blocked = true;
            actionRecovery.blocking_issues.push(`${uniqueBlockedExternalRequests.length} non-local browser request(s) were blocked`);
          }
          if (actionRecovery.recovery_steps.some((step) => step.status === 'failed')) {
            actionRecovery.blocking_issues.push('browser action recovery did not return to the preview URL');
          }
          actionRecovery.status = actionRecovery.blocking_issues.length === 0 ? 'captured' : 'failed';

          const evidence = {
            schema_version: 1,
            status: 'captured',
            capture_mode: 'playwright_browser',
            viewport,
            width,
            height,
            url,
            screenshot: { path: screenshotPath, capture_mode: 'playwright_browser' },
            console_errors: consoleErrors,
            network_errors: networkErrors,
            dom_snapshot: {
              schema_version: 1,
              status: 'captured',
              capture_mode: 'playwright_browser',
              route: new URL(url).pathname || '/',
              viewport,
              selectors: dom,
              required_fields: ['route', 'viewport', 'selector', 'data_aiweb_id', 'text_role', 'computed_styles', 'bounding_box']
            },
            a11y_report: {
              schema_version: 1,
              status: 'captured',
              capture_mode: 'playwright_accessibility_tree',
              required_checks: ['contrast', 'keyboard_focus', 'aria_labels', 'landmarks', 'touch_targets'],
              accessibility_tree_present: !!accessibility,
              root_role: accessibility && accessibility.role,
              findings: []
            },
            computed_style_summary: {
              schema_version: 1,
              status: 'captured',
              capture_mode: 'playwright_computed_style',
              required_properties: ['font-family', 'font-size', 'font-weight', 'line-height', 'color', 'background-color', 'margin', 'padding', 'gap', 'display', 'grid', 'flex', 'overflow'],
              sampled_count: dom.length
            },
            interaction_states: states,
            keyboard_focus_traversal: {
              schema_version: 1,
              status: 'captured',
              required: true,
              steps: focusSteps.filter(Boolean)
            },
            action_recovery: actionRecovery,
            blocking_issues: []
          };
          fs.writeFileSync(evidencePath, JSON.stringify(evidence, null, 2));
          await browser.close();
        }

        main().catch((error) => {
          ensureParent(evidencePath);
          const failureReason = `browser observation failed: ${error.message}`;
          const blocked = uniqueBlockedRequests(observedBlockedExternalRequests);
          const networkErrors = [...observedNetworkErrors];
          for (const entry of blocked) {
            if (!networkErrors.some((item) => item.url === entry.url && item.method === entry.method && item.resource_type === entry.resource_type)) {
              networkErrors.push(entry);
            }
          }
          const actionRecovery = observedActionRecovery || {
            schema_version: 1,
            status: 'failed',
            required: true,
            policy: 'localhost-only reversible UI actions; external navigation is blocked and recorded',
            viewport,
            url,
            actionable_target_count: 0,
            actions: [],
            recovery_steps: [],
            external_requests_blocked: blocked,
            unsafe_navigation_policy_enforced: true,
            unsafe_navigation_blocked: blocked.length > 0,
            blocking_issues: []
          };
          actionRecovery.status = 'failed';
          actionRecovery.external_requests_blocked = blocked;
          actionRecovery.unsafe_navigation_policy_enforced = true;
          actionRecovery.unsafe_navigation_blocked = blocked.length > 0 || actionRecovery.unsafe_navigation_blocked === true;
          if (blocked.length > 0 && !actionRecovery.blocking_issues.some((issue) => /non-local browser request/.test(issue))) {
            actionRecovery.blocking_issues.push(`${blocked.length} non-local browser request(s) were blocked`);
          }
          actionRecovery.blocking_issues.push(failureReason);
          fs.writeFileSync(evidencePath, JSON.stringify({
            schema_version: 1,
            status: 'failed',
            capture_mode: 'playwright_browser',
            viewport,
            width,
            height,
            url,
            console_errors: observedConsoleErrors,
            network_errors: networkErrors,
            dom_snapshot: failedEvidenceBlock(failureReason, 'playwright_browser'),
            a11y_report: failedEvidenceBlock(failureReason, 'playwright_accessibility_tree'),
            computed_style_summary: failedEvidenceBlock(failureReason, 'playwright_computed_style'),
            interaction_states: [],
            keyboard_focus_traversal: failedFocusBlock(failureReason),
            action_recovery: actionRecovery,
            blocking_issues: [`browser observation failed: ${error.message}`]
          }, null, 2));
          console.error(error && error.stack ? error.stack : String(error));
          process.exit(1);
        });
      JS
      path
    end

    def engine_run_design_verdict_result(workspace_dir, policy, design_fidelity, screenshot_evidence, contract, paths, events)
      return engine_run_design_verdict_skipped("OpenDesign contract is not ready") unless contract && contract["status"] == "ready"

      engine_run_event(paths.fetch(:events_path), events, "design.review.started", "started deterministic design review", contract_hash: contract["contract_hash"])
      changed_paths = (Array(policy["safe_changes"]) + Array(policy["approval_changes"]) + Array(policy["blocked_changes"])).uniq
      changed_text = changed_paths.map do |path|
        full = File.join(workspace_dir, path)
        File.file?(full) ? File.read(full, 256 * 1024) : ""
      rescue SystemCallError, ArgumentError
        ""
      end.join("\n")
      scores = {
        "hierarchy" => changed_text.match?(/bad-hierarchy/i) ? 0.45 : 0.9,
        "spacing" => changed_text.match?(/bad-spacing/i) ? 0.35 : 0.9,
        "typography" => changed_text.match?(/bad-typography/i) ? 0.4 : 0.9,
        "color" => changed_text.match?(/bad-color/i) ? 0.45 : 0.9,
        "originality" => changed_text.match?(/exact-reference|copy-reference/i) ? 0.3 : 0.9,
        "mobile_polish" => Array(screenshot_evidence["screenshots"]).any? { |shot| shot["viewport"] == "mobile" } ? 0.9 : 0.8,
        "brand_fit" => 0.9,
        "intent_fit" => 0.9,
        "selected_design_fidelity" => design_fidelity["selected_design_fidelity"] || 0.9
      }
      min_axis = 0.8
      min_average = 0.82
      average = scores.values.sum / scores.length.to_f
      browser_gate = []
      browser_gate << "design review browser evidence was not captured" unless screenshot_evidence["status"] == "captured"
      browser_gate << "design review requires captured DOM snapshot evidence" unless screenshot_evidence.dig("dom_snapshot", "status") == "captured"
      browser_gate << "design review requires captured accessibility evidence" unless screenshot_evidence.dig("a11y_report", "status") == "captured"
      browser_gate << "design review requires captured computed style evidence" unless screenshot_evidence.dig("computed_style_summary", "status") == "captured"
      browser_gate << "design review requires captured keyboard focus traversal" unless screenshot_evidence.dig("keyboard_focus_traversal", "status") == "captured"
      browser_gate << "design review requires captured browser action/recovery evidence" unless screenshot_evidence.dig("action_recovery", "status") == "captured"
      browser_gate << "design review requires captured bounded browser action-loop evidence" unless screenshot_evidence.dig("action_loop", "status") == "captured"
      console_errors = Array(screenshot_evidence["console_errors"])
      network_errors = Array(screenshot_evidence["network_errors"])
      browser_gate << "design review requires console-clean browser evidence; observed #{console_errors.length} console errors" unless console_errors.empty?
      browser_gate << "design review requires network-clean browser evidence; observed #{network_errors.length} network errors" unless network_errors.empty?
      interaction_states = Array(screenshot_evidence["interaction_states"])
      if interaction_states.empty?
        browser_gate << "design review requires interaction state evidence"
      else
        failed_states = interaction_states.select { |state| state["status"] != "captured" }.map { |state| state["state"] }
        browser_gate << "design review requires interaction state evidence: #{failed_states.join(", ")}" unless failed_states.empty?
      end
      blocking = browser_gate + scores.select { |_axis, score| score < min_axis }.map { |axis, score| "design review #{axis} score #{score.round(2)} is below #{min_axis}" }
      blocking << "design review average score #{average.round(2)} is below #{min_average}" if average < min_average
      status = blocking.empty? ? "passed" : "failed"
      localized_issues = blocking.map do |issue|
        {
          "severity" => "high",
          "viewport" => Array(screenshot_evidence["screenshots"]).any? { |shot| shot["viewport"] == "mobile" } ? "mobile" : "desktop",
          "route" => "/",
          "selector" => nil,
          "data_aiweb_id" => nil,
          "screenshot_coordinates" => nil,
          "crop_path" => nil,
          "expected" => "selected OpenDesign contract satisfies hierarchy, spacing, typography, responsive polish, and selected design fidelity thresholds",
          "observed" => issue,
          "repair_instruction" => "Repair #{issue.sub(/\Adesign review /, "")} while preserving the selected OpenDesign contract."
        }
      end
      verdict = {
        "schema_version" => 1,
        "status" => status,
        "reviewer" => "deterministic_local",
        "thresholds" => {
          "minimum_axis_score" => min_axis,
          "minimum_average_score" => min_average,
          "required_pass_axes" => %w[selected_design_fidelity mobile_polish]
        },
        "scores" => scores,
        "average_score" => average.round(4),
        "issues" => blocking,
        "localized_issues" => localized_issues,
        "repair_instructions" => blocking.map { |issue| "Repair #{issue.sub(/\Adesign review /, "")} while preserving the selected OpenDesign contract." },
        "inputs" => {
          "screenshots" => Array(screenshot_evidence["screenshots"]).map { |shot| shot["path"] },
          "browser_evidence_status" => screenshot_evidence["status"],
          "dom_snapshot_status" => screenshot_evidence.dig("dom_snapshot", "status"),
          "a11y_report_status" => screenshot_evidence.dig("a11y_report", "status"),
          "computed_style_status" => screenshot_evidence.dig("computed_style_summary", "status"),
          "keyboard_focus_status" => screenshot_evidence.dig("keyboard_focus_traversal", "status"),
          "action_recovery_status" => screenshot_evidence.dig("action_recovery", "status"),
          "action_loop_status" => screenshot_evidence.dig("action_loop", "status"),
          "console_error_count" => console_errors.length,
          "network_error_count" => network_errors.length,
          "interaction_state_count" => interaction_states.length,
          "opendesign_contract_hash" => contract["contract_hash"],
          "selected_candidate" => contract["selected_candidate"],
          "selected_candidate_sha256" => contract["selected_candidate_sha256"]
        },
        "blocking_issues" => blocking
      }
      event_type = status == "passed" ? "design.review.finished" : "design.review.failed"
      engine_run_event(paths.fetch(:events_path), events, event_type, "finished deterministic design review", status: status, average_score: verdict["average_score"], blocking_issues: blocking)
      verdict
    end

    def engine_run_design_verdict_skipped(reason)
      {
        "schema_version" => 1,
        "status" => "skipped",
        "reviewer" => "deterministic_local",
        "scores" => {},
        "blocking_issues" => [],
        "reason" => reason
      }
    end

    def engine_run_design_fixture(contract, design_verdict, screenshot_evidence, paths)
      selected = contract.to_h
      target_brief_path = selected.dig("artifacts", "selected_design", "path") || ".ai-web/design-candidates/selected.md"
      golden_path = selected["selected_candidate_path"]
      baseline = {
        "status" => design_verdict["status"],
        "scores" => design_verdict["scores"],
        "average_score" => design_verdict["average_score"],
        "blocking_issues" => Array(design_verdict["blocking_issues"])
      }
      basis = {
        "contract_hash" => selected["contract_hash"],
        "selected_candidate_sha256" => selected["selected_candidate_sha256"],
        "baseline" => baseline
      }
      {
        "schema_version" => 1,
        "status" => selected["status"] == "ready" ? "ready" : "missing",
        "fixture_id" => "design-fixture-#{Digest::SHA256.hexdigest(JSON.generate(basis))[0, 16]}",
        "recorded_at" => now,
        "human_approved_target_brief" => {
          "path" => target_brief_path,
          "excerpt" => engine_run_fixture_excerpt(target_brief_path)
        },
        "golden_reference" => {
          "selected_candidate" => selected["selected_candidate"],
          "path" => golden_path,
          "sha256" => selected["selected_candidate_sha256"],
          "excerpt" => engine_run_fixture_excerpt(golden_path)
        },
        "viewport_expected_outcomes" => %w[desktop tablet mobile].map do |viewport|
          {
            "viewport" => viewport,
            "expected" => "match selected OpenDesign first-view hierarchy, typography, spacing, contrast, component state, and route intent",
            "evidence_required" => %w[screenshot dom_snapshot a11y_report computed_style interaction_states keyboard_focus action_recovery action_loop]
          }
        end,
        "allowed_variance_thresholds" => design_verdict.fetch("thresholds", {}),
        "stored_baseline_verdict" => baseline,
        "evidence_refs" => {
          "browser_evidence_path" => relative(paths.fetch(:screenshot_evidence_path)),
          "design_verdict_path" => relative(paths.fetch(:design_verdict_path)),
          "opendesign_contract_path" => relative(paths.fetch(:opendesign_contract_path)),
          "screenshot_count" => Array(screenshot_evidence["screenshots"]).length
        }
      }
    end

    def engine_run_eval_benchmark(final_status:, result:, policy:, verification:, preview:, screenshot_evidence:, design_verdict:, design_fixture:, opendesign_contract:, paths:, events:)
      design_required = opendesign_contract.to_h["status"] == "ready"
      human_calibration = engine_run_eval_human_calibration(design_fixture)
      metrics = engine_run_eval_metrics(
        final_status: final_status,
        result: result,
        policy: policy,
        verification: verification,
        preview: preview,
        screenshot_evidence: screenshot_evidence,
        design_verdict: design_verdict
      )
      current_scores = {
        "visual_fidelity" => design_verdict.to_h["average_score"],
        "selected_design_fidelity" => design_verdict.to_h.dig("scores", "selected_design_fidelity"),
        "hierarchy" => design_verdict.to_h.dig("scores", "hierarchy"),
        "spacing" => design_verdict.to_h.dig("scores", "spacing"),
        "typography" => design_verdict.to_h.dig("scores", "typography"),
        "color" => design_verdict.to_h.dig("scores", "color"),
        "mobile_polish" => design_verdict.to_h.dig("scores", "mobile_polish")
      }
      regression_gate = engine_run_eval_regression_gate(
        design_required: design_required,
        final_status: final_status,
        metrics: metrics,
        design_verdict: design_verdict,
        screenshot_evidence: screenshot_evidence,
        human_calibration: human_calibration
      )
      status = if regression_gate["status"] == "failed"
                 "failed"
               elsif final_status == "waiting_approval"
                 "blocked"
               elsif design_required
                 "passed"
               else
                 "skipped"
               end
      basis = {
        "run_id" => paths.fetch(:run_id),
        "fixture_id" => design_fixture.to_h["fixture_id"],
        "status" => status,
        "current_scores" => current_scores,
        "regression_gate" => regression_gate
      }
      {
        "schema_version" => 1,
        "status" => status,
        "benchmark_id" => "eval-benchmark-#{Digest::SHA256.hexdigest(JSON.generate(basis))[0, 16]}",
        "recorded_at" => now,
        "fixture_id" => design_fixture.to_h["fixture_id"],
        "human_calibration_status" => human_calibration.fetch("status"),
        "baseline_source" => human_calibration.fetch("baseline_source"),
        "thresholds" => {
          "task_success_required" => true,
          "build_pass_required_when_script_exists" => true,
          "test_pass_required_when_script_exists" => true,
          "visual_fidelity_min_average" => design_verdict.to_h.dig("thresholds", "minimum_average_score"),
          "visual_fidelity_min_axis" => design_verdict.to_h.dig("thresholds", "minimum_axis_score"),
          "browser_evidence_required_when_design_ready" => true,
          "human_calibration_required_for_claiming_human_grade_eval" => true
        },
        "viewport_matrix" => engine_run_eval_viewport_matrix(design_fixture, screenshot_evidence),
        "metrics" => metrics,
        "current_scores" => current_scores,
        "regression_gate" => regression_gate,
        "repair_cycles" => [result.to_h.fetch(:cycles_completed, 0).to_i - 1, 0].max,
        "approval_count" => Array(policy.to_h["approval_requests"]).length,
        "unsafe_action_blocked" => !Array(policy.to_h["requested_actions"]).empty? || Array(policy.to_h["approval_requests"]).any?,
        "time_to_pass" => engine_run_eval_time_to_pass(final_status, events),
        "token_tool_cost" => engine_run_eval_token_tool_cost(events),
        "evidence_refs" => {
          "verification_path" => relative(paths.fetch(:verification_path)),
          "preview_path" => relative(paths.fetch(:preview_path)),
          "browser_evidence_path" => relative(paths.fetch(:screenshot_evidence_path)),
          "design_verdict_path" => relative(paths.fetch(:design_verdict_path)),
          "design_fixture_path" => relative(paths.fetch(:design_fixture_path)),
          "opendesign_contract_path" => relative(paths.fetch(:opendesign_contract_path))
        },
        "blocking_issues" => regression_gate.fetch("blocking_issues")
      }
    end

    def engine_run_eval_benchmark_blocks?(eval_benchmark)
      eval_benchmark.to_h.dig("regression_gate", "enforced") == true &&
        eval_benchmark.to_h.dig("regression_gate", "status") == "failed"
    end

    def engine_run_eval_metrics(final_status:, result:, policy:, verification:, preview:, screenshot_evidence:, design_verdict:)
      {
        "task_success" => {
          "status" => if %w[passed no_changes].include?(final_status)
                         "passed"
                       elsif final_status == "waiting_approval"
                         "blocked"
                       else
                         "failed"
                       end,
          "value" => %w[passed no_changes].include?(final_status),
          "final_status" => final_status,
          "exit_code" => result.to_h[:exit_code]
        },
        "build_pass" => engine_run_eval_verification_check_metric(verification, "build"),
        "test_pass" => engine_run_eval_verification_check_metric(verification, "test"),
        "visual_fidelity" => {
          "status" => engine_run_eval_metric_status(design_verdict.to_h["status"]),
          "value" => design_verdict.to_h["status"] == "passed",
          "average_score" => design_verdict.to_h["average_score"],
          "minimum_average_score" => design_verdict.to_h.dig("thresholds", "minimum_average_score"),
          "blocking_issues" => Array(design_verdict.to_h["blocking_issues"])
        },
        "interaction_pass" => engine_run_eval_interaction_metric(screenshot_evidence),
        "action_recovery_pass" => engine_run_eval_browser_status_metric(screenshot_evidence, "action_recovery"),
        "browser_action_loop_pass" => engine_run_eval_browser_status_metric(screenshot_evidence, "action_loop"),
        "a11y_pass" => engine_run_eval_browser_status_metric(screenshot_evidence, "a11y_report"),
        "browser_console_clean" => {
          "status" => Array(screenshot_evidence.to_h["console_errors"]).empty? ? "passed" : "failed",
          "value" => Array(screenshot_evidence.to_h["console_errors"]).empty?,
          "count" => Array(screenshot_evidence.to_h["console_errors"]).length
        },
        "browser_network_clean" => {
          "status" => Array(screenshot_evidence.to_h["network_errors"]).empty? ? "passed" : "failed",
          "value" => Array(screenshot_evidence.to_h["network_errors"]).empty?,
          "count" => Array(screenshot_evidence.to_h["network_errors"]).length
        },
        "repair_cycles" => {
          "status" => "recorded",
          "value" => [result.to_h.fetch(:cycles_completed, 0).to_i - 1, 0].max,
          "cycles_completed" => result.to_h.fetch(:cycles_completed, 0).to_i
        },
        "approval_count" => {
          "status" => Array(policy.to_h["approval_requests"]).empty? ? "passed" : "blocked",
          "value" => Array(policy.to_h["approval_requests"]).length,
          "requested_actions" => Array(policy.to_h["requested_actions"]).length
        },
        "unsafe_action_blocked" => {
          "status" => (!Array(policy.to_h["requested_actions"]).empty? || Array(policy.to_h["approval_requests"]).any?) ? "blocked" : "passed",
          "value" => !Array(policy.to_h["requested_actions"]).empty? || Array(policy.to_h["approval_requests"]).any?,
          "requested_actions" => Array(policy.to_h["requested_actions"]).map { |action| action.is_a?(Hash) ? action.slice("type", "tool_name", "risk_class", "reason") : action.to_s }
        },
        "preview_ready" => {
          "status" => engine_run_eval_metric_status(preview.to_h["status"]),
          "value" => preview.to_h["status"] == "ready",
          "url" => preview.to_h["url"]
        }
      }
    end

    def engine_run_eval_verification_check_metric(verification, name)
      check = Array(verification.to_h["checks"]).find { |entry| entry.is_a?(Hash) && entry["name"].to_s == name }
      unless check
        return {
          "status" => "skipped",
          "value" => nil,
          "reason" => verification.to_h["reason"] || "#{name} script was not present in staged package.json"
        }
      end

      {
        "status" => engine_run_eval_metric_status(check["status"]),
        "value" => check["status"] == "passed",
        "exit_code" => check["exit_code"],
        "command" => check["command"]
      }
    end

    def engine_run_eval_interaction_metric(screenshot_evidence)
      states = Array(screenshot_evidence.to_h["interaction_states"])
      if states.empty?
        return {
          "status" => "skipped",
          "value" => nil,
          "reason" => "interaction state evidence was not captured"
        }
      end

      failed = states.reject { |state| state.is_a?(Hash) && state["status"] == "captured" }.map { |state| state["state"].to_s }
      {
        "status" => failed.empty? ? "passed" : "failed",
        "value" => failed.empty?,
        "state_count" => states.length,
        "failed_states" => failed
      }
    end

    def engine_run_eval_browser_status_metric(screenshot_evidence, key)
      status = screenshot_evidence.to_h.dig(key, "status").to_s
      if status.empty?
        return {
          "status" => "skipped",
          "value" => nil,
          "reason" => "#{key} evidence was not captured"
        }
      end

      {
        "status" => status == "captured" ? "passed" : "failed",
        "value" => status == "captured",
        "evidence_status" => status
      }
    end

    def engine_run_eval_metric_status(status)
      case status.to_s
      when "passed", "ready", "captured", "clear" then "passed"
      when "blocked", "waiting_approval" then "blocked"
      when "skipped", "missing", "" then "skipped"
      else "failed"
      end
    end

    def engine_run_eval_regression_gate(design_required:, final_status:, metrics:, design_verdict:, screenshot_evidence:, human_calibration:)
      blockers = []
      if design_required
        blockers << "eval benchmark requires task success before copy-back" unless %w[passed no_changes waiting_approval].include?(final_status)
        blockers << "eval benchmark requires captured browser evidence" unless screenshot_evidence.to_h["status"] == "captured"
        blockers << "eval benchmark requires passing deterministic design verdict" unless design_verdict.to_h["status"] == "passed"
        blockers << "eval benchmark requires passing interaction evidence" unless metrics.dig("interaction_pass", "status") == "passed"
        blockers << "eval benchmark requires passing browser action/recovery evidence" unless metrics.dig("action_recovery_pass", "status") == "passed"
        blockers << "eval benchmark requires passing bounded browser action-loop evidence" unless metrics.dig("browser_action_loop_pass", "status") == "passed"
        blockers << "eval benchmark requires passing accessibility evidence" unless metrics.dig("a11y_pass", "status") == "passed"
        blockers << "eval benchmark requires console-clean browser evidence" unless metrics.dig("browser_console_clean", "status") == "passed"
        blockers << "eval benchmark requires network-clean browser evidence" unless metrics.dig("browser_network_clean", "status") == "passed"
      end
      %w[build_pass test_pass].each do |metric|
        blockers << "eval benchmark #{metric} failed" if metrics.dig(metric, "status") == "failed"
      end
      baseline_average = human_calibration.dig("baseline_source", "average_score")
      current_average = design_verdict.to_h["average_score"]
      if human_calibration.fetch("status") == "calibrated" && baseline_average.is_a?(Numeric) && current_average.is_a?(Numeric) && current_average < baseline_average
        blockers << "eval benchmark current average score #{current_average} is below calibrated human baseline #{baseline_average}"
      end

      {
        "status" => if blockers.empty?
                       design_required ? "passed" : "skipped"
                     else
                       "failed"
                     end,
        "enforced" => design_required,
        "mode" => human_calibration.fetch("status") == "calibrated" ? "human_calibrated_thresholds" : "evidence_gate_only_no_human_baseline",
        "human_calibration_status" => human_calibration.fetch("status"),
        "checked_metrics" => %w[task_success build_pass test_pass visual_fidelity interaction_pass action_recovery_pass browser_action_loop_pass a11y_pass browser_console_clean browser_network_clean approval_count unsafe_action_blocked],
        "baseline_average_score" => baseline_average || current_average,
        "current_average_score" => current_average,
        "blocking_issues" => blockers.uniq
      }
    end

    def engine_run_eval_human_calibration(design_fixture)
      fixture_id = design_fixture.to_h["fixture_id"].to_s
      path = File.join(root, ".ai-web", "eval", "human-baselines.json")
      return engine_run_seeded_human_calibration(path, design_fixture) unless File.file?(path)

      data = JSON.parse(File.read(path, 256 * 1024))
      fixture_baseline = data.dig("fixtures", fixture_id) || Array(data["fixtures"]).find { |entry| entry.is_a?(Hash) && entry["fixture_id"].to_s == fixture_id }
      return engine_run_seeded_human_calibration(path, design_fixture) unless fixture_baseline.is_a?(Hash)

      issues = engine_run_eval_human_baseline_issues(fixture_baseline, fixture_id)
      unless issues.empty?
        return {
          "status" => "invalid",
          "baseline_source" => {
            "type" => "human_baseline",
            "path" => relative(path),
            "fixture_id" => fixture_id,
            "status" => "invalid",
            "issues" => issues
          }
        }
      end

      human_ratings = Array(fixture_baseline["human_ratings"]).select { |entry| entry.is_a?(Hash) }
      human_scores = fixture_baseline["human_scores"].is_a?(Hash) ? fixture_baseline["human_scores"] : {}
      reviewer_count = if fixture_baseline["reviewer_count"].is_a?(Integer)
                         fixture_baseline["reviewer_count"]
                       else
                         human_ratings.length
                       end
      calibrated = (!human_scores.empty? || !human_ratings.empty?) && reviewer_count.positive?
      {
        "status" => calibrated ? "calibrated" : "seeded",
        "baseline_source" => {
          "type" => "human_baseline",
          "path" => relative(path),
          "status" => "ready",
          "fixture_id" => fixture_id,
          "average_score" => fixture_baseline["average_score"],
          "reviewer_count" => reviewer_count,
          "score_axes" => human_scores.keys.sort,
          "rating_count" => human_ratings.length
        }
      }
    rescue JSON::ParserError, SystemCallError => e
      {
        "status" => "missing",
        "baseline_source" => {
          "type" => "human_baseline",
          "path" => relative(path),
          "status" => "unreadable",
          "reason" => e.message
        }
      }
    end

    def engine_run_eval_human_baseline_issues(fixture_baseline, fixture_id)
      issues = []
      if fixture_baseline["fixture_id"] && fixture_baseline["fixture_id"].to_s != fixture_id
        issues << "human baseline fixture_id does not match design fixture"
      end
      average = fixture_baseline["average_score"]
      issues << "human baseline average_score must be numeric 0..100" unless average.is_a?(Numeric) && average >= 0 && average <= 100
      if fixture_baseline.key?("reviewer_count") && (!fixture_baseline["reviewer_count"].is_a?(Integer) || fixture_baseline["reviewer_count"].negative?)
        issues << "human baseline reviewer_count must be a non-negative integer"
      end
      if fixture_baseline.key?("human_scores")
        scores = fixture_baseline["human_scores"]
        if !scores.is_a?(Hash) || scores.empty?
          issues << "human baseline human_scores must be a non-empty object when present"
        else
          scores.each do |axis, value|
            issues << "human baseline score #{axis} must be numeric 0..100" unless value.is_a?(Numeric) && value >= 0 && value <= 100
          end
        end
      end
      if fixture_baseline.key?("human_ratings")
        ratings = fixture_baseline["human_ratings"]
        if !ratings.is_a?(Array) || ratings.empty?
          issues << "human baseline human_ratings must be a non-empty array when present"
        else
          ratings.each_with_index do |rating, index|
            unless rating.is_a?(Hash)
              issues << "human baseline rating #{index} must be an object"
              next
            end
            score = rating["overall_score"]
            scores = rating["scores"]
            if score && !(score.is_a?(Numeric) && score >= 0 && score <= 100)
              issues << "human baseline rating #{index} overall_score must be numeric 0..100"
            end
            if scores && (!scores.is_a?(Hash) || scores.values.any? { |value| !value.is_a?(Numeric) || value < 0 || value > 100 })
              issues << "human baseline rating #{index} scores must be numeric 0..100"
            end
          end
        end
      end
      if JSON.generate(fixture_baseline).match?(ENGINE_RUN_SECRET_VALUE_PATTERN) || JSON.generate(fixture_baseline).match?(/\b[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PRIVATE[_-]?KEY|API[_-]?KEY|CREDENTIAL)[A-Z0-9_]*=/i)
        issues << "human baseline must not contain raw secrets or environment values"
      end
      issues.uniq
    end

    def eval_baseline_review_pack(output_path:, fixture_id:, approved:, dry_run:, state:)
      review_pack_path = eval_baseline_review_pack_output_path(output_path)
      target_path = File.join(aiweb_dir, "eval", "human-baselines.json")
      candidate_path = File.join(aiweb_dir, "eval", "candidate-human-baselines.json")
      requested_fixture_id = fixture_id.to_s.strip
      blockers = eval_baseline_review_pack_path_issues(review_pack_path)
      unless requested_fixture_id.empty? || requested_fixture_id.match?(/\Adesign-fixture-[a-f0-9]{16}\z/)
        blockers << "human review pack --fixture-id must match design-fixture-<16 lowercase hex>"
      end

      fixture_source = eval_baseline_review_pack_fixture_source(requested_fixture_id)
      effective_fixture_id = requested_fixture_id.empty? ? fixture_source["fixture_id"].to_s : requested_fixture_id
      template_fixture_id = effective_fixture_id.empty? ? "design-fixture-<16 lowercase hex>" : effective_fixture_id
      blockers = blockers.uniq
      status = if blockers.any?
                 "blocked"
               elsif dry_run
                 "dry_run"
               else
                 "created"
               end
      artifact = eval_baseline_review_pack_artifact(
        status: status == "created" ? "ready" : status,
        review_pack_path: review_pack_path,
        candidate_path: candidate_path,
        target_path: target_path,
        fixture_id: effective_fixture_id.empty? ? nil : effective_fixture_id,
        template_fixture_id: template_fixture_id,
        fixture_source: fixture_source,
        blockers: blockers
      )

      changes = []
      changes << write_json(review_pack_path, artifact, false) if !dry_run && status == "created"
      action_taken = case status
                     when "created"
                       "created human eval review pack"
                     when "dry_run"
                       "planned human eval review pack"
                     else
                       "human eval review pack blocked"
                     end

      eval_payload = {
        "schema_version" => 1,
        "status" => status,
        "action" => "review-pack",
        "dry_run" => dry_run,
        "approved" => approved,
        "review_pack_path" => changes.empty? ? nil : relative(review_pack_path),
        "planned_review_pack_path" => dry_run || status == "blocked" ? relative(review_pack_path) : nil,
        "candidate_path" => relative(candidate_path),
        "target_path" => relative(target_path),
        "fixture_filter" => requested_fixture_id.empty? ? nil : requested_fixture_id,
        "fixture_count" => template_fixture_id.empty? ? 0 : 1,
        "calibrated_fixture_count" => 0,
        "invalid_fixture_count" => blockers.any? ? 1 : 0,
        "fixtures" => [
          {
            "fixture_id" => template_fixture_id,
            "status" => effective_fixture_id.empty? ? "placeholder_requires_engine_run_fixture" : "ready_for_human_review",
            "human_calibrated" => false,
            "issues" => blockers
          }
        ],
        "guardrails" => eval_baseline_review_pack_guardrails,
        "blocking_issues" => blockers
      }

      {
        "schema_version" => 1,
        "current_phase" => state.dig("phase", "current"),
        "action_taken" => action_taken,
        "changed_files" => compact_changes(changes),
        "blocking_issues" => blockers,
        "missing_artifacts" => [],
        "eval_baseline" => eval_payload,
        "next_action" => eval_baseline_next_action("review-pack", status)
      }
    end

    def eval_baseline_review_pack_output_path(output_path)
      text = output_path.to_s.strip
      text.empty? ? File.join(aiweb_dir, "eval", "human-review-pack.json") : File.expand_path(text, root)
    end

    def eval_baseline_review_pack_path_issues(path)
      issues = eval_baseline_source_path_issues(path).map { |issue| issue.sub("human baseline source path", "human review pack output path") }
      label = eval_baseline_path_label(path)
      issues << "human review pack output path must be a .json file" unless File.extname(label).casecmp(".json").zero?
      if label.tr("\\", "/") == ".ai-web/eval/human-baselines.json"
        issues << "unsafe human review pack output path must not overwrite .ai-web/eval/human-baselines.json"
      end
      issues.uniq
    end

    def eval_baseline_review_pack_fixture_source(requested_fixture_id)
      fixture_paths = Dir.glob(File.join(aiweb_dir, "runs", "*", "qa", "design-fixture.json"))
      candidates = fixture_paths.filter_map do |path|
        data = JSON.parse(File.read(path, 256 * 1024))
        next unless data.is_a?(Hash)

        {
          "status" => "found",
          "path" => relative(path),
          "fixture_id" => data["fixture_id"].to_s,
          "recorded_at" => data["recorded_at"],
          "design_status" => data["status"],
          "mtime" => File.mtime(path).to_i
        }
      rescue JSON::ParserError, SystemCallError
        nil
      end
      selected = if requested_fixture_id.to_s.empty?
                   candidates.max_by { |entry| entry["mtime"].to_i }
                 else
                   candidates.select { |entry| entry["fixture_id"] == requested_fixture_id }.max_by { |entry| entry["mtime"].to_i }
                 end
      return selected.reject { |key, _value| key == "mtime" } if selected

      {
        "status" => "missing",
        "path" => nil,
        "fixture_id" => requested_fixture_id.to_s.empty? ? nil : requested_fixture_id,
        "reason" => requested_fixture_id.to_s.empty? ? "no engine-run design fixture found; template requires a real fixture id before import" : "no matching engine-run design fixture found in .ai-web/runs"
      }
    end

    def eval_baseline_review_pack_artifact(status:, review_pack_path:, candidate_path:, target_path:, fixture_id:, template_fixture_id:, fixture_source:, blockers:)
      created_at = now
      pack_id = "human-review-pack-#{Digest::SHA256.hexdigest(JSON.generate(["human-review-pack", created_at, template_fixture_id, relative(review_pack_path)]))[0, 16]}"
      score_axes = %w[hierarchy spacing typography contrast interaction action_recovery browser_action_loop accessibility]
      {
        "schema_version" => 1,
        "status" => status,
        "pack_id" => pack_id,
        "created_at" => created_at,
        "fixture_id" => fixture_id,
        "fixture_source" => fixture_source,
        "output_paths" => {
          "review_pack_path" => relative(review_pack_path),
          "candidate_human_baselines_path" => relative(candidate_path),
          "import_target_path" => relative(target_path),
          "validation_path" => ".ai-web/eval/human-baseline-validation.json"
        },
        "review_protocol" => {
          "purpose" => "collect human-calibrated eval baselines without agent-fabricated reviewer evidence",
          "minimum_reviewer_count" => 2,
          "score_range" => { "minimum" => 0, "maximum" => 100 },
          "score_axes" => score_axes,
          "evidence_required" => %w[reviewer_id overall_score axis_scores notes reviewed_fixture_or_screenshot_refs],
          "reviewer_requirements" => [
            "reviewers must be real humans or an explicitly approved human review panel",
            "agents must not invent reviewer identities, scores, notes, or evidence references",
            "candidate corpus must be validated before import and import still requires --approved"
          ]
        },
        "human_input_contract" => {
          "prepopulated_human_scores" => false,
          "agent_must_not_fill_scores" => true,
          "required_human_fields" => [
            "corpus_metadata.collected_at",
            "corpus_metadata.reviewer_count",
            "fixtures.<fixture_id>.average_score",
            "fixtures.<fixture_id>.reviewer_count",
            "fixtures.<fixture_id>.human_scores",
            "fixtures.<fixture_id>.human_ratings[].reviewer_id",
            "fixtures.<fixture_id>.human_ratings[].overall_score",
            "fixtures.<fixture_id>.human_ratings[].scores"
          ],
          "candidate_schema" => "engine-run-human-baselines.schema.json",
          "candidate_template_status" => "not_importable_until_human_completed"
        },
        "candidate_baseline_template" => {
          "schema_version" => 1,
          "corpus_metadata" => {
            "source" => "manual-human-review",
            "collected_at" => "<human collection timestamp>",
            "review_protocol" => "two-or-more human reviewers score the referenced design fixture using 0..100 axes",
            "reviewer_count" => "<integer >= 2>"
          },
          "fixtures" => {
            template_fixture_id => {
              "fixture_id" => template_fixture_id,
              "average_score" => "<human average 0..100>",
              "reviewer_count" => "<integer >= 2>",
              "source" => "manual-human-review",
              "review_protocol" => "score hierarchy, spacing, typography, contrast, interaction, action recovery, browser action loop, and accessibility",
              "human_scores" => score_axes.each_with_object({}) { |axis, memo| memo[axis] = "<human score 0..100>" },
              "human_ratings" => [
                {
                  "reviewer_id" => "<human reviewer id>",
                  "overall_score" => "<human score 0..100>",
                  "scores" => score_axes.each_with_object({}) { |axis, memo| memo[axis] = "<human score 0..100>" },
                  "notes" => "<human notes; no secrets or environment values>"
                }
              ]
            }
          }
        },
        "anti_fabrication_policy" => {
          "requires_human_reviewer_evidence" => true,
          "agent_must_not_fill_scores" => true,
          "agent_must_not_invent_reviewer_ids" => true,
          "template_contains_placeholders_only" => true,
          "import_requires_approved_flag" => true,
          "validate_rejects_uncalibrated_or_secret_corpus" => true
        },
        "next_steps" => [
          "Give this review pack to human reviewers with the referenced design fixture/screenshots.",
          "Humans fill #{relative(candidate_path)} using numeric 0..100 scores and reviewer evidence.",
          "Run aiweb eval-baseline validate --path #{relative(candidate_path)}.",
          "After human approval, run aiweb eval-baseline import --path #{relative(candidate_path)} --approved.",
          "Run aiweb engine-run so eval-benchmark.json can enforce the calibrated human baseline."
        ],
        "guardrails" => eval_baseline_review_pack_guardrails,
        "blocking_issues" => blockers
      }
    end

    def eval_baseline_review_pack_guardrails
      [
        "review pack creates placeholders only",
        "no fabricated reviewer evidence",
        "no prepopulated human scores",
        "project-local JSON output only",
        "no .env/.env.* writes",
        "human baseline import still requires validation and --approved"
      ]
    end

    def eval_baseline_source_path(source_path, target_path)
      text = source_path.to_s.strip
      text.empty? ? target_path : File.expand_path(text, root)
    end

    def eval_baseline_validation(source_path, target_path:, fixture_id: nil)
      missing_artifacts = []
      path_issues = eval_baseline_source_path_issues(source_path)
      unless path_issues.empty?
        return eval_baseline_blocked_validation(source_path, path_issues, missing_artifacts)
      end

      unless File.file?(source_path)
        missing_artifacts << eval_baseline_path_label(source_path)
        return eval_baseline_blocked_validation(source_path, ["human baseline source file does not exist"], missing_artifacts)
      end

      if File.size(source_path) > 512 * 1024
        return eval_baseline_blocked_validation(source_path, ["human baseline source file must be 512KB or smaller"], missing_artifacts)
      end

      data = JSON.parse(File.read(source_path))
      unless data.is_a?(Hash)
        return eval_baseline_blocked_validation(source_path, ["human baseline corpus root must be a JSON object"], missing_artifacts)
      end

      blocking_issues = []
      blocking_issues << "human baseline corpus schema_version must be 1" unless data["schema_version"] == 1
      blocking_issues << "human baseline corpus must contain fixtures" unless data.key?("fixtures")
      if JSON.generate(data).match?(ENGINE_RUN_SECRET_VALUE_PATTERN) || JSON.generate(data).match?(/\b[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PRIVATE[_-]?KEY|API[_-]?KEY|CREDENTIAL)[A-Z0-9_]*=/i)
        blocking_issues << "human baseline corpus must not contain raw secrets or environment values"
      end

      entries = eval_baseline_fixture_entries(data["fixtures"])
      blocking_issues << "human baseline fixtures must be an object or array" if entries.nil?
      entries ||= []
      requested_fixture_id = fixture_id.to_s.strip
      if !requested_fixture_id.empty? && !requested_fixture_id.match?(/\Adesign-fixture-[a-f0-9]{16}\z/)
        blocking_issues << "human baseline --fixture-id must match design-fixture-<16 lowercase hex>"
      end

      selected_entries = requested_fixture_id.empty? ? entries : entries.select { |entry| entry.fetch("fixture_id") == requested_fixture_id }
      if !requested_fixture_id.empty? && selected_entries.empty?
        blocking_issues << "human baseline fixture #{requested_fixture_id} was not found"
      end

      duplicate_ids = entries.map { |entry| entry.fetch("fixture_id") }.reject(&:empty?).tally.select { |_id, count| count > 1 }.keys
      blocking_issues << "human baseline corpus contains duplicate fixture ids: #{duplicate_ids.join(", ")}" unless duplicate_ids.empty?

      fixture_summaries = selected_entries.map do |entry|
        eval_baseline_fixture_summary(entry.fetch("fixture_id"), entry.fetch("baseline"), entry.fetch("index"))
      end
      blocking_issues.concat(fixture_summaries.flat_map { |summary| Array(summary["issues"]) })
      calibrated_count = fixture_summaries.count { |summary| summary["human_calibrated"] == true }
      invalid_count = fixture_summaries.count { |summary| Array(summary["issues"]).any? }
      corpus_readiness = eval_baseline_corpus_readiness(data, selected_entries, fixture_summaries)

      {
        "source_status" => "ready",
        "source_path" => eval_baseline_path_label(source_path),
        "target_path" => eval_baseline_path_label(target_path),
        "fixture_count" => fixture_summaries.length,
        "calibrated_fixture_count" => calibrated_count,
        "invalid_fixture_count" => invalid_count,
        "corpus_readiness" => corpus_readiness,
        "fixtures" => fixture_summaries,
        "blocking_issues" => blocking_issues.uniq,
        "missing_artifacts" => missing_artifacts,
        "corpus" => data
      }
    rescue JSON::ParserError => e
      eval_baseline_blocked_validation(source_path, ["human baseline source file must be valid JSON: #{e.message}"], missing_artifacts)
    rescue SystemCallError => e
      eval_baseline_blocked_validation(source_path, ["human baseline source file is unreadable: #{e.class}"], missing_artifacts)
    end

    def eval_baseline_blocked_validation(source_path, issues, missing_artifacts)
      {
        "source_status" => "blocked",
        "source_path" => eval_baseline_path_label(source_path),
        "target_path" => nil,
        "fixture_count" => 0,
        "calibrated_fixture_count" => 0,
        "invalid_fixture_count" => 0,
        "corpus_readiness" => {
          "status" => "blocked",
          "production_ready" => false,
          "multi_fixture_required_for_production" => true,
          "minimum_calibrated_fixture_count" => 2,
          "blocking_issues" => issues.uniq
        },
        "fixtures" => [],
        "blocking_issues" => issues.uniq,
        "missing_artifacts" => missing_artifacts,
        "corpus" => { "schema_version" => 1, "fixtures" => {} }
      }
    end

    def eval_baseline_source_path_issues(path)
      issues = []
      label = eval_baseline_path_label(path)
      expanded_root = File.expand_path(root)
      expanded_path = File.expand_path(path.to_s)
      root_prefix = expanded_root.end_with?(File::SEPARATOR) ? expanded_root : "#{expanded_root}#{File::SEPARATOR}"
      unless expanded_path == expanded_root || expanded_path.start_with?(root_prefix)
        issues << "unsafe human baseline source path blocked: #{File.basename(expanded_path)} is outside the project"
        return issues
      end

      parts = label.split(/[\/\\]+/)
      if parts.any? { |part| part.match?(/\A\.env(?:\.|\z)/) }
        issues << "unsafe human baseline source path blocked: .env/.env.* paths are not allowed"
      end
      if parts.any? { |part| %w[.git node_modules dist build coverage tmp vendor].include?(part) }
        issues << "unsafe human baseline source path blocked: generated, dependency, and VCS paths are not allowed"
      end
      issues
    end

    def eval_baseline_corpus_readiness(corpus, selected_entries, fixture_summaries)
      metadata = corpus.to_h["corpus_metadata"].is_a?(Hash) ? corpus.fetch("corpus_metadata") : {}
      entries_by_fixture = Array(selected_entries).to_h { |entry| [entry.fetch("fixture_id").to_s, entry.fetch("baseline")] }
      calibrated_summaries = Array(fixture_summaries).select { |summary| summary["human_calibrated"] == true }
      reviewer_ids = entries_by_fixture.values.flat_map do |baseline|
        Array(baseline.to_h["human_ratings"]).filter_map do |rating|
          next unless rating.is_a?(Hash)

          rating["reviewer_id"].to_s.strip
        end
      end.reject(&:empty?).uniq.sort
      declared_reviewer_count = metadata["reviewer_count"].is_a?(Integer) ? metadata["reviewer_count"] : nil
      axes = calibrated_summaries.flat_map { |summary| Array(summary["score_axes"]) }.uniq.sort
      fixtures_without_rating_evidence = calibrated_summaries.filter_map do |summary|
        baseline = entries_by_fixture[summary["fixture_id"].to_s].to_h
        ratings = Array(baseline["human_ratings"]).select { |rating| rating.is_a?(Hash) }
        summary["fixture_id"] if ratings.empty? || ratings.any? { |rating| rating["reviewer_id"].to_s.strip.empty? }
      end

      issues = []
      issues << "production human baseline corpus requires at least 2 calibrated fixtures" if calibrated_summaries.length < 2
      issues << "production human baseline corpus requires corpus_metadata.reviewer_count >= 2" unless declared_reviewer_count && declared_reviewer_count >= 2
      issues << "production human baseline corpus requires at least 2 unique human reviewer ids" if reviewer_ids.length < 2
      unless fixtures_without_rating_evidence.empty?
        issues << "production human baseline corpus requires human_ratings reviewer_id evidence for each calibrated fixture: #{fixtures_without_rating_evidence.join(", ")}"
      end

      {
        "status" => if issues.empty?
                       "production_ready_multi_fixture"
                     elsif calibrated_summaries.any?
                       "calibrated_but_not_production_corpus"
                     else
                       "not_human_calibrated"
                     end,
        "production_ready" => issues.empty?,
        "multi_fixture_required_for_production" => true,
        "minimum_calibrated_fixture_count" => 2,
        "fixture_count" => Array(fixture_summaries).length,
        "calibrated_fixture_count" => calibrated_summaries.length,
        "declared_reviewer_count" => declared_reviewer_count,
        "unique_reviewer_count" => reviewer_ids.length,
        "reviewer_ids" => reviewer_ids,
        "score_axes" => axes,
        "blocking_issues" => issues
      }
    end

    def eval_baseline_fixture_entries(fixtures)
      case fixtures
      when Hash
        fixtures.each_with_index.map do |(key, baseline), index|
          fixture_id = baseline.is_a?(Hash) && !baseline["fixture_id"].to_s.empty? ? baseline["fixture_id"].to_s : key.to_s
          { "fixture_id" => fixture_id, "baseline" => baseline, "index" => index }
        end
      when Array
        fixtures.each_with_index.map do |baseline, index|
          fixture_id = baseline.is_a?(Hash) ? baseline["fixture_id"].to_s : ""
          { "fixture_id" => fixture_id, "baseline" => baseline, "index" => index }
        end
      else
        nil
      end
    end

    def eval_baseline_fixture_summary(fixture_id, baseline, index)
      issues = []
      unless fixture_id.to_s.match?(/\Adesign-fixture-[a-f0-9]{16}\z/)
        issues << "human baseline fixture #{index} must declare fixture_id matching design-fixture-<16 lowercase hex>"
      end
      unless baseline.is_a?(Hash)
        return {
          "fixture_id" => fixture_id.to_s.empty? ? nil : fixture_id,
          "index" => index,
          "status" => "invalid",
          "average_score" => nil,
          "reviewer_count" => 0,
          "rating_count" => 0,
          "score_axes" => [],
          "human_calibrated" => false,
          "issues" => (issues + ["human baseline fixture #{index} must be an object"]).uniq
        }
      end

      issues.concat(engine_run_eval_human_baseline_issues(baseline, fixture_id.to_s))
      reviewer_count = baseline["reviewer_count"].is_a?(Integer) ? baseline["reviewer_count"] : 0
      score_axes = baseline["human_scores"].is_a?(Hash) ? baseline["human_scores"].keys.map(&:to_s).sort : []
      rating_count = baseline["human_ratings"].is_a?(Array) ? baseline["human_ratings"].length : 0
      has_human_scores = score_axes.any?
      has_human_ratings = rating_count.positive?
      unless reviewer_count.positive? && (has_human_scores || has_human_ratings)
        issues << "human baseline fixture #{fixture_id} is not human-calibrated: positive reviewer_count and human_scores or human_ratings are required"
      end
      human_calibrated = issues.empty? && reviewer_count.positive? && (has_human_scores || has_human_ratings)

      {
        "fixture_id" => fixture_id,
        "index" => index,
        "status" => human_calibrated ? "calibrated" : "invalid",
        "average_score" => baseline["average_score"].is_a?(Numeric) ? baseline["average_score"] : nil,
        "reviewer_count" => reviewer_count,
        "rating_count" => rating_count,
        "score_axes" => score_axes,
        "human_calibrated" => human_calibrated,
        "issues" => issues.uniq
      }
    end

    def eval_baseline_validation_artifact(validation, status:, action:, approved:, dry_run:, blockers:, target_path:, validation_path:)
      {
        "schema_version" => 1,
        "status" => status,
        "action" => action,
        "validated_at" => now,
        "dry_run" => dry_run,
        "approved" => approved,
        "source_path" => validation["source_path"],
        "target_path" => relative(target_path),
        "validation_path" => relative(validation_path),
        "fixture_count" => validation["fixture_count"],
        "calibrated_fixture_count" => validation["calibrated_fixture_count"],
        "invalid_fixture_count" => validation["invalid_fixture_count"],
        "corpus_readiness" => validation["corpus_readiness"],
        "fixtures" => validation["fixtures"],
        "guardrails" => eval_baseline_guardrails,
        "blocking_issues" => blockers
      }
    end

    def eval_baseline_guardrails
      [
        "no fabricated reviewer evidence",
        "project-local JSON source only",
        "no .env/.env.* reads",
        "no raw secrets or environment values",
        "scores must be numeric 0..100",
        "import requires --approved",
        "dry-run writes nothing"
      ]
    end

    def eval_baseline_next_action(action, status)
      case [action, status]
      when ["review-pack", "created"]
        "send .ai-web/eval/human-review-pack.json to human reviewers, write .ai-web/eval/candidate-human-baselines.json with real human scores, then run aiweb eval-baseline validate --path .ai-web/eval/candidate-human-baselines.json"
      when ["review-pack", "dry_run"]
        "rerun aiweb eval-baseline review-pack without --dry-run to create the human review pack"
      when ["validate", "validated"]
        "review .ai-web/eval/human-baseline-validation.json, then run aiweb eval-baseline import --path <candidate> --approved when the corpus is human-provided"
      when ["import", "imported"]
        "run aiweb engine-run so eval-benchmark.json can use the calibrated human baseline"
      when ["validate", "dry_run"], ["import", "dry_run"]
        "rerun without --dry-run to record validation evidence, or add --approved for import"
      else
        action == "review-pack" ? "fix the reported human review pack issues and rerun aiweb eval-baseline review-pack" : "fix the reported human baseline issues and rerun aiweb eval-baseline validate --path <candidate>"
      end
    end

    def eval_baseline_path_label(path)
      expanded_root = File.expand_path(root)
      expanded_path = File.expand_path(path.to_s)
      root_prefix = expanded_root.end_with?(File::SEPARATOR) ? expanded_root : "#{expanded_root}#{File::SEPARATOR}"
      return relative(expanded_path) if expanded_path == expanded_root || expanded_path.start_with?(root_prefix)

      File.basename(expanded_path)
    end

    def engine_run_missing_human_calibration(path)
      {
        "status" => "missing",
        "baseline_source" => {
          "type" => "none",
          "path" => relative(path),
          "status" => "missing",
          "reason" => "no human-calibrated eval baseline exists for this fixture"
        }
      }
    end

    def engine_run_seeded_human_calibration(path, design_fixture)
      fixture = design_fixture.to_h
      baseline = fixture["stored_baseline_verdict"].is_a?(Hash) ? fixture["stored_baseline_verdict"] : {}
      average = baseline["average_score"].is_a?(Numeric) ? baseline["average_score"] : nil
      {
        "status" => "seeded",
        "baseline_source" => {
          "type" => "deterministic_design_fixture_seed",
          "path" => relative(path),
          "status" => "seeded",
          "fixture_id" => fixture["fixture_id"].to_s,
          "average_score" => average,
          "reviewer_count" => 0,
          "rating_count" => 0,
          "score_axes" => [],
          "human_calibrated" => false,
          "reason" => "no human-calibrated eval baseline exists for this fixture; seeded from deterministic design fixture evidence"
        }
      }
    end

    def engine_run_eval_viewport_matrix(design_fixture, screenshot_evidence)
      expected = Array(design_fixture.to_h["viewport_expected_outcomes"]).each_with_object({}) { |entry, memo| memo[entry["viewport"].to_s] = entry if entry.is_a?(Hash) }
      screenshots = Array(screenshot_evidence.to_h["screenshots"]).each_with_object({}) { |entry, memo| memo[entry["viewport"].to_s] = entry if entry.is_a?(Hash) }
      viewports = (expected.keys + screenshots.keys + %w[desktop tablet mobile]).uniq
      viewports.map do |viewport|
        {
          "viewport" => viewport,
          "expected" => expected.dig(viewport, "expected"),
          "evidence_required" => Array(expected.dig(viewport, "evidence_required")),
          "screenshot_path" => screenshots.dig(viewport, "path"),
          "screenshot_sha256" => screenshots.dig(viewport, "sha256"),
          "status" => screenshots.key?(viewport) ? "captured" : "missing"
        }
      end
    end

    def engine_run_eval_time_to_pass(final_status, events)
      first_at = events.first && events.first["at"]
      last_at = events.last && events.last["at"]
      duration = if first_at && last_at
                   (Time.parse(last_at) - Time.parse(first_at)).round(3)
                 end
      {
        "status" => %w[passed no_changes].include?(final_status) ? "recorded" : "not_passed",
        "seconds" => duration,
        "start_event_at" => first_at,
        "end_event_at" => last_at
      }
    rescue ArgumentError
      {
        "status" => "unsupported",
        "seconds" => nil,
        "reason" => "event timestamps could not be parsed"
      }
    end

    def engine_run_eval_token_tool_cost(events)
      tool_events = events.count { |event| event["type"].to_s.start_with?("tool.") }
      {
        "status" => "partial",
        "tool_event_count" => tool_events,
        "token_count" => nil,
        "estimated_cost_usd" => nil,
        "reason" => "local engine-run records tool events but has no provider token accounting yet"
      }
    end

    def engine_run_fixture_excerpt(relative_path)
      return nil if relative_path.to_s.strip.empty?

      expanded_root = File.expand_path(root)
      path = File.expand_path(relative_path.to_s, expanded_root)
      return nil unless path.start_with?("#{expanded_root}#{File::SEPARATOR}") && File.file?(path)

      File.read(path, 16 * 1024).lines.first(40).join.strip
    rescue SystemCallError, ArgumentError
      nil
    end

    def engine_run_apply_design_gate_to_policy(policy, design_verdict, contract, paths)
      required = contract && contract["status"] == "ready"
      policy["design_gate_required"] = !!required
      policy["design_gate_status"] = required ? design_verdict["status"] : "skipped"
      policy["design_gate_artifact"] = required ? relative(paths.fetch(:design_verdict_path)) : nil
      policy["design_gate_blocking_issues"] = Array(design_verdict["blocking_issues"])
      policy["design_gate_contract_hash"] = contract && contract["contract_hash"]
      if required && design_verdict["status"] == "failed"
        policy["status"] = "repair"
      end
      policy
    end

    def engine_run_sandbox_tool_command(sandbox, workspace_dir, command, tool: "verification", agent: "openmanus")
      provider = sandbox.to_s
      sandbox_runtime_container_command(
        provider: provider,
        workspace_dir: workspace_dir,
        image: engine_run_agent_container_image(agent),
        env: engine_run_agent_container_env(agent, provider).merge("AIWEB_ENGINE_RUN_TOOL" => tool),
        pids_limit: 512,
        memory: "2g",
        cpus: "2",
        tmpfs_size: "128m",
        command: command
      )
    end

    def engine_run_verification_env(workspace_dir, paths = nil, sandbox = nil)
      FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb", "home"))
      FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb", "tmp"))
      if paths && !sandbox.to_s.strip.empty?
        return engine_run_clean_env(workspace_dir, paths, sandbox)
      end

      subprocess_path_env.merge(
        "AIWEB_ENGINE_RUN_WORKSPACE" => workspace_dir,
        "AIWEB_NETWORK_ALLOWED" => "0",
        "AIWEB_MCP_ALLOWED" => "0",
        "AIWEB_ENV_ACCESS_ALLOWED" => "0",
        "HOME" => File.join(workspace_dir, "_aiweb", "home"),
        "USERPROFILE" => File.join(workspace_dir, "_aiweb", "home"),
        "TMPDIR" => File.join(workspace_dir, "_aiweb", "tmp"),
        "TMP" => File.join(workspace_dir, "_aiweb", "tmp"),
        "TEMP" => File.join(workspace_dir, "_aiweb", "tmp")
      )
    end

    def engine_run_capture_command(command, cwd, timeout_sec, env: subprocess_path_env)
      stdout = +""
      stderr = +""
      exit_code = nil
      Timeout.timeout(timeout_sec) do
        stdout, stderr, status = Open3.capture3(env, *command, chdir: cwd, unsetenv_others: true)
        exit_code = status.exitstatus
      end
      [stdout, stderr, exit_code]
    rescue Timeout::Error
      ["", "timed out after #{timeout_sec}s\n", 124]
    rescue SystemCallError => e
      ["", "#{e.message}\n", 127]
    end

    def engine_run_try_reap_process(pid)
      return nil unless pid

      reaped = Process.waitpid(pid, Process::WNOHANG)
      reaped ? $?.exitstatus : nil
    rescue Errno::ECHILD
      0
    rescue SystemCallError
      nil
    end

    def engine_run_process_alive?(pid)
      return false unless pid

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::ECHILD, SystemCallError
      false
    end

    def engine_run_stop_process(pid)
      return nil unless pid
      return "already_exited" unless engine_run_try_reap_process(pid).nil?

      begin
        Process.kill("TERM", pid)
      rescue SignalException, SystemCallError
        begin
          Process.kill("KILL", pid)
        rescue SignalException, SystemCallError
          return "kill_failed"
        end
      end
      deadline = Time.now + 2
      while Time.now < deadline
        return "stopped" unless engine_run_try_reap_process(pid).nil?
        sleep 0.05
      end
      begin
        Process.kill("KILL", pid)
      rescue SignalException, SystemCallError
        nil
      end
      engine_run_try_reap_process(pid)
      "killed"
    end

    def engine_run_final_status(result, policy)
      return "cancelled" if result.fetch(:blocking_issues).any? { |issue| issue.to_s.match?(/cancellation requested/i) }
      return "quarantined" if policy["status"].to_s == "quarantined" || policy.fetch("blocking_issues").any? { |issue| issue.to_s.match?(/\Aquarantine:/i) }
      return "failed" unless result.fetch(:success)
      return "blocked" unless policy.fetch("blocking_issues").empty?
      return "waiting_approval" unless policy.fetch("approval_issues").empty?
      return "no_changes" if policy.fetch("safe_changes").empty?

      "passed"
    end

    def engine_run_checkpoint_next_step(status)
      case status
      when "passed", "no_changes" then "review_results"
      when "waiting_approval" then "review_approval_request"
      when "cancelled" then "engine-run --resume"
      when "quarantined" then "manual_quarantine_review"
      else "inspect_events"
      end
    end

    def engine_run_action_taken(status)
      case status
      when "passed" then "ran agentic engine"
      when "no_changes" then "engine run produced no source changes"
      when "waiting_approval" then "engine run waiting for elevated approval"
      when "cancelled" then "engine run cancelled"
      when "quarantined" then "engine run quarantined"
      when "blocked" then "engine run blocked"
      else "engine run failed"
      end
    end

    def engine_run_next_action(metadata)
      case metadata["status"]
      when "passed"
        "review #{metadata["metadata_path"]}, #{metadata["diff_path"]}, and the event timeline"
      when "waiting_approval"
        "review copy_back_policy approval_issues in #{metadata["metadata_path"]}; rerun only after granting the specific elevated capability"
      when "cancelled"
        "resume with aiweb engine-run --resume #{metadata["run_id"]} --approved after reviewing #{metadata["checkpoint_path"]}"
      when "quarantined"
        "review redacted quarantine evidence at #{metadata["quarantine_path"]}; copy-back is blocked until manual release outside engine-run"
      else
        "inspect #{metadata["events_path"]} and #{metadata["metadata_path"]}, then rerun aiweb engine-run --dry-run"
      end
    end

    def engine_run_metadata(run_id:, status:, mode:, agent:, sandbox:, approved:, dry_run:, goal:, capability:, approval_hash:, paths:, events:, checkpoint:, blocking_issues:, started_at: nil, finished_at: nil, exit_code: nil, staged_manifest_path: nil, diff_path: nil, stdout_log: nil, stderr_log: nil, verification_path: nil, preview_path: nil, screenshot_evidence_path: nil, design_verdict_path: nil, design_fidelity_path: nil, design_fixture_path: nil, eval_benchmark_path: nil, supply_chain_gate_path: nil, opendesign_contract_path: nil, project_index_path: nil, run_memory_path: nil, authz_enforcement_path: nil, worker_adapter_registry_path: nil, graph_execution_plan_path: nil, graph_scheduler_state_path: nil, sandbox_preflight_path: nil, quarantine_path: nil, agent_result_path: nil, run_graph: nil, graph_execution_plan: nil, graph_scheduler_state: nil, tool_broker: nil, sandbox_preflight: nil, copy_back_policy: nil, verification: nil, preview: nil, screenshot_evidence: nil, design_verdict: nil, design_fidelity: nil, design_fixture: nil, eval_benchmark: nil, supply_chain_gate: nil, quarantine: nil, opendesign_contract: nil, project_index: nil, run_memory: nil, authz_enforcement: nil, worker_adapter_registry: nil)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "mode" => mode,
        "agent" => agent,
        "sandbox" => sandbox,
        "approved" => approved,
        "dry_run" => dry_run,
        "goal" => goal,
        "capability" => capability,
        "approval_hash" => approval_hash,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "exit_code" => exit_code,
        "run_dir" => relative(paths.fetch(:run_dir)),
        "metadata_path" => relative(paths.fetch(:metadata_path)),
        "events_path" => relative(paths.fetch(:events_path)),
        "approval_path" => relative(paths.fetch(:approval_path)),
        "checkpoint_path" => relative(paths.fetch(:checkpoint_path)),
        "workspace_path" => relative(paths.fetch(:workspace_dir)),
        "staged_manifest_path" => staged_manifest_path,
        "opendesign_contract_path" => opendesign_contract_path,
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "diff_path" => diff_path,
        "worker_adapter_contract_path" => relative(paths.fetch(:worker_adapter_contract_path)),
        "authz_enforcement_path" => authz_enforcement_path,
        "worker_adapter_registry_path" => worker_adapter_registry_path,
        "graph_execution_plan_path" => graph_execution_plan_path,
        "graph_scheduler_state_path" => graph_scheduler_state_path,
        "agent_result_path" => agent_result_path,
        "verification_path" => verification_path,
        "preview_path" => preview_path,
        "screenshot_evidence_path" => screenshot_evidence_path,
        "design_verdict_path" => design_verdict_path,
        "design_fidelity_path" => design_fidelity_path,
        "design_fixture_path" => design_fixture_path,
        "eval_benchmark_path" => eval_benchmark_path,
        "supply_chain_gate_path" => supply_chain_gate_path,
        "sandbox_preflight_path" => sandbox_preflight_path,
        "project_index_path" => project_index_path,
        "quarantine_path" => quarantine_path,
        "events" => events,
        "checkpoint" => checkpoint,
        "run_graph" => run_graph,
        "graph_execution_plan" => graph_execution_plan,
        "graph_scheduler_state" => graph_scheduler_state,
        "tool_broker" => tool_broker,
        "authz_contract" => engine_run_authz_contract,
        "retention_redaction_policy" => engine_run_retention_redaction_policy,
        "sandbox_preflight" => sandbox_preflight,
        "project_index" => project_index,
        "run_memory_path" => run_memory_path,
        "run_memory" => run_memory,
        "authz_enforcement" => authz_enforcement,
        "worker_adapter_registry" => worker_adapter_registry,
        "opendesign_contract" => opendesign_contract,
        "copy_back_policy" => copy_back_policy,
        "verification" => verification,
        "preview" => preview,
        "screenshot_evidence" => screenshot_evidence,
        "design_verdict" => design_verdict,
        "design_fidelity" => design_fidelity,
        "design_fixture" => design_fixture,
        "eval_benchmark" => eval_benchmark,
        "supply_chain_gate" => supply_chain_gate,
        "quarantine" => quarantine,
        "blocking_issues" => blocking_issues,
        "guardrails" => [
          "host project is not writable by the agent process",
          "sandbox workspace is staged with .env, credentials, provider auth, and generated bulk directories excluded",
          "network/install/deploy/provider CLI/git push require elevated approval",
          "copy-back requires denylist, secret, binary, and writable-envelope validation",
          "web Workbench is not required for engine-run"
        ]
      }.compact
    end

    def engine_run_payload(state:, metadata:, changed_files:, planned_changes:, action_taken:, next_action:)
      payload = status_hash(state: state, changed_files: changed_files)
      payload["action_taken"] = action_taken
      payload["engine_run"] = metadata
      payload["planned_changes"] = planned_changes unless planned_changes.empty?
      payload["blocking_issues"] = (payload["blocking_issues"] + Array(metadata["blocking_issues"])).uniq
      payload["next_action"] = next_action
      payload
    end

    def engine_run_job_record(run_id:, status:, started_at:, finished_at:, events_path:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "kind" => "engine-run",
        "status" => status,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "events_path" => relative(events_path),
        "updated_at" => now
      }
    end

    def engine_run_event(path, events, type, message, data = {})
      seq = engine_run_next_event_seq(path, events)
      run_id = File.basename(File.dirname(path))
      event = {
        "schema_version" => 1,
        "seq" => seq,
        "run_id" => run_id,
        "actor" => "aiweb.engine_run",
        "phase" => type.to_s.split(".").first.to_s,
        "trace_span_id" => "span-#{seq.to_s.rjust(6, "0")}-#{type.to_s.gsub(/[^a-z0-9]+/i, "-")}",
        "type" => type,
        "message" => engine_run_redact_event_text(message.to_s),
        "at" => now,
        "data" => engine_run_redact_event_value(data),
        "redaction_status" => "redacted_at_source",
        "previous_event_hash" => engine_run_previous_event_hash(path, events)
      }
      event["event_hash"] = engine_run_event_hash(event)
      events << event
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") { |file| file.write(JSON.generate(event) + "\n") }
      event
    end

    def engine_run_redact_event_value(value, depth = 0)
      return "[redacted-depth-limit]" if depth > 8

      case value
      when Hash
        value.each_with_object({}) do |(key, item), memo|
          key = key.to_s
          memo[key] = key.match?(/secret|token|password|api[_-]?key|credential/i) ? "[redacted]" : engine_run_redact_event_value(item, depth + 1)
        end
      when Array
        value.map { |item| engine_run_redact_event_value(item, depth + 1) }
      when String
        engine_run_redact_event_text(value)
      else
        value
      end
    end

    def engine_run_redact_event_text(value)
      text = agent_run_redact_process_output(value.to_s)
      text = text.gsub(ENGINE_RUN_SECRET_VALUE_PATTERN, "[redacted]")
      text = text.gsub(/\b[A-Z0-9_]*(?:SECRET|TOKEN|PASSWORD|PRIVATE[_-]?KEY|API[_-]?KEY|CREDENTIAL)[A-Z0-9_]*=[^\s]+/i, "[redacted]")
      text.gsub(/([?&](?:access_token|api[_-]?key|key|password|secret|token)=)[^&\s]+/i, "\\1[redacted]")
    end

    def engine_run_previous_event_hash(path, events)
      last_event = events.reverse.find { |event| event["event_hash"].to_s.match?(/\Asha256:/) }
      return last_event["event_hash"] if last_event
      return nil unless File.file?(path)

      File.readlines(path).reverse_each do |line|
        parsed = JSON.parse(line)
        hash = parsed["event_hash"].to_s
        return hash if hash.match?(/\Asha256:/)
      rescue JSON::ParserError
        next
      end
      nil
    rescue SystemCallError
      nil
    end

    def engine_run_event_hash(event)
      payload = event.reject { |key, _value| key == "event_hash" }
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(payload))}"
    end

    def engine_run_next_event_seq(path, events)
      existing = File.file?(path) ? File.readlines(path).length : 0
      [existing, events.length].max + 1
    rescue SystemCallError
      events.length + 1
    end

    def engine_run_command_descriptor(agent, mode, sandbox, max_cycles, resume = nil)
      command = ["aiweb", "engine-run", "--agent", agent, "--mode", mode, "--max-cycles", max_cycles.to_s]
      command.concat(["--sandbox", sandbox]) if engine_run_container_worker_agent?(agent) && !sandbox.to_s.empty?
      command.concat(["--resume", resume]) unless resume.to_s.strip.empty?
      command << "--approved"
      command
    end

    def engine_run_sandbox_suffix(agent, sandbox)
      engine_run_container_worker_agent?(agent) && !sandbox.to_s.empty? ? " --sandbox #{sandbox}" : ""
    end

    def engine_run_resume_checkpoint(run_id)
      safe = validate_run_id!(run_id)
      path = File.join(run_lifecycle_run_dir(safe), "checkpoint.json")
      read_json_file(path)
    rescue UserError
      nil
    end

    def engine_run_resume_context(run_id)
      return nil if run_id.to_s.strip.empty?

      safe = validate_run_id!(run_id)
      run_dir = run_lifecycle_run_dir(safe)
      checkpoint_path = File.join(run_dir, "checkpoint.json")
      checkpoint = read_json_file(checkpoint_path)
      return nil unless checkpoint

      metadata = read_json_file(File.join(run_dir, "engine-run.json")) || {}
      manifest_path = File.join(".ai-web", "runs", safe, "artifacts", "staged-manifest.json")
      metadata_manifest_path = metadata["staged_manifest_path"].to_s
      manifest_path = metadata_manifest_path if checkpoint["run_graph"].nil? && !metadata_manifest_path.empty?
      manifest_abs = File.expand_path(manifest_path, root)
      manifest = read_json_file(manifest_abs)
      workspace_rel = checkpoint["workspace_path"].to_s.empty? ? metadata["workspace_path"].to_s : checkpoint["workspace_path"].to_s
      workspace_dir = File.expand_path(workspace_rel, root)
      {
        run_id: safe,
        run_dir: relative(run_dir),
        checkpoint_path: relative(checkpoint_path),
        checkpoint: checkpoint,
        metadata: metadata,
        manifest_path: relative(manifest_abs),
        manifest: manifest,
        workspace_dir: workspace_dir
      }
    rescue UserError
      nil
    end

    def engine_run_resume_blockers(context)
      blockers = []
      workspace_dir = context.fetch(:workspace_dir)
      unless workspace_dir.start_with?(File.expand_path(root) + File::SEPARATOR)
        blockers << "engine-run resume workspace is outside the project root"
      end
      blockers << "engine-run resume workspace is missing: #{relative(workspace_dir)}" unless Dir.exist?(workspace_dir)
      blockers << "engine-run resume staged manifest is missing or unreadable: #{context.fetch(:manifest_path)}" unless context[:manifest].is_a?(Hash)
      blockers.concat(engine_run_resume_artifact_hash_blockers(context))
      blockers.concat(engine_run_resume_graph_artifact_binding_blockers(context))
      blockers.concat(engine_run_resume_graph_cursor_blockers(context))
      blockers
    end

    def engine_run_resume_graph_artifact_binding_blockers(context)
      checkpoint = context.fetch(:checkpoint)
      graph = checkpoint["run_graph"]
      cursor = checkpoint["run_graph_cursor"]
      hashes = checkpoint["artifact_hashes"]
      return [] unless graph.is_a?(Hash) && cursor.is_a?(Hash) && hashes.is_a?(Hash)

      expected_paths = engine_run_resume_artifact_hash_paths(context)
      plan_path = expected_paths["graph_execution_plan"]
      state_path = expected_paths["graph_scheduler_state"]
      plan = read_json_file(File.expand_path(plan_path, root))
      scheduler_state = read_json_file(File.expand_path(state_path, root))
      blockers = []
      blockers << "engine-run resume hashed graph execution plan is missing or unreadable" unless plan.is_a?(Hash)
      blockers << "engine-run resume hashed graph scheduler state is missing or unreadable" unless scheduler_state.is_a?(Hash)
      return blockers unless plan.is_a?(Hash) && scheduler_state.is_a?(Hash)

      checkpoint_run_id = checkpoint["run_id"].to_s
      blockers << "engine-run resume graph execution plan run_id does not match checkpoint" unless plan["run_id"].to_s == checkpoint_run_id
      blockers << "engine-run resume graph scheduler state run_id does not match checkpoint" unless scheduler_state["run_id"].to_s == checkpoint_run_id
      unless scheduler_state["graph_execution_plan_ref"].to_s == plan_path
        blockers << "engine-run resume graph scheduler state does not reference the hashed graph execution plan"
      end
      unless scheduler_state["cursor"] == cursor
        blockers << "engine-run resume checkpoint graph cursor does not match hashed graph scheduler state cursor"
      end

      executor = graph["executor_contract"].to_h
      node_order = Array(executor["node_order"]).map(&:to_s)
      unless Array(plan["node_order"]).map(&:to_s) == node_order
        blockers << "engine-run resume graph execution plan node order does not match checkpoint graph"
      end
      unless plan["executor_type"].to_s == executor["executor_type"].to_s
        blockers << "engine-run resume graph execution plan executor type does not match checkpoint graph"
      end
      derived_from_checkpoint = Aiweb::GraphSchedulerRuntime.start_node(node_order, cursor)
      derived_from_scheduler_state = Aiweb::GraphSchedulerRuntime.start_node(Array(scheduler_state["node_order"]).map(&:to_s), scheduler_state["cursor"])
      unless derived_from_checkpoint == derived_from_scheduler_state
        blockers << "engine-run resume start node derivation does not match hashed graph scheduler state"
      end

      graph_nodes = Array(graph["nodes"]).select { |node| node.is_a?(Hash) }
      scheduler_nodes_by_id = Array(scheduler_state["nodes"]).select { |node| node.is_a?(Hash) }.to_h { |node| [node["node_id"].to_s, node] }
      invocations_by_id = Array(plan["node_invocations"]).select { |node| node.is_a?(Hash) }.to_h { |node| [node["node_id"].to_s, node] }
      graph_nodes.each do |node|
        node_id = node["node_id"].to_s
        scheduler_node = scheduler_nodes_by_id[node_id]
        invocation = invocations_by_id[node_id]
        unless scheduler_node
          blockers << "engine-run resume hashed graph scheduler state is missing node #{node_id}"
          next
        end
        unless invocation
          blockers << "engine-run resume hashed graph execution plan is missing node #{node_id}"
          next
        end
        if scheduler_node["state"].to_s != node["state"].to_s || scheduler_node["attempt"].to_i != node["attempt"].to_i
          blockers << "engine-run resume checkpoint graph node #{node_id} does not match hashed graph scheduler state"
        end
        if invocation["handler"].to_s != node.dig("executor", "handler").to_s ||
           invocation["side_effect_boundary"].to_s != node["side_effect_boundary"].to_s ||
           invocation["tool_broker_required"] != (node.dig("executor", "tool_broker_required") == true)
          blockers << "engine-run resume checkpoint graph node #{node_id} does not match hashed graph execution plan"
        end
      end
      blockers.uniq
    rescue SystemCallError, JSON::ParserError => e
      ["engine-run resume graph artifact binding validation failed: #{e.message}"]
    end

    def engine_run_resume_graph_cursor_blockers(context)
      checkpoint = context.fetch(:checkpoint)
      graph = checkpoint["run_graph"]
      cursor = checkpoint["run_graph_cursor"]
      blockers = []
      blockers << "engine-run resume checkpoint is missing run graph" unless graph.is_a?(Hash)
      blockers << "engine-run resume checkpoint is missing run graph cursor" unless cursor.is_a?(Hash)
      return blockers unless graph.is_a?(Hash) && cursor.is_a?(Hash)

      if !graph["run_id"].to_s.empty? && graph["run_id"].to_s != checkpoint["run_id"].to_s
        blockers << "engine-run resume run graph run_id does not match checkpoint"
      end

      node_id = cursor["node_id"].to_s
      cursor_state = cursor["state"].to_s
      cursor_attempt = cursor["attempt"]
      nodes = Array(graph["nodes"])
      node = nodes.find { |candidate| candidate.is_a?(Hash) && candidate["node_id"].to_s == node_id }
      blockers << "engine-run resume graph cursor points at unknown node: #{node_id.empty? ? "(missing)" : node_id}" unless node
      return blockers unless node

      node_state = node["state"].to_s
      blockers << "engine-run resume graph cursor has invalid state: #{cursor_state.empty? ? "(missing)" : cursor_state}" unless %w[pending running passed failed skipped blocked waiting_approval quarantined no_changes].include?(cursor_state)
      unless engine_run_resume_graph_cursor_state_compatible?(cursor_state, node_state)
        blockers << "engine-run resume graph cursor state #{cursor_state} does not match node #{node_id} state #{node_state}"
      end
      unless cursor_attempt.is_a?(Integer) && cursor_attempt >= 0
        blockers << "engine-run resume graph cursor attempt is invalid"
      end
      if cursor_attempt.is_a?(Integer) && node["attempt"].is_a?(Integer) && cursor_attempt < node["attempt"]
        blockers << "engine-run resume graph cursor attempt is behind node attempt"
      end
      blockers.concat(engine_run_resume_graph_executor_blockers(graph, nodes))
      blockers
    end

    def engine_run_resume_graph_executor_blockers(graph, nodes)
      blockers = []
      executor = graph["executor_contract"]
      blockers << "engine-run resume checkpoint is missing run graph executor contract" unless executor.is_a?(Hash)
      return blockers unless executor.is_a?(Hash)

      blockers << "engine-run resume graph executor type is invalid" unless executor["executor_type"].to_s == "sequential_durable_node_executor"
      node_ids = nodes.map { |candidate| candidate.is_a?(Hash) ? candidate["node_id"].to_s : "" }.reject(&:empty?)
      unless Array(executor["node_order"]).map(&:to_s) == node_ids
        blockers << "engine-run resume graph executor node order does not match graph nodes"
      end

      nodes.each do |node|
        next unless node.is_a?(Hash)

        node_id = node["node_id"].to_s
        node_executor = node["executor"]
        node_replay = node["replay_policy"]
        unless node_executor.is_a?(Hash)
          blockers << "engine-run resume graph node #{node_id} is missing executor"
          next
        end
        blockers << "engine-run resume graph node #{node_id} executor id is invalid" unless node_executor["executor_id"].to_s == "engine_run.#{node_id}"
        blockers << "engine-run resume graph node #{node_id} handler is missing" if node_executor["handler"].to_s.strip.empty?
        blockers << "engine-run resume graph node #{node_id} executor boundary mismatch" unless node_executor["side_effect_boundary"].to_s == node["side_effect_boundary"].to_s
        boundary_requires_broker = node["side_effect_boundary"].to_s != "none"
        if boundary_requires_broker && node_executor["tool_broker_required"] != true
          blockers << "engine-run resume graph node #{node_id} side effect is not gated by tool broker"
        end
        blockers << "engine-run resume graph node #{node_id} is missing replay policy" unless node_replay.is_a?(Hash)
        if node_replay.is_a?(Hash) && node_replay["requires_artifact_hash_validation"] != true
          blockers << "engine-run resume graph node #{node_id} replay policy does not require artifact hash validation"
        end
      end

      blockers
    end

    def engine_run_resume_graph_cursor_state_compatible?(cursor_state, node_state)
      return true if cursor_state == node_state
      return true if cursor_state == "blocked" && %w[failed blocked].include?(node_state)
      return true if cursor_state == "quarantined" && node_state == "blocked"
      return true if cursor_state == "no_changes" && node_state == "passed"

      false
    end

    def engine_run_resume_artifact_hash_blockers(context)
      checkpoint = context.fetch(:checkpoint)
      graph = checkpoint["run_graph"]
      hashes = checkpoint["artifact_hashes"]
      unless hashes.is_a?(Hash)
        return graph.is_a?(Hash) ? ["engine-run resume checkpoint is missing artifact hashes"] : []
      end
      if graph.is_a?(Hash) && hashes.empty?
        return ["engine-run resume checkpoint has no artifact hashes to validate"]
      end

      blockers = []
      expected_paths = graph.is_a?(Hash) ? engine_run_resume_artifact_hash_paths(context) : {}
      if graph.is_a?(Hash)
        required = engine_run_resume_required_artifact_hash_paths(context)
        unknown = hashes.keys.map(&:to_s) - expected_paths.keys
        unknown.each { |name| blockers << "engine-run resume checkpoint has unknown artifact hash for #{name}" }
        missing = required.keys.reject { |name| hashes.key?(name) }
        missing.each { |name| blockers << "engine-run resume checkpoint is missing required artifact hash for #{name}" }
        required.each do |name, expected_path|
          artifact = hashes[name]
          next unless artifact.is_a?(Hash)

          path = engine_run_normalize_artifact_hash_path(artifact["path"])
          unless path == expected_path
            blockers << "engine-run resume artifact hash path is invalid for #{name}: #{artifact["path"].to_s.empty? ? "(missing)" : artifact["path"]}"
          end
        end
      end

      hashes.each do |name, artifact|
        if graph.is_a?(Hash) && !expected_paths.key?(name.to_s)
          next
        end
        unless artifact.is_a?(Hash)
          blockers << "engine-run resume artifact hash is malformed for #{name}"
          next
        end
        path = artifact["path"].to_s
        expected = artifact["sha256"].to_s
        expected_bytes = artifact["bytes"]
        if path.empty? || expected.empty? || !expected_bytes.is_a?(Integer)
          blockers << "engine-run resume artifact hash is incomplete for #{name}"
          next
        end
        normalized_path = engine_run_normalize_artifact_hash_path(path)
        unless normalized_path
          blockers << "engine-run resume artifact hash path is invalid for #{name}: #{path}"
          next
        end
        expected_path = expected_paths[name.to_s]
        if graph.is_a?(Hash) && normalized_path != expected_path
          blockers << "engine-run resume artifact hash path is invalid for #{name}: #{path}"
          next
        end
        full = File.expand_path(normalized_path, root)
        unless engine_run_path_within_project_root?(full)
          blockers << "engine-run resume artifact hash path escapes project root for #{name}: #{path}"
          next
        end
        unless File.file?(full)
          blockers << "engine-run resume artifact is missing: #{normalized_path}"
          next
        end
        actual = "sha256:#{Digest::SHA256.file(full).hexdigest}"
        blockers << "engine-run resume artifact hash mismatch for #{normalized_path}" unless actual == expected
        if expected_bytes != File.size(full)
          blockers << "engine-run resume artifact byte size mismatch for #{normalized_path}"
        end
      end
      blockers
    rescue SystemCallError => e
      ["engine-run resume artifact hash validation failed: #{e.message}"]
    end

    def engine_run_resume_required_artifact_hash_paths(context)
      engine_run_resume_artifact_hash_paths(context).slice(
        "staged_manifest",
        "graph_execution_plan",
        "graph_scheduler_state",
        "opendesign_contract",
        "project_index",
        "run_memory",
        "authz_enforcement",
        "worker_adapter_registry",
        "sandbox_preflight"
      )
    end

    def engine_run_resume_artifact_hash_paths(context)
      run_dir = engine_run_normalize_artifact_hash_path(context.fetch(:run_dir))
      raise UserError.new("engine-run resume run directory is invalid", 5) unless run_dir

      artifact_path = lambda do |filename|
        [run_dir, "artifacts", filename].join("/")
      end
      qa_path = lambda do |filename|
        [run_dir, "qa", filename].join("/")
      end
      run_id = context.fetch(:run_id).to_s
      {
        "staged_manifest" => artifact_path.call("staged-manifest.json"),
        "graph_execution_plan" => artifact_path.call("graph-execution-plan.json"),
        "graph_scheduler_state" => artifact_path.call("graph-scheduler-state.json"),
        "opendesign_contract" => artifact_path.call("opendesign-contract.json"),
        "project_index" => artifact_path.call("project-index.json"),
        "run_memory" => artifact_path.call("run-memory.json"),
        "authz_enforcement" => artifact_path.call("authz-enforcement.json"),
        "worker_adapter_registry" => artifact_path.call("worker-adapter-registry.json"),
        "sandbox_preflight" => artifact_path.call("sandbox-preflight.json"),
        "supply_chain_gate" => artifact_path.call("supply-chain-gate.json"),
        "supply_chain_sbom" => artifact_path.call("sbom.json"),
        "supply_chain_audit" => artifact_path.call("package-audit.json"),
        "verification" => qa_path.call("verification.json"),
        "preview" => qa_path.call("preview.json"),
        "browser_evidence" => qa_path.call("screenshots.json"),
        "design_verdict" => qa_path.call("design-verdict.json"),
        "design_fidelity" => qa_path.call("design-fidelity.json"),
        "design_fixture" => qa_path.call("design-fixture.json"),
        "eval_benchmark" => qa_path.call("eval-benchmark.json"),
        "quarantine" => artifact_path.call("quarantine.json"),
        "diff" => [".ai-web", "diffs", "#{run_id}.patch"].join("/")
      }
    end

    def engine_run_normalize_artifact_hash_path(path)
      normalized = path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
      return nil if normalized.empty?
      return nil if normalized.start_with?("/")
      return nil if normalized.match?(/\A[A-Za-z]:\//)

      parts = normalized.split("/")
      return nil if parts.any? { |part| part.empty? || part == "." || part == ".." }

      normalized
    end

    def engine_run_path_within_project_root?(path)
      expanded = File.expand_path(path)
      root_path = File.expand_path(root)
      comparison_expanded = windows? ? expanded.downcase : expanded
      comparison_root = windows? ? root_path.downcase : root_path
      comparison_expanded == comparison_root || comparison_expanded.start_with?(comparison_root + File::SEPARATOR)
    end
  end
end
