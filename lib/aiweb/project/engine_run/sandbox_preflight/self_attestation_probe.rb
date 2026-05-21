# frozen_string_literal: true

require "fileutils"
require "json"

module Aiweb
  module ProjectEngineRun
    private

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
  end
end
