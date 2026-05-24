# frozen_string_literal: true

require_relative "sandbox_process/image_inspect"
require_relative "sandbox_process/policy"
require_relative "sandbox_process/runtime_inspect"

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

    def engine_run_remove_runtime_container(sandbox, container_id)
      return if sandbox.to_s.strip.empty? || container_id.to_s.strip.empty?

      engine_run_sandbox_runtime_capture(sandbox, ["rm", "-f", container_id.to_s], risk_class: "engine_run_sandbox_container_cleanup", timeout: 10, max_output_bytes: 8_000)
      nil
    rescue ArgumentError, SystemCallError
      nil
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
