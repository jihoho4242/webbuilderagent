# frozen_string_literal: true

module Aiweb
  class GraphSchedulerRuntime
    SCHEDULER_TYPE = "sequential_durable_node_scheduler"
    STATE_TYPE = "sequential_durable_node_scheduler_state"
    EXECUTION_DRIVER = "aiweb.graph_scheduler.runtime.v1"
    STATE_OWNER = "graph_scheduler_runtime"
    SUPPORTED_CONTINUATION_START_NODES = %w[preflight load_design_contract stage_workspace worker_act repair].freeze
    TERMINAL_STATUSES = %w[passed failed blocked waiting_approval quarantined no_changes].freeze

    attr_reader :run_graph, :artifact_refs, :resume_checkpoint, :resume_run_id

    def initialize(run_graph:, artifact_refs:, resume_checkpoint: nil, resume_run_id: nil)
      @run_graph = run_graph
      @artifact_refs = artifact_refs
      @resume_checkpoint = resume_checkpoint
      @resume_run_id = resume_run_id
    end

    def execution_plan
      executor = run_graph.fetch("executor_contract")
      nodes = Array(run_graph.fetch("nodes"))
      nodes_by_id = nodes.to_h { |node| [node.fetch("node_id"), node] }
      node_order = Array(executor.fetch("node_order"))
      cursor = resume_checkpoint ? resume_checkpoint.to_h["run_graph_cursor"] : run_graph["cursor"]
      start_node_id = self.class.start_node(node_order, cursor)
      {
        "schema_version" => 1,
        "run_id" => run_graph.fetch("run_id"),
        "artifact_path" => artifact_refs.fetch(:graph_execution_plan_path),
        "scheduler_type" => SCHEDULER_TYPE,
        "execution_driver" => EXECUTION_DRIVER,
        "scheduler_runtime" => self.class.name,
        "state_owner" => STATE_OWNER,
        "executor_source" => "run_graph.executor_contract",
        "executor_type" => executor.fetch("executor_type"),
        "node_order" => node_order,
        "start_node_id" => start_node_id,
        "supported_continuation_start_nodes" => SUPPORTED_CONTINUATION_START_NODES,
        "resume_cursor" => cursor,
        "checkpoint_policy" => executor["checkpoint_policy"],
        "resume_strategy" => executor["resume_strategy"],
        "side_effect_gate" => executor["side_effect_gate"],
        "node_invocations" => node_order.map do |node_id|
          node = nodes_by_id.fetch(node_id)
          executor_descriptor = node.fetch("executor")
          {
            "node_id" => node_id,
            "ordinal" => node["ordinal"],
            "handler" => executor_descriptor["handler"],
            "executor_id" => executor_descriptor["executor_id"],
            "side_effect_boundary" => node["side_effect_boundary"],
            "tool_broker_required" => executor_descriptor["tool_broker_required"] == true,
            "idempotent" => executor_descriptor["idempotent"] == true,
            "replay_policy" => node["replay_policy"],
            "input_artifact_refs" => node["input_artifact_refs"],
            "output_artifact_refs" => node["output_artifact_refs"],
            "idempotency_key" => node["idempotency_key"],
            "checkpoint_cursor" => node["checkpoint_cursor"]
          }
        end,
        "validation" => {
          "node_order_matches_graph" => node_order == nodes.map { |node| node.fetch("node_id") },
          "all_handlers_present" => nodes.all? { |node| node.dig("executor", "handler").to_s.strip != "" },
          "all_side_effect_nodes_gated" => nodes.all? { |node| node["side_effect_boundary"].to_s == "none" || node.dig("executor", "tool_broker_required") == true },
          "all_replay_policies_require_artifact_hash_validation" => nodes.all? { |node| node.dig("replay_policy", "requires_artifact_hash_validation") == true },
          "runtime_owns_retry_replay_cursor_checkpoint" => true
        }
      }
    end

    def initial_state(graph_execution_plan)
      node_order = Array(graph_execution_plan.fetch("node_order"))
      run_nodes = Array(run_graph.fetch("nodes"))
      run_nodes_by_id = run_nodes.to_h { |node| [node.fetch("node_id"), node] }
      {
        "schema_version" => 1,
        "run_id" => run_graph.fetch("run_id"),
        "artifact_path" => artifact_refs.fetch(:graph_scheduler_state_path),
        "scheduler_type" => STATE_TYPE,
        "execution_driver" => EXECUTION_DRIVER,
        "scheduler_runtime" => self.class.name,
        "state_owner" => STATE_OWNER,
        "graph_execution_plan_ref" => artifact_refs.fetch(:graph_execution_plan_path),
        "executor_type" => graph_execution_plan.fetch("executor_type"),
        "start_node_id" => graph_execution_plan.fetch("start_node_id"),
        "supported_continuation_start_nodes" => SUPPORTED_CONTINUATION_START_NODES,
        "resume_from" => resume_run_id,
        "status" => "running",
        "cursor" => run_graph["cursor"],
        "checkpoint_policy" => graph_execution_plan["checkpoint_policy"],
        "resume_strategy" => graph_execution_plan["resume_strategy"],
        "checkpoint_ref" => artifact_refs.fetch(:checkpoint_path),
        "retry_replay_cursor_checkpoint_owned" => true,
        "node_execution_mode" => "delegates_node_body_to_registered_engine_handlers",
        "node_order" => node_order,
        "nodes" => node_order.map do |node_id|
          graph_node = run_nodes_by_id.fetch(node_id)
          {
            "node_id" => node_id,
            "state" => graph_node.fetch("state"),
            "attempt" => graph_node.fetch("attempt"),
            "handler" => graph_node.dig("executor", "handler"),
            "side_effect_boundary" => graph_node["side_effect_boundary"],
            "tool_broker_required" => graph_node.dig("executor", "tool_broker_required") == true,
            "idempotency_key" => graph_node["idempotency_key"],
            "input_artifact_refs" => graph_node["input_artifact_refs"],
            "output_artifact_refs" => graph_node["output_artifact_refs"]
          }
        end,
        "transitions" => [],
        "terminal_statuses" => TERMINAL_STATUSES,
        "notes" => "GraphSchedulerRuntime owns scheduler plan/state shape, resume cursor, retry/replay policy evidence, transition append, and checkpoint references. Registered engine handlers still execute node bodies."
      }
    end

    def reconcile!(scheduler_state:, run_graph:, graph_execution_plan:, final_status:, checkpoint_ref:, transition_sink: nil)
      existing = Array(scheduler_state["transitions"]).map { |transition| [transition["node_id"], transition["state"], transition["attempt"]] }
      graph_nodes_by_id = Array(run_graph.fetch("nodes")).to_h { |node| [node.fetch("node_id"), node] }
      Array(graph_execution_plan.fetch("node_order")).each do |node_id|
        node = graph_nodes_by_id.fetch(node_id)
        state = node.fetch("state")
        attempt = node.fetch("attempt")
        next if state == "pending"
        next if existing.include?([node_id, state, attempt])

        transition = {
          "seq" => Array(scheduler_state["transitions"]).length + 1,
          "node_id" => node_id,
          "state" => state,
          "attempt" => attempt,
          "handler" => node.dig("executor", "handler"),
          "side_effect_boundary" => node["side_effect_boundary"],
          "tool_broker_required" => node.dig("executor", "tool_broker_required") == true,
          "idempotency_key" => node["idempotency_key"],
          "output_artifact_refs" => node["output_artifact_refs"],
          "checkpoint_cursor" => node["checkpoint_cursor"]
        }
        scheduler_state["transitions"] << transition
        scheduler_node = Array(scheduler_state["nodes"]).find { |candidate| candidate["node_id"] == node_id }
        if scheduler_node
          scheduler_node["state"] = state
          scheduler_node["attempt"] = attempt
        end
        transition_sink.call(transition, node) if transition_sink
      end
      scheduler_state["cursor"] = run_graph["cursor"]
      scheduler_state["status"] = final_status
      scheduler_state["completed_node_count"] = Array(scheduler_state["nodes"]).count { |node| node["state"] != "pending" }
      scheduler_state["pending_node_count"] = Array(scheduler_state["nodes"]).count { |node| node["state"] == "pending" }
      scheduler_state["checkpoint_ref"] = checkpoint_ref
      scheduler_state["retry_replay_cursor_checkpoint_owned"] = true
      scheduler_state
    end

    def unsupported_start_blockers(plan)
      start_node_id = plan.to_h["start_node_id"].to_s
      return [] if SUPPORTED_CONTINUATION_START_NODES.include?(start_node_id)

      ["engine-run graph scheduler start node #{start_node_id.empty? ? "(missing)" : start_node_id} requires a dedicated continuation handler before worker execution"]
    end

    def self.plan_blockers(plan)
      validation = plan.to_h["validation"].to_h
      blockers = []
      blockers << "graph execution plan node order does not match run graph" unless validation["node_order_matches_graph"] == true
      blockers << "graph execution plan has missing handlers" unless validation["all_handlers_present"] == true
      blockers << "graph execution plan has ungated side-effect nodes" unless validation["all_side_effect_nodes_gated"] == true
      unless validation["all_replay_policies_require_artifact_hash_validation"] == true
        blockers << "graph execution plan has replay policies without artifact hash validation"
      end
      blockers << "graph scheduler runtime does not own retry/replay/cursor/checkpoint evidence" unless validation["runtime_owns_retry_replay_cursor_checkpoint"] == true
      blockers
    end

    def self.start_node(node_order, cursor)
      cursor_node = cursor.to_h["node_id"].to_s
      cursor_state = cursor.to_h["state"].to_s
      return node_order.first if cursor_node.empty?
      return cursor_node unless %w[passed skipped no_changes].include?(cursor_state)

      index = node_order.index(cursor_node)
      return node_order.first unless index

      node_order[index + 1] || cursor_node
    end
  end
end
