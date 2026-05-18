# frozen_string_literal: true

module Aiweb
  module ProjectVerifyLoop
    private

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

  end
end
