# frozen_string_literal: true

require_relative "verify_loop/execution"
require_relative "verify_loop/reporting"

module Aiweb
  module ProjectVerifyLoop
    VERIFY_LOOP_RESULT_STATUS_KEYS = %w[
      build
      preview
      playwright_qa
      a11y_qa
      lighthouse_qa
      qa_screenshot
      screenshot_qa
      visual_critique
      repair_loop
      visual_polish
      component_map
      agent_run
    ].freeze

    VERIFY_LOOP_PASSING_STATUSES = {
      "preview" => %w[running already_running],
      "repair" => %w[created reused],
      "visual-polish" => %w[created reused],
      "component-map" => %w[created discovered ready]
    }.freeze

    VERIFY_LOOP_QA_RESULT_PATH_KEYS = %w[
      playwright_qa
      a11y_qa
      lighthouse_qa
      qa_screenshot
      screenshot_qa
    ].freeze

    def verify_loop(max_cycles: 3, agent: nil, sandbox: nil, approved: false, dry_run: false, force: false)
      assert_initialized!

      state = load_state
      ensure_implementation_state_defaults!(state)
      cycle_limit = verify_loop_cycle_limit(max_cycles)
      implementation_agent = verify_loop_agent(agent, state)
      implementation_sandbox = verify_loop_sandbox(sandbox, implementation_agent)
      agent_runtime_plan = verify_loop_agent_runtime_plan(cycle_limit)
      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      run_id = "verify-loop-#{timestamp}"
      run_dir = File.join(aiweb_dir, "runs", run_id)
      metadata_path = File.join(run_dir, "verify-loop.json")
      planned_changes = verify_loop_planned_changes(run_dir, metadata_path, cycle_limit)

      unless dry_run || approved
        metadata = verify_loop_run_metadata(
          run_id: run_id,
          status: "blocked",
          max_cycles: cycle_limit,
          agent: implementation_agent,
          sandbox: implementation_sandbox,
          approved: false,
          dry_run: false,
          run_dir: run_dir,
          metadata_path: metadata_path,
          cycles: [],
          blocking_issues: ["--approved is required for real verify-loop execution"],
          latest_blocker: "--approved is required for real verify-loop execution"
        )
        metadata["agent_runtime_plan"] = agent_runtime_plan
        return verify_loop_payload(
          state: state,
          metadata: metadata,
          changed_files: [],
          planned_changes: [],
          action_taken: "verify loop blocked",
          next_action: "rerun aiweb verify-loop --max-cycles #{cycle_limit} --agent #{implementation_agent}#{verify_loop_sandbox_suffix(implementation_agent, implementation_sandbox)} --dry-run to inspect the plan or aiweb verify-loop --max-cycles #{cycle_limit} --agent #{implementation_agent}#{verify_loop_sandbox_suffix(implementation_agent, implementation_sandbox, default_openmanus: true)} --approved to execute locally"
        )
      end

      if dry_run
        metadata = verify_loop_run_metadata(
          run_id: run_id,
          status: "dry_run",
          max_cycles: cycle_limit,
          agent: implementation_agent,
          sandbox: implementation_sandbox,
          approved: approved,
          dry_run: true,
          run_dir: run_dir,
          metadata_path: metadata_path,
          cycles: [],
          blocking_issues: [],
          latest_blocker: nil
        )
        metadata["agent_runtime_plan"] = agent_runtime_plan
        metadata["planned_steps"] = verify_loop_planned_steps(cycle_limit)
        metadata["steps"] = metadata.fetch("planned_steps").flat_map do |cycle|
          Array(cycle["steps"]).map { |step| { "cycle" => cycle["cycle"], "name" => step, "command" => step } }
        end
        return verify_loop_payload(
          state: state,
          metadata: metadata,
          changed_files: [],
          planned_changes: planned_changes,
          action_taken: "planned verify loop",
          next_action: "rerun aiweb verify-loop --max-cycles #{cycle_limit} --agent #{implementation_agent}#{verify_loop_sandbox_suffix(implementation_agent, implementation_sandbox, default_openmanus: true)} --approved to execute the local closed loop"
        )
      end

      dependency_blockers = verify_loop_dependency_blockers
      unless dependency_blockers.empty?
        metadata = verify_loop_run_metadata(
          run_id: run_id,
          status: "blocked",
          max_cycles: cycle_limit,
          agent: implementation_agent,
          sandbox: implementation_sandbox,
          approved: true,
          dry_run: false,
          run_dir: run_dir,
          metadata_path: metadata_path,
          cycles: [],
          blocking_issues: dependency_blockers,
          latest_blocker: dependency_blockers.first
        )
        metadata["agent_runtime_plan"] = agent_runtime_plan
        return verify_loop_payload(
          state: state,
          metadata: metadata,
          changed_files: [],
          planned_changes: [],
          action_taken: "verify loop blocked",
          next_action: "resolve local runtime dependencies with aiweb setup --install --approved, then rerun aiweb verify-loop --max-cycles #{cycle_limit} --agent #{implementation_agent}#{verify_loop_sandbox_suffix(implementation_agent, implementation_sandbox, default_openmanus: true)} --approved"
        )
      end

      active_record = active_run_begin!(
        kind: "verify-loop",
        run_id: run_id,
        run_dir: run_dir,
        metadata_path: metadata_path,
        command: ["aiweb", "verify-loop", "--max-cycles", cycle_limit.to_s, "--agent", implementation_agent, *verify_loop_sandbox_argv(implementation_agent, implementation_sandbox), "--approved"],
        force: force
      )
      begin
        FileUtils.mkdir_p(run_dir)
        changed_files = [relative(run_dir)]
        cycles = []
        final_status = "max_cycles"
        latest_blocker = nil
        stop_reason = "max_cycles"

        cycle_limit.times do |index|
          cycle_number = index + 1
          cycle = verify_loop_start_cycle(run_dir, cycle_number, changed_files, cycles)
          outcome = verify_loop_execute_cycle(
            cycle,
            run_id: run_id,
            cycle_number: cycle_number,
            cycle_limit: cycle_limit,
            agent: implementation_agent,
            sandbox: implementation_sandbox,
            force: force
          )
          next if outcome[:continue]

          final_status = outcome.fetch(:final_status)
          stop_reason = outcome.fetch(:stop_reason)
          latest_blocker = outcome[:latest_blocker]
          break
        end

        state = load_state
        ensure_implementation_state_defaults!(state)
        provenance = deploy_workspace_provenance(state, include_tool_versions: true)

        metadata = verify_loop_run_metadata(
          run_id: run_id,
          status: final_status,
          max_cycles: cycle_limit,
          agent: implementation_agent,
          sandbox: implementation_sandbox,
          approved: true,
          dry_run: false,
          run_dir: run_dir,
          metadata_path: metadata_path,
          cycles: cycles,
          blocking_issues: latest_blocker ? [latest_blocker] : [],
          latest_blocker: latest_blocker,
          provenance: provenance
        )
        metadata["stop_reason"] = stop_reason
        metadata["cycle_count"] = cycles.length
        metadata["agent_runtime_plan"] = agent_runtime_plan
        changed_files << write_json(metadata_path, metadata, false)

        state["implementation"]["latest_verify_loop"] = relative(metadata_path)
        state["implementation"]["verify_loop_status"] = final_status
        state["implementation"]["verify_loop_cycle_count"] = cycles.length
        state["implementation"]["latest_blocker"] = latest_blocker
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changed_files << write_yaml(state_path, state, false)

        result = verify_loop_payload(
          state: state,
          metadata: metadata,
          changed_files: compact_changes(changed_files),
          planned_changes: [],
          action_taken: verify_loop_action_taken(final_status),
          next_action: verify_loop_next_action(metadata)
        )
        active_run_finish!(active_record, final_status)
        active_record = nil
        result
      ensure
        active_run_finish!(active_record, "failed") if active_record
      end
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

    def verify_loop_sandbox_suffix(agent, sandbox, default_openmanus: false)
      return "" unless agent == "openmanus"

      chosen = sandbox.to_s.empty? && default_openmanus ? "docker" : sandbox.to_s
      chosen.empty? ? "" : " --sandbox #{chosen}"
    end

    def verify_loop_sandbox_argv(agent, sandbox)
      agent == "openmanus" && !sandbox.to_s.empty? ? ["--sandbox", sandbox] : []
    end

    def verify_loop_planned_steps(cycle_limit)
      (1..cycle_limit).map do |cycle|
        {
          "cycle" => cycle,
          "steps" => %w[
            build
            preview
            qa-playwright
            qa-a11y
            qa-lighthouse
            qa-screenshot
            visual-critique
            failure-analysis
            repair-or-visual-polish
            agent-run
          ],
          "writes_planned" => true,
          "processes_planned" => true
        }
      end
    end

    def verify_loop_planned_changes(run_dir, metadata_path, cycle_limit)
      changes = [relative(run_dir), relative(metadata_path)]
      (1..cycle_limit).each do |cycle|
        cycle_dir = File.join(run_dir, "cycle-#{cycle}")
        changes << relative(cycle_dir)
        %w[build preview qa-playwright qa-a11y qa-lighthouse qa-screenshot visual-critique repair visual-polish component-map agent-run].each do |step|
          changes << relative(File.join(cycle_dir, "#{step}.json"))
        end
      end
      compact_changes(changes)
    end

    def verify_loop_dependency_blockers
      state, state_error = runtime_state_snapshot
      ensure_scaffold_state_defaults!(state) if state
      scaffold = runtime_scaffold_summary(state)
      contract = runtime_profile_contract(scaffold)
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary(contract)
      missing_files = runtime_missing_required_files(contract)
      blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files, contract)
      blockers.concat(runtime_capability_blockers(contract, :build))
      blockers.concat(runtime_capability_blockers(contract, :preview))
      blockers.concat(runtime_capability_blockers(contract, :browser_qa))
      blockers << "pnpm executable is missing; run aiweb setup --install --approved after installing pnpm locally, then rerun verify-loop." if executable_path("pnpm").nil?
      blockers << "node_modules is missing; run aiweb setup --install --approved before verify-loop." unless File.directory?(File.join(root, "node_modules"))
      {
        "playwright" => qa_playwright_executable_path,
        "axe" => qa_static_executable_path("axe"),
        "lighthouse" => qa_static_executable_path("lighthouse")
      }.each do |tool, path|
        blockers << "local #{tool} executable is missing under node_modules/.bin; run aiweb setup --install --approved before verify-loop." if path.nil?
      end
      blockers.compact.uniq
    end

    def verify_loop_agent_runtime_plan(cycle_limit)
      Aiweb::AgentRuntime::Loop.new(self).run(
        goal: "verify local web-building loop for #{cycle_limit} cycle(s)",
        mode: "plan-only",
        profile: nil,
        max_steps: cycle_limit,
        approved: false,
        dry_run: true
      ).fetch("agent_runtime")
    rescue StandardError => e
      {
        "status" => "blocked",
        "blocking_issues" => ["AgentRuntime plan unavailable: #{e.class}: #{e.message}"]
      }
    end

    def verify_loop_run_metadata(run_id:, status:, max_cycles:, agent:, sandbox:, approved:, dry_run:, run_dir:, metadata_path:, cycles:, blocking_issues:, latest_blocker:, provenance: nil)
      metadata = {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "agent" => agent,
        "sandbox" => sandbox,
        "approved" => approved,
        "dry_run" => dry_run,
        "requires_approval" => !approved && !dry_run,
        "max_cycles" => max_cycles,
        "cycle_count" => cycles.length,
        "run_dir" => relative(run_dir),
        "metadata_path" => relative(metadata_path),
        "cycles" => cycles,
        "latest_blocker" => latest_blocker,
        "blocking_issues" => blocking_issues,
        "guardrails" => [
          "no package install inside verify-loop",
          "no deploy or provider CLI",
          "approved local process execution only",
          "dry-run writes nothing and launches nothing",
          "no .env or .env.* reads, writes, or output"
        ]
      }
      metadata["provenance"] = provenance if provenance
      metadata
    end

    def verify_loop_cycle_record(cycle_number, cycle_dir)
      {
        "cycle" => cycle_number,
        "status" => "running",
        "cycle_dir" => relative(cycle_dir),
        "steps" => [],
        "blocking_issues" => []
      }
    end


    def verify_loop_start_cycle(run_dir, cycle_number, changed_files, cycles)
      cycle_dir = File.join(run_dir, "cycle-#{cycle_number}")
      FileUtils.mkdir_p(cycle_dir)
      changed_files << relative(cycle_dir)
      cycle = verify_loop_cycle_record(cycle_number, cycle_dir)
      cycles << cycle
      cycle
    end


  end
end
