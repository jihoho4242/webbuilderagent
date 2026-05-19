# frozen_string_literal: true

require "json"
require "tmpdir"

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
        l3_boolean_gateway = gateway.execute(run_id: "p5-demo", goal: "p5 l3 boolean rejection demo", tool_name: "build", approved: true)
        l3_packet = packet_builder.build(run_id: "p5-demo", goal: "p5 l3 approval artifact demo", requested_tool: "build")
        l3_action_diff = { "tool" => "build", "expected_outputs" => l3_packet.fetch("expected_outputs") }
        l3_args = { "tool" => "build", "inputs_hash" => l3_packet.fetch("inputs_hash") }
        l3_evidence = { "packet_id" => l3_packet.fetch("packet_id"), "fixture" => "p5-l3-hitl" }
        l3_approval = Aiweb::Approval::Artifact.build(run_id: "p5-demo", decision_packet_ids: [l3_packet.fetch("packet_id")], risk_tier: "L3", requested_capabilities: ["build"], action_diff: l3_action_diff, args: l3_args, evidence: l3_evidence, approver_id: "p5-fixture-approver")
        l3_artifact_gateway = gateway.execute(run_id: "p5-demo", goal: "p5 l3 approval artifact demo", tool_name: "build", decision_packet: l3_packet, approval_artifact: l3_approval, action_diff: l3_action_diff, args: l3_args, evidence: l3_evidence)
        verifier_result_gateway = gateway.execute(run_id: "p5-demo", goal: "p5 forged verifier result rejection demo", tool_name: "external_deploy", approval: { "schema_version" => 1, "status" => "passed", "approval_id" => "approval-forged", "approval_hash" => "sha256:forged", "blocking_issues" => [] })
        packet = packet_builder.build(run_id: "p5-demo", goal: "approval demo", requested_tool: "external_deploy", inputs: { demo: true })
        approval = Aiweb::Approval::Artifact.build(run_id: "p5-demo", decision_packet_ids: [packet["packet_id"]], risk_tier: "L4", requested_capabilities: ["external_deploy"], action_diff: "dry-run", args: { demo: true }, evidence: { demo: true }, approver_id: "p5-fixture-approver", second_reviewer_id: "p5-fixture-reviewer")
        approval_check = Aiweb::Approval::Verifier.new.verify(artifact: approval, decision_packet: packet, action_diff: "dry-run", args: { demo: true }, evidence: { demo: true })
        hitl_evidence = approval_check.merge(
          "fixture_status" => approval_check["status"] == "passed" ? "approval_fixture_passed" : "approval_fixture_failed",
          "production_gate_status" => "blocked",
          "production_ready_claim_allowed" => false,
          "approver_fixture_only" => true,
          "operational_blocking_issues" => [
            "production HITL evidence requires a real operator approval artifact, expiry/single-use consumption proof, and audit trail"
          ]
        )
        brain_evidence = Dir.mktmpdir("aiweb-p5-brain") do |brain_root|
          store = Aiweb::Brain::Store.new(root: brain_root)
          mem = store.remember(summary: "Use policy-gated memory proposals only", evidence_grade: "high")
          forgotten = store.forget(mem["memory_id"])
          audit = Aiweb::Brain::MemoryAudit.new.audit(store)
          {
            "audit" => audit,
            "forgotten" => forgotten,
            "storage_mode" => store.storage_mode,
            "search_projection" => Aiweb::Brain::SearchProjection.status(store),
            "ledger_event_count" => store.ledger_event_count,
            "event_hash_chain_valid" => store.event_hash_chain_valid?,
            "health_report_present" => File.file?(store.health_report_path.to_s)
          }
        end
        proposal = Aiweb::SelfImprovement::Governor.new.dry_run_proposal(target_component: "runtime_tool_description", hypothesis: "Improve clarity", eval_plan: { "required" => true }, rollback_plan: { "summary" => "revert proposal" })
        experiment = Aiweb::SelfImprovement::ExperimentRegistry.new.record(proposal)
        redteam = Aiweb::Redteam::Arena.new.run(policy_kernel: policy_kernel, packet_builder: packet_builder)
        eval_result = Aiweb::Evals::Runner.new.run(cases: Aiweb::Evals::Runner.default_fixture_cases)
        side_effect_audit = Aiweb::Project.new(Dir.pwd).send(:side_effect_surface_audit)
        scaffold_blockers = []
        scaffold_blockers.concat(constitution.fetch("blocking_issues", [])) unless constitution["status"] == "passed"
        scaffold_blockers << "tool gateway demo failed" unless gateway_result["status"] == "passed"
        scaffold_blockers << "L3 boolean approval was not rejected by ToolGateway" unless l3_boolean_gateway.dig("policy_decision", "approval_status") == "boolean_approval_rejected"
        scaffold_blockers << "L3 hash-bound approval artifact did not pass ToolGateway" unless l3_artifact_gateway.dig("policy_decision", "approval_status") == "passed"
        scaffold_blockers << "verifier-result approval hash was not rejected by ToolGateway" unless verifier_result_gateway.dig("policy_decision", "approval_status") == "blocked"
        scaffold_blockers << "side-effect surface audit has unclassified direct execution surfaces" unless side_effect_audit["coverage_status"] == "classified"
        scaffold_blockers.concat(approval_check.fetch("blocking_issues", [])) unless approval_check["status"] == "passed"
        scaffold_blockers.concat(redteam.fetch("blocking_issues", [])) unless redteam["status"] == "catalog_fixture_passed"
        brain_audit = brain_evidence.fetch("audit")
        scaffold_blockers.concat(brain_audit.fetch("blocking_issues", [])) unless brain_audit["status"] == "passed"
        brain_release_evidence = brain_audit.merge(
          "status" => brain_audit["status"] == "passed" ? "memory_safety_fixture_passed" : "memory_safety_fixture_blocked",
          "verifier_status" => brain_audit["status"],
          "storage_mode" => brain_evidence.fetch("storage_mode"),
          "ledger_event_count" => brain_evidence.fetch("ledger_event_count"),
          "event_hash_chain_valid" => brain_evidence.fetch("event_hash_chain_valid"),
          "search_projection" => brain_evidence.fetch("search_projection"),
          "health_report_present" => brain_evidence.fetch("health_report_present"),
          "production_gate_status" => "blocked",
          "production_ready_claim_allowed" => false,
          "operational_status" => "blocked"
        )
        scaffold_blockers << "self-improvement proposal changed source" if proposal["source_changed"] != false
        scaffold_blockers << "eval fixture gate failed" unless eval_result["expanded_fixture_gate_passed"] == true && eval_result["failure_count"].to_i.zero?
        tool_gateway_evidence = {
          "status" => gateway_result["status"] == "passed" ? "gateway_demo_passed" : "gateway_demo_failed",
          "verifier_status" => gateway_result["status"],
          "demo_tool" => "finish",
          "event_order" => gateway_result.fetch("events", []).map { |event| event["event"] },
          "l3_boolean_approval_rejected" => l3_boolean_gateway.dig("policy_decision", "approval_status") == "boolean_approval_rejected",
          "l3_boolean_gateway_status" => l3_boolean_gateway["status"],
          "l3_hash_bound_approval_passed" => l3_artifact_gateway.dig("policy_decision", "approval_status") == "passed",
          "l3_artifact_gateway_status" => l3_artifact_gateway["status"],
          "verifier_result_hash_rejected" => verifier_result_gateway.dig("policy_decision", "approval_status") == "blocked",
          "verifier_result_gateway_status" => verifier_result_gateway["status"],
          "production_gate_status" => "blocked",
          "production_ready_claim_allowed" => false,
          "operational_blocking_issues" => [
            "tool gateway demo exercised finish plus L3 approval gating fixtures, but full side-effect tool gateway audit is not attached to this release evidence"
          ]
        }
        policy_coverage = {
          "status" => "gateway_demo_passed",
          "coverage_status" => "unproven",
          "all_side_effects_require_decision_packet_policy_gateway" => false,
          "demo_tool" => "finish",
          "production_gate_status" => "blocked",
          "operational_blocking_issues" => [
            "static side-effect surface audit is attached, but runtime universal side-effect enforcement is not proven by this release evidence"
          ]
        }
        side_effect_surface_audit_evidence = {
          "status" => side_effect_audit["coverage_status"] == "classified" ? "static_audit_attached" : "static_audit_blocked",
          "scanner" => side_effect_audit["scanner"],
          "coverage_status" => side_effect_audit["coverage_status"],
          "entry_count" => side_effect_audit["entry_count"],
          "unclassified_count" => side_effect_audit["unclassified_count"],
          "runtime_universal_enforcement_proven" => false,
          "production_gate_status" => "blocked",
          "production_ready_claim_allowed" => false,
          "scanner_limitations" => side_effect_audit.fetch("scanner_limitations", []),
          "operational_blocking_issues" => [
            "side-effect surface audit is static classification evidence only; runtime universal enforcement still requires release-bound broker execution evidence"
          ]
        }
        replay_evidence = {
          "status" => "replay_demo_passed",
          "fixture_status" => "decision_replay_key_fixture_present",
          "production_gate_status" => "blocked",
          "side_effect_free_replay" => false,
          "side_effect_free_replay_proven" => false,
          "decision_replay_key_present" => true,
          "replay_run_attached" => false,
          "production_ready_claim_allowed" => false,
          "operational_blocking_issues" => [
            "durable replay/resume audit with artifact hash validation is not attached to this release evidence"
          ]
        }
        operational_blockers = [
          "production readiness not claimed: GitHub Actions run id is not attached",
          "operator drill evidence is placeholder only"
        ] + validation_blocking_issues(validation) + tool_gateway_evidence.fetch("operational_blocking_issues", []) + policy_coverage.fetch("operational_blocking_issues", []) + side_effect_surface_audit_evidence.fetch("operational_blocking_issues", []) + hitl_evidence.fetch("operational_blocking_issues", []) + replay_evidence.fetch("operational_blocking_issues", []) + eval_result.fetch("blocking_issues", []) + redteam.fetch("operational_blocking_issues", []) + brain_audit.fetch("operational_blocking_issues", []) + experiment.fetch("operational_blocking_issues", [])
        {
          "schema_version" => 1,
          "release_id" => "v0.3.2-rc1",
          "p5_status" => scaffold_blockers.empty? ? "scaffold_demo_passed" : "scaffold_demo_blocked",
          "release_ready" => false,
          "production_readiness_claimed" => false,
          "operational_readiness" => "blocked_pending_ci_operator_drill_and_production_benchmarks",
          "constitution_hash" => constitution["content_hash"],
          "policy_coverage" => policy_coverage,
          "side_effect_surface_audit" => side_effect_surface_audit_evidence,
          "tool_gateway_coverage" => tool_gateway_evidence,
          "hitl_v2" => hitl_evidence,
          "replay" => replay_evidence,
          "redteam" => redteam,
          "eval" => eval_result,
          "brain" => brain_release_evidence.merge("forgotten_memory" => brain_evidence.fetch("forgotten")),
          "self_improvement" => { "proposal" => proposal, "experiment" => experiment },
          "script_executor_neutralization" => { "status" => "top_level_surfaces_neutralized", "top_level_agent_runtime_removed" => true, "verify_loop_role" => "engine_run_compatibility_shim_no_fixed_pipeline", "browser_static_scenario_role" => "deterministic_local_browser_probe" },
          "validation" => validation,
          "scaffold_demo_blocking_issues" => scaffold_blockers,
          "operational_blocking_issues" => operational_blockers,
          "blocking_issues" => scaffold_blockers + operational_blockers
        }
      end

      private

      def validation_blocking_issues(validation)
        text = validation.to_s
        blockers = []
        blockers << "full ruby bin/check evidence is not attached to this release evidence" unless text.match?(/ruby bin\/check.*passed|bin_check.*passed/i)
        blockers << "full ruby -Itest test/all.rb evidence is not attached to this release evidence" unless text.match?(/test\/all\.rb.*passed|test_all.*passed/i)
        blockers
      end
    end
  end
end
