# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "sandbox_preflight/runtime_matrix"

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

    def engine_run_sandbox_self_attestation_probe(agent:, sandbox:, workspace_dir:)
      return { "schema_version" => 1, "status" => "skipped", "reason" => "missing_sandbox_or_non_container_agent" } unless engine_run_container_worker_agent?(agent) && !sandbox.to_s.strip.empty?

      engine_run_prepare_container_scratch_dirs(workspace_dir)
      script = <<~'SH'
        if command -v python3 >/dev/null 2>&1; then PY=python3; elif command -v python >/dev/null 2>&1; then PY=python; else echo '{"schema_version":1,"status":"not_observed","reason":"python_unavailable"}'; exit 0; fi
        "$PY" - <<'PY'
        import getpass, json, os, socket

        def write_probe(path, content):
            try:
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write(content)
                try:
                    os.remove(path)
                except OSError:
                    pass
                return True
            except OSError:
                return False

        def root_write_blocked():
            path = "/aiweb-root-write-probe"
            try:
                with open(path, "w", encoding="utf-8") as handle:
                    handle.write("probe")
                try:
                    os.remove(path)
                except OSError:
                    pass
                return False
            except OSError:
                return True

        def read_text(path, limit=12000):
            try:
                with open(path, "r", encoding="utf-8", errors="replace") as handle:
                    return handle.read(limit)
            except OSError:
                return ""

        def proc_status_fields():
            fields = {}
            for line in read_text("/proc/self/status").splitlines():
                if ":" not in line:
                    continue
                key, value = line.split(":", 1)
                if key in ["NoNewPrivs", "Seccomp", "Seccomp_filters", "CapEff", "CapPrm", "CapBnd"]:
                    fields[key] = value.strip()
            no_new_privs = fields.get("NoNewPrivs") == "1"
            seccomp_filtering = fields.get("Seccomp") in ["2", "1"]
            cap_eff = fields.get("CapEff", "")
            try:
                cap_eff_zero = int(cap_eff, 16) == 0
            except ValueError:
                cap_eff_zero = False
            status = "passed" if no_new_privs and seccomp_filtering and cap_eff_zero else "failed"
            return {
                "status": status,
                "source": "/proc/self/status",
                "no_new_privs": fields.get("NoNewPrivs"),
                "no_new_privs_enabled": no_new_privs,
                "seccomp": fields.get("Seccomp"),
                "seccomp_filtering": seccomp_filtering,
                "seccomp_filters": fields.get("Seccomp_filters"),
                "cap_eff": cap_eff,
                "cap_eff_zero": cap_eff_zero,
                "cap_prm": fields.get("CapPrm"),
                "cap_bnd": fields.get("CapBnd")
            }

        egress = {
            "status": "not_observed",
            "method": "inside_container_python_socket_connect_93_184_216_34_80",
            "target": "93.184.216.34:80"
        }
        try:
            socket.create_connection(("93.184.216.34", 80), timeout=2).close()
            egress.update({"status": "failed", "observed": "unexpected_connect"})
        except OSError as error:
            egress.update({"status": "passed", "observed": "connection_denied", "error_class": error.__class__.__name__, "error": str(error)[:160]})

        env_guards = {
            key: os.environ.get(key)
            for key in ["AIWEB_NETWORK_ALLOWED", "AIWEB_MCP_ALLOWED", "AIWEB_ENV_ACCESS_ALLOWED", "AIWEB_ENGINE_RUN_TOOL"]
        }
        uid = os.getuid() if hasattr(os, "getuid") else None
        gid = os.getgid() if hasattr(os, "getgid") else None
        try:
            user_name = getpass.getuser()
        except Exception:
            user_name = str(uid) if uid is not None else None
        security = proc_status_fields()
        cgroup_lines = read_text("/proc/self/cgroup", 4000).splitlines()[:20]
        mountinfo_lines = read_text("/proc/self/mountinfo", 8000).splitlines()[:40]
        workspace_writable = write_probe("/workspace/_aiweb/self-attestation-write-probe", "ok")
        root_blocked = root_write_blocked()
        probe = {
            "schema_version": 1,
            "status": "passed" if egress["status"] == "passed" and workspace_writable and root_blocked and security["status"] == "passed" else "failed",
            "container_id": socket.gethostname(),
            "effective_user": {
                "uid": uid,
                "gid": gid,
                "name": user_name
            },
            "cwd": os.getcwd(),
            "home": os.environ.get("HOME"),
            "env_guards": env_guards,
            "workspace_writable": workspace_writable,
            "root_filesystem_write_blocked": root_blocked,
            "security_attestation": security,
            "cgroup": {
                "source": "/proc/self/cgroup",
                "lines": cgroup_lines
            },
            "mountinfo_excerpt": {
                "source": "/proc/self/mountinfo",
                "lines": mountinfo_lines
            },
            "egress_denial_probe": egress
        }
        print(json.dumps(probe, sort_keys=True))
        PY
      SH
      cidfile = File.join(workspace_dir, "_aiweb", "sandbox-preflight.cid")
      FileUtils.rm_f(cidfile)
      command = engine_run_sandbox_tool_command(sandbox, workspace_dir, ["sh", "-lc", script], tool: "sandbox_preflight_probe", agent: agent)
      command = engine_run_preflight_probe_command(command, cidfile)
      stdout, stderr, status = engine_run_capture_command(command, workspace_dir, 30, env: engine_run_clean_env(workspace_dir, { events_path: File.join(workspace_dir, "_aiweb", "preflight-events.jsonl") }, sandbox))
      runtime_container_id = File.file?(cidfile) ? File.read(cidfile, 512).to_s.strip : nil
      runtime_container_inspect = runtime_container_id.to_s.empty? ? { "status" => "not_observed", "reason" => "cidfile was not written" } : engine_run_runtime_container_inspect(sandbox, runtime_container_id, expected_workspace_dir: workspace_dir)
      engine_run_remove_runtime_container(sandbox, runtime_container_id) unless runtime_container_id.to_s.empty?
      unless status == 0
        return engine_run_failed_sandbox_self_attestation(
          reason: "self_attestation_probe_command_failed",
          runtime_container_id: runtime_container_id,
          runtime_container_inspect: runtime_container_inspect,
          exit_code: status,
          stderr: stderr
        )
      end

      parsed = JSON.parse(stdout.to_s)
      unless parsed.is_a?(Hash)
        return engine_run_failed_sandbox_self_attestation(
          reason: "self_attestation_probe_output_not_object",
          runtime_container_id: runtime_container_id,
          runtime_container_inspect: runtime_container_inspect
        )
      end
      parsed["schema_version"] ||= 1
      parsed["runtime_container_id"] = runtime_container_id unless runtime_container_id.to_s.empty?
      parsed["runtime_container_inspect"] = runtime_container_inspect
      parsed["effective_user"] = { "uid" => nil, "gid" => nil, "name" => nil } unless parsed["effective_user"].is_a?(Hash)
      parsed["security_attestation"] = engine_run_failed_security_attestation("self_attestation_probe_missing_security_attestation") unless parsed["security_attestation"].is_a?(Hash)
      parsed["egress_denial_probe"] = engine_run_failed_egress_denial_probe("self_attestation_probe_missing_egress_denial_probe") unless parsed["egress_denial_probe"].is_a?(Hash)
      parsed
    rescue JSON::ParserError
      engine_run_failed_sandbox_self_attestation(reason: "self_attestation_probe_output_parse_failed", runtime_container_id: runtime_container_id, runtime_container_inspect: runtime_container_inspect)
    rescue SystemCallError => e
      engine_run_failed_sandbox_self_attestation(reason: e.message, runtime_container_id: runtime_container_id, runtime_container_inspect: runtime_container_inspect)
    end

    def engine_run_failed_sandbox_self_attestation(reason:, runtime_container_id: nil, runtime_container_inspect: nil, exit_code: nil, stderr: nil)
      record = {
        "schema_version" => 1,
        "status" => "failed",
        "reason" => reason.to_s,
        "runtime_container_id" => runtime_container_id,
        "container_id" => nil,
        "effective_user" => {
          "uid" => nil,
          "gid" => nil,
          "name" => nil
        },
        "env_guards" => {},
        "workspace_writable" => false,
        "root_filesystem_write_blocked" => false,
        "security_attestation" => engine_run_failed_security_attestation(reason),
        "cgroup" => {
          "source" => "/proc/self/cgroup",
          "lines" => []
        },
        "mountinfo_excerpt" => {
          "source" => "/proc/self/mountinfo",
          "lines" => []
        },
        "egress_denial_probe" => engine_run_failed_egress_denial_probe(reason),
        "runtime_container_inspect" => runtime_container_inspect || { "status" => "not_observed", "reason" => "runtime container id was not observed" }
      }
      record["exit_code"] = exit_code if exit_code
      record["stderr"] = agent_run_redact_process_output(stderr.to_s)[0, 1000] unless stderr.to_s.empty?
      record
    end

    def engine_run_failed_security_attestation(reason = "security_attestation_not_observed")
      {
        "status" => "failed",
        "source" => "/proc/self/status",
        "reason" => reason.to_s,
        "no_new_privs" => nil,
        "no_new_privs_enabled" => false,
        "seccomp" => nil,
        "seccomp_filtering" => false,
        "seccomp_filters" => nil,
        "cap_eff" => nil,
        "cap_eff_zero" => false,
        "cap_prm" => nil,
        "cap_bnd" => nil
      }
    end

    def engine_run_not_observed_security_attestation(reason = "security_attestation_not_observed")
      engine_run_failed_security_attestation(reason).merge(
        "status" => "not_observed",
        "no_new_privs_enabled" => false,
        "seccomp_filtering" => false,
        "cap_eff_zero" => false
      )
    end

    def engine_run_failed_egress_denial_probe(reason = "egress_denial_probe_not_observed")
      {
        "status" => "failed",
        "method" => "inside_container_socket_probe",
        "observed" => reason.to_s
      }
    end

  end
end
