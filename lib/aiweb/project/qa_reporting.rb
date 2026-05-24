# frozen_string_literal: true

require_relative "qa_reporting/semantic_checks"

module Aiweb
  class Project
    private

    def qa_checklist_markdown(state)
      semantic_checks = semantic_qa_checks(state)
      <<~MD
        # QA Checklist

        Phase: #{state.dig("phase", "current")}
        Generated at: #{now}

        ## Runtime guard
        - Stop a single QA run at #{state.dig("budget", "max_qa_runtime_minutes") || 60} minutes.
        - If timed out, create F-QA-TIMEOUT, capture logs/screenshots/state, diagnose cause, generate fix packet, rerun.

        ## Semantic checks
        #{semantic_qa_items(state)}

        ## Checks
        - [ ] Mobile viewport has no horizontal scroll.
        - [ ] Tablet and desktop layouts preserve hierarchy.
        - [ ] Keyboard navigation reaches all interactive controls.
        - [ ] Color contrast appears compliant or is flagged.
        - [ ] Title, description, canonical, and OG metadata exist when public.
        - [ ] Primary CTA appears above the fold.
        - [ ] Console/network errors are captured.
        - [ ] Screenshots/evidence paths are recorded.
        #{semantic_checks.empty? ? "" : "\n## Semantic intent checks\n#{semantic_checks.map { |check| "- [ ] #{check}" }.join("\n")}\n"}
      MD
    end

    def default_qa_result(status, task_id, duration_minutes, timed_out)
      started = Time.now.utc - ((duration_minutes || 0).to_f * 60)
      {
        "schema_version" => 1,
        "task_id" => task_id.to_s.empty? ? "manual-qa" : task_id.to_s,
        "status" => status,
        "started_at" => started.iso8601,
        "finished_at" => now,
        "duration_minutes" => (duration_minutes || 0).to_f,
        "timed_out" => timed_out == true,
        "environment" => {
          "url" => "http://localhost",
          "browser" => "codex_browser",
          "browser_version" => "unknown",
          "viewport" => { "width" => 1440, "height" => 900, "name" => "desktop" },
          "commit_sha" => "unknown",
          "server_command" => "unknown"
        },
        "checks" => [],
        "evidence" => [],
        "console_errors" => [],
        "network_errors" => [],
        "recommended_action" => status == "passed" ? "advance" : "create_fix_packet",
        "created_fix_task" => nil
      }
    end

    def normalize_qa_result!(result, state)
      result["schema_version"] ||= 1
      result["task_id"] = "manual-qa" if blank?(result["task_id"])
      result["started_at"] ||= now
      result["finished_at"] ||= now
      result["duration_minutes"] = result["duration_minutes"].to_f
      result["timed_out"] = !!result["timed_out"]
      result["environment"] ||= default_qa_result("pending", result["task_id"], 0, false)["environment"]
      result["checks"] ||= []
      result["evidence"] ||= []
      result["console_errors"] ||= []
      result["network_errors"] ||= []
      result["recommended_action"] ||= "none"
      result["created_fix_task"] = nil unless result.key?("created_fix_task")
      if result["duration_minutes"].to_f > (state.dig("budget", "max_qa_runtime_minutes") || 60).to_f
        result["timed_out"] = true
      end
    end

    def qa_timeout?(result, state)
      result["timed_out"] == true || result["duration_minutes"].to_f > (state.dig("budget", "max_qa_runtime_minutes") || 60).to_f
    end

    def enforce_qa_timeout_recovery_budget!(state, result)
      return unless qa_timeout?(result, state)

      max_cycles = (state.dig("budget", "max_qa_timeout_recovery_cycles") || 3).to_i
      task_id = result["task_id"].to_s
      used = qa_timeout_recovery_cycles_used(state, task_id)
      return if used < max_cycles

      raise UserError.new(
        "QA timeout recovery budget exceeded for task #{task_id.inspect}: #{used}/#{max_cycles} F-QA-TIMEOUT cycles already recorded",
        3
      )
    end

    def qa_timeout_recovery_cycles_used(state, task_id)
      (state.dig("qa", "open_failures") || []).count do |failure|
        next false unless failure["check_id"] == "F-QA-TIMEOUT"

        failure_task = failure["task_id"]
        failure_task.nil? || failure_task.to_s == task_id.to_s
      end
    end

    def qa_failures_from_result(result, state, source_result)
      failures = []
      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      blocking_severities = %w[critical high medium]
      (result["checks"] || []).each_with_index do |check, index|
        next unless %w[failed blocked].include?(check["status"])
        next unless blocking_severities.include?(check["severity"])
        next unless blank?(check["accepted_risk_id"])
        check_id = check["id"].to_s.empty? ? "check-#{index + 1}" : check["id"]
        failures << {
          "id" => "F-QA-#{timestamp}-#{slug(check_id)}",
          "source_result" => source_result,
          "check_id" => check_id,
          "task_id" => result["task_id"],
          "severity" => check["severity"],
          "blocking" => true,
          "accepted_risk_id" => nil
        }
      end

      if qa_timeout?(result, state)
        failures << {
          "id" => "F-QA-TIMEOUT-#{timestamp}",
          "source_result" => source_result,
          "check_id" => "F-QA-TIMEOUT",
          "task_id" => result["task_id"],
          "severity" => "high",
          "blocking" => true,
          "accepted_risk_id" => nil
        }
      elsif result["status"] != "passed" && failures.empty?
        failures << {
          "id" => "F-QA-#{timestamp}-status",
          "source_result" => source_result,
          "check_id" => "QA-STATUS-#{result["status"].upcase}",
          "task_id" => result["task_id"],
          "severity" => "medium",
          "blocking" => true,
          "accepted_risk_id" => nil
        }
      end

      failures
    end

    def qa_fix_task_markdown(failures, result, state)
      primary = failures.first
      source_targets = agent_run_default_source_targets
      source_target_lines = source_targets.empty? ? "- TODO: add one safe source target before running agent-run." : source_targets.map { |path| "- `#{path}`" }.join("\n")
      machine_source_targets = source_targets.empty? ? "- TODO" : source_targets.map { |path| "- #{path}" }.join("\n")
      timeout = failures.any? { |failure| failure["check_id"] == "F-QA-TIMEOUT" }
      timeout_steps = if timeout
        <<~TXT
          ## Timeout recovery loop
          1. Capture logs, screenshots, current state, server/build output.
          2. Classify cause: server start, missing precondition, selector/wait, infinite loading/network stall, runtime/build error, oversized checklist, adapter/browser failure.
          3. Apply smallest fix.
          4. Rerun QA within #{state.dig("budget", "max_qa_runtime_minutes") || 60} minutes.
          5. Repeat up to #{state.dig("budget", "max_qa_timeout_recovery_cycles") || 3} timeout recovery cycles, then escalate blocker.
        TXT
      else
        ""
      end
      failure_list = failures.map do |failure|
        "- #{failure["id"]}: #{failure["check_id"]} (#{failure["severity"]})"
      end.join("\n")
      <<~MD
        # Task Packet — qa-fix

        Task ID: fix-#{primary["id"]}
        QA result: #{primary["source_result"]}
        Created at: #{now}

        ## Goal
        Fix the QA failure with the smallest local source patch.

        ## Inputs
        - `.ai-web/state.yaml`
        - `.ai-web/DESIGN.md`
        - `.ai-web/component-map.json`
        - `#{primary["source_result"]}`
        #{source_target_lines}

        ## Constraints
        - Do not read `.env` or `.env.*`.
        - Patch only the allowed source paths listed below.
        - Do not run package installs, deploys, provider CLIs, or network calls from agent-run.
        - Keep changes minimal and reversible.

        ## Machine Constraints
        shell_allowed: false
        network_allowed: false
        env_access_allowed: false
        requires_selected_design: true
        allowed_source_paths:
        #{machine_source_targets}

        ## Open failures
        #{failure_list}

        #{timeout_steps}
        ## Acceptance Criteria
        - Root cause is identified and documented.
        - Fix is minimal and scoped to the failed checks.
        - QA report is rerun and linked.

        ## Raw status
        #{result["status"]}
      MD
    end

    def final_qa_report_markdown(state, result, failures)
      <<~MD
        # Final QA Report

        Generated at: #{now}
        Phase: #{state.dig("phase", "current")}
        Last result: #{state.dig("qa", "last_result")}
        Status: #{result["status"]}
        Duration minutes: #{result["duration_minutes"]}
        Timed out: #{result["timed_out"]}

        ## Open failures from this result
        #{failures.empty? ? "- None" : failures.map { |failure| "- #{failure["id"]}: #{failure["check_id"]} (#{failure["severity"]})" }.join("\n")}

        ## Evidence
        #{(result["evidence"] || []).empty? ? "- None recorded" : result["evidence"].map { |item| "- #{item}" }.join("\n")}

        ## Release readiness
        #{failures.empty? ? "Ready for Gate 4 review if all other predeploy artifacts are approved." : "Not ready. Resolve open failures before Gate 4 approval."}
      MD
    end

    def rollback_markdown(invalidation)
      <<~MD
        # Rollback Decision — #{invalidation["id"]}

        Failure: #{invalidation["failure"] || "manual"}
        From phase: #{invalidation["from_phase"]}
        To phase: #{invalidation["to_phase"]}
        Created at: #{invalidation["created_at"]}

        ## Reason
        #{invalidation["reason"]}

        ## Affected tasks
        #{invalidation["affected_tasks"].map { |task| "- #{task}" }.join("\n")}
      MD
    end

  end
end
