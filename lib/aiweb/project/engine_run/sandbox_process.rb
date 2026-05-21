# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    private

    def engine_run_preflight_probe_command(command, cidfile)
      argv = Array(command).map(&:to_s)
      run_index = argv.index("run")
      return argv unless run_index

      argv.dup.tap do |copy|
        copy.delete_at(copy.index("--rm")) if copy.include?("--rm")
        copy.insert(run_index + 1, "--cidfile", cidfile.to_s)
      end
    end

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

    def engine_run_remove_runtime_container(sandbox, container_id)
      return if sandbox.to_s.strip.empty? || container_id.to_s.strip.empty?

      engine_run_sandbox_runtime_capture(sandbox, ["rm", "-f", container_id.to_s], risk_class: "engine_run_sandbox_container_cleanup", timeout: 10, max_output_bytes: 8_000)
      nil
    rescue ArgumentError, SystemCallError
      nil
    end

    def engine_run_digest_pinned_image?(image)
      image.to_s.include?("@sha256:")
    end

    def engine_run_require_digest_pinned_openmanus_image?
      !engine_run_digest_pinned_openmanus_policy_sources.empty?
    end

    def engine_run_required_sandbox_runtime_matrix
      engine_run_sandbox_runtime_matrix_tokens.select { |runtime| %w[docker podman].include?(runtime) }.uniq
    end

    def engine_run_invalid_sandbox_runtime_matrix
      engine_run_sandbox_runtime_matrix_tokens.reject { |runtime| %w[docker podman].include?(runtime) }.uniq
    end

    def engine_run_sandbox_runtime_matrix_tokens
      raw = ENV["AIWEB_ENGINE_RUN_RUNTIME_MATRIX"].to_s
      raw = "docker,podman" if raw.strip.empty? && engine_run_truthy_env?(ENV["AIWEB_ENGINE_RUN_REQUIRE_RUNTIME_MATRIX"])
      raw = "docker,podman" if raw.strip.empty? && engine_run_truthy_env?(ENV["AIWEB_REQUIRE_DOCKER_PODMAN_MATRIX"])
      raw.split(/[\s,]+/).map(&:strip).map(&:downcase).reject(&:empty?)
    end

    def engine_run_required_sandbox_runtime_matrix_policy_sources
      sources = []
      sources << "AIWEB_ENGINE_RUN_RUNTIME_MATRIX" unless ENV["AIWEB_ENGINE_RUN_RUNTIME_MATRIX"].to_s.strip.empty?
      sources << "AIWEB_ENGINE_RUN_REQUIRE_RUNTIME_MATRIX" if engine_run_truthy_env?(ENV["AIWEB_ENGINE_RUN_REQUIRE_RUNTIME_MATRIX"])
      sources << "AIWEB_REQUIRE_DOCKER_PODMAN_MATRIX" if engine_run_truthy_env?(ENV["AIWEB_REQUIRE_DOCKER_PODMAN_MATRIX"])
      sources
    end

    def engine_run_truthy_env?(value)
      %w[1 true yes on strict required].include?(value.to_s.strip.downcase)
    end

    def engine_run_digest_pinned_openmanus_policy_sources
      values = [
        ["AIWEB_OPENMANUS_REQUIRE_DIGEST", ENV["AIWEB_OPENMANUS_REQUIRE_DIGEST"]],
        ["AIWEB_REQUIRE_PINNED_OPENMANUS_IMAGE", ENV["AIWEB_REQUIRE_PINNED_OPENMANUS_IMAGE"]],
        ["AIWEB_ENGINE_RUN_STRICT_SANDBOX", ENV["AIWEB_ENGINE_RUN_STRICT_SANDBOX"]],
        ["AIWEB_ENV", ENV["AIWEB_ENV"]],
        ["AIWEB_RUNTIME_ENV", ENV["AIWEB_RUNTIME_ENV"]],
        ["AIWEB_ENGINE_RUN_ENV", ENV["AIWEB_ENGINE_RUN_ENV"]]
      ]
      values.each_with_object([]) do |(name, value), sources|
        normalized = value.to_s.strip.downcase
        next unless %w[1 true yes on strict production prod].include?(normalized)

        sources << name
      end
    end

    def engine_run_sandbox_preflight_warnings(image:, image_inspect:, runtime_info:, inside_probe:)
      warnings = []
      warnings << "container image reference is not digest-pinned" if image.to_s.strip != "" && !engine_run_digest_pinned_image?(image)
      warnings << "container image digest was not observable" if image.to_s.strip != "" && image_inspect.fetch("digest", nil).to_s.strip.empty?
      warnings << "sandbox runtime rootless/rootful mode was not observable" if runtime_info.fetch("rootless_mode", "not_observed") == "not_observed"
      warnings << "inside-container self-attestation probe did not pass" unless inside_probe.fetch("status", "not_observed") == "passed"
      warnings << "inside-container egress denial was not proven" unless inside_probe.dig("egress_denial_probe", "status") == "passed"
      warnings
    end

    def engine_run_container_image_inspect(sandbox, image)
      return { "status" => "skipped", "reason" => "missing_sandbox_or_image" } if sandbox.to_s.strip.empty? || image.to_s.strip.empty?

      result = engine_run_sandbox_runtime_capture(sandbox, ["image", "inspect", image.to_s], risk_class: "engine_run_sandbox_image_inspect")
      return { "status" => "failed", "exit_code" => result.exit_code } unless result.success?
      return { "status" => "failed", "reason" => "image_inspect_empty_output" } if result.stdout.to_s.strip.empty?

      parsed = JSON.parse(result.stdout.to_s)
      image_record = parsed.is_a?(Array) ? parsed.first : parsed
      return { "status" => "failed", "reason" => "image_inspect_missing_record" } unless image_record.is_a?(Hash)

      repo_digests = Array(image_record["RepoDigests"]).map(&:to_s).reject(&:empty?)
      image_id = image_record["Id"].to_s
      digest = repo_digests.find { |entry| entry.include?("@sha256:") } ||
               (image_id.match?(/\Asha256:[a-f0-9]{64}\z/i) ? image_id : nil)
      return { "status" => "failed", "reason" => "image_inspect_missing_digest", "repo_digests" => repo_digests, "image_id" => image_id.empty? ? nil : image_id } if digest.to_s.empty?

      {
        "status" => "passed",
        "digest" => digest,
        "repo_digests" => repo_digests,
        "image_id" => image_id.empty? ? nil : image_id,
        "created" => image_record["Created"],
        "architecture" => image_record["Architecture"],
        "os" => image_record["Os"]
      }
    rescue JSON::ParserError
      { "status" => "failed", "reason" => "image_inspect_parse_failed" }
    rescue ArgumentError, SystemCallError => e
      { "status" => "failed", "error" => e.message }
    end

    def engine_run_container_image_digest(image, image_inspect)
      return image.to_s[/sha256:[a-f0-9]{64}/i] if engine_run_digest_pinned_image?(image)

      image_inspect.fetch("digest", nil)
    end

    def engine_run_sandbox_runtime_info(sandbox)
      return { "status" => "skipped", "reason" => "missing_sandbox" } if sandbox.to_s.strip.empty?

      result = engine_run_sandbox_runtime_capture(sandbox, ["info", "--format", "{{json .}}"], risk_class: "engine_run_sandbox_runtime_info")
      return { "status" => "failed", "exit_code" => result.exit_code, "rootless_mode" => "not_observed", "security_options" => [] } unless result.success?

      parsed = result.stdout.to_s.strip.empty? ? {} : JSON.parse(result.stdout.to_s)
      parsed = {} unless parsed.is_a?(Hash)
      security_options = Array(parsed["SecurityOptions"] || parsed.dig("Host", "Security", "SecurityOptions")).map(&:to_s)
      rootless = parsed.dig("Host", "Security", "Rootless")
      rootless = security_options.any? { |item| item.match?(/rootless/i) } if rootless.nil?
      {
        "status" => "passed",
        "rootless_mode" => rootless.nil? ? "not_observed" : (rootless ? "observed_rootless" : "observed_rootful"),
        "security_options" => security_options,
        "server_version" => parsed["ServerVersion"] || parsed["Version"],
        "driver" => parsed["Driver"],
        "cgroup_driver" => parsed["CgroupDriver"] || parsed.dig("Host", "CgroupManager")
      }
    rescue JSON::ParserError
      { "status" => "passed", "raw_parse_failed" => true, "rootless_mode" => "not_observed", "security_options" => [] }
    rescue ArgumentError, SystemCallError => e
      { "status" => "failed", "error" => e.message, "rootless_mode" => "not_observed", "security_options" => [] }
    end

    def engine_run_sandbox_runtime_capture(sandbox, args, risk_class:, timeout: 15, max_output_bytes: 32_000)
      executable = executable_path(sandbox.to_s) || sandbox.to_s
      runtime_process_runner.capture(
        Aiweb::Runtime::CommandSpec.new(
          argv: [executable, *Array(args).map(&:to_s)],
          cwd: root,
          env: subprocess_path_env,
          timeout: timeout,
          max_output_bytes: max_output_bytes,
          risk_class: risk_class,
          description: "engine-run sandbox runtime attestation"
        )
      )
    end

    def engine_run_sandbox_negative_checks(argv, workspace_dir)
      mounts = sandbox_runtime_argv_values(argv, "-v")
      mounted_hosts = mounts.map { |mount| sandbox_runtime_mount_host(mount) }.reject(&:empty?).map { |host| File.expand_path(host) }
      forbidden = {
        "project_root" => root,
        ".git" => File.join(root, ".git"),
        ".env" => File.join(root, ".env"),
        ".env.local" => File.join(root, ".env.local"),
        "cloud_credentials" => File.join(Dir.home, ".aws"),
        "browser_profiles" => File.join(Dir.home, ".config", "google-chrome"),
        "host_home" => Dir.home
      }
      expected_workspace = File.expand_path(workspace_dir)
      forbidden.transform_values do |path|
        expanded = File.expand_path(path)
        mounted = mounted_hosts.any? do |host|
          host_cmp = windows? ? host.downcase : host
          expanded_cmp = windows? ? expanded.downcase : expanded
          workspace_cmp = windows? ? expected_workspace.downcase : expected_workspace
          next false if host_cmp == workspace_cmp

          host_cmp == expanded_cmp || expanded_cmp.start_with?("#{host_cmp}#{File::SEPARATOR}") || host_cmp.start_with?("#{expanded_cmp}#{File::SEPARATOR}")
        end
        mounted ? "mounted" : "not_mounted"
      end
    rescue SystemCallError
      { "status" => "unknown" }
    end

    def engine_run_sandbox_tool_command(sandbox, workspace_dir, command, tool: "verification", agent: "openmanus")
      provider = sandbox.to_s
      sandbox_runtime_container_command(
        provider: provider,
        workspace_dir: workspace_dir,
        image: engine_run_agent_container_image(agent),
        env: engine_run_agent_container_env(agent, provider).merge("AIWEB_ENGINE_RUN_TOOL" => tool),
        pids_limit: 512,
        memory: "2g",
        cpus: "2",
        tmpfs_size: "128m",
        command: command
      )
    end

    def engine_run_verification_env(workspace_dir, paths = nil, sandbox = nil)
      FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb", "home"))
      FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb", "tmp"))
      if paths && !sandbox.to_s.strip.empty?
        return engine_run_clean_env(workspace_dir, paths, sandbox)
      end

      subprocess_path_env.merge(
        "AIWEB_ENGINE_RUN_WORKSPACE" => workspace_dir,
        "AIWEB_NETWORK_ALLOWED" => "0",
        "AIWEB_MCP_ALLOWED" => "0",
        "AIWEB_ENV_ACCESS_ALLOWED" => "0",
        "HOME" => File.join(workspace_dir, "_aiweb", "home"),
        "USERPROFILE" => File.join(workspace_dir, "_aiweb", "home"),
        "TMPDIR" => File.join(workspace_dir, "_aiweb", "tmp"),
        "TMP" => File.join(workspace_dir, "_aiweb", "tmp"),
        "TEMP" => File.join(workspace_dir, "_aiweb", "tmp")
      )
    end

    def engine_run_capture_command(command, cwd, timeout_sec, env: subprocess_path_env)
      result = runtime_process_runner.capture(
        Aiweb::Runtime::CommandSpec.new(
          argv: Array(command).map(&:to_s),
          cwd: cwd,
          env: env,
          timeout: timeout_sec,
          max_output_bytes: 200_000,
          risk_class: "engine_run_capture_command",
          description: "engine-run brokered capture command",
          allow_shell_meta: true
        )
      )
      exit_code = result.status == "timeout" ? 124 : (result.exit_code || 127)
      [result.stdout.to_s, result.stderr.to_s, exit_code]
    rescue ArgumentError, SystemCallError => e
      ["", "#{e.message}\n", 127]
    end

    def engine_run_try_reap_process(pid)
      return nil unless pid

      reaped = Process.waitpid(pid, Process::WNOHANG)
      reaped ? $?.exitstatus : nil
    rescue Errno::ECHILD
      0
    rescue SystemCallError
      nil
    end

    def engine_run_process_alive?(pid)
      return false unless pid

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::ECHILD, SystemCallError
      false
    end

    def engine_run_stop_process(pid)
      return nil unless pid
      return "already_exited" unless engine_run_try_reap_process(pid).nil?

      begin
        Process.kill("TERM", pid)
      rescue SignalException, SystemCallError
        begin
          Process.kill("KILL", pid)
        rescue SignalException, SystemCallError
          return "kill_failed"
        end
      end
      deadline = Time.now + 2
      while Time.now < deadline
        return "stopped" unless engine_run_try_reap_process(pid).nil?
        sleep 0.05
      end
      begin
        Process.kill("KILL", pid)
      rescue SignalException, SystemCallError
        nil
      end
      engine_run_try_reap_process(pid)
      "killed"
    end

  end
end
