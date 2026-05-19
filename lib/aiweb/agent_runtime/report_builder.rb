# frozen_string_literal: true

require "digest"
require "json"

module Aiweb
  module AgentRuntime
    class ReportBuilder
      def initialize(project)
        @project = project
      end

      def build(session:, observation:, plan:, tool_results:, verification:, reflection:, contract:, dry_run:, canonical_engine_run: nil)
        not_tested = not_tested_items(session: session, contract: contract, tool_results: tool_results, dry_run: dry_run)
        {
          "schema_version" => 1,
          "status" => reflection.fetch("status"),
          "summary" => summary_for(reflection.fetch("status"), session: session, contract: contract, tool_results: tool_results),
          "agent_os" => agent_os_summary(session: session, tool_results: tool_results, canonical_engine_run: canonical_engine_run),
          "agent_session" => session.to_h(status: reflection.fetch("status"), stop_reason: reflection.fetch("stop_reason"), profile_contract: contract),
          "profile" => observation["profile"],
          "mode" => session.mode,
          "steps" => plan.fetch("planned_actions"),
          "toolResults" => tool_results.map { |result| compact_tool_result(result) },
          "tests" => test_summaries(tool_results),
          "reflection" => reflection,
          "browserQa" => browser_qa_feedback(session: session, observation: observation, plan: plan, contract: contract, tool_results: tool_results),
          "patchManifest" => source_patch_manifest(session: session, plan: plan, contract: contract),
          "safety" => {
            "dot_env_read" => false,
            "external_actions_performed" => false,
            "source_mutation_performed" => false,
            "approved" => session.approved,
            "mode" => session.mode
          },
          "artifacts" => session.to_h(status: reflection.fetch("status"), stop_reason: reflection.fetch("stop_reason"), profile_contract: contract).fetch("artifact_paths"),
          "errors" => [],
          "warnings" => warnings_for(tool_results, reflection),
          "blocking_issues" => reflection.fetch("blocking_issues"),
          "reproduction" => ["aiweb agent #{session.goal.inspect} --mode #{session.mode} --max-steps #{session.max_steps}"],
          "ci" => nil,
          "Not-tested" => not_tested,
          "dry_run" => dry_run
        }
      end

      private

      def agent_os_summary(session:, tool_results:, canonical_engine_run:)
        constitution = Aiweb::Constitution::Verifier.new.verify
        {
          "schema_version" => 1,
          "canonical_runtime" => "engine-run",
          "agent_facade_role" => "goal_facade_compatibility_surface",
          "agent_runtime_execution_role" => "summary_only_engine_run_wrapper",
          "split_brain_policy" => "agent artifacts must reference engine-run compatible DecisionPacket/PolicyKernel/ToolGateway evidence",
          "constitution_hash" => constitution["content_hash"],
          "constitution_status" => constitution["status"],
          "tool_gateway_event_order" => tool_results.flat_map { |result| Array(result["tool_gateway_events"]).map { |event| event["event"] } },
          "script_executor_neutralization" => {
            "agent_runtime_top_level_engine_role" => "demoted_compatibility_facade",
            "verify_loop_role" => "legacy_verification_bundle_tool",
            "browser_static_scenario_role" => "deterministic_local_browser_probe"
          },
          "engine_run_facade" => canonical_engine_run || {
            "status" => "canonical_runtime_selected",
            "recommended_command" => "aiweb engine-run --goal #{session.goal.inspect} --dry-run"
          }
        }
      end

      def source_patch_manifest(session:, plan:, contract:)
        source_supported = contract&.supports?(:source_patch) == true
        guard_result = SourcePatchGuard.new.validate(
          manifest: {
            "allowed_source_paths" => allowed_source_paths,
            "max_changed_files" => 20,
            "max_patch_bytes" => 200_000
          },
          changed_files: [],
          patch_bytes: 0
        )
        {
          "schema_version" => 1,
          "run_id" => session.run_id,
          "profile_contract_hash" => contract ? Digest::SHA256.hexdigest(JSON.generate(contract.to_h)) : nil,
          "allowed_source_paths" => allowed_source_paths,
          "base_file_hashes" => source_base_file_hashes,
          "max_changed_files" => 20,
          "max_patch_bytes" => 200_000,
          "requested_changes" => Array(plan["planned_actions"]).select { |action| action["tool"] == "source_patch" },
          "changed_file_manifest" => [],
          "blocked_changes" => source_supported ? [] : ["active profile contract does not support source_patch"],
          "copy_back_status" => "not_requested",
          "secret_scan" => { "status" => "not_run", "dot_env_read" => false },
          "guard_result" => guard_result,
          "verifier_decision" => source_supported ? "manifest_required_before_source_mutation" : "blocked"
        }
      end

      def allowed_source_paths
        %w[src public package.json astro.config.mjs next.config.mjs tsconfig.json tailwind.config.mjs test docs]
      end

      def browser_qa_feedback(session:, observation:, plan:, contract:, tool_results:)
        supported = contract&.supports?(:browser_qa) == true
        qa_result = tool_results.find { |result| result["tool"] == "browser_qa" }
        raw = qa_result&.dig("raw_result") || {}
        metadata = raw["playwright_qa"].is_a?(Hash) ? raw["playwright_qa"] : {}
        result_status = qa_result && qa_result["status"]
        {
          "schema_version" => 1,
          "run_id" => session.run_id,
          "profile" => contract&.id || observation["profile"],
          "status" => result_status || (supported ? "planned" : "not_supported_by_profile"),
          "localhost_only" => true,
          "external_navigation" => false,
          "routes" => browser_routes(metadata),
          "console_errors" => extract_qa_array(metadata, "console_errors"),
          "network_failures" => extract_qa_array(metadata, "network_errors"),
          "a11y_violations" => [],
          "evidence" => Array(metadata["result_path"]) + Array(metadata["stdout_log"]) + Array(metadata["stderr_log"]),
          "suggested_repair_hints" => browser_repair_hints(qa_result),
          "planned_actions" => Array(plan["planned_actions"]).select { |action| action["tool"] == "browser_qa" },
          "not_tested_reason" => browser_not_tested_reason(supported, qa_result)
        }
      end

      def compact_tool_result(result)
        result.reject { |key, _value| key == "raw_result" }
      end

      def test_summaries(tool_results)
        tool_results.map do |result|
          {
            "tool" => result["tool"],
            "status" => result["status"],
            "artifacts" => result["artifacts"] || {},
            "blocking_issues" => Array(result["blocking_issues"])
          }
        end
      end

      def warnings_for(tool_results, reflection)
        warnings = Array(reflection["blocking_issues"])
        warnings.concat(tool_results.select { |result| result["status"] == "pending_approval" }.map { |result| "#{result["tool"]} pending approval" })
        warnings.uniq
      end

      def summary_for(status, session:, contract:, tool_results:)
        executed = tool_results.reject { |result| %w[planned pending_approval].include?(result["status"].to_s) }.map { |result| result["tool"] }
        return "Agent runtime completed required local #{contract&.id || session.profile} validation with profile-aware evidence." if status == "complete"
        return "Agent runtime hit a blocking runtime/safety precondition and recorded evidence." if status == "blocked"
        return "Agent runtime validation failed and recorded bounded failure evidence." if status == "failed_validation"
        return "Agent runtime produced a profile-aware plan and is waiting for approval to run local runtime tools." if tool_results.any? { |result| result["status"] == "pending_approval" }

        "Agent runtime observed project state, produced a profile-aware plan, and recorded audit artifacts#{executed.empty? ? "" : " after #{executed.join(", ")}"}."
      end

      def not_tested_items(session:, contract:, tool_results:, dry_run:)
        items = []
        items << "local runtime execution not performed because this was a dry-run/plan-only run" if dry_run || session.mode == "plan-only"
        items << "browser QA not supported by active profile #{contract.id}" if contract && !contract.supports?(:browser_qa)
        if contract&.supports?(:browser_qa) && !tool_results.any? { |result| result["tool"] == "browser_qa" && result["status"] == "passed" }
          items << "browser QA did not produce a passing live result"
        end
        items << "source patch copy-back not requested; source mutation remains manifest/verifier gated"
        items << "deploy/provider actions intentionally blocked"
        items.uniq
      end

      def browser_routes(metadata)
        target = metadata["target"].is_a?(Hash) ? metadata["target"] : {}
        url = target["url"] || metadata["url"]
        url.to_s.empty? ? [] : [{ "url" => url, "status" => metadata["status"] || "unknown" }]
      end

      def extract_qa_array(metadata, key)
        value = metadata[key]
        value.is_a?(Array) ? value : []
      end

      def browser_repair_hints(qa_result)
        return [] unless qa_result
        return [] if %w[passed planned pending_approval].include?(qa_result["status"].to_s)

        Array(qa_result["blocking_issues"]).map { |issue| "Inspect browser QA artifact and repair: #{issue}" }
      end

      def browser_not_tested_reason(supported, qa_result)
        return "active profile contract does not support browser QA" unless supported
        return "browser QA action was planned but not executed" if qa_result.nil? || qa_result["status"] == "planned"
        return "browser QA awaits --approved in supervised mode" if qa_result["status"] == "pending_approval"

        nil
      end

      def source_base_file_hashes
        paths = Dir.glob(File.join(@project.root, "{src,public,test,docs}", "**", "*"), File::FNM_EXTGLOB)
        paths.concat(%w[package.json astro.config.mjs next.config.mjs tsconfig.json tailwind.config.mjs].map { |path| File.join(@project.root, path) })
        paths.select { |path| File.file?(path) }
             .reject { |path| Aiweb::Runtime::PathPolicy.unsafe_env_path?(@project.send(:relative, path)) }
             .first(200)
             .to_h { |path| [@project.send(:relative, path), Digest::SHA256.file(path).hexdigest] }
      end
    end
  end
end
