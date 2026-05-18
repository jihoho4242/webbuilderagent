# frozen_string_literal: true

require "time"

require_relative "decision_packet"
require_relative "registry"
require_relative "../policy"

module Aiweb
  module Tools
    class Gateway
      def initialize(policy_kernel: Aiweb::Policy::Kernel.new, packet_builder: DecisionPacket.new)
        @policy_kernel = policy_kernel
        @packet_builder = packet_builder
      end

      def execute(run_id:, goal:, tool_name:, inputs: {}, expected_outputs: [], approved: false, approval: nil, paths: [])
        packet = @packet_builder.build(
          run_id: run_id,
          goal: goal,
          requested_tool: tool_name,
          inputs: inputs,
          expected_outputs: expected_outputs,
          approval_requirement: approved ? "satisfied" : nil
        )
        requested = event("tool.requested", tool_name, packet, nil, "requested")
        decision = @policy_kernel.decide(packet: packet, approved: approved, approval: approval, paths: paths)
        policy_event = event("policy.decision", tool_name, packet, decision, decision.fetch("decision"))
        unless decision.fetch("decision") == "allow"
          return {
            "schema_version" => 1,
            "status" => decision.fetch("decision"),
            "packet" => packet,
            "policy_decision" => decision,
            "events" => [requested, policy_event, event("tool.blocked", tool_name, packet, decision, "blocked")],
            "blocking_issues" => [decision.fetch("reason")]
          }
        end

        started = event("tool.started", tool_name, packet, decision, "started")
        result = block_given? ? yield(packet, decision) : { "status" => "passed", "blocking_issues" => [] }
        finished = event("tool.finished", tool_name, packet, decision, result.fetch("status", "finished"))
        {
          "schema_version" => 1,
          "status" => result.fetch("status", "passed"),
          "packet" => packet,
          "policy_decision" => decision,
          "events" => [requested, policy_event, started, finished],
          "tool_result" => result,
          "blocking_issues" => Array(result["blocking_issues"])
        }
      rescue StandardError => e
        {
          "schema_version" => 1,
          "status" => "blocked",
          "blocking_issues" => ["ToolGateway failed closed for #{tool_name}: #{e.class}: #{e.message}"],
          "events" => []
        }
      end

      private

      def event(type, tool_name, packet, decision, status)
        {
          "schema_version" => 1,
          "event" => type,
          "tool_name" => tool_name.to_s,
          "packet_id" => packet.fetch("packet_id"),
          "policy_decision_id" => decision ? decision.fetch("decision_id") : "pending",
          "status" => status.to_s,
          "created_at" => Time.now.utc.iso8601
        }
      end
    end
  end
end
