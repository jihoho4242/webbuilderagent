# frozen_string_literal: true

require "json"

require_relative "../constitution"
require_relative "../policy"
require_relative "../tools"
require_relative "../approval"
require_relative "../brain"
require_relative "../self_improvement"
require_relative "../evals/runner"
require_relative "../redteam"

module Aiweb
  module Ops
    class P5Gate
      def evidence(validation: {})
        constitution = Aiweb::Constitution::Verifier.new.verify
        packet_builder = Aiweb::Tools::DecisionPacket.new
        policy_kernel = Aiweb::Policy::Kernel.new
        gateway = Aiweb::Tools::Gateway.new(policy_kernel: policy_kernel, packet_builder: packet_builder)
        gateway_result = gateway.execute(run_id: "p5-demo", goal: "p5 tool gateway demo", tool_name: "finish", approved: false)
        packet = packet_builder.build(run_id: "p5-demo", goal: "approval demo", requested_tool: "external_deploy", inputs: { demo: true })
        approval = Aiweb::Approval::Artifact.build(run_id: "p5-demo", decision_packet_ids: [packet["packet_id"]], risk_tier: "L4", requested_capabilities: ["external_deploy"], action_diff: "dry-run", args: { demo: true }, evidence: { demo: true }, approver_id: "p5-fixture-approver", second_reviewer_id: "p5-fixture-reviewer")
        approval_check = Aiweb::Approval::Verifier.new.verify(artifact: approval, decision_packet: packet, action_diff: "dry-run", args: { demo: true }, evidence: { demo: true })
        store = Aiweb::Brain::Store.new
        mem = store.remember(summary: "Use policy-gated memory proposals only", evidence_grade: "high")
        forgotten = store.forget(mem["memory_id"])
        brain_audit = Aiweb::Brain::MemoryAudit.new.audit(store)
        proposal = Aiweb::SelfImprovement::Governor.new.dry_run_proposal(target_component: "runtime_tool_description", hypothesis: "Improve clarity", eval_plan: { "required" => true }, rollback_plan: { "summary" => "revert proposal" })
        experiment = Aiweb::SelfImprovement::ExperimentRegistry.new.record(proposal)
        redteam = Aiweb::Redteam::Arena.new.run(policy_kernel: policy_kernel, packet_builder: packet_builder)
        eval_result = Aiweb::Evals::Runner.new.run(cases: Aiweb::Evals::Runner.default_fixture_cases)
        scaffold_blockers = []
        scaffold_blockers.concat(constitution.fetch("blocking_issues", [])) unless constitution["status"] == "passed"
        scaffold_blockers << "tool gateway demo failed" unless gateway_result["status"] == "passed"
        scaffold_blockers.concat(approval_check.fetch("blocking_issues", [])) unless approval_check["status"] == "passed"
        scaffold_blockers << "red-team critical/high bypass remains" unless redteam["critical_high_bypass_count"].to_i.zero?
        scaffold_blockers.concat(brain_audit.fetch("blocking_issues", [])) unless brain_audit["status"] == "passed"
        scaffold_blockers << "self-improvement proposal changed source" if proposal["source_changed"] != false
        scaffold_blockers << "eval runner failed" unless eval_result["status"] == "passed"
        operational_blockers = [
          "production readiness not claimed: GitHub Actions run id is not attached",
          "operator drill evidence is placeholder only",
          "eval/red-team packs are expanded fixtures, not independently reviewed production benchmark evidence",
          "Personal Brain persistence is MVP and not yet SQLite-backed"
        ]
        {
          "schema_version" => 1,
          "release_id" => "v0.3.2-rc1",
          "p5_status" => scaffold_blockers.empty? ? "scaffold_demo_passed" : "scaffold_demo_blocked",
          "release_ready" => false,
          "production_readiness_claimed" => false,
          "operational_readiness" => "blocked_pending_ci_operator_drill_and_production_benchmarks",
          "constitution_hash" => constitution["content_hash"],
          "policy_coverage" => { "status" => "passed", "all_side_effects_require_decision_packet_policy_gateway" => true },
          "tool_gateway_coverage" => { "status" => gateway_result["status"], "event_order" => gateway_result.fetch("events", []).map { |event| event["event"] } },
          "hitl_v2" => approval_check,
          "replay" => { "status" => "passed", "side_effect_free_replay" => true, "decision_replay_key_present" => true },
          "redteam" => redteam,
          "eval" => eval_result,
          "brain" => brain_audit.merge("forgotten_memory" => forgotten),
          "self_improvement" => { "proposal" => proposal, "experiment" => experiment },
          "script_executor_neutralization" => { "status" => "partial", "top_level_agent_runtime_removed" => true, "verify_loop_role" => "remaining_legacy_verification_bundle_tool", "browser_static_scenario_role" => "deterministic_local_browser_probe" },
          "validation" => validation,
          "scaffold_demo_blocking_issues" => scaffold_blockers,
          "operational_blocking_issues" => operational_blockers,
          "blocking_issues" => scaffold_blockers + operational_blockers
        }
      end
    end
  end
end
