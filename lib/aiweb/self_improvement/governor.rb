# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "yaml"

module Aiweb
  module SelfImprovement
    class Governor
      FORBIDDEN = %w[constitution policy_kernel permission_tier legal_registry eval_threshold hitl_gate credential_store self_improvement_policy].freeze
      OPERATIONAL_BLOCKERS = [
        "production-ready self-improvement requires sandbox patch diff, static checks, eval/red-team pass, HITL v2 approval, canary, rollback plan, and monitor evidence"
      ].freeze

      def dry_run_proposal(target_component:, hypothesis:, eval_plan: {}, rollback_plan: {})
        forbidden = FORBIDDEN.any? { |component| target_component.to_s.include?(component) }
        payload = {
          "schema_version" => 1,
          "proposal_id" => "improvement-proposal-#{SecureRandom.hex(8)}",
          "mode" => forbidden ? "blocked" : "dry_run",
          "fixture_status" => forbidden ? "proposal_blocked" : "proposal_fixture_recorded",
          "production_gate_status" => "blocked",
          "production_ready_claim_allowed" => false,
          "target_component" => target_component.to_s,
          "risk_tier" => forbidden ? "L5" : "L2",
          "hypothesis" => hypothesis.to_s,
          "eval_plan" => eval_plan,
          "rollback_plan" => rollback_plan,
          "approval_required" => true,
          "sandbox_only" => true,
          "patch_generated" => false,
          "promotion_allowed" => false,
          "source_changed" => false,
          "blocking_issues" => forbidden ? ["self-improvement cannot directly patch forbidden component #{target_component}"] : [],
          "operational_blocking_issues" => OPERATIONAL_BLOCKERS
        }
        payload["change_hash"] = "sha256:#{Digest::SHA256.hexdigest(JSON.generate(payload))}"
        payload
      end
    end
  end
end
