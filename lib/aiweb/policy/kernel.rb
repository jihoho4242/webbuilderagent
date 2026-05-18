# frozen_string_literal: true

require_relative "decision_event"
require_relative "rule_registry"
require_relative "../runtime/path_policy"
require_relative "../constitution"

module Aiweb
  module Policy
    class Kernel
      VERSION = "agent-os-policy-kernel-v1"

      def initialize(constitution_verifier: Aiweb::Constitution::Verifier.new)
        @constitution_verifier = constitution_verifier
      end

      def decide(packet:, approved: false, approval: nil, paths: [])
        constitution = @constitution_verifier.verify(expected_hash: packet["constitution_hash"])
        return DecisionEvent.build(packet: packet, decision: "block", reason: constitution.fetch("blocking_issues").join("; ")) unless constitution["status"] == "passed"

        path_blocker = secret_path_blocker(paths)
        return DecisionEvent.build(packet: packet, decision: "block", reason: path_blocker) if path_blocker
        return DecisionEvent.build(packet: packet, decision: "block", reason: "decision packet has blockers: #{packet["blockers"].join("; ")}") if Array(packet["blockers"]).any?

        tier = packet.fetch("risk_tier")
        if %w[L4 L5].include?(tier)
          return DecisionEvent.build(packet: packet, decision: "approval_required", reason: "#{tier} requires HITL v2 approval") unless approved && approval_satisfied?(approval, tier)
        elsif tier == "L3"
          return DecisionEvent.build(packet: packet, decision: "approval_required", reason: "L3 local side effect requires explicit approval") unless approved
        end

        DecisionEvent.build(packet: packet, decision: "allow", reason: "policy allow for #{tier}")
      rescue StandardError => e
        fallback = packet.is_a?(Hash) ? packet : { "packet_id" => "missing", "requested_tool" => "unknown", "risk_tier" => "L5", "permission_tier" => "L5", "constitution_hash" => Aiweb::Constitution::Loader.new.content_hash, "policy_kernel_version" => VERSION }
        DecisionEvent.build(packet: fallback, decision: "block", reason: "policy kernel failure: #{e.class}: #{e.message}")
      end

      private

      def approval_satisfied?(approval, tier)
        return false unless approval.is_a?(Hash)
        return false if approval["status"] == "blocked"
        return false if %w[L4 L5].include?(tier) && approval["second_reviewer_id"].to_s.strip.empty?

        true
      end

      def secret_path_blocker(paths)
        Array(paths).each do |path|
          next if Aiweb::Runtime::PathPolicy.safe_relative_path?(path.to_s)

          return "unsafe or secret path blocked by PolicyKernel: #{path}"
        end
        nil
      end
    end
  end
end
