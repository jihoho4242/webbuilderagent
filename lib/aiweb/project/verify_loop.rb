# frozen_string_literal: true

module Aiweb
  module ProjectVerifyLoop
    REMOVED_VERIFY_LOOP_STEPS = %w[
      build
      preview
      qa-playwright
      qa-a11y
      qa-lighthouse
      qa-screenshot
      visual-critique
      repair
      visual-polish
      component-map
      agent-run
    ].freeze

    def verify_loop(max_cycles: 3, agent: nil, sandbox: nil, approved: false, dry_run: false, force: false, approval_hash: nil)
      assert_initialized!

      state = load_state
      ensure_implementation_state_defaults!(state)
      cycle_limit = verify_loop_cycle_limit(max_cycles)
      implementation_agent = verify_loop_agent(agent, state)
      implementation_sandbox = verify_loop_sandbox(sandbox, implementation_agent)
      approval_hash_present = !approval_hash.to_s.strip.empty?
      execute_engine = approved && approval_hash_present && !dry_run
      engine_payload = engine_run(
        goal: verify_loop_engine_goal(cycle_limit),
        agent: implementation_agent,
        mode: "agentic_local",
        sandbox: implementation_sandbox,
        max_cycles: cycle_limit,
        approved: execute_engine,
        approval_hash: approval_hash,
        dry_run: !execute_engine,
        force: force
      )

      engine = engine_payload["engine_run"].is_a?(Hash) ? engine_payload["engine_run"] : {}
      metadata = verify_loop_engine_shim_metadata(
        engine: engine,
        cycle_limit: cycle_limit,
        agent: implementation_agent,
        sandbox: implementation_sandbox,
        approved: approved,
        dry_run: dry_run,
        approval_hash_present: approval_hash_present,
        requested_execution: !dry_run
      )
      payload = engine_payload.merge(
        "action_taken" => verify_loop_action_taken(metadata),
        "verify_loop" => metadata,
        "blocking_issues" => (Array(engine_payload["blocking_issues"]) + Array(metadata["blocking_issues"])).uniq,
        "next_action" => verify_loop_next_action(metadata, engine_payload)
      )
      payload["dry_run"] = true if dry_run
      payload
    end

    private

    def verify_loop_cycle_limit(max_cycles)
      value = max_cycles.nil? || max_cycles.to_s.strip.empty? ? 3 : max_cycles.to_i
      value = value.positive? ? value : 1
      if value > self.class::VERIFY_LOOP_MAX_CYCLES
        raise UserError.new("--max-cycles must be between 1 and #{self.class::VERIFY_LOOP_MAX_CYCLES}", 1)
      end

      value
    end

    def verify_loop_agent(requested, state)
      value = requested.to_s.strip
      value = state.dig("adapters", "implementation_agent", "provider").to_s.strip if value.empty?
      value = "codex" if value.empty?
      raise UserError.new("verify-loop --agent must be codex or openmanus", 1) unless %w[codex openmanus].include?(value)

      value
    end

    def verify_loop_sandbox(requested, agent)
      value = requested.to_s.strip.downcase
      return nil if value.empty?
      raise UserError.new("verify-loop --sandbox is only supported with --agent openmanus", 1) unless agent == "openmanus"
      raise UserError.new("verify-loop --sandbox must be docker or podman", 1) unless %w[docker podman].include?(value)

      value
    end

    def verify_loop_engine_goal(cycle_limit)
      "verify and improve local web-building evidence for #{cycle_limit} engine-run cycle(s)"
    end

    def verify_loop_engine_shim_metadata(engine:, cycle_limit:, agent:, sandbox:, approved:, dry_run:, approval_hash_present:, requested_execution:)
      engine_status = engine["status"].to_s.empty? ? "unknown" : engine["status"].to_s
      approval_blocked = requested_execution && (!approved || !approval_hash_present)
      status = if approval_blocked
                 "blocked"
               else
                 engine_status
               end
      blocking_issues = Array(engine["blocking_issues"])
      if approval_blocked
        blocking_issues.unshift("--approved and --approval-hash HASH are required for local execution through engine-run")
      end

      {
        "schema_version" => 2,
        "status" => status,
        "canonical_runtime" => "engine-run",
        "compatibility_role" => "engine_run_facade",
        "legacy_execution_removed" => true,
        "script_executor_neutralized" => true,
        "fixed_pipeline_present" => false,
        "direct_build_preview_qa_repair_loop_present" => false,
        "removed_steps" => REMOVED_VERIFY_LOOP_STEPS,
        "agent" => agent,
        "sandbox" => sandbox,
        "approved" => approved,
        "dry_run" => dry_run,
        "requires_approval" => approval_blocked,
        "max_cycles" => cycle_limit,
        "cycle_count" => 0,
        "cycles" => [],
        "steps" => [],
        "engine_run" => {
          "run_id" => engine["run_id"],
          "status" => engine_status,
          "mode" => engine["mode"],
          "agent" => engine["agent"],
          "metadata_path" => engine["metadata_path"],
          "events_path" => engine["events_path"],
          "checkpoint_path" => engine["checkpoint_path"],
          "workspace_path" => engine["workspace_path"],
          "approval_hash" => engine["approval_hash"]
        }.compact,
        "approval_hash" => engine["approval_hash"],
        "blocking_issues" => blocking_issues.uniq,
        "guardrails" => [
          "verify-loop no longer executes a hardcoded build/preview/QA/repair/agent-run script",
          "local source work must enter through engine-run",
          "engine-run enforces DecisionPacket/PolicyKernel/ToolGateway and sandbox/copy-back gates",
          "dry-run writes nothing and launches nothing",
          "no deploy or provider CLI",
          "no .env or .env.* reads, writes, or output"
        ]
      }
    end

    def verify_loop_action_taken(metadata)
      return "planned engine-run verification handoff" if metadata["dry_run"]
      return "verify-loop blocked before local execution" if metadata["requires_approval"]

      "delegated verify-loop compatibility request to engine-run"
    end

    def verify_loop_next_action(metadata, engine_payload)
      approval_hash = metadata["approval_hash"].to_s
      agent = metadata["agent"]
      sandbox = metadata["sandbox"].to_s
      sandbox_args = agent == "openmanus" && !sandbox.empty? ? " --sandbox #{sandbox}" : ""
      if metadata["dry_run"] || metadata["requires_approval"]
        return "rerun aiweb verify-loop --max-cycles #{metadata["max_cycles"]} --dry-run to obtain an approval_hash before any --approved execution; verify-loop is only a compatibility shim" if approval_hash.empty?

        return "use aiweb engine-run --agent #{agent} --mode agentic_local#{sandbox_args} --max-cycles #{metadata["max_cycles"]} --approval-hash #{approval_hash} --approved; verify-loop is only a compatibility shim"
      end

      engine_payload["next_action"] || "inspect engine-run evidence"
    end
  end
end
