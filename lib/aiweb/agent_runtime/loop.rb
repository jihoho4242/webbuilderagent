# frozen_string_literal: true

module Aiweb
  module AgentRuntime
    class Loop
      def initialize(project)
        @project = project
      end

      def run(goal:, mode:, profile:, max_steps:, approved: false, dry_run:)
        observer = Observer.new(@project)
        observation = observer.snapshot(profile: profile)
        session = Session.new(root: @project.root, goal: goal, mode: mode, profile: observation["profile"], max_steps: max_steps, approved: approved)
        contract = Aiweb::ProfilePolicy::Resolver.fetch(observation["profile"].to_s)
        plan = Planner.new.plan(goal: goal, observation: observation, mode: mode, max_steps: session.max_steps)
        executor = Executor.new(@project)
        tool_results = plan.fetch("planned_actions").map do |action|
          executor.execute(action, dry_run: dry_run, mode: mode, approved: approved)
        end
        verification = Verifier.new.verify(observation: observation, plan: plan, tool_results: tool_results)
        reflection = Reflector.new.reflect(verification)
        status = reflection.fetch("status")
        report = ReportBuilder.new(@project).build(session: session, observation: observation, plan: plan, tool_results: tool_results, verification: verification, reflection: reflection, contract: contract, dry_run: dry_run)
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

    end
  end
end
