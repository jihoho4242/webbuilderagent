# frozen_string_literal: true

require "fileutils"
require "time"

module Aiweb
  module AgentRuntime
    class ArtifactWriter
      def initialize(project)
        @project = project
      end

      def write(session:, observation:, plan:, tool_results:, verification:, reflection:, report:, contract:)
        store = Aiweb::Runtime::ArtifactStore.new(root: @project.root, run_id: session.run_id)
        FileUtils.mkdir_p(session.run_dir)
        writes = []
        writes << store.write_json("agent-session.json", session.to_h(status: reflection.fetch("status"), stop_reason: reflection.fetch("stop_reason"), profile_contract: contract))
        writes << store.write_json("observation.json", observation)
        writes << store.write_json("plan.json", plan)
        writes << store.write_json("verification.json", verification)
        writes << store.write_json("reflection.json", reflection)
        writes << store.write_json("source-patch-manifest.json", report.fetch("patchManifest"))
        writes << store.write_json("browser-qa-feedback.json", report.fetch("browserQa"))
        writes << store.write_json("final-report.json", report)
        writes << store.write_jsonl("timeline.jsonl", timeline_events(observation, plan, verification, reflection))
        tool_results.each_with_index do |tool_result, index|
          writes << store.write_json("tool-result-#{index + 1}.json", tool_result)
        end
        writes
      end

      def write_state_pointer(session, report, status)
        state = @project.load_state
        @project.send(:ensure_implementation_state_defaults!, state)
        state["implementation"]["latest_agent_runtime"] = File.join(session.relative_run_dir, "final-report.json").tr("\\", "/")
        state["implementation"]["agent_runtime_status"] = status
        state["implementation"]["agent_runtime_run_id"] = session.run_id
        state["implementation"]["agent_runtime_mode"] = session.mode
        state["implementation"]["agent_runtime_profile"] = report["profile"]
        state["project"]["updated_at"] = @project.send(:now) if state["project"].is_a?(Hash)
        [@project.send(:write_yaml, @project.send(:state_path), state, false)]
      rescue StandardError => e
        [File.join(session.relative_run_dir, "state-pointer-error.txt").tr("\\", "/")].tap do
          warn "agent runtime state pointer skipped: #{e.class}: #{e.message}" if $VERBOSE
        end
      end

      private

      def timeline_events(observation, plan, verification, reflection)
        now = Time.now.utc.iso8601
        [
          { "event" => "observe", "at" => now, "status" => observation.dig("runtime_plan", "readiness") },
          { "event" => "plan", "at" => now, "actions" => plan.fetch("planned_actions") },
          { "event" => "act", "at" => now, "planned_action_count" => plan.fetch("planned_actions").length },
          { "event" => "verify", "at" => now, "status" => verification.fetch("status") },
          { "event" => "reflect", "at" => now, "status" => reflection.fetch("status"), "stop_reason" => reflection.fetch("stop_reason") }
        ]
      end
    end
  end
end
