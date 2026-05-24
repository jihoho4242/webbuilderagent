# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    def engine_run_graph_node_inputs(node_id, paths)
      case node_id
      when "build_decision_packet", "policy_check", "hitl_wait_if_required", "execute_tool", "verify_result", "reflect_next_step"
        [relative(paths.fetch(:metadata_path))]
      when "load_design_contract"
        [relative(paths.fetch(:opendesign_contract_path))]
      when "worker_act", "verify", "preview", "observe_browser", "design_gate"
        [relative(paths.fetch(:manifest_path)), relative(paths.fetch(:opendesign_contract_path))]
      when "copy_back"
        [relative(paths.fetch(:diff_path)), relative(paths.fetch(:design_verdict_path)), relative(paths.fetch(:verification_path))]
      else
        []
      end
    end

    def engine_run_graph_node_outputs(node_id, paths)
      case node_id
      when "observe_goal", "load_constitution", "build_decision_packet", "policy_check", "hitl_wait_if_required", "execute_tool", "verify_result", "reflect_next_step", "write_memory_proposal", "finish_or_continue"
        [relative(paths.fetch(:events_path))]
      when "preflight"
        [relative(paths.fetch(:sandbox_preflight_path))]
      when "stage_workspace"
        [relative(paths.fetch(:manifest_path))]
      when "worker_act"
        [relative(paths.fetch(:agent_result_path)), relative(paths.fetch(:diff_path))]
      when "verify"
        [relative(paths.fetch(:verification_path))]
      when "preview"
        [relative(paths.fetch(:preview_path))]
      when "observe_browser"
        [relative(paths.fetch(:screenshot_evidence_path))]
      when "design_gate"
        [relative(paths.fetch(:design_fidelity_path)), relative(paths.fetch(:design_verdict_path))]
      when "finalize"
        [relative(paths.fetch(:metadata_path)), relative(paths.fetch(:checkpoint_path))]
      else
        []
      end
    end

    def engine_run_graph_retry_policy(node_id, capability)
      if %w[worker_act verify preview observe_browser design_gate repair].include?(node_id)
        { "max_attempts" => capability.dig("limits", "max_cycles").to_i.clamp(1, 10), "strategy" => "bounded_repair" }
      else
        { "max_attempts" => 1, "strategy" => "none" }
      end
    end

    def engine_run_graph_approval_policy(node_id)
      case node_id
      when "hitl_wait_if_required"
        { "required_when" => "policy_decision_requires_human_approval", "single_use" => true, "binds_decision_packet_hash" => true }
      when "approval"
        { "required_when" => "elevated_capability_requested", "single_use" => true, "binds_capability_hash" => true }
      when "copy_back"
        { "required_when" => "safe_changes_present_and_policy_passed", "single_use" => true, "binds_capability_hash" => true }
      else
        { "required_when" => "never" }
      end
    end

    def engine_run_graph_side_effect_boundary(node_id)
      case node_id
      when "execute_tool", "verify_result"
        "tool_gateway"
      when "write_memory_proposal"
        "memory_proposal_only"
      when "hitl_wait_if_required"
        "human_approval_record"
      when "worker_act", "verify", "preview", "observe_browser", "repair"
        "sandbox_tool_broker"
      when "copy_back"
        "validated_host_copy_back"
      when "approval"
        "human_approval_record"
      else
        "none"
      end
    end

    def engine_run_graph_node_executor(node_id)
      boundary = engine_run_graph_side_effect_boundary(node_id)
      {
        "executor_id" => "engine_run.#{node_id}",
        "executor_type" => "ruby_method",
        "handler" => engine_run_graph_node_handler(node_id),
        "side_effect_boundary" => boundary,
        "tool_broker_required" => boundary != "none",
        "idempotent" => !%w[worker_act repair copy_back approval].include?(node_id)
      }
    end

    def engine_run_graph_node_handler(node_id)
      {
        "observe_goal" => "engine_run_goal",
        "load_constitution" => "Aiweb::Constitution::Verifier.verify",
        "build_decision_packet" => "Aiweb::Tools::DecisionPacket.build",
        "policy_check" => "Aiweb::Policy::Kernel.decide",
        "hitl_wait_if_required" => "Aiweb::Approval::Verifier.verify_or_wait",
        "execute_tool" => "Aiweb::Tools::Gateway.execute",
        "verify_result" => "engine_run_verification_result",
        "reflect_next_step" => "engine_run_reflect_next_step",
        "write_memory_proposal" => "Aiweb::Brain::MemoryProposals.record",
        "finish_or_continue" => "engine_run_finish_or_continue",
        "preflight" => "engine_run_sandbox_preflight_evidence",
        "load_design_contract" => "engine_run_opendesign_contract",
        "stage_workspace" => "engine_run_stage_workspace",
        "worker_act" => "engine_run_execute_agentic_loop",
        "verify" => "engine_run_verification_result",
        "preview" => "engine_run_preview_result",
        "observe_browser" => "engine_run_screenshot_evidence",
        "design_gate" => "engine_run_design_verdict_result",
        "repair" => "engine_run_write_repair_observation",
        "approval" => "engine_run_approval_requests",
        "copy_back" => "engine_run_apply_safe_changes",
        "finalize" => "engine_run_metadata"
      }.fetch(node_id, "engine_run_unknown_node")
    end

    def engine_run_graph_node_replay_policy(node_id)
      boundary = engine_run_graph_side_effect_boundary(node_id)
      {
        "resume_from" => boundary == "none" ? "replay_or_next_node" : "cursor_node_after_validation",
        "requires_artifact_hash_validation" => true,
        "can_replay_without_side_effect" => boundary == "none",
        "replay_guard" => "idempotency_key_and_artifact_hash"
      }
    end

  end
end
