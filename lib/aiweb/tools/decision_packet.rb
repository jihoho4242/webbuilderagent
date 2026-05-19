# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "time"

require_relative "registry"
require_relative "../constitution"

module Aiweb
  module Tools
    class DecisionPacket
      POLICY_KERNEL_VERSION = "agent-os-policy-kernel-v1"

      def initialize(tool_registry: Registry.new, constitution_loader: Aiweb::Constitution::Loader.new)
        @tool_registry = tool_registry
        @constitution_loader = constitution_loader
      end

      def build(run_id:, goal:, requested_tool:, inputs: {}, expected_outputs: [], approval_requirement: nil, blockers: [])
        tool = @tool_registry.fetch(requested_tool)
        risk_tier = tool.fetch("risk_tier")
        permission_tier = tool.fetch("permission_tier")
        read_paths = Array(inputs["read_paths"] || inputs[:read_paths])
        write_paths = Array(inputs["write_paths"] || inputs[:write_paths] || expected_outputs)
        process_argv = Array(inputs["process_argv"] || inputs[:process_argv])
        network_policy = inputs["network_policy"] || inputs[:network_policy] || network_policy_for(tool)
        inputs_hash = sha(inputs)
        approval = approval_requirement || (%w[L3 L4 L5].include?(risk_tier) ? "required" : "none")
        idempotency_key = sha([
          run_id,
          requested_tool,
          inputs_hash,
          @constitution_loader.content_hash,
          @tool_registry.version
        ])
        packet_seed = [run_id, requested_tool, inputs_hash, Time.now.utc.iso8601, SecureRandom.hex(4)].join(":")
        {
          "schema_version" => 1,
          "packet_id" => "decision-packet-#{Digest::SHA256.hexdigest(packet_seed)[0, 16]}",
          "run_id" => run_id.to_s,
          "goal_hash" => sha(goal.to_s),
          "constitution_hash" => @constitution_loader.content_hash,
          "policy_kernel_version" => POLICY_KERNEL_VERSION,
          "tool_registry_version" => @tool_registry.version,
          "inputs_hash" => inputs_hash,
          "requested_tool" => requested_tool.to_s,
          "risk_tier" => risk_tier,
          "permission_tier" => permission_tier,
          "side_effect_class" => tool["side_effect_class"],
          "owner" => tool["owner"],
          "read_paths" => read_paths,
          "write_paths" => write_paths,
          "process_argv" => process_argv,
          "network_policy" => network_policy,
          "expected_outputs" => Array(expected_outputs),
          "approval_requirement" => approval,
          "idempotency_key" => idempotency_key,
          "replay_policy" => {
            "requires_artifact_hash_validation" => true,
            "side_effect_free_replay" => true,
            "decision_replay_key" => sha([run_id, requested_tool, inputs_hash])
          },
          "blockers" => Array(blockers)
        }
      end

      def valid?(packet)
        required = %w[
          schema_version packet_id run_id goal_hash constitution_hash policy_kernel_version
          tool_registry_version inputs_hash requested_tool risk_tier permission_tier read_paths write_paths process_argv network_policy expected_outputs
          approval_requirement idempotency_key replay_policy blockers
        ]
        (required - packet.keys).empty? && packet["schema_version"] == 1 && packet["idempotency_key"].to_s.start_with?("sha256:")
      end

      private

      def sha(value)
        "sha256:#{Digest::SHA256.hexdigest(value.is_a?(String) ? value : JSON.generate(value))}"
      end

      def network_policy_for(tool)
        side_effect_class = tool["side_effect_class"].to_s
        return "external_requires_approval" if side_effect_class.include?("external")
        return "localhost_only" if side_effect_class.include?("browser") || side_effect_class.include?("preview")

        "none"
      end
    end
  end
end
