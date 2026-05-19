# frozen_string_literal: true

require_relative "decision_event"
require_relative "rule_registry"
require_relative "../runtime/path_policy"
require_relative "../constitution"
require_relative "../approval"

module Aiweb
  module Policy
    class Kernel
      VERSION = "agent-os-policy-kernel-v1"

      def initialize(constitution_verifier: Aiweb::Constitution::Verifier.new, rule_registry: RuleRegistry.new, approval_verifier: Aiweb::Approval::Verifier.new)
        @constitution_verifier = constitution_verifier
        @rule_registry = rule_registry
        @approval_verifier = approval_verifier
      end

      def decide(packet:, approved: false, approval: nil, approval_artifact: nil, action_diff: nil, args: nil, evidence: nil, paths: [])
        registry = @rule_registry.load
        capability_matrix = @rule_registry.capability_matrix
        constitution = @constitution_verifier.verify(expected_hash: packet["constitution_hash"])
        unless constitution["status"] == "passed"
          return event(packet, "block", constitution.fetch("blocking_issues").join("; "), "constitution_hash_mismatch", "critical", "blocked")
        end

        path_blocker = secret_path_blocker(paths)
        return event(packet, "block", path_blocker, rule_for(registry, "block_secret_paths"), "critical", "blocked") if path_blocker

        scope_blocker = side_effect_scope_blocker(packet)
        return event(packet, "block", scope_blocker, "side_effect_scope_violation", "critical", "blocked") if scope_blocker

        if Array(packet["blockers"]).any?
          return event(packet, "block", "decision packet has blockers: #{packet["blockers"].join("; ")}", "packet_blockers", "critical", "blocked")
        end

        tier = packet.fetch("risk_tier")
        validate_tier!(capability_matrix, tier)
        if %w[L4 L5].include?(tier)
          approval_check = verify_approval(packet, approval_artifact || approval, action_diff, args, evidence)
          return event(packet, "approval_required", "#{tier} requires passing HITL v2 approval artifact: #{approval_check.fetch("blocking_issues", []).join("; ")}", rule_for(registry, "require_hitl_for_l4_l5"), "high", approval_check.fetch("status", "blocked")) unless approval_check["status"] == "passed"
        elsif tier == "L3"
          if approval_artifact || approval.to_h["schema_version"] == 2
            approval_check = verify_approval(packet, approval_artifact || approval, action_diff, args, evidence)
            return event(packet, "approval_required", "L3 approval artifact failed: #{approval_check.fetch("blocking_issues", []).join("; ")}", rule_for(registry, "require_approval_for_l3"), "medium", approval_check.fetch("status", "blocked")) unless approval_check["status"] == "passed"

            return event(packet, "allow", "policy allow for L3 with passing HITL v2 approval artifact", rule_for(registry, "require_approval_for_l3"), "low", approval_check.fetch("status", "passed"))
          else
            approval_status = approved ? "boolean_approval_rejected" : "missing"
            return event(packet, "approval_required", "L3 local side effect requires a hash-bound HITL v2 approval artifact; boolean approval is not sufficient", rule_for(registry, "require_approval_for_l3"), "medium", approval_status)
          end
        end

        event(packet, "allow", "policy allow for #{tier}", rule_for(registry, "allow_l0_l2_local"), tier == "L2" ? "low" : "none", "not_required")
      rescue StandardError => e
        fallback = packet.is_a?(Hash) ? packet : { "packet_id" => "missing", "requested_tool" => "unknown", "risk_tier" => "L5", "permission_tier" => "L5", "constitution_hash" => Aiweb::Constitution::Loader.new.content_hash, "policy_kernel_version" => VERSION }
        DecisionEvent.build(packet: fallback, decision: "block", reason: "policy kernel failure: #{e.class}: #{e.message}", rule_id: "policy_kernel_fail_closed", residual_risk: "critical", approval_status: "blocked")
      end

      private

      def event(packet, decision, reason, rule_id, residual_risk, approval_status)
        DecisionEvent.build(
          packet: packet,
          decision: decision,
          reason: reason,
          rule_id: rule_id,
          policy_registry_version: @rule_registry.version,
          capability_matrix_version: @rule_registry.capability_matrix_version,
          residual_risk: residual_risk,
          approval_status: approval_status
        )
      end

      def rule_for(registry, id)
        Array(registry["rules"]).find { |rule| rule["id"] == id }.to_h.fetch("id", id)
      end

      def validate_tier!(capability_matrix, tier)
        return if capability_matrix.fetch("permission_tiers").key?(tier)

        raise KeyError, "unknown permission tier #{tier}"
      end

      def verify_approval(packet, artifact, action_diff, args, evidence)
        return { "status" => "blocked", "blocking_issues" => ["approval artifact missing"] } unless artifact.is_a?(Hash)
        return artifact if artifact["schema_version"] == 1 && artifact.key?("status")

        @approval_verifier.verify(
          artifact: artifact,
          decision_packet: packet,
          action_diff: action_diff || default_action_diff(packet),
          args: args || default_approval_args(packet),
          evidence: evidence || default_approval_evidence(packet)
        )
      end

      def secret_path_blocker(paths)
        Array(paths).each do |path|
          next if Aiweb::Runtime::PathPolicy.safe_relative_path?(path.to_s)

          return "unsafe or secret path blocked by PolicyKernel: #{path}"
        end
        nil
      end

      def side_effect_scope_blocker(packet)
        network_policy = packet["network_policy"].to_s
        return "unknown network policy blocked by PolicyKernel: #{network_policy}" unless %w[none localhost_only external_requires_approval].include?(network_policy)
        if network_policy == "external_requires_approval" && !%w[L4 L5].include?(packet["risk_tier"].to_s)
          return "external network policy requires L4/L5 risk tier"
        end

        argv_text = Array(packet["process_argv"]).join(" ")
        return "process argv attempts raw environment or secret access" if argv_text.match?(/(?:\A|\s)(?:env|printenv)(?:\s|\z)|\.env/i)
        return "process argv attempts external network without L4/L5 policy" if argv_text.match?(/\b(?:curl|wget)\s+https?:/i) && network_policy != "external_requires_approval"

        nil
      end

      def default_action_diff(packet)
        {
          "requested_tool" => packet["requested_tool"],
          "inputs_hash" => packet["inputs_hash"],
          "expected_outputs" => packet["expected_outputs"]
        }
      end

      def default_approval_args(packet)
        {
          "requested_tool" => packet["requested_tool"],
          "inputs_hash" => packet["inputs_hash"],
          "idempotency_key" => packet["idempotency_key"]
        }
      end

      def default_approval_evidence(packet)
        {
          "packet_id" => packet["packet_id"],
          "constitution_hash" => packet["constitution_hash"],
          "policy_kernel_version" => packet["policy_kernel_version"]
        }
      end
    end
  end
end
