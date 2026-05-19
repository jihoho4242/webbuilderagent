# frozen_string_literal: true

require "time"

module Aiweb
  module AgentRuntime
    class Executor
      def initialize(project)
        @project = project
        @gateway = Aiweb::Tools::Gateway.new
      end

      def execute(action, dry_run: true, mode: "plan-only", approved: false)
        tool = action.fetch("tool")
        return ToolResult.planned(tool, action) if dry_run
        return ToolResult.pending_approval(tool, action, mode) if approval_required?(action, mode, approved)

        gateway_result = @gateway.execute(
          run_id: "agent-runtime-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}",
          goal: action.fetch("reason", tool),
          tool_name: tool,
          inputs: action,
          expected_outputs: [action["expected_artifact"]].compact,
          approved: approved,
          paths: [action["expected_artifact"]].compact
        ) do
          execute_gateway_allowed_tool(tool, action)
        end
        merge_gateway_result(tool, gateway_result)
      end

      private

      def approval_required?(action, mode, approved)
        return false if approved == true

        action["requires_approval"] == true
      end

      def execute_gateway_allowed_tool(tool, action)
        case tool
        when "build"
          wrap_project_result(tool, @project.build(dry_run: false), "build")
        when "preview"
          wrap_project_result(tool, @project.preview(dry_run: false), "preview")
        when "browser_qa"
          wrap_project_result(tool, @project.qa_playwright(force: true, dry_run: false), "playwright_qa")
        when "local_verify"
          wrap_project_result(tool, @project.supabase_local_verify(dry_run: false), "supabase_local_verify")
        when "source_patch"
          source_patch_blocked_result(action)
        when "finish"
          { "tool" => tool, "status" => "passed", "blocking_issues" => [], "changed_files" => [] }
        else
          { "tool" => tool, "status" => "blocked", "blocking_issues" => ["agent runtime executor currently requires explicit tool-specific integration for #{tool}"] }
        end
      end

      def merge_gateway_result(tool, gateway_result)
        result = gateway_result["tool_result"].is_a?(Hash) ? gateway_result["tool_result"] : {}
        base = result.merge(
          "tool" => tool,
          "decision_packet" => gateway_result["packet"],
          "policy_decision" => gateway_result["policy_decision"],
          "tool_gateway_events" => gateway_result.fetch("events", [])
        )
        base["status"] ||= gateway_result["status"]
        base["blocking_issues"] = (Array(base["blocking_issues"]) + Array(gateway_result["blocking_issues"])).uniq
        base
      end

      def wrap_project_result(tool, payload, nested_key)
        nested = payload[nested_key].is_a?(Hash) ? payload[nested_key] : {}
        status = nested["status"] || payload["status"] || "unknown"
        {
          "tool" => tool,
          "status" => status,
          "dry_run" => false,
          "blocking_issues" => Array(payload["blocking_issues"]) + Array(nested["blocking_issues"]),
          "changed_files" => Array(payload["changed_files"]),
          "artifacts" => artifact_paths_for(payload, nested),
          "raw_result" => payload
        }
      rescue StandardError => e
        {
          "tool" => tool,
          "status" => "failed",
          "blocking_issues" => ["#{tool} raised #{e.class}: #{e.message}"],
          "errors" => [{ "class" => e.class.name, "message" => e.message }]
        }
      end

      def artifact_paths_for(payload, nested)
        keys = %w[
          metadata_path result_path stdout_log stderr_log spec_path tool_report
          run_metadata_path screenshot_metadata_path
        ]
        keys.each_with_object({}) do |key, memo|
          value = nested[key] || payload[key]
          memo[key] = value unless value.to_s.empty?
        end
      end

      def source_patch_blocked_result(action)
        {
          "tool" => "source_patch",
          "status" => "blocked",
          "blocking_issues" => [
            "source_patch requires a verifier-approved source-patch-manifest.json and is not executed implicitly by AgentRuntime"
          ],
          "action" => action
        }
      end
    end
  end
end
