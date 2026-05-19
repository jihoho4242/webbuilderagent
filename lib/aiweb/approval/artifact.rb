# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "time"

module Aiweb
  module Approval
    class Artifact
      def self.sha(value)
        "sha256:#{Digest::SHA256.hexdigest(value.is_a?(String) ? value : JSON.generate(canonicalize(value)))}"
      end

      def self.build(run_id:, decision_packet_ids:, risk_tier:, requested_capabilities:, action_diff:, args:, evidence:, approver_id:, second_reviewer_id: nil, ttl_seconds: 900)
        expires_at = (Time.now.utc + ttl_seconds).iso8601
        base = {
          "schema_version" => 2,
          "approval_id" => "approval-#{SecureRandom.hex(8)}",
          "run_id" => run_id.to_s,
          "decision_packet_ids" => Array(decision_packet_ids),
          "risk_tier" => risk_tier.to_s,
          "requested_capabilities" => Array(requested_capabilities),
          "action_diff_hash" => sha(action_diff),
          "args_hash" => sha(args),
          "evidence_hash" => sha(evidence),
          "expires_at" => expires_at,
          "single_use" => true,
          "consumed_at" => nil,
          "approver_id" => approver_id.to_s,
          "second_reviewer_id" => second_reviewer_id
        }
        base["approval_hash"] = sha(base.reject { |key, _| key == "approval_hash" || key == "validation_hash" })
        base["validation_hash"] = sha([base["approval_hash"], base["run_id"], base["decision_packet_ids"]])
        base
      end

      def self.canonicalize(value)
        case value
        when Hash
          value.keys.map(&:to_s).sort.each_with_object({}) do |key, result|
            original_key = value.key?(key) ? key : key.to_sym
            result[key] = canonicalize(value[original_key])
          end
        when Array
          value.map { |item| canonicalize(item) }
        else
          value
        end
      end
    end
  end
end
