# frozen_string_literal: true

require "json"

module Aiweb
  module ProjectAgentRun
    private

    def agent_run_openmanus_sandbox_name(value)
      text = value.to_s.strip.downcase
      text.empty? ? nil : text
    end

    def agent_run_openmanus_sandbox_blockers(command, sandbox:, workspace_dir:)
      return ["openmanus approved execution requires --sandbox docker or --sandbox podman so aiweb can construct and verify the OS/network sandbox"] if sandbox.to_s.empty?
      return ["openmanus sandbox must be docker or podman"] unless %w[docker podman].include?(sandbox.to_s)
      return ["openmanus sandbox executable is missing from PATH: #{sandbox}"] if executable_path(sandbox).nil?

      agent_run_openmanus_sandbox_command_blockers(command, sandbox: sandbox, workspace_dir: workspace_dir) +
        agent_run_openmanus_image_blockers(command, sandbox: sandbox)
    end

    def agent_run_openmanus_sandbox_mode(command)
      executable = File.basename(Array(command).first.to_s).downcase
      executable = executable.sub(/\.(?:exe|cmd|bat|com)\z/, "")
      return executable if %w[docker podman].include?(executable)

      "missing"
    end

    def agent_run_openmanus_command_env(sandbox:, source_paths:, task_source:, run_id:, diff_path:, metadata_path:)
      {
        "AIWEB_AGENT_RUN_CONTEXT_PATH" => "/workspace/_aiweb/openmanus-context.json",
        "AIWEB_AGENT_RUN_ALLOWED_SOURCE_PATHS_JSON" => JSON.generate(source_paths),
        "AIWEB_AGENT_RUN_TASK_PATH" => task_source["relative"].to_s,
        "AIWEB_AGENT_RUN_APPROVED" => "1",
        "AIWEB_AGENT_RUN_DRY_RUN" => "0",
        "AIWEB_AGENT_RUN_RUN_ID" => run_id,
        "AIWEB_AGENT_RUN_DIFF_PATH" => relative(diff_path),
        "AIWEB_AGENT_RUN_METADATA_PATH" => relative(metadata_path),
        "AIWEB_OPENMANUS_WORKSPACE" => "/workspace",
        "AIWEB_OPENMANUS_RESULT_PATH" => "/workspace/_aiweb/openmanus-result.json",
        "AIWEB_OPENMANUS_SANDBOX" => sandbox.to_s,
        "AIWEB_TOOL_BROKER_EVENTS_PATH" => "/workspace/_aiweb/tool-broker-events.jsonl",
        "AIWEB_TOOL_BROKER_REAL_PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "PATH" => "/workspace/_aiweb/tool-broker-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "HOME" => "/workspace/_aiweb/home",
        "USERPROFILE" => "/workspace/_aiweb/home",
        "TMPDIR" => "/workspace/_aiweb/tmp",
        "TMP" => "/workspace/_aiweb/tmp",
        "TEMP" => "/workspace/_aiweb/tmp",
        "AIWEB_NETWORK_ALLOWED" => "0",
        "AIWEB_MCP_ALLOWED" => "0",
        "AIWEB_ENV_ACCESS_ALLOWED" => "0"
      }
    end

    def agent_run_openmanus_container_command(sandbox, workspace_dir, env)
      provider = sandbox.to_s
      image = ENV["AIWEB_OPENMANUS_IMAGE"].to_s.strip
      image = "openmanus:latest" if image.empty?
      sandbox_runtime_container_command(
        provider: provider,
        workspace_dir: workspace_dir,
        image: image,
        env: env,
        pids_limit: 256,
        memory: "1g",
        cpus: "1",
        tmpfs_size: "64m",
        command: ["openmanus"]
      )
    end

    def agent_run_openmanus_sandbox_command_blockers(command, sandbox:, workspace_dir:)
      sandbox_runtime_container_command_blockers(
        command,
        sandbox: sandbox,
        workspace_dir: workspace_dir,
        required_env: {
        "AIWEB_AGENT_RUN_CONTEXT_PATH" => "/workspace/_aiweb/openmanus-context.json",
        "AIWEB_OPENMANUS_RESULT_PATH" => "/workspace/_aiweb/openmanus-result.json",
        "AIWEB_TOOL_BROKER_EVENTS_PATH" => "/workspace/_aiweb/tool-broker-events.jsonl",
        "PATH" => "/workspace/_aiweb/tool-broker-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "AIWEB_NETWORK_ALLOWED" => "0",
        "AIWEB_MCP_ALLOWED" => "0",
        "AIWEB_ENV_ACCESS_ALLOWED" => "0"
        },
        label: "openmanus sandbox"
      )
    end

    def agent_run_openmanus_mount_blockers(argv, workspace_dir)
      mounts = agent_run_argv_values(argv, "-v")
      blockers = []
      expected_host = File.expand_path(workspace_dir, root)
      workspace_mounts = mounts.select { |mount| mount.match?(%r{:/workspace:rw\z}) }
      blockers << "openmanus sandbox command must mount only the staging workspace at /workspace:rw" unless workspace_mounts.length == 1
      workspace_mounts.each do |mount|
        host = mount.sub(%r{:/workspace:rw\z}, "")
        expected = windows? ? expected_host.downcase : expected_host
        actual = windows? ? File.expand_path(host).downcase : File.expand_path(host)
        blockers << "openmanus sandbox command must not mount the project root or any path except the staging workspace" unless actual == expected
      end
      mounts.each do |mount|
        next if mount.match?(%r{:/workspace:rw\z})

        host = mount.sub(/:.+\z/, "")
        target = mount.sub(/\A#{Regexp.escape(host)}:/, "").split(":").first.to_s
        next if target == "/workspace"

        blockers << "openmanus sandbox command contains unapproved mount target: #{target}"
      end
      blockers
    end

    def agent_run_openmanus_image_blockers(command, sandbox:)
      image = agent_run_openmanus_image(command)
      result = agent_run_openmanus_image_inspect_result(sandbox, image)
      return ["openmanus sandbox image preflight timed out for #{image}"] if result.status == "timeout"
      return [] if result.success?

      message = "openmanus sandbox image is missing locally: #{image}; build or pull it before approved execution"
      details = result.stderr.to_s.strip
      message = "#{message} (#{details[0, 200]})" unless details.empty?
      [message]
    rescue ArgumentError, SystemCallError => e
      ["openmanus sandbox image preflight failed for #{image}: #{e.message}"]
    end

    def agent_run_openmanus_image_inspect_result(sandbox, image)
      executable = executable_path(sandbox.to_s) || sandbox.to_s
      runtime_process_runner.capture(
        Aiweb::Runtime::CommandSpec.new(
          argv: [executable, "image", "inspect", image],
          cwd: root,
          timeout: 10,
          max_output_bytes: 16_000,
          risk_class: "agent_run_openmanus_image_preflight",
          description: "agent-run OpenManus local image inspect preflight"
        )
      )
    end

    def agent_run_openmanus_image(command)
      image = Array(command).map(&:to_s)[-2].to_s
      image.empty? ? "openmanus:latest" : image
    end

    def agent_run_argv_option_value(argv, flag)
      index = argv.index(flag)
      return argv[index + 1].to_s if index && index + 1 < argv.length

      prefix = "#{flag}="
      argv.find { |value| value.start_with?(prefix) }.to_s.delete_prefix(prefix)
    end

    def agent_run_argv_values(argv, flag)
      values = []
      argv.each_with_index do |value, index|
        values << argv[index + 1].to_s if value == flag && index + 1 < argv.length
        values << value.delete_prefix("#{flag}=") if value.start_with?("#{flag}=")
      end
      values
    end

    def agent_run_container_env_values(argv)
      agent_run_argv_values(argv, "-e").each_with_object({}) do |entry, memo|
        key, value = entry.split("=", 2)
        memo[key] = value unless value.nil?
      end
    end

    def agent_run_approved_command(agent_name, sandbox, approval_hash = "HASH")
      parts = ["aiweb", "agent-run", "--task", "latest", "--agent", agent_name]
      parts.concat(["--sandbox", sandbox]) if agent_name == "openmanus" && !sandbox.to_s.empty?
      parts.concat(["--approval-hash", approval_hash])
      parts << "--approved"
      parts.join(" ")
    end

    def agent_run_approved_next_action(agent_name, sandbox, approval_hash)
      if agent_name == "openmanus"
        chosen = sandbox.to_s.empty? ? "docker" : sandbox
        "review approval_hash #{approval_hash} for the lower-level openmanus adapter with #{chosen} sandbox; prefer aiweb agent or aiweb engine-run for user-facing execution"
      else
        "review approval_hash #{approval_hash} for the lower-level #{agent_name} adapter; prefer aiweb agent or aiweb engine-run for user-facing execution"
      end
    end

    def agent_run_source_security_blockers(source_paths)
      source_paths.each_with_object([]) do |path, blockers|
        normalized = agent_run_normalized_relative_path(path)
        expanded = File.expand_path(normalized, root)
        root_prefix = File.expand_path(root)
        comparison_expanded = windows? ? expanded.downcase : expanded
        comparison_root = windows? ? root_prefix.downcase : root_prefix
        unless comparison_expanded == comparison_root || comparison_expanded.start_with?(comparison_root + File::SEPARATOR)
          blockers << "agent-run source path escapes project root: #{normalized}"
        end
        blockers << "agent-run refuses symlink source path: #{normalized}" if File.symlink?(expanded)
        blockers << "agent-run refuses unsafe secret-looking source path: #{normalized}" if unsafe_secret_surface_path?(normalized)
        if File.file?(expanded) && File.lstat(expanded).nlink.to_i > 1
          blockers << "agent-run refuses hardlinked source path: #{normalized}"
        end
      end.uniq
    end

  end
end
