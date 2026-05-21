# frozen_string_literal: true

require "digest"
require "json"

module Aiweb
  module ProjectAgentRun
    private

    def agent_run_openmanus_contract(run_id:, run_dir:, context_path:, prompt_path:, validator_path:, result_path:, network_log_path:, browser_log_path:, denied_access_log_path:, tool_broker_log_path:, task_source:, context:, source_paths:, command:, dry_run:, approved:)
      workspace_dir = File.join(aiweb_dir, "tmp", "openmanus", run_id)
      selected_file = Array(context["selected_design_files"]).find { |file| file["kind"] == "selected_candidate" }
      source_hashes = source_paths.each_with_object({}) do |path, memo|
        full = File.join(root, path)
        next if File.symlink?(full) || unsafe_secret_surface_path?(path)

        memo[path] = "sha256:#{Digest::SHA256.file(full).hexdigest}" if File.file?(full)
      end
      context_hash_input = source_hashes.sort.map { |path, hash| "#{path}=#{hash}" }.join("\n")
      task_id = task_source["relative"].to_s[/([^\/\\]+)\.md\z/, 1]

      context_payload = {
        "schema_version" => 1,
        "mode" => dry_run ? "dry_run" : (approved ? "approved" : "blocked"),
        "run_id" => run_id,
        "task_id" => task_id,
        "task_path" => task_source["relative"],
        "project_root_hash" => "sha256:#{Digest::SHA256.hexdigest(context_hash_input)}",
        "workspace_root" => relative(workspace_dir),
        "design_path" => context.dig("design", "path"),
        "selected_candidate_path" => selected_file && selected_file["path"],
        "component_map_path" => context.dig("component_map", "path"),
        "allowed_source_paths" => source_paths,
        "allowed_globs" => source_paths,
        "denied_globs" => agent_run_denied_globs,
        "base_hashes" => source_hashes,
        "timeout_sec" => agent_run_openmanus_timeout,
        "max_output_bytes" => 200_000,
        "permission_profile" => "implementation-local-no-network",
        "sandbox_mode" => agent_run_openmanus_sandbox_mode(command),
        "sandbox_required" => true,
        "forbidden_actions" => %w[read_env install deploy external_network mcp_tools modify_unlisted_files],
        "tool_broker" => {
          "events_path" => "_aiweb/tool-broker-events.jsonl",
          "host_evidence_path" => relative(tool_broker_log_path),
          "bin_path" => "_aiweb/tool-broker-bin",
          "path_prepend_required" => true,
          "blocks" => %w[package_install external_network deploy provider_cli git_push env_read]
        },
        "expected_output" => "source changes inside the isolated workspace only"
      }

      {
        "context" => context_payload,
        "planned_context_path" => relative(context_path),
        "planned_prompt_path" => relative(prompt_path),
        "planned_validator_path" => relative(validator_path),
        "planned_result_path" => relative(result_path),
        "planned_network_log_path" => relative(network_log_path),
        "planned_browser_request_log_path" => relative(browser_log_path),
        "planned_denied_access_log_path" => relative(denied_access_log_path),
        "workspace_root" => relative(workspace_dir),
        "contract_docs" => [
          "docs/contracts/openmanus-agent-run.md",
          "docs/contracts/security-boundary.md"
        ],
        "guardrails" => [
          "Ruby subprocess plus JSON file contract",
          "clean environment; no user tokens or provider credentials are intentionally passed",
          "workspace-scoped copy-back with allowed source copies only",
          "network and MCP are disabled by the aiweb-generated docker/podman sandbox and guard env",
          "secret surfaces and symlinks are rejected",
          "only allowed source files are copied back after validation"
        ]
      }
    end

    def agent_run_openmanus_prompt(context:, contract_context:)
      [
        "You are OpenManus running as a bounded aiweb implementation adapter.",
        "You are not the project director. aiweb owns state, gates, QA, and deploy.",
        "Patch only the allowed source files copied into this workspace.",
        "Do not read secret surfaces, environment files, browser profiles, package credentials, or provider CLI auth stores.",
        "Do not install packages, run deploy/provider CLIs, use MCP, or contact external networks.",
        "The contract JSON is available at AIWEB_AGENT_RUN_CONTEXT_PATH.",
        "",
        "## Contract",
        JSON.pretty_generate(contract_context),
        "",
        agent_run_prompt(context: context)
      ].join("\n")
    end

  end
end
