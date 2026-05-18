# frozen_string_literal: true

require "digest"
require "json"
require "time"

module Aiweb
  module AgentRuntime
    class Session
      MAX_STEPS_DEFAULT = 20
      MAX_STEPS_HARD_LIMIT = 50
      MAX_REPAIRS_DEFAULT = 3
      MAX_REPAIRS_HARD_LIMIT = 8

      attr_reader :run_id, :goal, :mode, :profile, :max_steps, :max_repairs, :run_dir, :approved

      def initialize(root:, goal:, mode:, profile:, max_steps:, max_repairs: MAX_REPAIRS_DEFAULT, approved: false, run_id: nil)
        timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%S%6NZ")
        @run_id = run_id || "agent-session-#{timestamp}"
        @goal = goal.to_s.strip
        @mode = mode.to_s.strip.empty? ? "plan-only" : mode.to_s.strip
        @profile = profile.to_s.strip.empty? ? nil : profile.to_s.strip.upcase
        @max_steps = clamp_positive(max_steps, MAX_STEPS_DEFAULT, MAX_STEPS_HARD_LIMIT)
        @max_repairs = clamp_positive(max_repairs, MAX_REPAIRS_DEFAULT, MAX_REPAIRS_HARD_LIMIT)
        @approved = approved == true
        @run_dir = File.join(root, ".ai-web", "runs", @run_id)
      end

      def to_h(status:, stop_reason:, profile_contract: nil)
        {
          "schema_version" => 1,
          "run_id" => run_id,
          "goal" => goal,
          "mode" => mode,
          "profile" => profile,
          "profile_contract_hash" => profile_contract ? Digest::SHA256.hexdigest(JSON.generate(profile_contract.to_h)) : nil,
          "max_steps" => max_steps,
          "max_repairs" => max_repairs,
          "approved" => approved,
          "status" => status,
          "stop_reason" => stop_reason,
          "artifact_paths" => {
            "run_dir" => relative_run_dir,
            "session" => File.join(relative_run_dir, "agent-session.json"),
            "timeline" => File.join(relative_run_dir, "timeline.jsonl"),
            "source_patch_manifest" => File.join(relative_run_dir, "source-patch-manifest.json"),
            "browser_qa_feedback" => File.join(relative_run_dir, "browser-qa-feedback.json"),
            "final_report" => File.join(relative_run_dir, "final-report.json")
          }
        }
      end

      def relative_run_dir
        File.join(".ai-web", "runs", run_id).tr("\\", "/")
      end

      private

      def clamp_positive(value, default, max)
        integer = value.to_i
        integer = default unless integer.positive?
        [integer, max].min
      end
    end
  end
end
