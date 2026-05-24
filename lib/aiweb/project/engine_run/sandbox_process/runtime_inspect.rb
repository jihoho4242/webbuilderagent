# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

    def engine_run_runtime_container_inspect(sandbox, container_id, expected_workspace_dir: nil)
      return { "status" => "not_observed", "reason" => "missing_container_id" } if sandbox.to_s.strip.empty? || container_id.to_s.strip.empty?

      result = engine_run_sandbox_runtime_capture(sandbox, ["inspect", container_id.to_s], risk_class: "engine_run_sandbox_container_inspect")
      return { "status" => "failed", "exit_code" => result.exit_code, "stderr" => agent_run_redact_process_output(result.stderr.to_s)[0, 1000] } unless result.success?

      parsed = result.stdout.to_s.strip.empty? ? [] : JSON.parse(result.stdout.to_s)
      record = parsed.is_a?(Array) ? parsed.first : parsed
      record = {} unless record.is_a?(Hash)
      host_config = record["HostConfig"].is_a?(Hash) ? record["HostConfig"] : {}
      config = record["Config"].is_a?(Hash) ? record["Config"] : {}
      state = record["State"].is_a?(Hash) ? record["State"] : {}
      blockers = engine_run_runtime_container_inspect_blockers(host_config: host_config, config: config, record: record, expected_workspace_dir: expected_workspace_dir)
      {
        "status" => blockers.empty? ? "passed" : "failed",
        "blocking_issues" => blockers,
        "container_id" => record["Id"].to_s.empty? ? container_id.to_s : record["Id"].to_s,
        "name" => record["Name"],
        "image" => record["Image"],
        "state" => {
          "status" => state["Status"],
          "exit_code" => state["ExitCode"],
          "oom_killed" => state["OOMKilled"]
        },
        "config_user" => config["User"],
        "expected_workspace_source" => expected_workspace_dir.to_s.empty? ? nil : File.expand_path(expected_workspace_dir.to_s),
        "host_config" => {
          "network_mode" => host_config["NetworkMode"],
          "readonly_rootfs" => host_config["ReadonlyRootfs"],
          "cap_drop" => Array(host_config["CapDrop"]).map(&:to_s),
          "security_opt" => Array(host_config["SecurityOpt"]).map(&:to_s),
          "userns_mode" => host_config["UsernsMode"],
          "pids_limit" => host_config["PidsLimit"],
          "memory" => host_config["Memory"],
          "nano_cpus" => host_config["NanoCpus"]
        },
        "apparmor_profile" => record["AppArmorProfile"],
        "process_label" => record["ProcessLabel"],
        "mounts" => Array(record["Mounts"]).map do |mount|
          {
            "type" => mount["Type"],
            "source" => mount["Source"],
            "destination" => mount["Destination"],
            "mode" => mount["Mode"],
            "rw" => mount["RW"]
          }
        end
      }
    rescue JSON::ParserError
      { "status" => "failed", "reason" => "container_inspect_parse_failed" }
    rescue ArgumentError, SystemCallError => e
      { "status" => "failed", "reason" => e.message }
    end

    def engine_run_runtime_container_inspect_blockers(host_config:, config:, record:, expected_workspace_dir: nil)
      blockers = []
      network_mode = host_config["NetworkMode"].to_s
      readonly_rootfs = host_config["ReadonlyRootfs"]
      cap_drop = Array(host_config["CapDrop"]).map(&:to_s)
      security_opt = Array(host_config["SecurityOpt"]).map(&:to_s)
      user = config["User"].to_s.strip

      blockers << "runtime inspect did not confirm --network none" unless network_mode == "none"
      blockers << "runtime inspect did not confirm read-only root filesystem" unless readonly_rootfs == true
      unless engine_run_runtime_inspect_cap_drop_all?(cap_drop)
        blockers << "runtime inspect did not confirm cap-drop ALL"
      end
      unless security_opt.any? { |option| option == "no-new-privileges" || option.start_with?("no-new-privileges:") }
        blockers << "runtime inspect did not confirm no-new-privileges"
      end
      blockers << "runtime inspect did not confirm non-root --user" if user.empty? || user == "0" || user.start_with?("0:")

      mounts = Array(record["Mounts"]).select { |mount| mount.is_a?(Hash) }
      workspace_mounts = mounts.select { |mount| mount["Type"].to_s == "bind" && mount["Destination"].to_s == "/workspace" }
      blockers << "runtime inspect did not observe exactly one /workspace bind mount" unless workspace_mounts.length == 1
      workspace_mounts.each do |mount|
        blockers << "runtime inspect did not confirm writable /workspace mount" unless mount["RW"] == true
        source = mount["Source"].to_s
        if expected_workspace_dir && !engine_run_same_filesystem_path?(source, expected_workspace_dir)
          blockers << "runtime inspect did not confirm /workspace source is the staged workspace"
        end
      end

      mounts.each do |mount|
        next unless mount.is_a?(Hash)

        if mount["Type"].to_s == "bind" && mount["Destination"].to_s != "/workspace"
          blockers << "runtime inspect observed unexpected bind mount #{mount["Destination"]}"
        end
      end

      blockers.uniq
    end

    def engine_run_runtime_inspect_cap_drop_all?(cap_drop)
      values = Array(cap_drop).map(&:to_s).reject(&:empty?)
      return true if values.include?("ALL")

      # Podman expands `--cap-drop ALL` into the concrete capability names in
      # inspect output. The inside-container /proc/self/status attestation still
      # proves CapEff/CapPrm/CapBnd are zero; this inspect check accepts the
      # expanded runtime representation instead of requiring Docker's literal
      # "ALL" echo.
      values.any? && values.all? { |value| value.match?(/\ACAP_[A-Z0-9_]+\z/) }
    end

    def engine_run_same_filesystem_path?(observed, expected)
      observed_path = engine_run_normalized_filesystem_path(observed)
      expected_path = engine_run_normalized_filesystem_path(expected)
      !observed_path.empty? && observed_path == expected_path
    end

    def engine_run_normalized_filesystem_path(path)
      text = path.to_s.strip
      return "" if text.empty?

      expanded = File.expand_path(text)
      expanded = File.realpath(expanded) if File.exist?(expanded)
      normalized = expanded.tr("\\", "/").sub(%r{/+\z}, "")
      File::ALT_SEPARATOR == "\\" ? normalized.downcase : normalized
    rescue ArgumentError, SystemCallError
      text.tr("\\", "/").sub(%r{/+\z}, "")
    end
  end
end
