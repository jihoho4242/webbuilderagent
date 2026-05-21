# frozen_string_literal: true

require "digest"
require_relative "run_state/event_log"
require_relative "run_state/resume_validation"

module Aiweb
  module ProjectEngineRun
    private

    def engine_run_final_status(result, policy)
      return "cancelled" if result.fetch(:blocking_issues).any? { |issue| issue.to_s.match?(/cancellation requested/i) }
      return "quarantined" if policy["status"].to_s == "quarantined" || policy.fetch("blocking_issues").any? { |issue| issue.to_s.match?(/\Aquarantine:/i) }
      return "failed" unless result.fetch(:success)
      return "blocked" unless policy.fetch("blocking_issues").empty?
      return "waiting_approval" unless policy.fetch("approval_issues").empty?
      return "no_changes" if policy.fetch("safe_changes").empty?

      "passed"
    end

    def engine_run_checkpoint_next_step(status)
      case status
      when "passed", "no_changes" then "review_results"
      when "waiting_approval" then "review_approval_request"
      when "cancelled" then "engine-run --resume"
      when "quarantined" then "manual_quarantine_review"
      else "inspect_events"
      end
    end

    def engine_run_action_taken(status)
      case status
      when "passed" then "ran agentic engine"
      when "no_changes" then "engine run produced no source changes"
      when "waiting_approval" then "engine run waiting for elevated approval"
      when "cancelled" then "engine run cancelled"
      when "quarantined" then "engine run quarantined"
      when "blocked" then "engine run blocked"
      else "engine run failed"
      end
    end

    def engine_run_next_action(metadata)
      case metadata["status"]
      when "passed"
        "review #{metadata["metadata_path"]}, #{metadata["diff_path"]}, and the event timeline"
      when "waiting_approval"
        "review copy_back_policy approval_issues in #{metadata["metadata_path"]}; rerun only after granting the specific elevated capability"
      when "cancelled"
        "review #{metadata["checkpoint_path"]}, run aiweb engine-run --resume #{metadata["run_id"]} --dry-run to obtain the resume approval_hash, then rerun with --approval-hash HASH --approved"
      when "quarantined"
        "review redacted quarantine evidence at #{metadata["quarantine_path"]}; copy-back is blocked until manual release outside engine-run"
      else
        "inspect #{metadata["events_path"]} and #{metadata["metadata_path"]}, then rerun aiweb engine-run --dry-run"
      end
    end

    def engine_run_metadata(**attrs)
      run_id = attrs.fetch(:run_id)
      status = attrs.fetch(:status)
      mode = attrs.fetch(:mode)
      agent = attrs.fetch(:agent)
      sandbox = attrs.fetch(:sandbox)
      approved = attrs.fetch(:approved)
      dry_run = attrs.fetch(:dry_run)
      goal = attrs.fetch(:goal)
      capability = attrs.fetch(:capability)
      approval_hash = attrs.fetch(:approval_hash)
      paths = attrs.fetch(:paths)
      events = attrs.fetch(:events)
      checkpoint = attrs.fetch(:checkpoint)
      blocking_issues = attrs.fetch(:blocking_issues)
      started_at = attrs[:started_at]
      finished_at = attrs[:finished_at]
      exit_code = attrs[:exit_code]
      staged_manifest_path = attrs[:staged_manifest_path]
      diff_path = attrs[:diff_path]
      stdout_log = attrs[:stdout_log]
      stderr_log = attrs[:stderr_log]
      verification_path = attrs[:verification_path]
      preview_path = attrs[:preview_path]
      screenshot_evidence_path = attrs[:screenshot_evidence_path]
      design_verdict_path = attrs[:design_verdict_path]
      design_fidelity_path = attrs[:design_fidelity_path]
      design_fixture_path = attrs[:design_fixture_path]
      eval_benchmark_path = attrs[:eval_benchmark_path]
      supply_chain_gate_path = attrs[:supply_chain_gate_path]
      opendesign_contract_path = attrs[:opendesign_contract_path]
      project_index_path = attrs[:project_index_path]
      run_memory_path = attrs[:run_memory_path]
      authz_enforcement_path = attrs[:authz_enforcement_path]
      worker_adapter_registry_path = attrs[:worker_adapter_registry_path]
      graph_execution_plan_path = attrs[:graph_execution_plan_path]
      graph_scheduler_state_path = attrs[:graph_scheduler_state_path]
      sandbox_preflight_path = attrs[:sandbox_preflight_path]
      quarantine_path = attrs[:quarantine_path]
      agent_result_path = attrs[:agent_result_path]
      run_graph = attrs[:run_graph]
      graph_execution_plan = attrs[:graph_execution_plan]
      graph_scheduler_state = attrs[:graph_scheduler_state]
      tool_broker = attrs[:tool_broker]
      sandbox_preflight = attrs[:sandbox_preflight]
      copy_back_policy = attrs[:copy_back_policy]
      verification = attrs[:verification]
      preview = attrs[:preview]
      screenshot_evidence = attrs[:screenshot_evidence]
      design_verdict = attrs[:design_verdict]
      design_fidelity = attrs[:design_fidelity]
      design_fixture = attrs[:design_fixture]
      eval_benchmark = attrs[:eval_benchmark]
      supply_chain_gate = attrs[:supply_chain_gate]
      quarantine = attrs[:quarantine]
      opendesign_contract = attrs[:opendesign_contract]
      project_index = attrs[:project_index]
      run_memory = attrs[:run_memory]
      authz_enforcement = attrs[:authz_enforcement]
      worker_adapter_registry = attrs[:worker_adapter_registry]
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "mode" => mode,
        "agent" => agent,
        "sandbox" => sandbox,
        "approved" => approved,
        "dry_run" => dry_run,
        "goal" => goal,
        "capability" => capability,
        "approval_hash" => approval_hash,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "exit_code" => exit_code,
        "run_dir" => relative(paths.fetch(:run_dir)),
        "metadata_path" => relative(paths.fetch(:metadata_path)),
        "events_path" => relative(paths.fetch(:events_path)),
        "approval_path" => relative(paths.fetch(:approval_path)),
        "checkpoint_path" => relative(paths.fetch(:checkpoint_path)),
        "workspace_path" => relative(paths.fetch(:workspace_dir)),
        "staged_manifest_path" => staged_manifest_path,
        "opendesign_contract_path" => opendesign_contract_path,
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "diff_path" => diff_path,
        "worker_adapter_contract_path" => relative(paths.fetch(:worker_adapter_contract_path)),
        "authz_enforcement_path" => authz_enforcement_path,
        "worker_adapter_registry_path" => worker_adapter_registry_path,
        "graph_execution_plan_path" => graph_execution_plan_path,
        "graph_scheduler_state_path" => graph_scheduler_state_path,
        "agent_result_path" => agent_result_path,
        "verification_path" => verification_path,
        "preview_path" => preview_path,
        "screenshot_evidence_path" => screenshot_evidence_path,
        "design_verdict_path" => design_verdict_path,
        "design_fidelity_path" => design_fidelity_path,
        "design_fixture_path" => design_fixture_path,
        "eval_benchmark_path" => eval_benchmark_path,
        "supply_chain_gate_path" => supply_chain_gate_path,
        "sandbox_preflight_path" => sandbox_preflight_path,
        "project_index_path" => project_index_path,
        "quarantine_path" => quarantine_path,
        "events" => events,
        "checkpoint" => checkpoint,
        "run_graph" => run_graph,
        "graph_execution_plan" => graph_execution_plan,
        "graph_scheduler_state" => graph_scheduler_state,
        "tool_broker" => tool_broker,
        "authz_contract" => engine_run_authz_contract,
        "retention_redaction_policy" => engine_run_retention_redaction_policy,
        "sandbox_preflight" => sandbox_preflight,
        "project_index" => project_index,
        "run_memory_path" => run_memory_path,
        "run_memory" => run_memory,
        "authz_enforcement" => authz_enforcement,
        "worker_adapter_registry" => worker_adapter_registry,
        "opendesign_contract" => opendesign_contract,
        "copy_back_policy" => copy_back_policy,
        "verification" => verification,
        "preview" => preview,
        "screenshot_evidence" => screenshot_evidence,
        "design_verdict" => design_verdict,
        "design_fidelity" => design_fidelity,
        "design_fixture" => design_fixture,
        "eval_benchmark" => eval_benchmark,
        "supply_chain_gate" => supply_chain_gate,
        "quarantine" => quarantine,
        "blocking_issues" => blocking_issues,
        "guardrails" => [
          "host project is not writable by the agent process",
          "sandbox workspace is staged with .env, credentials, provider auth, and generated bulk directories excluded",
          "network/install/deploy/provider CLI/git push require elevated approval",
          "copy-back requires denylist, secret, binary, and writable-envelope validation",
          "web Workbench is not required for engine-run"
        ]
      }.compact
    end

    def engine_run_payload(state:, metadata:, changed_files:, planned_changes:, action_taken:, next_action:)
      payload = status_hash(state: state, changed_files: changed_files)
      payload["action_taken"] = action_taken
      payload["engine_run"] = metadata
      payload["planned_changes"] = planned_changes unless planned_changes.empty?
      payload["blocking_issues"] = (payload["blocking_issues"] + Array(metadata["blocking_issues"])).uniq
      payload["next_action"] = next_action
      payload
    end

    def engine_run_job_record(run_id:, status:, started_at:, finished_at:, events_path:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "kind" => "engine-run",
        "status" => status,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "events_path" => relative(events_path),
        "updated_at" => now
      }
    end

    def engine_run_command_descriptor(agent, mode, sandbox, max_cycles, resume = nil)
      command = ["aiweb", "engine-run", "--agent", agent, "--mode", mode, "--max-cycles", max_cycles.to_s]
      command.concat(["--sandbox", sandbox]) if engine_run_container_worker_agent?(agent) && !sandbox.to_s.empty?
      command.concat(["--resume", resume]) unless resume.to_s.strip.empty?
      command << "--approved"
      command
    end

    def engine_run_sandbox_suffix(agent, sandbox)
      engine_run_container_worker_agent?(agent) && !sandbox.to_s.empty? ? " --sandbox #{sandbox}" : ""
    end
  end
end
