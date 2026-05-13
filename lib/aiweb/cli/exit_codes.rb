# frozen_string_literal: true

module Aiweb
  class CLI
    module ExitCodes
      private

    def setup_exit_code(result)
      status = result.dig("setup", "status").to_s
      return EXIT_SUCCESS if %w[planned dry_run passed completed].include?(status)
      return EXIT_PHASE_BLOCKED if status == "blocked" && ((result.dig("setup", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ").match?(/phase|runtime-plan|readiness|initialized/i)
      return EXIT_UNSAFE_EXTERNAL_ACTION if status == "blocked" && ((result.dig("setup", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ").match?(/approved|approval|unsafe/i)

      EXIT_VALIDATION_FAILED
    end

    def agent_run_exit_code(result)
      status = result.dig("agent_run", "status").to_s
      return EXIT_SUCCESS if %w[planned dry_run passed completed].include?(status)
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)
      if status == "blocked"
        issues = ((result.dig("agent_run", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ")
        return EXIT_UNSAFE_EXTERNAL_ACTION if issues.match?(/\.env|no implementation task|task packet|safe source target|source targets?|source target|available|missing-target|missing target|required|approved|approval|unsafe|guardrail/i)
        return EXIT_PHASE_BLOCKED if issues.match?(/phase/i)
      end
      return EXIT_VALIDATION_FAILED if %w[failed no_changes].include?(status)

      EXIT_VALIDATION_FAILED
    end

    def build_exit_code(result)
      result.dig("build", "status") == "passed" || result.dig("build", "status") == "dry_run" ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def preview_exit_code(result)
      %w[dry_run running already_running stopped not_running].include?(result.dig("preview", "status")) ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def qa_playwright_exit_code(result)
      %w[dry_run passed].include?(result.dig("playwright_qa", "status")) ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def qa_screenshot_exit_code(result)
      status = result.dig("screenshot_qa", "status").to_s
      return EXIT_SUCCESS if %w[dry_run passed].include?(status)
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)

      EXIT_VALIDATION_FAILED
    end

    def qa_a11y_exit_code(result)
      %w[dry_run passed].include?(result.dig("a11y_qa", "status")) ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def qa_lighthouse_exit_code(result)
      %w[dry_run passed].include?(result.dig("lighthouse_qa", "status")) ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def visual_critique_exit_code(result)
      critique = result["visual_critique"] || {}
      status = critique["status"].to_s
      return EXIT_SUCCESS if %w[dry_run planned].include?(status)
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)
      return EXIT_VALIDATION_FAILED if status == "blocked"

      critique["approval"].to_s == "pass" ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def repair_exit_code(result)
      status = result.dig("repair_loop", "status")
      return EXIT_SUCCESS if %w[planned dry_run created reused].include?(status)
      return EXIT_VALIDATION_FAILED unless status == "blocked"

      issues = ((result.dig("repair_loop", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ")
      return EXIT_BUDGET_BLOCKED if issues.match?(/budget|cycle|cap|max-cycles|max cycles/i)
      return EXIT_PHASE_BLOCKED if issues.match?(/phase/i)

      EXIT_VALIDATION_FAILED
    end

    def visual_polish_exit_code(result)
      status = result.dig("visual_polish", "status")
      return EXIT_SUCCESS if %w[planned dry_run created reused].include?(status)
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)
      return EXIT_VALIDATION_FAILED unless status == "blocked"

      issues = ((result.dig("visual_polish", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ")
      return EXIT_BUDGET_BLOCKED if issues.match?(/budget|cycle|cap|max-cycles|max cycles/i)
      return EXIT_PHASE_BLOCKED if issues.match?(/phase/i)

      EXIT_VALIDATION_FAILED
    end

    def verify_loop_exit_code(result)
      status = result.dig("verify_loop", "status").to_s
      return EXIT_SUCCESS if %w[dry_run planned passed cancelled].include?(status)
      return EXIT_BUDGET_BLOCKED if status == "max_cycles"
      if status == "blocked"
        issues = ((result.dig("verify_loop", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ")
        return EXIT_UNSAFE_EXTERNAL_ACTION if issues.match?(/approved|approval|unsafe|\.env|deploy|provider/i)
        return EXIT_PHASE_BLOCKED if issues.match?(/phase|runtime-plan|scaffold|initialized/i)
      end
      return EXIT_VALIDATION_FAILED if status == "agent_run_failed"

      EXIT_VALIDATION_FAILED
    end

    def engine_run_exit_code(result)
      status = result.dig("engine_run", "status").to_s
      return EXIT_SUCCESS if %w[dry_run planned passed no_changes cancelled].include?(status)
      return EXIT_UNSAFE_EXTERNAL_ACTION if status == "waiting_approval"
      if status == "blocked"
        issues = ((result.dig("engine_run", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ")
        return EXIT_UNSAFE_EXTERNAL_ACTION if issues.match?(/approved|approval|unsafe|\.env|credential|secret|network|deploy|provider|git push|openmanus|image/i)
      end

      EXIT_VALIDATION_FAILED
    end

    def run_lifecycle_exit_code(result)
      status = result.dig("run_lifecycle", "status").to_s
      return EXIT_SUCCESS if %w[idle running cancel_planned cancel_requested resume_planned].include?(status)
      return EXIT_VALIDATION_FAILED if status == "blocked"

      EXIT_SUCCESS
    end

    def component_map_exit_code(result)
      status = result.dig("component_map", "status").to_s
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)
      return EXIT_SUCCESS if %w[planned discovered created ready].include?(status)
      return EXIT_PHASE_BLOCKED if status == "blocked" && ((result.dig("component_map", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ").match?(/phase/i)

      EXIT_VALIDATION_FAILED
    end

    def visual_edit_exit_code(result)
      status = result.dig("visual_edit", "status").to_s
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)
      return EXIT_SUCCESS if %w[planned created].include?(status)
      return EXIT_PHASE_BLOCKED if status == "blocked" && ((result.dig("visual_edit", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ").match?(/phase/i)

      EXIT_VALIDATION_FAILED
    end

    def github_sync_exit_code(result)
      result.dig("github_sync", "status") == "planned" ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def deploy_plan_exit_code(result)
      result.dig("deploy_plan", "status") == "planned" ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED
    end

    def deploy_exit_code(result)
      status = result.dig("deploy", "status").to_s
      return EXIT_SUCCESS if %w[planned passed].include?(status)
      issues = ((result.dig("deploy", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ")
      return EXIT_UNSAFE_EXTERNAL_ACTION if issues.match?(/unsafe.*deploy.*blocked|approved|approval|provider CLI|verify-loop|deploy output|missing/i)

      EXIT_VALIDATION_FAILED
    end

    def supabase_secret_qa_exit_code(result)
      status = result.dig("supabase_secret_qa", "status").to_s
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)
      return EXIT_SUCCESS if %w[planned dry_run passed].include?(status)
      return EXIT_PHASE_BLOCKED if status == "blocked" && ((result.dig("supabase_secret_qa", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ").match?(/phase/i)

      EXIT_VALIDATION_FAILED
    end

    def supabase_local_verify_exit_code(result)
      status = result.dig("supabase_local_verify", "status").to_s
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)
      return EXIT_SUCCESS if %w[planned dry_run passed].include?(status)
      return EXIT_PHASE_BLOCKED if status == "blocked" && ((result.dig("supabase_local_verify", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ").match?(/phase/i)

      EXIT_VALIDATION_FAILED
    end

    def workbench_exit_code(result)
      status = result.dig("workbench", "status").to_s
      return EXIT_ADAPTER_UNAVAILABLE if status == "blocked" && (result["action_taken"].to_s =~ /unavailable/)
      return EXIT_SUCCESS if %w[planned exported ready running already_running].include?(status)
      return EXIT_PHASE_BLOCKED if status == "blocked" && ((result.dig("workbench", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ").match?(/phase/i)
      return EXIT_UNSAFE_EXTERNAL_ACTION if status == "blocked" && ((result.dig("workbench", "blocking_issues") || []) + (result["blocking_issues"] || [])).join(" ").match?(/approved|unsafe|host|localhost|127\.0\.0\.1/i)

      EXIT_VALIDATION_FAILED
    end

    def exit_code_for(command, result)
      if result["validation_errors"] && !result["validation_errors"].empty?
        return EXIT_UNSAFE_EXTERNAL_ACTION if command == "design-systems"

        return EXIT_VALIDATION_FAILED
      end
      return result.dig("runtime_plan", "readiness") == "ready" ? EXIT_SUCCESS : EXIT_VALIDATION_FAILED if RUNTIME_PLAN_COMMANDS.include?(command)
      return EXIT_SUCCESS if REGISTRY_COMMANDS.include?(command) || command == "intent"
      return run_lifecycle_exit_code(result) if %w[run-status run-cancel run-resume].include?(command)
      return EXIT_SUCCESS if %w[run-timeline timeline observability-summary summary].include?(command)
      return setup_exit_code(result) if command == "setup"
      return engine_run_exit_code(result) if command == "engine-run"
      return agent_run_exit_code(result) if command == "agent-run"
      return build_exit_code(result) if command == "build"
      return preview_exit_code(result) if command == "preview"
      return qa_playwright_exit_code(result) if %w[qa-playwright browser-qa].include?(command)
      return qa_screenshot_exit_code(result) if %w[qa-screenshot screenshot-qa].include?(command)
      return qa_a11y_exit_code(result) if %w[qa-a11y a11y-qa].include?(command)
      return qa_lighthouse_exit_code(result) if %w[qa-lighthouse lighthouse-qa].include?(command)
      return visual_critique_exit_code(result) if command == "visual-critique"
      return repair_exit_code(result) if command == "repair"
      return visual_polish_exit_code(result) if command == "visual-polish"
      return verify_loop_exit_code(result) if command == "verify-loop"
      return workbench_exit_code(result) if command == "workbench"
      return component_map_exit_code(result) if command == "component-map"
      return visual_edit_exit_code(result) if command == "visual-edit"
      return github_sync_exit_code(result) if command == "github-sync"
      return deploy_plan_exit_code(result) if command == "deploy-plan"
      return deploy_exit_code(result) if command == "deploy"
      return supabase_secret_qa_exit_code(result) if command == "supabase-secret-qa"
      return supabase_local_verify_exit_code(result) if command == "supabase-local-verify"
      return EXIT_SUCCESS if %w[help version status start init interview run run-status run-timeline timeline observability-summary summary run-cancel run-resume engine-run agent-run verify-loop design-brief design-research design-system design-prompt design select-design scaffold ingest-reference ingest-design next-task qa-checklist qa-report rollback resolve-blocker snapshot visual-critique visual-polish component-map visual-edit].include?(command)
      if command == "advance" && result["action_taken"] == "advance blocked"
        issue = result["blocking_issues"].join(" ")
        return EXIT_BUDGET_BLOCKED if issue =~ /budget|candidate cap|design generation cap/i
        return EXIT_PHASE_BLOCKED
      end
      EXIT_SUCCESS
    end
    end
  end
end
