# frozen_string_literal: true

require "digest"
require "json"
require "time"

require_relative "../runtime/path_policy"
require_relative "../constitution"

module Aiweb
  module Policy
    class DecisionEvent
      def self.build(packet:, decision:, reason:)
        created_at = Time.now.utc.iso8601
        seed = [packet["packet_id"], packet["requested_tool"], decision, reason, created_at].join(":")
        {
          "schema_version" => 1,
          "decision_id" => "policy-decision-#{Digest::SHA256.hexdigest(seed)[0, 16]}",
          "packet_id" => packet.fetch("packet_id"),
          "tool_name" => packet.fetch("requested_tool"),
          "decision" => decision,
          "risk_tier" => packet.fetch("risk_tier"),
          "permission_tier" => packet.fetch("permission_tier"),
          "reason" => reason,
          "constitution_hash" => packet.fetch("constitution_hash"),
          "policy_kernel_version" => packet.fetch("policy_kernel_version"),
          "created_at" => created_at
        }
      end
    end
  end
end
