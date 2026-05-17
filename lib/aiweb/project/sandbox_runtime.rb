# frozen_string_literal: true

module Aiweb
  module ProjectSandboxRuntime
    private

    def sandbox_runtime_container_command(provider:, workspace_dir:, image:, env:, pids_limit:, memory:, cpus:, tmpfs_size:, command:)
      [
        provider.to_s, "run", "--rm", "-i",
        "--network", "none",
        "--read-only",
        "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges",
        "--user", sandbox_runtime_user,
        "--pids-limit", pids_limit.to_s,
        "--memory", memory.to_s,
        "--cpus", cpus.to_s,
        "--tmpfs", "/tmp:rw,noexec,nosuid,nodev,size=#{tmpfs_size}",
        "-v", "#{File.expand_path(workspace_dir)}:/workspace:rw",
        "-w", "/workspace",
        *sandbox_runtime_env_flags(env),
        image.to_s,
        *Array(command).map(&:to_s)
      ]
    end

    def sandbox_runtime_container_command_blockers(command, sandbox:, workspace_dir:, required_env:, label:)
      argv = Array(command).map(&:to_s)
      blockers = []
      executable = File.basename(argv.first.to_s).downcase.sub(/\.(?:exe|cmd|bat|com)\z/, "")
      blockers << "#{label} command must start with #{sandbox}" unless executable == sandbox.to_s
      blockers << "#{label} command must use #{sandbox} run" unless argv[1] == "run"
      blockers << "#{label} command must disable networking with --network none" unless sandbox_runtime_argv_option_value(argv, "--network") == "none"
      blockers << "#{label} command must use --read-only root filesystem" unless argv.include?("--read-only")
      blockers << "#{label} command must drop all capabilities" unless sandbox_runtime_argv_option_value(argv, "--cap-drop") == "ALL"
      blockers << "#{label} command must set no-new-privileges" unless sandbox_runtime_argv_option_value(argv, "--security-opt") == "no-new-privileges"
      user = sandbox_runtime_argv_option_value(argv, "--user")
      blockers << "#{label} command must run as a non-root numeric user" if user.to_s.empty? || user.to_s.match?(/\A(?:0(?::0)?|root)(?::|$)/i)
      blockers << "#{label} command must set --pids-limit" if sandbox_runtime_argv_option_value(argv, "--pids-limit").to_s.empty?
      blockers << "#{label} command must set --memory" if sandbox_runtime_argv_option_value(argv, "--memory").to_s.empty?
      blockers << "#{label} command must set --cpus" if sandbox_runtime_argv_option_value(argv, "--cpus").to_s.empty?
      blockers << "#{label} command must mount a restricted /tmp tmpfs" unless sandbox_runtime_argv_option_value(argv, "--tmpfs").to_s.start_with?("/tmp:")
      blockers << "#{label} command must set workdir to /workspace" unless sandbox_runtime_argv_option_value(argv, "-w") == "/workspace"
      blockers.concat(sandbox_runtime_mount_blockers(argv, workspace_dir, label: label))
      blockers.concat(sandbox_runtime_env_blockers(argv, required_env, label: label))
      blockers.uniq
    end

    def sandbox_runtime_user
      configured = ENV["AIWEB_ENGINE_RUN_SANDBOX_USER"].to_s.strip
      configured = ENV["AIWEB_SANDBOX_USER"].to_s.strip if configured.empty?
      configured.empty? ? "1000:1000" : configured
    end

    def sandbox_runtime_env_flags(env)
      env.to_h.sort.flat_map do |key, value|
        ["-e", "#{key}=#{value}"]
      end
    end

    def sandbox_runtime_env_blockers(argv, required_env, label:)
      entries = sandbox_runtime_argv_values(argv, "-e")
      blockers = []
      entries.each do |entry|
        blockers << "#{label} command must not use unsafe env passthrough: #{entry}" unless entry.include?("=")
      end
      env_values = sandbox_runtime_container_env_values(argv)
      required_env.to_h.each do |key, expected|
        blockers << "#{label} command must pass #{key}=#{expected}" unless env_values[key.to_s] == expected.to_s
      end
      blockers
    end

    def sandbox_runtime_mount_blockers(argv, workspace_dir, label:)
      mounts = sandbox_runtime_argv_values(argv, "-v")
      blockers = []
      expected_host = File.expand_path(workspace_dir)
      workspace_mounts = mounts.select { |mount| mount.match?(%r{:/workspace:rw\z}) }
      blockers << "#{label} command must mount only the staging workspace at /workspace:rw" unless workspace_mounts.length == 1
      workspace_mounts.each do |mount|
        host = mount.sub(%r{:/workspace:rw\z}, "")
        expected = windows? ? expected_host.downcase : expected_host
        actual = windows? ? File.expand_path(host).downcase : File.expand_path(host)
        blockers << "#{label} command must not mount the project root or any path except the staging workspace" unless actual == expected
      end
      mounts.each do |mount|
        next if mount.match?(%r{:/workspace:rw\z})

        target = sandbox_runtime_mount_target(mount)
        next if target == "/workspace"

        blockers << "#{label} command contains unapproved mount target: #{target}"
      end
      blockers
    end

    def sandbox_runtime_container_env_values(argv)
      sandbox_runtime_argv_values(argv, "-e").each_with_object({}) do |entry, memo|
        key, value = entry.split("=", 2)
        memo[key] = value unless value.nil?
      end
    end

    def sandbox_runtime_argv_option_value(argv, flag)
      index = argv.index(flag)
      return argv[index + 1].to_s if index && index + 1 < argv.length

      prefix = "#{flag}="
      argv.find { |value| value.start_with?(prefix) }.to_s.delete_prefix(prefix)
    end

    def sandbox_runtime_argv_values(argv, flag)
      values = []
      argv.each_with_index do |value, index|
        values << argv[index + 1].to_s if value == flag && index + 1 < argv.length
        values << value.delete_prefix("#{flag}=") if value.start_with?("#{flag}=")
      end
      values
    end

    def sandbox_runtime_mount_host(mount)
      parts = mount.to_s.split(":")
      return "" if parts.length < 3

      parts[0...-2].join(":")
    end

    def sandbox_runtime_mount_target(mount)
      parts = mount.to_s.split(":")
      return "" if parts.length < 2

      parts[-2].to_s
    end
  end
end
