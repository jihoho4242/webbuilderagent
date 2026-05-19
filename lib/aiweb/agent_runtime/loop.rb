# frozen_string_literal: true

module Aiweb
  module AgentRuntime
    class Loop
      def initialize(project)
        @project = project
      end

      def run(goal:, mode:, profile:, max_steps:, approved: false, dry_run:, canonical_engine_run: nil)
        observer = Observer.new(@project)
        observation = observer.snapshot(profile: profile)
        session = Session.new(root: @project.root, goal: goal, mode: mode, profile: observation["profile"], max_steps: max_steps, approved: approved)
        contract = Aiweb::ProfilePolicy::Resolver.fetch(observation["profile"].to_s)
        plan = Planner.new.plan(goal: goal, observation: observation, mode: mode, max_steps: session.max_steps)
        tool_results = plan.fetch("planned_actions").map do |action|
          canonical_engine_run ? delegated_to_engine_run_result(action, canonical_engine_run, dry_run: dry_run, mode: mode, approved: approved) : Executor.new(@project).execute(action, dry_run: dry_run, mode: mode, approved: approved)
        end
        verification = Verifier.new.verify(observation: observation, plan: plan, tool_results: tool_results)
        reflection = Reflector.new.reflect(verification)
        status = reflection.fetch("status")
        report = ReportBuilder.new(@project).build(session: session, observation: observation, plan: plan, tool_results: tool_results, verification: verification, reflection: reflection, contract: contract, dry_run: dry_run, canonical_engine_run: canonical_engine_run)
        changed_files = []
        unless dry_run
          artifact_writer = ArtifactWriter.new(@project)
          changed_files = artifact_writer.write(session: session, observation: observation, plan: plan, tool_results: tool_results, verification: verification, reflection: reflection, report: report, contract: contract)
          changed_files.concat(artifact_writer.write_state_pointer(session, report, status))
        end
        {
          "schema_version" => 1,
          "current_phase" => observation["current_phase"],
          "action_taken" => dry_run ? "planned agent session" : "recorded agent session plan",
          "changed_files" => changed_files,
          "blocking_issues" => report.fetch("blocking_issues"),
          "missing_artifacts" => [],
          "agent_session" => report.fetch("agent_session"),
          "agent_runtime" => report,
          "next_action" => status == "blocked" ? "resolve blockers, then rerun aiweb agent" : "review artifacts, then continue with bounded execution/repair when local tool integrations are enabled"
        }
      end

      private

      def delegated_to_engine_run_result(action, canonical_engine_run, dry_run:, mode:, approved:)
        tool = action.fetch("tool")
        return Executor.new(@project).send(:planned_result, tool, action).merge("canonical_runtime" => "engine-run") if dry_run
        return Executor.new(@project).send(:pending_approval_result, tool, action, mode).merge("canonical_runtime" => "engine-run") if action["requires_approval"] == true && !approved

        {
          "tool" => tool,
          "status" => "delegated_to_engine_run",
          "dry_run" => false,
          "canonical_runtime" => "engine-run",
          "engine_run_facade" => canonical_engine_run,
          "blocking_issues" => [],
          "action" => action,
          "reason" => "aiweb agent compatibility facade does not execute tool bodies; engine-run owns durable execution, checkpoint, replay, and side-effect gating"
        }
      end

    end
  end
end
