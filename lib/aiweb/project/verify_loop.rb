# frozen_string_literal: true

module Aiweb
  module ProjectVerifyLoop
    def verify_loop(max_cycles: 3, agent: nil, sandbox: nil, approved: false, dry_run: false, force: false)
      assert_initialized!

      state = load_state
      ensure_implementation_state_defaults!(state)
      cycle_limit = verify_loop_cycle_limit(max_cycles)
      implementation_agent = verify_loop_agent(agent, state)
      implementation_sandbox = verify_loop_sandbox(sandbox, implementation_agent)
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
      metadata = runtime_metadata_summary(scaffold)
      design = runtime_design_summary(state, metadata)
      package_json = runtime_package_json_summary
      missing_files = self.class::SCAFFOLD_PROFILE_D_REQUIRED_FILES.reject { |path| File.exist?(File.join(root, path)) }
      blockers = runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files)
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

    def verify_loop_execute_cycle(cycle, run_id:, cycle_number:, cycle_limit:, agent:, sandbox:, force:)
      if (outcome = verify_loop_cancelled_outcome(cycle, run_id))
        return outcome
      end

      build_result = verify_loop_record_step(cycle, "build") { build(dry_run: false) }
      unless verify_loop_step_passed?(build_result, "build")
        return verify_loop_step_blocked_outcome(cycle, "build", build_result, stop_reason: "build_blocked")
      end
      if (outcome = verify_loop_cancelled_outcome(cycle, run_id))
        return outcome
      end

      preview_result = verify_loop_record_step(cycle, "preview") { preview(dry_run: false) }
      unless verify_loop_step_passed?(preview_result, "preview")
        return verify_loop_step_blocked_outcome(cycle, "preview", preview_result, stop_reason: "preview_blocked")
      end
      if (outcome = verify_loop_cancelled_outcome(cycle, run_id))
        return outcome
      end

      preview_url = verify_loop_preview_url(preview_result)
      qa_results = verify_loop_run_qa_steps(cycle, preview_url, cycle_number, force)
      if (outcome = verify_loop_cancelled_outcome(cycle, run_id))
        return outcome
      end

      if (outcome = verify_loop_qa_failure_outcome(cycle, qa_results, cycle_number, cycle_limit, agent, sandbox))
        return outcome
      end

      critique_result = verify_loop_record_step(cycle, "visual-critique") { visual_critique(from_screenshots: "latest", task_id: "verify-loop-cycle-#{cycle_number}", dry_run: false) }
      if verify_loop_step_passed?(critique_result, "visual-critique")
        cycle["status"] = "passed"
        return { continue: false, final_status: "passed", stop_reason: "passed", latest_blocker: nil }
      end

      polish_result = verify_loop_record_step(cycle, "visual-polish") { visual_polish(from_critique: "latest", max_cycles: cycle_limit, dry_run: false) }
      unless verify_loop_step_passed?(polish_result, "visual-polish")
        return verify_loop_budgetable_step_blocked_outcome(cycle, "visual-polish", polish_result, budget_stop_reason: "visual_polish_budget", blocked_stop_reason: "visual_polish_blocked")
      end

      verify_loop_ensure_component_map(cycle)
      if (outcome = verify_loop_agent_run_outcome(cycle, agent, sandbox))
        return outcome
      end

      if cycle_number == cycle_limit
        return verify_loop_max_cycles_outcome(cycle, "verify-loop reached max cycles with unresolved visual critique failures")
      end

      cycle["status"] = "polished"
      { continue: true }
    end

    def verify_loop_run_qa_steps(cycle, preview_url, cycle_number, force)
      [
        verify_loop_record_step(cycle, "qa-playwright") { qa_playwright(url: preview_url, task_id: "verify-loop-cycle-#{cycle_number}-playwright", force: force, dry_run: false) },
        verify_loop_record_step(cycle, "qa-a11y") { qa_a11y(url: preview_url, task_id: "verify-loop-cycle-#{cycle_number}-a11y", force: force, dry_run: false) },
        verify_loop_record_step(cycle, "qa-lighthouse") { qa_lighthouse(url: preview_url, task_id: "verify-loop-cycle-#{cycle_number}-lighthouse", force: force, dry_run: false) },
        verify_loop_record_step(cycle, "qa-screenshot") { qa_screenshot(url: preview_url, task_id: "verify-loop-cycle-#{cycle_number}-screenshot", force: force, dry_run: false) }
      ]
    end

    def verify_loop_qa_failure_outcome(cycle, qa_results, cycle_number, cycle_limit, agent, sandbox)
      blocked_qa = qa_results.find { |result| verify_loop_step_status(result).to_s == "blocked" }
      return verify_loop_step_blocked_outcome(cycle, "qa", blocked_qa, stop_reason: "qa_blocked") if blocked_qa

      failed_qa = qa_results.find { |result| !verify_loop_step_passed?(result, "qa") }
      return nil unless failed_qa

      repair_result = verify_loop_record_step(cycle, "repair") do
        repair(from_qa: verify_loop_qa_result_path(failed_qa), max_cycles: cycle_limit, force: true, dry_run: false)
      end
      unless verify_loop_step_passed?(repair_result, "repair")
        return verify_loop_budgetable_step_blocked_outcome(cycle, "repair", repair_result, budget_stop_reason: "repair_budget", blocked_stop_reason: "repair_blocked")
      end

      verify_loop_ensure_component_map(cycle)
      if (outcome = verify_loop_agent_run_outcome(cycle, agent, sandbox))
        return outcome
      end

      if cycle_number == cycle_limit
        return verify_loop_max_cycles_outcome(cycle, "verify-loop reached max cycles with unresolved QA failures")
      end

      cycle["status"] = "repaired"
      { continue: true }
    end

    def verify_loop_agent_run_outcome(cycle, agent, sandbox)
      agent_result = verify_loop_record_step(cycle, "agent-run") { agent_run(task: "latest", agent: agent, sandbox: sandbox, approved: true, dry_run: false) }
      return nil if verify_loop_step_passed?(agent_result, "agent-run")

      verify_loop_status_outcome(
        cycle,
        status: "agent_run_failed",
        stop_reason: "agent_run_failed",
        latest_blocker: verify_loop_step_blocker("agent-run", agent_result)
      )
    end

    def verify_loop_step_blocked_outcome(cycle, step_name, result, stop_reason:)
      verify_loop_status_outcome(
        cycle,
        status: "blocked",
        stop_reason: stop_reason,
        latest_blocker: verify_loop_step_blocker(step_name, result)
      )
    end

    def verify_loop_budgetable_step_blocked_outcome(cycle, step_name, result, budget_stop_reason:, blocked_stop_reason:)
      latest_blocker = verify_loop_step_blocker(step_name, result)
      maxed = verify_loop_step_status(result) == "blocked" && latest_blocker.to_s.match?(/budget|cycle|cap/i)
      verify_loop_status_outcome(
        cycle,
        status: maxed ? "max_cycles" : "blocked",
        stop_reason: maxed ? budget_stop_reason : blocked_stop_reason,
        latest_blocker: latest_blocker
      )
    end

    def verify_loop_cancelled_outcome(cycle, run_id)
      latest_blocker = verify_loop_cancel_blocker(run_id)
      return nil unless latest_blocker

      verify_loop_status_outcome(cycle, status: "cancelled", stop_reason: "cancelled", latest_blocker: latest_blocker)
    end

    def verify_loop_max_cycles_outcome(cycle, latest_blocker)
      verify_loop_status_outcome(cycle, status: "max_cycles", stop_reason: "max_cycles", latest_blocker: latest_blocker)
    end

    def verify_loop_status_outcome(cycle, status:, stop_reason:, latest_blocker:)
      cycle["status"] = status
      cycle["blocking_issues"] << latest_blocker if latest_blocker
      { continue: false, final_status: status, stop_reason: stop_reason, latest_blocker: latest_blocker }
    end

    def verify_loop_record_step(cycle, step_name)
      result = yield
      step_path = File.join(root, cycle.fetch("cycle_dir"), "#{step_name}.json")
      write_json(step_path, result, false)
      cycle.fetch("steps") << {
        "name" => step_name,
        "status" => verify_loop_step_status(result),
        "artifact_path" => relative(step_path),
        "blocking_issues" => result["blocking_issues"] || []
      }
      result
    rescue UserError => e
      result = {
        "schema_version" => 1,
        "status" => "error",
        "action_taken" => "#{step_name} error",
        "blocking_issues" => [e.message],
        "error" => { "message" => e.message, "exit_code" => e.exit_code }
      }
      step_path = File.join(root, cycle.fetch("cycle_dir"), "#{step_name}.json")
      write_json(step_path, result, false)
      cycle.fetch("steps") << {
        "name" => step_name,
        "status" => "error",
        "artifact_path" => relative(step_path),
        "blocking_issues" => [e.message]
      }
      result
    end

    def verify_loop_step_status(result)
      return result.dig("build", "status") if result["build"].is_a?(Hash)
      return result.dig("preview", "status") if result["preview"].is_a?(Hash)
      return result.dig("playwright_qa", "status") if result["playwright_qa"].is_a?(Hash)
      return result.dig("a11y_qa", "status") if result["a11y_qa"].is_a?(Hash)
      return result.dig("lighthouse_qa", "status") if result["lighthouse_qa"].is_a?(Hash)
      return result.dig("qa_screenshot", "status") if result["qa_screenshot"].is_a?(Hash)
      return result.dig("screenshot_qa", "status") if result["screenshot_qa"].is_a?(Hash)
      return result.dig("visual_critique", "status") if result["visual_critique"].is_a?(Hash)
      return result.dig("repair_loop", "status") if result["repair_loop"].is_a?(Hash)
      return result.dig("visual_polish", "status") if result["visual_polish"].is_a?(Hash)
      return result.dig("component_map", "status") if result["component_map"].is_a?(Hash)
      return result.dig("agent_run", "status") if result["agent_run"].is_a?(Hash)

      result["status"]
    end

    def verify_loop_step_passed?(result, step_name)
      status = verify_loop_step_status(result).to_s
      case step_name
      when "build", "qa", "qa-playwright", "qa-a11y", "qa-lighthouse", "qa-screenshot"
        status == "passed"
      when "preview"
        %w[running already_running].include?(status)
      when "visual-critique"
        result.dig("visual_critique", "approval").to_s == "pass" || status == "passed"
      when "repair"
        %w[created reused].include?(status)
      when "visual-polish"
        %w[created reused].include?(status)
      when "component-map"
        %w[created discovered ready].include?(status)
      when "agent-run"
        status == "passed"
      else
        status == "passed"
      end
    end

    def verify_loop_step_blocker(step_name, result)
      issues = []
      issues.concat(result["blocking_issues"]) if result["blocking_issues"].is_a?(Array)
      %w[build preview playwright_qa a11y_qa lighthouse_qa qa_screenshot screenshot_qa visual_critique repair_loop visual_polish component_map agent_run].each do |key|
        issues.concat(result.dig(key, "blocking_issues")) if result.dig(key, "blocking_issues").is_a?(Array)
      end
      issues << "#{step_name} status #{verify_loop_step_status(result)}"
      issues.compact.map(&:to_s).reject(&:empty?).uniq.join("; ")
    end

    def verify_loop_preview_url(preview_result)
      preview_result.dig("preview", "url").to_s.empty? ? preview_result.dig("preview", "preview_url") : preview_result.dig("preview", "url")
    end

    def verify_loop_qa_result_path(result)
      result.dig("playwright_qa", "result_path") ||
        result.dig("a11y_qa", "result_path") ||
        result.dig("lighthouse_qa", "result_path") ||
        result.dig("qa_screenshot", "result_path") ||
        result.dig("screenshot_qa", "result_path") ||
        result.dig("qa_result", "artifact_path") ||
        "latest"
    end

    def verify_loop_ensure_component_map(cycle)
      return if File.file?(File.join(aiweb_dir, "component-map.json"))

      result = verify_loop_record_step(cycle, "component-map") { component_map(force: false, dry_run: false) }
      return if verify_loop_step_passed?(result, "component-map")

      raise UserError.new(verify_loop_step_blocker("component-map", result), 1)
    end

    def verify_loop_payload(state:, metadata:, changed_files:, planned_changes:, action_taken:, next_action:)
      payload = status_hash(state: state, changed_files: changed_files)
      payload["action_taken"] = action_taken
      payload["blocking_issues"] = metadata["blocking_issues"] || []
      payload["planned_changes"] = planned_changes unless planned_changes.empty?
      payload["verify_loop"] = metadata
      payload["next_action"] = next_action
      payload
    end

    def verify_loop_cancel_blocker(run_id)
      return nil unless run_cancel_requested?(run_id)

      "verify-loop cancellation requested for #{run_id}"
    end

    def verify_loop_action_taken(status)
      case status
      when "passed" then "verify loop passed"
      when "max_cycles" then "verify loop reached max cycles"
      when "cancelled" then "verify loop cancelled"
      when "agent_run_failed" then "verify loop stopped after agent-run failure"
      else "verify loop blocked"
      end
    end

    def verify_loop_next_action(metadata)
      case metadata["status"]
      when "passed"
        "review #{metadata["metadata_path"]} and continue toward deploy planning only after approval gates are satisfied"
      when "max_cycles"
        "inspect #{metadata["metadata_path"]}, review latest blocker, then rerun with a higher --max-cycles and --agent #{metadata["agent"]} only after reviewing the generated task/diff evidence"
      when "agent_run_failed"
        "inspect the cycle agent-run logs in #{metadata["run_dir"]}, then repair the task packet or source allowlist"
      when "cancelled"
        "inspect #{metadata["metadata_path"]}, then record a resume descriptor with aiweb run-resume --run-id #{metadata["run_id"]} if you want to continue"
      else
        "resolve #{metadata["latest_blocker"] || "verify-loop blockers"}, then rerun aiweb verify-loop --max-cycles #{metadata["max_cycles"]} --agent #{metadata["agent"]} --approved"
      end
    end

  end
end
