# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

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
