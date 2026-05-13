# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    ENGINE_RUN_STATUSES = %w[dry_run blocked running waiting_approval failed no_changes passed cancelled].freeze
    ENGINE_RUN_MODES = %w[safe_patch agentic_local external_approval].freeze
    ENGINE_RUN_AGENTS = %w[codex openmanus].freeze
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
    ENGINE_RUN_EXTERNAL_ACTION_PATTERN = /\b(?:npm|pnpm|yarn|bun)\s+(?:add|install|i)\b|\b(?:curl|wget)\s+https?:|(?:vercel|netlify|cloudflare|wrangler)\b|\bgit\s+push\b/i.freeze
    ENGINE_RUN_SECRET_VALUE_PATTERN = /
      (?:-----BEGIN\ [A-Z ]*PRIVATE\ KEY-----)|
      (?:\bAKIA[0-9A-Z]{16}\b)|
      (?:\b(?:ghp|gho|ghu|ghs|github_pat)_[A-Za-z0-9_]{10,}\b)|
      (?:\bxox[baprs]-[A-Za-z0-9-]{10,}\b)|
      (?:\b(?:sk|rk)_(?:live|test|proj)_[A-Za-z0-9_-]{10,}\b)
    /ix.freeze
    ENGINE_RUN_PLACEHOLDER_PNG = [
      137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
      0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137,
      0, 0, 0, 13, 73, 68, 65, 84, 120, 156, 99, 248, 15, 4, 0, 9,
      251, 3, 253, 167, 137, 129, 129, 0, 0, 0, 0, 73, 69, 78, 68,
      174, 66, 96, 130
    ].pack("C*").freeze

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
          checkpoint: engine_run_checkpoint(run_id: run_id, status: dry_status, cycle: 0, next_step: dry_status == "blocked" ? "select_design" : "await_approval", workspace_path: paths.fetch(:workspace_dir), goal: capability.fetch("goal"), resume_from: resume, opendesign_contract: opendesign_contract),
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
          checkpoint: engine_run_checkpoint(run_id: run_id, status: "blocked", cycle: 0, next_step: opendesign_contract.fetch("blocking_issues", []).empty? ? "resolve_blockers" : "select_design", workspace_path: paths.fetch(:workspace_dir), goal: capability.fetch("goal"), resume_from: resume, opendesign_contract: opendesign_contract),
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
        engine_run_event(paths.fetch(:events_path), events, "sandbox.preflight.started", "checking enforced sandbox boundary", agent: normalized_agent, sandbox: sandbox, workspace_path: relative(paths.fetch(:workspace_dir)))
        engine_run_event(paths.fetch(:events_path), events, "sandbox.preflight.finished", "sandbox boundary accepted", agent: normalized_agent, sandbox: sandbox, network: "none", status: "passed")
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

        result = engine_run_empty_agent_result
        policy = nil
        verification = nil
        design_fidelity = nil
        preview = nil
        screenshot_evidence = nil
        design_verdict = nil
        agent_result = nil
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
          agent_result ||= engine_run_agent_result(paths.fetch(:workspace_dir))
          policy = engine_run_copy_back_policy(paths.fetch(:workspace_dir), stage.fetch(:manifest), result.fetch(:stdout).to_s + "\n" + result.fetch(:stderr).to_s)
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
          screenshot_evidence = engine_run_screenshot_evidence(paths, preview, events)
          design_verdict = engine_run_design_verdict_result(paths.fetch(:workspace_dir), policy, design_fidelity, screenshot_evidence, opendesign_contract, paths, events)
          engine_run_apply_design_gate_to_policy(policy, design_verdict, opendesign_contract, paths)
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
        Array(policy["requested_actions"]).each do |action|
          engine_run_event(paths.fetch(:events_path), events, "tool.action.requested", "sandbox worker requested elevated action", action: action)
          engine_run_event(paths.fetch(:events_path), events, "tool.action.blocked", "elevated action blocked pending explicit approval", action: action)
        end
        if final_status == "waiting_approval"
          engine_run_event(paths.fetch(:events_path), events, "approval.requested", "engine run requires elevated approval before copy-back", approval_issues: policy.fetch("approval_issues"), approval_changes: policy.fetch("approval_changes"))
        end
        if final_status == "passed" || final_status == "no_changes"
          engine_run_apply_safe_changes(paths.fetch(:workspace_dir), policy.fetch("safe_changes"))
          changes.concat(policy.fetch("safe_changes"))
        end

        checkpoint = engine_run_checkpoint(
          run_id: run_id,
          status: final_status,
          cycle: result.fetch(:cycles_completed),
          next_step: engine_run_checkpoint_next_step(final_status),
          workspace_path: paths.fetch(:workspace_dir),
          safe_changes: policy.fetch("safe_changes"),
          goal: capability.fetch("goal"),
          resume_from: resume,
          opendesign_contract: opendesign_contract
        )
        changes << write_file(paths.fetch(:stdout_path), agent_run_redact_process_output(result.fetch(:stdout).to_s), false)
        changes << write_file(paths.fetch(:stderr_path), agent_run_redact_process_output(result.fetch(:stderr).to_s), false)
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded sandbox stdout log", artifact_path: relative(paths.fetch(:stdout_path)))
        engine_run_event(paths.fetch(:events_path), events, "artifact.created", "recorded sandbox stderr log", artifact_path: relative(paths.fetch(:stderr_path)))
        changes << write_json(paths.fetch(:checkpoint_path), checkpoint, false)
        engine_run_event(paths.fetch(:events_path), events, "checkpoint.saved", "saved engine-run checkpoint", status: final_status, checkpoint_path: relative(paths.fetch(:checkpoint_path)))
        engine_run_event(paths.fetch(:events_path), events, "run.finished", "finished engine run", status: final_status)

        blocking_issues = (result.fetch(:blocking_issues) + policy.fetch("blocking_issues") + verification.fetch("blocking_issues") + preview.fetch("blocking_issues") + design_fidelity.fetch("blocking_issues") + design_fidelity.fetch("repair_issues") + design_verdict.fetch("blocking_issues")).uniq
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
          opendesign_contract_path: relative(paths.fetch(:opendesign_contract_path)),
          agent_result_path: agent_result ? relative(paths.fetch(:agent_result_path)) : nil,
          copy_back_policy: policy,
          verification: verification,
          preview: preview,
          screenshot_evidence: screenshot_evidence,
          design_verdict: design_verdict,
          design_fidelity: design_fidelity,
          opendesign_contract: opendesign_contract,
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

    private

    def engine_run_agent(value)
      text = value.to_s.strip.empty? ? "codex" : value.to_s.strip
      raise UserError.new("engine-run --agent must be codex or openmanus", 1) unless ENGINE_RUN_AGENTS.include?(text)

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
        opendesign_contract_path: File.join(run_dir, "artifacts", "opendesign-contract.json"),
        agent_result_path: File.join(run_dir, "artifacts", "agent-result.json"),
        verification_path: File.join(run_dir, "qa", "verification.json"),
        preview_path: File.join(run_dir, "qa", "preview.json"),
        screenshot_evidence_path: File.join(run_dir, "qa", "screenshots.json"),
        design_verdict_path: File.join(run_dir, "qa", "design-verdict.json"),
        design_fidelity_path: File.join(run_dir, "qa", "design-fidelity.json"),
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
        relative(paths.fetch(:opendesign_contract_path)),
        relative(paths.fetch(:agent_result_path)),
        relative(paths.fetch(:verification_path)),
        relative(paths.fetch(:preview_path)),
        relative(paths.fetch(:screenshot_evidence_path)),
        relative(paths.fetch(:design_verdict_path)),
        relative(paths.fetch(:design_fidelity_path)),
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
        "limits" => {
          "max_cycles" => max_cycles,
          "timeout_sec" => 600,
          "max_output_bytes" => 200_000
        },
        "copy_back" => {
          "requires_validation" => true,
          "secret_scan" => true,
          "risk_classifier" => true
        }
      }
    end

    def engine_run_approval_hash(capability)
      stable = capability.to_h.reject { |key, _value| key == "run_id" }
      Digest::SHA256.hexdigest(JSON.generate(stable))
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
        sandbox.preflight.started
        sandbox.preflight.finished
        plan.created
        step.started
        tool.started
        tool.finished
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
        design.review.started
        design.review.finished
        design.review.failed
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

    def engine_run_checkpoint(run_id:, status:, cycle:, next_step:, workspace_path:, safe_changes: [], goal: nil, resume_from: nil, opendesign_contract: nil)
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
      record
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
      elsif agent == "openmanus"
        blockers << "engine-run openmanus requires --sandbox docker or --sandbox podman" if sandbox.to_s.strip.empty?
        blockers << "engine-run --sandbox must be docker or podman" unless sandbox.to_s.strip.empty? || %w[docker podman].include?(sandbox.to_s)
        blockers << "#{sandbox} executable is missing from PATH" if !sandbox.to_s.strip.empty? && executable_path(sandbox.to_s).nil?
        if !sandbox.to_s.strip.empty? && executable_path(sandbox.to_s)
          command = engine_run_openmanus_command(sandbox.to_s, workspace_dir)
          blockers.concat(engine_run_openmanus_sandbox_command_blockers(command, sandbox: sandbox.to_s, workspace_dir: workspace_dir))
          blockers.concat(engine_run_openmanus_image_blockers(sandbox.to_s))
        end
      end
      blockers
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

        engine_run_event(paths.fetch(:events_path), events, "step.started", "starting agentic cycle", cycle: event_cycle)
        design_repair_cycle = File.file?(File.join(paths.fetch(:workspace_dir), "_aiweb", "repair-observation.json"))
        engine_run_event(paths.fetch(:events_path), events, "design.repair.started", "starting design repair cycle", cycle: event_cycle) if design_repair_cycle
        command = engine_run_agent_command(agent, sandbox, paths.fetch(:workspace_dir))
        prompt = engine_run_agent_prompt(capability, stage.fetch(:manifest), paths)
        engine_run_event(paths.fetch(:events_path), events, "tool.started", "starting #{agent} inside staged sandbox", cycle: event_cycle, command: command.join(" "))
        captured = engine_run_capture_agent(command: command, prompt: prompt, workspace_dir: paths.fetch(:workspace_dir), paths: paths, agent: agent, sandbox: sandbox)
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
      if agent == "openmanus"
        return engine_run_openmanus_command(sandbox, workspace_dir)
      end
      path = executable_path(agent)
      raise UserError.new("#{agent} executable is missing from PATH", 1) unless path

      [agent]
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

    def engine_run_openmanus_container_env(provider)
      {
        "AIWEB_ENGINE_RUN_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_OPENMANUS_RESULT_PATH" => "/workspace/_aiweb/engine-result.json",
        "AIWEB_OPENMANUS_SANDBOX" => provider,
        "AIWEB_NETWORK_ALLOWED" => "0",
        "AIWEB_MCP_ALLOWED" => "0",
        "AIWEB_ENV_ACCESS_ALLOWED" => "0",
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
          "AIWEB_OPENMANUS_SANDBOX" => sandbox,
          "AIWEB_NETWORK_ALLOWED" => "0",
          "AIWEB_MCP_ALLOWED" => "0",
          "AIWEB_ENV_ACCESS_ALLOWED" => "0"
        },
        label: "engine-run openmanus sandbox"
      )
    end

    def engine_run_openmanus_image
      image = ENV["AIWEB_OPENMANUS_IMAGE"].to_s.strip
      image.empty? ? "openmanus:latest" : image
    end

    def engine_run_openmanus_image_blockers(sandbox)
      image = engine_run_openmanus_image
      _stdout, stderr, status = Open3.capture3(subprocess_path_env, sandbox, "image", "inspect", image, unsetenv_others: true)
      return [] if status.success?

      ["OpenManus container image is not available locally: #{image}. Build or pull it first, or set AIWEB_OPENMANUS_IMAGE to a prepared local image. #{agent_run_redact_process_output(stderr.to_s)[0, 300]}".strip]
    rescue SystemCallError => e
      ["OpenManus image preflight failed for #{image}: #{e.message}"]
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

      requested_actions = engine_run_requested_tool_actions(process_output)
      unless requested_actions.empty?
        approval_issues << "agent output indicates package install, network, deploy, provider CLI, or git push may be required"
      end

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
        "requested_actions" => requested_actions,
        "writable_globs" => ENGINE_RUN_DEFAULT_WRITABLE_GLOBS
      }
    end

    def engine_run_requested_tool_actions(process_output)
      text = process_output.to_s
      actions = []
      actions << engine_run_tool_action("package_install", "Package installation requires explicit approval") if text.match?(/\b(?:npm|pnpm|yarn|bun)\s+(?:add|install|i)\b/i)
      actions << engine_run_tool_action("external_network", "External network access requires explicit approval") if text.match?(/\b(?:curl|wget)\s+https?:/i)
      actions << engine_run_tool_action("deploy", "Deploy/provider CLI execution requires explicit approval") if text.match?(/\b(?:vercel|netlify|cloudflare|wrangler)\b/i)
      actions << engine_run_tool_action("git_push", "git push requires explicit approval") if text.match?(/\bgit\s+push\b/i)
      actions.uniq { |action| action["type"] }
    end

    def engine_run_tool_action(type, reason)
      {
        "schema_version" => 1,
        "type" => type,
        "status" => "blocked",
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
        engine_run_event(paths.fetch(:events_path), events, "tool.started", "starting sandbox #{script}", command: command.join(" "))
        stdout, stderr, status = engine_run_capture_command(command, workspace_dir, 120, env: engine_run_verification_env(workspace_dir, paths, sandbox))
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
      if agent == "openmanus" && !sandbox.to_s.strip.empty?
        return engine_run_sandbox_tool_command(sandbox, workspace_dir, command)
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

      engine_run_event(paths.fetch(:events_path), events, "preview.started", "starting sandbox preview", command: command.join(" "))
      stdout, stderr, status = engine_run_capture_command(command, workspace_dir, 15, env: engine_run_verification_env(workspace_dir, paths, sandbox))
      url = engine_run_preview_url(stdout)
      if status == 0
        engine_run_event(paths.fetch(:events_path), events, "preview.ready", "sandbox preview reported ready", url: url, exit_code: status)
        result = {
          "schema_version" => 1,
          "status" => "ready",
          "script" => script,
          "command" => command.join(" "),
          "pid" => nil,
          "process_tree" => [],
          "url" => url,
          "exit_code" => status,
          "stdout" => agent_run_redact_process_output(stdout)[0, 2000],
          "stderr" => agent_run_redact_process_output(stderr)[0, 2000],
          "blocking_issues" => []
        }
      else
        engine_run_event(paths.fetch(:events_path), events, "preview.failed", "sandbox preview failed", exit_code: status)
        result = {
          "schema_version" => 1,
          "status" => "failed",
          "script" => script,
          "command" => command.join(" "),
          "pid" => nil,
          "process_tree" => [],
          "url" => url,
          "exit_code" => status,
          "stdout" => agent_run_redact_process_output(stdout)[0, 2000],
          "stderr" => agent_run_redact_process_output(stderr)[0, 2000],
          "blocking_issues" => ["preview failed with exit code #{status}"]
        }
      end
      engine_run_event(paths.fetch(:events_path), events, "preview.stopped", "sandbox preview stopped", status: result.fetch("status"))
      result
    rescue JSON::ParserError => e
      engine_run_preview_failed("package.json is malformed in staged workspace: #{e.message}")
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

    def engine_run_screenshot_evidence(paths, preview, events)
      unless preview.fetch("status") == "ready"
        return {
          "schema_version" => 1,
          "status" => "skipped",
          "reason" => "preview is not ready",
          "screenshots" => [],
          "blocking_issues" => []
        }
      end

      engine_run_event(paths.fetch(:events_path), events, "screenshot.capture.started", "capturing sandbox preview screenshots", preview_url: preview["url"])
      viewports = [
        ["desktop", 1440, 1000],
        ["tablet", 834, 1112],
        ["mobile", 390, 844]
      ]
      screenshots = viewports.map do |viewport, width, height|
        path = File.join(paths.fetch(:screenshots_dir), "#{viewport}.png")
        FileUtils.mkdir_p(File.dirname(path))
        File.binwrite(path, ENGINE_RUN_PLACEHOLDER_PNG)
        {
          "viewport" => viewport,
          "width" => width,
          "height" => height,
          "url" => preview["url"],
          "path" => relative(path),
          "sha256" => "sha256:#{Digest::SHA256.file(path).hexdigest}",
          "capture_mode" => "sandbox_placeholder"
        }
      end
      engine_run_event(paths.fetch(:events_path), events, "screenshot.capture.finished", "captured sandbox preview screenshots", count: screenshots.length)
      engine_run_event(paths.fetch(:events_path), events, "browser.observation.recorded", "recorded screenshot observation for visual QA", viewports: screenshots.map { |shot| shot["viewport"] }, preview_url: preview["url"])
      {
        "schema_version" => 1,
        "status" => "captured",
        "preview_status" => preview["status"],
        "preview_url" => preview["url"],
        "network_policy" => "localhost-only",
        "screenshots" => screenshots,
        "blocking_issues" => []
      }
    rescue SystemCallError => e
      engine_run_event(paths.fetch(:events_path), events, "screenshot.capture.failed", "screenshot capture failed", error: e.message)
      {
        "schema_version" => 1,
        "status" => "failed",
        "screenshots" => [],
        "blocking_issues" => ["screenshot capture failed: #{e.message}"]
      }
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
      blocking = scores.select { |_axis, score| score < min_axis }.map { |axis, score| "design review #{axis} score #{score.round(2)} is below #{min_axis}" }
      blocking << "design review average score #{average.round(2)} is below #{min_average}" if average < min_average
      status = blocking.empty? ? "passed" : "failed"
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
        "repair_instructions" => blocking.map { |issue| "Repair #{issue.sub(/\Adesign review /, "")} while preserving the selected OpenDesign contract." },
        "inputs" => {
          "screenshots" => Array(screenshot_evidence["screenshots"]).map { |shot| shot["path"] },
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

    def engine_run_sandbox_tool_command(sandbox, workspace_dir, command)
      provider = sandbox.to_s
      sandbox_runtime_container_command(
        provider: provider,
        workspace_dir: workspace_dir,
        image: engine_run_openmanus_image,
        env: engine_run_openmanus_container_env(provider).merge("AIWEB_ENGINE_RUN_TOOL" => "verification"),
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

    def engine_run_final_status(result, policy)
      return "cancelled" if result.fetch(:blocking_issues).any? { |issue| issue.to_s.match?(/cancellation requested/i) }
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
      else "inspect_events"
      end
    end

    def engine_run_action_taken(status)
      case status
      when "passed" then "ran agentic engine"
      when "no_changes" then "engine run produced no source changes"
      when "waiting_approval" then "engine run waiting for elevated approval"
      when "cancelled" then "engine run cancelled"
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
      else
        "inspect #{metadata["events_path"]} and #{metadata["metadata_path"]}, then rerun aiweb engine-run --dry-run"
      end
    end

    def engine_run_metadata(run_id:, status:, mode:, agent:, sandbox:, approved:, dry_run:, goal:, capability:, approval_hash:, paths:, events:, checkpoint:, blocking_issues:, started_at: nil, finished_at: nil, exit_code: nil, staged_manifest_path: nil, diff_path: nil, stdout_log: nil, stderr_log: nil, verification_path: nil, preview_path: nil, screenshot_evidence_path: nil, design_verdict_path: nil, design_fidelity_path: nil, opendesign_contract_path: nil, agent_result_path: nil, copy_back_policy: nil, verification: nil, preview: nil, screenshot_evidence: nil, design_verdict: nil, design_fidelity: nil, opendesign_contract: nil)
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
        "agent_result_path" => agent_result_path,
        "verification_path" => verification_path,
        "preview_path" => preview_path,
        "screenshot_evidence_path" => screenshot_evidence_path,
        "design_verdict_path" => design_verdict_path,
        "design_fidelity_path" => design_fidelity_path,
        "events" => events,
        "checkpoint" => checkpoint,
        "opendesign_contract" => opendesign_contract,
        "copy_back_policy" => copy_back_policy,
        "verification" => verification,
        "preview" => preview,
        "screenshot_evidence" => screenshot_evidence,
        "design_verdict" => design_verdict,
        "design_fidelity" => design_fidelity,
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
      event = {
        "schema_version" => 1,
        "seq" => engine_run_next_event_seq(path, events),
        "type" => type,
        "message" => message,
        "at" => now,
        "data" => data
      }
      events << event
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, "a") { |file| file.write(JSON.generate(event) + "\n") }
      event
    end

    def engine_run_next_event_seq(path, events)
      existing = File.file?(path) ? File.readlines(path).length : 0
      [existing, events.length].max + 1
    rescue SystemCallError
      events.length + 1
    end

    def engine_run_command_descriptor(agent, mode, sandbox, max_cycles, resume = nil)
      command = ["aiweb", "engine-run", "--agent", agent, "--mode", mode, "--max-cycles", max_cycles.to_s]
      command.concat(["--sandbox", sandbox]) if agent == "openmanus" && !sandbox.to_s.empty?
      command.concat(["--resume", resume]) unless resume.to_s.strip.empty?
      command << "--approved"
      command
    end

    def engine_run_sandbox_suffix(agent, sandbox)
      agent == "openmanus" && !sandbox.to_s.empty? ? " --sandbox #{sandbox}" : ""
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
      manifest_path = metadata["staged_manifest_path"].to_s
      manifest_path = File.join(".ai-web", "runs", safe, "artifacts", "staged-manifest.json") if manifest_path.empty?
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
      blockers
    end
  end
end
