# frozen_string_literal: true

require_relative "output/runtime"
require_relative "output/webbuilding"
require_relative "output/agent"
require_relative "output/registry"

module Aiweb
  class CLI
    module Output
      private

    def help_payload
      base_payload("help", HelpText::TEXT)
    end

    def base_payload(action, message)
      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => action,
        "changed_files" => [],
        "blocking_issues" => [],
        "missing_artifacts" => [],
        "next_action" => message
      }
    end

    def emit_result(result)
      if @json
        puts JSON.pretty_generate(json_safe_value(result))
      else
        puts human_result(result)
      end
    end

    def emit_error(message, code)
      payload = {
        "schema_version" => 1,
        "status" => "error",
        "error" => { "code" => code, "message" => message },
        "blocking_issues" => [message],
        "next_action" => "fix the reported issue and rerun the command"
      }
      if @json
        puts JSON.pretty_generate(json_safe_value(payload))
      else
        warn "Error: #{message}"
        warn "Next command: #{payload["next_action"]}"
      end
      code
    end

    def json_safe_value(value)
      Aiweb::JsonSafety.safe_value(value)
    end

    def json_safe_string(value)
      Aiweb::JsonSafety.safe_string(value)
    end

    def human_result(result)
      return human_registry_result(result) if result["registry"]
      return human_intent_result(result) if result["intent"]
      return human_runtime_plan_result(result) if result["runtime_plan"]
      return human_verify_loop_result(result) if result["verify_loop"]
      return human_engine_scheduler_result(result) if result["engine_scheduler"]
      return human_mcp_broker_result(result) if result["mcp_broker"]
      return human_agent_runtime_result(result) if result["agent_runtime"]
      return human_agent_run_result(result) if result["agent_run"]
      return human_eval_baseline_result(result) if result["eval_baseline"]
      return human_repair_result(result) if result["repair_loop"]
      return human_qa_screenshot_result(result) if result["screenshot_qa"]
      return human_visual_critique_result(result) if result["visual_critique"]
      return human_visual_polish_result(result) if result["visual_polish"]
      return human_workbench_result(result) if result["workbench"]
      return human_component_map_result(result) if result["component_map"]
      return human_visual_edit_result(result) if result["visual_edit"]
      return human_supabase_local_verify_result(result) if result["supabase_local_verify"]
      return human_supabase_secret_qa_result(result) if result["supabase_secret_qa"]
      return human_setup_result(result) if result["setup"]
      return human_run_timeline_result(result) if result["run_timeline"]
      return human_observability_summary_result(result) if result["observability_summary"]
      return human_run_lifecycle_result(result) if result["run_lifecycle"]

      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = result["blocking_issues"] || []
      [
        "Current phase: #{result["current_phase"] || "n/a"}",
        "Action taken: #{result["action_taken"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    end
  end
end
