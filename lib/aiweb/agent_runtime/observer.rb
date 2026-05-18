# frozen_string_literal: true

require "time"

module Aiweb
  module AgentRuntime
    class Observer
      def initialize(project)
        @project = project
      end

      def snapshot(profile: nil)
        runtime = @project.runtime_plan
        scaffold_profile = runtime.dig("runtime_plan", "scaffold", "profile")
        selected_profile = profile || scaffold_profile
        contract = Aiweb::ProfilePolicy::Resolver.fetch(selected_profile.to_s)
        {
          "schema_version" => 1,
          "current_phase" => runtime["current_phase"],
          "runtime_plan" => runtime.fetch("runtime_plan"),
          "blocking_issues" => runtime.fetch("blocking_issues", []),
          "profile" => selected_profile,
          "profile_contract" => contract&.to_h,
          "observed_at" => Time.now.utc.iso8601
        }
      end
    end
  end
end
