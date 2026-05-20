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
      metadata = verify_loop_engine_shim_metadata(
        cycle_limit: cycle_limit,
        agent: implementation_agent,
        sandbox: implementation_sandbox,
        approved: approved,
        dry_run: dry_run,
        approval_hash_present: approval_hash_present,
        requested_execution: !dry_run
      )
      {
        "schema_version" => 1,
        "current_phase" => state["phase"]["current"],
        "action_taken" => verify_loop_action_taken(metadata),
        "verify_loop" => metadata,
        "changed_files" => [],
        "planned_changes" => [],
        "blocking_issues" => Array(metadata["blocking_issues"]).uniq,
        "next_action" => verify_loop_next_action(metadata),
        "dry_run" => dry_run
      }
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

    def verify_loop_engine_shim_metadata(cycle_limit:, agent:, sandbox:, approved:, dry_run:, approval_hash_present:, requested_execution:)
      execution_blocked = requested_execution
      status = if execution_blocked
                 "blocked"
               else
                 "dry_run"
               end
      blocking_issues = []
      if execution_blocked
        blocking_issues.unshift("verify-loop has been removed as an execution engine; use aiweb agent --dry-run or aiweb engine-run --dry-run directly")
      end

      {
        "schema_version" => 2,
        "status" => status,
        "canonical_runtime" => "engine-run",
        "compatibility_role" => "removed_command_tombstone",
        "removed_command" => true,
        "read_only_migration_shim" => false,
        "execution_allowed" => false,
        "engine_run_dry_run" => false,
        "engine_run_delegation_present" => false,
        "legacy_execution_removed" => true,
        "script_executor_neutralized" => true,
        "fixed_pipeline_present" => false,
        "direct_build_preview_qa_repair_loop_present" => false,
        "removed_steps" => REMOVED_VERIFY_LOOP_STEPS,
        "agent" => agent,
        "sandbox" => sandbox,
        "approved" => approved,
        "dry_run" => dry_run,
        "requires_approval" => false,
        "requires_engine_run_direct_execution" => execution_blocked,
        "max_cycles" => cycle_limit,
        "cycle_count" => 0,
        "cycles" => [],
        "steps" => [],
        "approval_hash_present" => approval_hash_present,
        "blocking_issues" => blocking_issues.uniq,
        "guardrails" => [
          "verify-loop no longer executes a hardcoded build/preview/QA/repair/agent-run script",
          "verify-loop has no engine-run delegation path",
          "local source work must enter through engine-run",
          "engine-run enforces DecisionPacket/PolicyKernel/ToolGateway and sandbox/copy-back gates",
          "dry-run writes nothing and launches nothing",
          "no deploy or provider CLI",
          "no .env or .env.* reads, writes, or output"
        ]
      }
    end

    def verify_loop_action_taken(metadata)
      return "verify-loop removed command tombstone" if metadata["dry_run"]
      return "verify-loop removed before local execution" if metadata["requires_engine_run_direct_execution"]

      "verify-loop removed command tombstone"
    end

    def verify_loop_next_action(metadata)
      agent = metadata["agent"]
      sandbox = metadata["sandbox"].to_s
      sandbox_args = agent == "openmanus" && !sandbox.empty? ? " --sandbox #{sandbox}" : ""

      "use aiweb agent \"verify and improve this local scaffold\" --mode supervised --dry-run or aiweb engine-run --agent #{agent} --mode agentic_local#{sandbox_args} --max-cycles #{metadata["max_cycles"]} --dry-run; verify-loop has been removed"
    end
  end
end
