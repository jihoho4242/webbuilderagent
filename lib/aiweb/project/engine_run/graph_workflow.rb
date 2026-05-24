# frozen_string_literal: true

require_relative "graph_workflow/nodes"

module Aiweb
  module ProjectEngineRun
    def engine_run_graph_contract(run_id:, capability:, paths:)
      nodes = [
        ["observe_goal", "goal"],
        ["load_constitution", "policy"],
        ["build_decision_packet", "policy"],
        ["policy_check", "policy"],
        ["hitl_wait_if_required", "human_gate"],
        ["execute_tool", "tool"],
        ["verify_result", "tool"],
        ["reflect_next_step", "reflection"],
        ["write_memory_proposal", "memory"],
        ["finish_or_continue", "finalize"],
        ["preflight", "preflight"],
        ["load_design_contract", "design_contract"],
        ["stage_workspace", "filesystem"],
        ["worker_act", "worker"],
        ["verify", "tool"],
        ["preview", "tool"],
        ["observe_browser", "browser"],
        ["design_gate", "policy"],
        ["repair", "worker"],
        ["approval", "human_gate"],
        ["copy_back", "filesystem"],
        ["finalize", "finalize"]
      ].map.with_index(1) do |(id, type), index|
        {
          "node_id" => id,
          "node_type" => type,
          "ordinal" => index,
          "input_artifact_refs" => engine_run_graph_node_inputs(id, paths),
          "output_artifact_refs" => engine_run_graph_node_outputs(id, paths),
          "state" => "pending",
          "attempt" => 0,
          "retry_policy" => engine_run_graph_retry_policy(id, capability),
          "approval_policy" => engine_run_graph_approval_policy(id),
          "side_effect_boundary" => engine_run_graph_side_effect_boundary(id),
          "executor" => engine_run_graph_node_executor(id),
          "replay_policy" => engine_run_graph_node_replay_policy(id),
          "idempotency_key" => Digest::SHA256.hexdigest([run_id, id, capability["approval_hash"] || capability["goal"]].join(":")),
          "checkpoint_cursor" => "#{run_id}:#{id}:0"
        }
      end
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "constitution_hash" => Aiweb::Constitution::Loader.new.content_hash,
        "agent_os_goal_runtime_nodes" => %w[
          observe_goal
          load_constitution
          build_decision_packet
          policy_check
          hitl_wait_if_required
          execute_tool
          verify_result
          reflect_next_step
          write_memory_proposal
          finish_or_continue
        ],
        "cursor" => {
          "node_id" => "preflight",
          "state" => "pending",
          "attempt" => 0
        },
        "nodes" => nodes,
        "executor_contract" => engine_run_graph_executor_contract(nodes),
        "resume_policy" => "validate_graph_cursor_and_artifact_hashes_before_next_idempotent_node",
        "side_effects_must_use_tool_broker" => true
      }
    end

    def engine_run_graph_executor_contract(nodes)
      {
        "schema_version" => 1,
        "executor_type" => "sequential_durable_node_executor",
        "node_order" => nodes.map { |node| node.fetch("node_id") },
        "checkpoint_policy" => "persist_before_and_after_side_effect_boundaries",
        "resume_strategy" => "validate_cursor_artifact_hashes_and_continue_at_next_idempotent_node",
        "side_effect_gate" => "tool_broker_required_for_non_none_boundaries"
      }
    end

    def engine_run_graph_execution_plan(run_graph:, paths:, resume_context:)
      engine_run_graph_scheduler_runtime(run_graph: run_graph, paths: paths, resume_context: resume_context).execution_plan
    end

    def engine_run_graph_execution_start_node(node_order, cursor)
      Aiweb::GraphSchedulerRuntime.start_node(node_order, cursor)
    end

    def engine_run_graph_execution_plan_blockers(plan)
      Aiweb::GraphSchedulerRuntime.plan_blockers(plan)
    end

    def engine_run_graph_scheduler_unsupported_start_blockers(plan)
      Aiweb::GraphSchedulerRuntime.new(run_graph: {}, artifact_refs: engine_run_graph_scheduler_artifact_refs_from_plan(plan)).unsupported_start_blockers(plan)
    end

    def engine_run_write_workspace_graph_execution_plan(workspace_dir, graph_execution_plan)
      path = File.join(workspace_dir, "_aiweb", "graph-execution-plan.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, json_pretty_generate(graph_execution_plan) + "\n")
      path
    end

    def engine_run_graph_scheduler_state(run_graph:, graph_execution_plan:, paths:, resume_context:)
      engine_run_graph_scheduler_runtime(run_graph: run_graph, paths: paths, resume_context: resume_context).initial_state(graph_execution_plan)
    end

    def engine_run_graph_scheduler_reconcile!(scheduler_state, run_graph, graph_execution_plan, final_status:, paths:, events_path:, events:)
      runtime = engine_run_graph_scheduler_runtime(run_graph: run_graph, paths: paths, resume_context: nil)
      runtime.reconcile!(
        scheduler_state: scheduler_state,
        run_graph: run_graph,
        graph_execution_plan: graph_execution_plan,
        final_status: final_status,
        checkpoint_ref: relative(paths.fetch(:checkpoint_path)),
        transition_sink: lambda do |transition, node|
          engine_run_event(events_path, events, "graph.node.finished", "durable graph scheduler recorded node transition", node_id: transition["node_id"], state: transition["state"], attempt: transition["attempt"], artifact_refs: node["output_artifact_refs"])
        end
      )
      engine_run_event(events_path, events, "graph.scheduler.finished", "durable graph scheduler checkpointed state", status: final_status, cursor: scheduler_state["cursor"], artifact_path: relative(paths.fetch(:graph_scheduler_state_path)))
      scheduler_state
    end

    def engine_run_graph_scheduler_runtime(run_graph:, paths:, resume_context:)
      Aiweb::GraphSchedulerRuntime.new(
        run_graph: run_graph,
        artifact_refs: engine_run_graph_scheduler_artifact_refs(paths),
        resume_checkpoint: resume_context ? resume_context.fetch(:checkpoint) : nil,
        resume_run_id: resume_context ? resume_context.fetch(:run_id) : nil
      )
    end

    def engine_run_graph_scheduler_artifact_refs(paths)
      {
        graph_execution_plan_path: relative(paths.fetch(:graph_execution_plan_path)),
        graph_scheduler_state_path: relative(paths.fetch(:graph_scheduler_state_path)),
        checkpoint_path: relative(paths.fetch(:checkpoint_path))
      }
    end

    def engine_run_graph_scheduler_artifact_refs_from_plan(plan)
      {
        graph_execution_plan_path: plan.to_h["artifact_path"].to_s,
        graph_scheduler_state_path: plan.to_h["graph_scheduler_state_ref"].to_s,
        checkpoint_path: plan.to_h["checkpoint_ref"].to_s
      }
    end

    def engine_run_write_workspace_graph_scheduler_state(workspace_dir, graph_scheduler_state)
      path = File.join(workspace_dir, "_aiweb", "graph-scheduler-state.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, json_pretty_generate(graph_scheduler_state) + "\n")
      path
    end

    def engine_run_update_graph_state!(run_graph, final_status:, result:, policy:, verification:, preview:, screenshot_evidence:, design_verdict:, design_fidelity:, quarantine:)
      attempts = result.fetch(:cycles_completed).to_i
      %w[
        observe_goal
        load_constitution
        build_decision_packet
        policy_check
        hitl_wait_if_required
        execute_tool
        verify_result
        reflect_next_step
        write_memory_proposal
        finish_or_continue
      ].each do |node_id|
        engine_run_mark_graph_node!(run_graph, node_id, "passed", attempt: 1)
      end
      engine_run_mark_graph_node!(run_graph, "preflight", "passed", attempt: 1)
      engine_run_mark_graph_node!(run_graph, "load_design_contract", "passed", attempt: 1)
      engine_run_mark_graph_node!(run_graph, "stage_workspace", "passed", attempt: 1)
      engine_run_mark_graph_node!(run_graph, "worker_act", result.fetch(:success) ? "passed" : "failed", attempt: attempts)
      engine_run_mark_graph_node!(run_graph, "verify", engine_run_graph_status_from_artifact(verification), attempt: attempts)
      engine_run_mark_graph_node!(run_graph, "preview", engine_run_graph_status_from_artifact(preview), attempt: attempts)
      engine_run_mark_graph_node!(run_graph, "observe_browser", engine_run_graph_status_from_artifact(screenshot_evidence), attempt: attempts)
      engine_run_mark_graph_node!(run_graph, "design_gate", engine_run_design_gate_graph_status(design_verdict, design_fidelity), attempt: attempts)
      engine_run_mark_graph_node!(run_graph, "repair", attempts > 1 ? (final_status == "passed" ? "passed" : "failed") : "skipped", attempt: [attempts - 1, 0].max)
      engine_run_mark_graph_node!(run_graph, "approval", final_status == "waiting_approval" ? "waiting_approval" : "skipped", attempt: final_status == "waiting_approval" ? 1 : 0)
      copy_back_state = if %w[passed no_changes].include?(final_status)
                          "passed"
                        elsif final_status == "quarantined" || quarantine.to_h.fetch("status", nil) == "quarantined"
                          "blocked"
                        elsif policy.fetch("blocking_issues", []).empty? && policy.fetch("approval_issues", []).empty?
                          "skipped"
                        else
                          "blocked"
                        end
      engine_run_mark_graph_node!(run_graph, "copy_back", copy_back_state, attempt: %w[passed no_changes].include?(final_status) ? 1 : 0)
      engine_run_mark_graph_node!(run_graph, "finalize", "passed", attempt: 1)
    end

    def engine_run_mark_graph_node!(run_graph, node_id, state, attempt:)
      node = run_graph.fetch("nodes").find { |candidate| candidate.fetch("node_id") == node_id }
      return unless node

      node["state"] = state
      node["attempt"] = attempt
      node["finished_at"] = now if %w[passed failed skipped blocked waiting_approval].include?(state)
    end

    def engine_run_graph_status_from_artifact(artifact)
      status = artifact.to_h.fetch("status", "skipped").to_s
      case status
      when "passed", "ready", "captured", "clear" then "passed"
      when "skipped", "missing" then "skipped"
      when "blocked", "quarantined", "waiting_approval" then status
      else "failed"
      end
    end

    def engine_run_design_gate_graph_status(design_verdict, design_fidelity)
      statuses = [design_verdict.to_h.fetch("status", "skipped"), design_fidelity.to_h.fetch("status", "skipped")].map(&:to_s)
      return "failed" if statuses.any? { |status| status == "failed" || status == "repair" }
      return "blocked" if statuses.any? { |status| status == "blocked" }
      return "skipped" if statuses.all? { |status| %w[skipped missing].include?(status) }

      "passed"
    end

    def engine_run_graph_cursor_node(status)
      case status
      when "passed", "no_changes" then "finalize"
      when "waiting_approval" then "approval"
      when "quarantined" then "copy_back"
      when "blocked" then "design_gate"
      else "worker_act"
      end
    end

  end
end
