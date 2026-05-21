# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

    def engine_run_sandbox_runtime_matrix_evidence(agent:, selected_sandbox:, workspace_dir:, selected_runtime_info:, selected_inside_probe:, selected_image_inspect:)
      unless engine_run_container_worker_agent?(agent) && !selected_sandbox.to_s.strip.empty?
        return {
          "schema_version" => 1,
          "status" => "skipped",
          "required" => false,
          "policy_source" => [],
          "selected_runtime" => nil,
          "requested_runtimes" => [],
          "entries" => [],
          "blocking_issues" => [],
          "reason" => "missing_sandbox_or_non_container_agent"
        }
      end

      requested = engine_run_required_sandbox_runtime_matrix
      policy_sources = engine_run_required_sandbox_runtime_matrix_policy_sources
      invalid_requested = engine_run_invalid_sandbox_runtime_matrix
      required = !policy_sources.empty?
      runtimes = (required && !requested.empty? ? requested : [selected_sandbox.to_s]).uniq
      entries = runtimes.map do |runtime|
        engine_run_sandbox_runtime_matrix_entry(
          runtime: runtime,
          selected_sandbox: selected_sandbox.to_s,
          workspace_dir: workspace_dir,
          selected_runtime_info: selected_runtime_info,
          selected_inside_probe: selected_inside_probe,
          selected_image_inspect: selected_image_inspect,
          agent: agent
        )
      end
      blockers = entries.flat_map do |entry|
        entry.fetch("blocking_issues", []).map { |issue| "#{entry.fetch("runtime")} runtime matrix: #{issue}" }
      end.uniq
      invalid_requested.each do |runtime|
        blockers << "unsupported runtime matrix entry: #{runtime.inspect}; expected docker or podman"
      end
      blockers << "runtime matrix policy configured but no valid runtimes were requested" if required && requested.empty?
      {
        "schema_version" => 1,
        "status" => blockers.empty? ? "passed" : (required ? "failed" : "partial"),
        "required" => required,
        "policy_source" => policy_sources,
        "selected_runtime" => selected_sandbox.to_s,
        "requested_runtimes" => requested,
        "invalid_requested_runtimes" => invalid_requested,
        "entries" => entries,
        "blocking_issues" => blockers
      }
    end

    def engine_run_sandbox_runtime_matrix_entry(runtime:, selected_sandbox:, workspace_dir:, selected_runtime_info:, selected_inside_probe:, selected_image_inspect:, agent: "openmanus")
      image = engine_run_agent_container_image(agent)
      command = executable_path(runtime) ? engine_run_agent_container_command(agent, runtime, workspace_dir) : []
      command_blockers = executable_path(runtime) ? engine_run_agent_sandbox_command_blockers(agent, command, sandbox: runtime, workspace_dir: workspace_dir) : ["#{runtime} executable is missing from PATH"]
      image_inspect = runtime == selected_sandbox ? selected_image_inspect : engine_run_container_image_inspect(runtime, image)
      runtime_info = runtime == selected_sandbox ? selected_runtime_info : engine_run_sandbox_runtime_info(runtime)
      inside_probe = if command_blockers.empty?
                       runtime == selected_sandbox ? selected_inside_probe : engine_run_sandbox_self_attestation_probe(agent: agent, sandbox: runtime, workspace_dir: workspace_dir)
                     else
                       engine_run_failed_sandbox_self_attestation(reason: "runtime_matrix_command_blocked")
                     end
      inspect = inside_probe["runtime_container_inspect"] || { "status" => "not_observed", "reason" => "runtime_matrix_missing_container_inspect" }
      security = inside_probe["security_attestation"] || engine_run_failed_security_attestation("runtime_matrix_missing_security_attestation")
      egress = inside_probe["egress_denial_probe"] || engine_run_failed_egress_denial_probe("runtime_matrix_missing_egress_denial_probe")
      effective_user = inside_probe["effective_user"]

      blockers = []
      blockers.concat(command_blockers)
      blockers << "image inspect did not pass" unless image_inspect.fetch("status", "failed") == "passed"
      blockers << "runtime info did not pass" unless runtime_info.fetch("status", "failed") == "passed"
      blockers << "inside-container self-attestation did not pass" unless inside_probe.fetch("status", "failed") == "passed"
      blockers << "inside-container security attestation did not pass" unless security.fetch("status", "failed") == "passed"
      blockers << "inside-container egress denial did not pass" unless egress.fetch("status", "failed") == "passed"
      blockers << "runtime container inspect did not pass" unless inspect.fetch("status", "failed") == "passed"
      if effective_user.is_a?(Hash)
        blockers << "effective user id was not observed" if effective_user["uid"].nil?
        blockers << "effective user is root" if effective_user["uid"].to_i == 0
      else
        blockers << "effective user id was not observed"
      end

      {
        "runtime" => runtime,
        "status" => blockers.empty? ? "passed" : "failed",
        "command" => command,
        "resolved_executable_path" => executable_path(runtime),
        "image_inspect" => image_inspect,
        "runtime_info" => runtime_info,
        "inside_container_probe_status" => inside_probe["status"],
        "inside_container_probe_reason" => inside_probe["reason"],
        "inside_container_probe_exit_code" => inside_probe["exit_code"],
        "inside_container_probe_stderr" => inside_probe["stderr"],
        "inside_container_workspace_writable" => inside_probe["workspace_writable"],
        "inside_container_root_filesystem_write_blocked" => inside_probe["root_filesystem_write_blocked"],
        "inside_container_env_guards" => inside_probe["env_guards"],
        "runtime_container_id" => inside_probe["runtime_container_id"],
        "runtime_container_inspect" => inspect,
        "security_attestation" => security,
        "egress_denial_probe" => egress,
        "effective_user" => effective_user,
        "blocking_issues" => blockers.uniq
      }
    end
  end
end
