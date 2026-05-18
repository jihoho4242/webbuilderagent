# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    def engine_run_sandbox_preflight_skipped(reason)
      {
        "schema_version" => 1,
        "status" => "skipped",
        "generated_argv" => [],
        "resolved_executable_path" => nil,
        "container_image" => nil,
        "container_image_digest" => nil,
        "container_image_inspect" => { "status" => "skipped", "reason" => reason.to_s },
        "runtime_info" => { "status" => "skipped", "reason" => reason.to_s },
        "runtime_matrix" => {
          "schema_version" => 1,
          "status" => "skipped",
          "required" => false,
          "selected_runtime" => nil,
          "requested_runtimes" => [],
          "entries" => [],
          "blocking_issues" => []
        },
        "inside_container_probe" => {
          "schema_version" => 1,
          "status" => "skipped",
          "reason" => reason.to_s
        },
        "container_id" => nil,
        "runtime_container_inspect" => { "status" => "not_observed", "reason" => reason.to_s, "blocking_issues" => [] },
        "effective_user" => nil,
        "security_attestation" => engine_run_not_observed_security_attestation(reason.to_s),
        "host_mounts" => [],
        "inside_mounts" => [],
        "network_mode" => nil,
        "sandbox_user" => nil,
        "egress_denial_probe" => { "status" => "not_observed", "method" => "skipped", "reason" => reason.to_s },
        "capabilities" => {},
        "resource_limits" => {},
        "negative_checks" => {},
        "preflight_warnings" => [reason.to_s],
        "blocking_issues" => []
      }
    end

    def engine_run_sandbox_preflight_evidence(agent:, sandbox:, workspace_dir:, command:)
      argv = Array(command).map(&:to_s)
      mounts = sandbox_runtime_argv_values(argv, "-v")
      image = engine_run_container_worker_agent?(agent) ? engine_run_agent_container_image(agent) : nil
      image_inspect = engine_run_container_image_inspect(sandbox, image)
      runtime_info = engine_run_sandbox_runtime_info(sandbox)
      inside_probe = engine_run_sandbox_self_attestation_probe(agent: agent, sandbox: sandbox, workspace_dir: workspace_dir)
      runtime_matrix = engine_run_sandbox_runtime_matrix_evidence(
        agent: agent,
        selected_sandbox: sandbox,
        workspace_dir: workspace_dir,
        selected_runtime_info: runtime_info,
        selected_inside_probe: inside_probe,
        selected_image_inspect: image_inspect
      )
      container_id = inside_probe["runtime_container_id"] || inside_probe["container_id"]
      runtime_container_inspect = inside_probe["runtime_container_inspect"] || { "status" => "not_observed", "reason" => "self_attestation_probe_missing_runtime_container_inspect" }
      egress_probe = inside_probe.fetch("egress_denial_probe", {
        "status" => sandbox_runtime_argv_option_value(argv, "--network") == "none" ? "configured" : "missing",
        "method" => "argv_network_none"
      })
      security_attestation = inside_probe["security_attestation"] || engine_run_failed_security_attestation("self_attestation_probe_missing_security_attestation")
      evidence = {
        "schema_version" => 1,
        "status" => "passed",
        "recorded_at" => now,
        "managed_runtime_equivalence" => "local_docker_podman_is_not_managed_microvm",
        "agent" => agent,
        "sandbox" => sandbox,
        "generated_argv" => argv,
        "resolved_executable_path" => executable_path(sandbox.to_s),
        "container_image" => image,
        "container_image_digest_required" => engine_run_require_digest_pinned_openmanus_image?,
        "container_image_digest_policy_source" => engine_run_digest_pinned_openmanus_policy_sources,
        "container_image_reference_pinned" => engine_run_digest_pinned_image?(image),
        "container_image_digest" => engine_run_container_image_digest(image, image_inspect),
        "container_image_inspect" => image_inspect,
        "preflight_warnings" => engine_run_sandbox_preflight_warnings(image: image, image_inspect: image_inspect, runtime_info: runtime_info, inside_probe: inside_probe),
        "container_id" => container_id,
        "container_hostname" => inside_probe["container_id"],
        "runtime_container_inspect" => runtime_container_inspect,
        "effective_user" => inside_probe["effective_user"] || "not_observed",
        "inside_container_probe" => inside_probe,
        "security_attestation" => security_attestation,
        "rootless_mode" => runtime_info.fetch("rootless_mode", "not_observed"),
        "runtime_info" => runtime_info,
        "runtime_matrix" => runtime_matrix,
        "host_mounts" => mounts,
        "inside_mounts" => mounts.map { |mount| sandbox_runtime_mount_target(mount) },
        "workspace_mount" => mounts.find { |mount| mount.end_with?(":/workspace:rw") },
        "network_mode" => sandbox_runtime_argv_option_value(argv, "--network"),
        "sandbox_user" => sandbox_runtime_argv_option_value(argv, "--user"),
        "egress_denial_probe" => egress_probe,
        "capabilities" => {
          "cap_drop" => sandbox_runtime_argv_option_value(argv, "--cap-drop"),
          "no_new_privileges" => sandbox_runtime_argv_option_value(argv, "--security-opt") == "no-new-privileges"
        },
        "seccomp_apparmor_profile" => runtime_info.fetch("security_options", []).empty? ? "runtime_default" : runtime_info.fetch("security_options"),
        "resource_limits" => {
          "pids_limit" => sandbox_runtime_argv_option_value(argv, "--pids-limit"),
          "memory" => sandbox_runtime_argv_option_value(argv, "--memory"),
          "cpus" => sandbox_runtime_argv_option_value(argv, "--cpus"),
          "tmpfs" => sandbox_runtime_argv_option_value(argv, "--tmpfs")
        },
        "negative_checks" => engine_run_sandbox_negative_checks(argv, workspace_dir),
        "shared_responsibility" => %w[
          agent_code_security
          dependency_management
          iam_resource_policies
          command_security
          session_to_user_mapping
          prompt_injection_tool_abuse_defense
          network_configuration
        ]
      }
      evidence["blocking_issues"] = engine_run_sandbox_preflight_blockers(evidence)
      evidence["status"] = evidence["blocking_issues"].empty? ? "passed" : "failed"
      evidence
    end

    def engine_run_sandbox_preflight_blockers(evidence)
      blockers = []
      blockers << "sandbox command must disable networking with --network none" unless evidence["network_mode"] == "none"
      blockers << "inside-container self-attestation probe did not pass" unless evidence.dig("inside_container_probe", "status") == "passed"
      blockers << "inside-container egress denial probe did not pass" unless evidence.dig("egress_denial_probe", "status") == "passed"
      blockers << "inside-container security attestation did not pass" unless evidence.dig("security_attestation", "status") == "passed"
      blockers << "runtime container inspect cross-check did not pass" unless evidence.dig("runtime_container_inspect", "status") == "passed"
      if evidence.dig("runtime_matrix", "required") && evidence.dig("runtime_matrix", "status") != "passed"
        blockers << "sandbox runtime matrix verification did not pass"
      end
      blockers << "sandbox preflight did not observe a container id/hostname" if evidence["container_id"].to_s.strip.empty?
      effective_user = evidence["effective_user"]
      if effective_user.is_a?(Hash)
        blockers << "sandbox preflight did not observe an effective user id" if effective_user["uid"].nil?
        blockers << "sandbox preflight observed root effective user" if effective_user["uid"].to_i == 0
      else
        blockers << "sandbox preflight did not observe an effective user id"
      end
      blockers.uniq
    end

  end
end
