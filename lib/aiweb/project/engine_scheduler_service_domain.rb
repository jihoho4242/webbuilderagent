# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

module Aiweb
  module ProjectEngineSchedulerService
    module Domain
      private

      def engine_scheduler_action_taken(service)
        case service["decision"]
        when "no_run" then "engine scheduler idle"
        when "noop_terminal" then "recorded terminal scheduler checkpoint"
        when "blocked" then "engine scheduler blocked"
        when "resume_ready" then service["execute"] ? "executed engine scheduler resume bridge" : "recorded engine scheduler resume decision"
        else "recorded engine scheduler status"
        end
      end

      def engine_scheduler_target(run_id)
        selector = run_id.to_s.strip
        selector = "latest" if selector.empty?
        return nil if selector == "latest" && latest_run_id.to_s.empty?

        resolve_run_lifecycle_target(selector)
      rescue UserError
        nil
      end

      def engine_scheduler_service_record(action:, target:, approved:, execute:)
        selected_run = target && target["run_id"] ? run_lifecycle_record("run_id" => target.fetch("run_id")) : nil
        run_id = selected_run && selected_run["run_id"]
        checkpoint = run_id ? engine_run_resume_checkpoint(run_id) : nil
        resume_context = run_id ? engine_run_resume_context(run_id) : nil
        metadata = run_id ? (read_json_file(File.join(run_lifecycle_run_dir(run_id), "engine-run.json")) || {}) : {}
        scheduler_artifacts = engine_scheduler_artifacts(run_id, metadata)
        graph = checkpoint.to_h["run_graph"]
        cursor = checkpoint.to_h["run_graph_cursor"]
        graph_nodes = graph.is_a?(Hash) ? Array(graph["nodes"]) : []
        node_order = graph.is_a?(Hash) ? Array(graph.dig("executor_contract", "node_order")).map(&:to_s) : []
        start_node = graph.is_a?(Hash) && cursor.is_a?(Hash) ? Aiweb::GraphSchedulerRuntime.start_node(node_order, cursor) : nil
        terminal = %w[passed no_changes failed blocked quarantined cancelled].include?(metadata["status"].to_s) ||
          (start_node.to_s == "finalize" && %w[passed no_changes].include?(metadata["status"].to_s))
        resume_blockers = resume_context && !terminal ? engine_run_resume_blockers(resume_context) : []
        blockers = []
        blockers << "engine scheduler has no selected engine run" if action == "tick" && !run_id
        blockers << "engine scheduler selected run has no readable checkpoint" if run_id && !checkpoint.is_a?(Hash)
        blockers.concat(resume_blockers)
        blockers << "engine scheduler execute requires --approved" if execute && !approved
        supported_start = start_node && Aiweb::GraphSchedulerRuntime::SUPPORTED_CONTINUATION_START_NODES.include?(start_node)
        blockers << "engine scheduler start node #{start_node || "(missing)"} is not executable by the local resume bridge" if !terminal && start_node && !supported_start

        decision = if run_id.nil?
                     "no_run"
                   elsif terminal
                     "noop_terminal"
                   elsif blockers.empty?
                     "resume_ready"
                   else
                     "blocked"
                   end

        {
          "schema_version" => ENGINE_SCHEDULER_SERVICE_SCHEMA_VERSION,
          "status" => blockers.empty? ? "recorded" : "blocked",
          "service_driver" => ENGINE_SCHEDULER_SERVICE_DRIVER,
          "service_type" => "project_local_durable_graph_scheduler_service",
          "action" => action,
          "decision" => decision,
          "approved" => approved == true,
          "execute" => execute == true,
          "selected_run" => selected_run,
          "selected_run_id" => run_id,
          "service_artifact_path" => run_id ? relative(engine_scheduler_service_path(run_id)) : nil,
          "ledger_path" => ENGINE_SCHEDULER_LEDGER_PATH,
          "scheduler_artifacts" => scheduler_artifacts,
          "graph_cursor" => cursor,
          "derived_start_node_id" => start_node,
          "supported_continuation_start_nodes" => Aiweb::GraphSchedulerRuntime::SUPPORTED_CONTINUATION_START_NODES,
          "terminal_run" => terminal,
          "node_body_executor" => "engine_run_resume_bridge",
          "node_body_execution_mode" => execute ? "approved_inline_resume_bridge" : "deferred_command",
          "resume_command" => run_id ? engine_scheduler_resume_command(metadata, run_id) : [],
          "resume_blockers" => resume_blockers,
          "graph_node_summary" => graph_nodes.map { |node| node.slice("node_id", "state", "attempt", "side_effect_boundary") },
          "lease" => engine_scheduler_lease(run_id, start_node),
          "limitations" => [
            "project-local scheduler service, not a distributed worker cluster",
            "node bodies still execute through the engine-run resume bridge",
            "background daemon mode is represented by repeated tick invocations"
          ],
          "blocking_issues" => blockers.uniq
        }
      end

      def engine_scheduler_artifacts(run_id, metadata)
        return {} unless run_id

        {
          "metadata_path" => relative(File.join(run_lifecycle_run_dir(run_id), "engine-run.json")),
          "checkpoint_path" => relative(File.join(run_lifecycle_run_dir(run_id), "checkpoint.json")),
          "graph_execution_plan_path" => metadata["graph_execution_plan_path"] || relative(File.join(run_lifecycle_run_dir(run_id), "artifacts", "graph-execution-plan.json")),
          "graph_scheduler_state_path" => metadata["graph_scheduler_state_path"] || relative(File.join(run_lifecycle_run_dir(run_id), "artifacts", "graph-scheduler-state.json"))
        }
      end

      def engine_scheduler_lease(run_id, start_node)
        {
          "lease_id" => run_id && start_node ? "engine-scheduler-#{Digest::SHA256.hexdigest([run_id, start_node].join(":"))[0, 16]}" : nil,
          "run_id" => run_id,
          "start_node_id" => start_node,
          "status" => run_id ? "available" : "none",
          "created_at" => now
        }
      end

      def engine_scheduler_resume_command(metadata, run_id)
        agent = metadata["agent"].to_s.empty? ? "codex" : metadata["agent"].to_s
        mode = metadata["mode"].to_s.empty? ? "agentic_local" : metadata["mode"].to_s
        sandbox = metadata["sandbox"].to_s
        max_cycles = metadata.dig("capability", "limits", "max_cycles") || 3
        command = ["aiweb", "engine-run", "--resume", run_id, "--agent", agent, "--mode", mode, "--max-cycles", max_cycles.to_s]
        command.concat(["--sandbox", sandbox]) if agent == "openmanus" && !sandbox.empty?
        command << "--approved"
        command
      end

      def engine_scheduler_resume_kwargs(service)
        command = Array(service["resume_command"])
        {
          resume: service.fetch("selected_run_id"),
          agent: command.include?("--agent") ? command[command.index("--agent") + 1] : "codex",
          mode: command.include?("--mode") ? command[command.index("--mode") + 1] : "agentic_local",
          sandbox: command.include?("--sandbox") ? command[command.index("--sandbox") + 1] : nil,
          max_cycles: command.include?("--max-cycles") ? command[command.index("--max-cycles") + 1].to_i : 3,
          approved: true,
          force: true
        }
      end

      def engine_scheduler_service_path(run_id)
        File.join(run_lifecycle_run_dir(run_id), "artifacts", "scheduler-service.json")
      end

      def engine_scheduler_append_ledger(service)
        path = File.join(root, ENGINE_SCHEDULER_LEDGER_PATH)
        FileUtils.mkdir_p(File.dirname(path))
        entry = service.slice("schema_version", "service_driver", "action", "decision", "selected_run_id", "derived_start_node_id", "status", "blocking_issues").merge("recorded_at" => now)
        File.open(path, "a") { |file| file.write(JSON.generate(entry) + "\n") }
        ENGINE_SCHEDULER_LEDGER_PATH
      end

      def engine_scheduler_next_action(service)
        case service["decision"]
        when "no_run"
          "run aiweb engine-run --approved first, or pass --run-id to inspect a run"
        when "noop_terminal"
          "no scheduler action required for terminal run #{service["selected_run_id"]}"
        when "resume_ready"
          service["execute"] ? "inspect resumed engine-run result and scheduler ledger" : "rerun aiweb engine-scheduler tick --run-id #{service["selected_run_id"]} --approved --execute to resume through the bridge"
        else
          "inspect #{service.dig("scheduler_artifacts", "checkpoint_path")} and #{service.dig("scheduler_artifacts", "graph_scheduler_state_path")}"
        end
      end
    end
  end
end
