# frozen_string_literal: true

module Aiweb
  module AgentRuntime
    class Executor
      def initialize(project)
        @project = project
      end

      def execute(action, dry_run: true, mode: "plan-only", approved: false)
        tool = action.fetch("tool")
        return planned_result(tool, action) if dry_run
        return pending_approval_result(tool, action, mode) if approval_required?(action, mode, approved)

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

      private

      def planned_result(tool, action)
        { "tool" => tool, "status" => "planned", "dry_run" => true, "blocking_issues" => [], "action" => action }
      end

      def approval_required?(action, mode, approved)
        return false if approved == true
        return false if mode == "autonomous-local"

        action["requires_approval"] == true
      end

      def pending_approval_result(tool, action, mode)
        {
          "tool" => tool,
          "status" => "pending_approval",
          "dry_run" => false,
          "blocking_issues" => [],
          "pending_approval" => true,
          "reason" => "#{tool} is an approved local runtime action; mode #{mode.inspect} requires --approved before execution.",
          "action" => action
        }
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
