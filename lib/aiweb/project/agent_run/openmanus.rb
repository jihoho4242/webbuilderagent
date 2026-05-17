# frozen_string_literal: true

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
      _stdout, stderr, status = Open3.capture3(subprocess_path_env, sandbox.to_s, "image", "inspect", image, unsetenv_others: true)
      return [] if status.success?

      message = "openmanus sandbox image is missing locally: #{image}; build or pull it before approved execution"
      details = stderr.to_s.strip
      message = "#{message} (#{details[0, 200]})" unless details.empty?
      [message]
    rescue SystemCallError => e
      ["openmanus sandbox image preflight failed for #{image}: #{e.message}"]
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

    def agent_run_approved_command(agent_name, sandbox)
      parts = ["aiweb", "agent-run", "--task", "latest", "--agent", agent_name]
      parts.concat(["--sandbox", sandbox]) if agent_name == "openmanus" && !sandbox.to_s.empty?
      parts << "--approved"
      parts.join(" ")
    end

    def agent_run_approved_next_action(agent_name, sandbox)
      if agent_name == "openmanus"
        chosen = sandbox.to_s.empty? ? "docker" : sandbox
        "rerun aiweb agent-run --task latest --agent openmanus --sandbox #{chosen} --approved to execute the local openmanus patch run in an aiweb-managed sandbox"
      else
        "rerun aiweb agent-run --task latest --agent #{agent_name} --approved to execute the local #{agent_name} patch run"
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

    def agent_run_openmanus_contract(run_id:, run_dir:, context_path:, prompt_path:, validator_path:, result_path:, network_log_path:, browser_log_path:, denied_access_log_path:, tool_broker_log_path:, task_source:, context:, source_paths:, command:, dry_run:, approved:)
      workspace_dir = File.join(aiweb_dir, "tmp", "openmanus", run_id)
      selected_file = Array(context["selected_design_files"]).find { |file| file["kind"] == "selected_candidate" }
      source_hashes = source_paths.each_with_object({}) do |path, memo|
        full = File.join(root, path)
        next if File.symlink?(full) || unsafe_secret_surface_path?(path)

        memo[path] = "sha256:#{Digest::SHA256.file(full).hexdigest}" if File.file?(full)
      end
      context_hash_input = source_hashes.sort.map { |path, hash| "#{path}=#{hash}" }.join("\n")
      task_id = task_source["relative"].to_s[/([^\/\\]+)\.md\z/, 1]

      context_payload = {
        "schema_version" => 1,
        "mode" => dry_run ? "dry_run" : (approved ? "approved" : "blocked"),
        "run_id" => run_id,
        "task_id" => task_id,
        "task_path" => task_source["relative"],
        "project_root_hash" => "sha256:#{Digest::SHA256.hexdigest(context_hash_input)}",
        "workspace_root" => relative(workspace_dir),
        "design_path" => context.dig("design", "path"),
        "selected_candidate_path" => selected_file && selected_file["path"],
        "component_map_path" => context.dig("component_map", "path"),
        "allowed_source_paths" => source_paths,
        "allowed_globs" => source_paths,
        "denied_globs" => agent_run_denied_globs,
        "base_hashes" => source_hashes,
        "timeout_sec" => agent_run_openmanus_timeout,
        "max_output_bytes" => 200_000,
        "permission_profile" => "implementation-local-no-network",
        "sandbox_mode" => agent_run_openmanus_sandbox_mode(command),
        "sandbox_required" => true,
        "forbidden_actions" => %w[read_env install deploy external_network mcp_tools modify_unlisted_files],
        "tool_broker" => {
          "events_path" => "_aiweb/tool-broker-events.jsonl",
          "host_evidence_path" => relative(tool_broker_log_path),
          "bin_path" => "_aiweb/tool-broker-bin",
          "path_prepend_required" => true,
          "blocks" => %w[package_install external_network deploy provider_cli git_push env_read]
        },
        "expected_output" => "source changes inside the isolated workspace only"
      }

      {
        "context" => context_payload,
        "planned_context_path" => relative(context_path),
        "planned_prompt_path" => relative(prompt_path),
        "planned_validator_path" => relative(validator_path),
        "planned_result_path" => relative(result_path),
        "planned_network_log_path" => relative(network_log_path),
        "planned_browser_request_log_path" => relative(browser_log_path),
        "planned_denied_access_log_path" => relative(denied_access_log_path),
        "workspace_root" => relative(workspace_dir),
        "contract_docs" => [
          "docs/contracts/openmanus-agent-run.md",
          "docs/contracts/security-boundary.md"
        ],
        "guardrails" => [
          "Ruby subprocess plus JSON file contract",
          "clean environment; no user tokens or provider credentials are intentionally passed",
          "workspace-scoped copy-back with allowed source copies only",
          "network and MCP are disabled by the aiweb-generated docker/podman sandbox and guard env",
          "secret surfaces and symlinks are rejected",
          "only allowed source files are copied back after validation"
        ]
      }
    end

    def agent_run_openmanus(state:, task_source:, context:, source_paths:, run_id:, run_dir:, stdout_path:, stderr_path:, metadata_path:, diff_path:, context_path:, prompt_path:, validator_path:, result_path:, network_log_path:, browser_log_path:, denied_access_log_path:, tool_broker_log_path:, command:, contract:)
      changes = []
      payload = nil
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << relative(run_dir)
        FileUtils.mkdir_p(File.dirname(diff_path))

        started_at = now
        prompt = agent_run_openmanus_prompt(context: context, contract_context: contract.fetch("context"))
        workspace_dir = File.join(root, contract.fetch("workspace_root"))
        workspace_result_path = File.join(workspace_dir, "_aiweb", "openmanus-result.json")
        stdout = +""
        stderr = +""
        exit_code = nil
        status = "blocked"
        blocking_issues = []
        changed_source_files = []
        openmanus_report = nil
        preapply_patch = ""

        changes << write_json(context_path, contract.fetch("context"), false)
        changes << write_file(prompt_path, prompt, false)
        workspace_blockers = agent_run_prepare_openmanus_workspace(workspace_dir, source_paths)
        changes << relative(workspace_dir)
        if workspace_blockers.empty?
          engine_run_prepare_workspace_tool_broker(workspace_dir)
          changes << relative(File.join(workspace_dir, "_aiweb", "tool-broker-bin"))
          changes << write_json(File.join(workspace_dir, "_aiweb", "openmanus-context.json"), contract.fetch("context"), false)
        end
        before_snapshot = agent_run_workspace_snapshot

        if workspace_blockers.empty?
          result = agent_run_capture_openmanus(
            command: command,
            prompt: prompt,
            workspace_dir: workspace_dir,
            timeout_sec: contract.dig("context", "timeout_sec"),
            context_path: context_path,
            result_path: workspace_result_path,
            source_paths: source_paths,
            run_id: run_id,
            metadata_path: metadata_path,
            diff_path: diff_path
          )
          stdout = agent_run_redact_process_output(result.fetch(:stdout))
          stderr = agent_run_redact_process_output(result.fetch(:stderr))
          exit_code = result[:exit_code]
          blocking_issues.concat(result.fetch(:blocking_issues))
          tool_broker_events = engine_run_workspace_tool_broker_events(workspace_dir)
          unless tool_broker_events.empty?
            blocked = tool_broker_events.map { |event| [event["risk_class"], event["tool_name"]].compact.join(":") }.reject(&:empty?).join(", ")
            blocking_issues << "openmanus tool broker blocked prohibited staged action: #{blocked}"
          end
          openmanus_report, report_blockers = agent_run_read_openmanus_report(workspace_result_path, source_paths)
          blocking_issues.concat(report_blockers)
          after_snapshot = agent_run_workspace_snapshot
          unauthorized_changes = agent_run_unauthorized_workspace_changes(before_snapshot, after_snapshot, [])
          unless unauthorized_changes.empty?
            blocking_issues << "openmanus rejected changes outside the isolated workspace: #{unauthorized_changes.join(", ")}"
          end
          changed_source_files, validation_blockers, validator = agent_run_validate_openmanus_workspace(
            workspace_dir: workspace_dir,
            source_paths: source_paths,
            base_hashes: contract.dig("context", "base_hashes")
          )
          blocking_issues.concat(validation_blockers)
          preapply_patch = agent_run_openmanus_workspace_diff(workspace_dir, changed_source_files)
          blocking_issues.concat(agent_run_validate_source_diff(preapply_patch, source_paths))
          if result[:success] && blocking_issues.empty?
            agent_run_apply_openmanus_changes(workspace_dir, changed_source_files)
            status = changed_source_files.empty? ? "no_changes" : "passed"
          else
            status = "failed"
          end
        else
          blocking_issues.concat(workspace_blockers)
          validator = {
            "schema_version" => 1,
            "status" => "blocked",
            "changed_source_files" => [],
            "blocking_issues" => blocking_issues
          }
        end

        changes << write_file(stdout_path, stdout, false)
        changes << write_file(stderr_path, stderr, false)
        changes << write_file(network_log_path, "network_allowed=false\n", false)
        changes << write_file(browser_log_path, "browser_navigation_allowed=localhost-only\n", false)
        changes << write_file(tool_broker_log_path, agent_run_openmanus_tool_broker_log(workspace_dir), false)
        changes << write_file(denied_access_log_path, blocking_issues.join("\n") + (blocking_issues.empty? ? "" : "\n"), false)
        diff_patch, diff_changed_files = if status == "passed" || status == "no_changes"
                                           agent_run_source_diff(source_paths)
                                         else
                                           [preapply_patch.to_s, changed_source_files]
                                         end
        diff_validation_blockers = agent_run_validate_source_diff(diff_patch, source_paths)
        unless diff_validation_blockers.empty?
          blocking_issues.concat(diff_validation_blockers)
          status = "failed"
        end
        changes << write_file(diff_path, diff_patch, false)
        patch_hash = diff_patch.to_s.empty? ? nil : "sha256:#{Digest::SHA256.hexdigest(diff_patch)}"
        validator ||= {}
        validator["status"] = blocking_issues.empty? ? "passed" : status
        validator["changed_source_files"] = changed_source_files
        validator["diff_changed_files"] = diff_changed_files
        validator["patch_hash"] = patch_hash
        validator["blocking_issues"] = blocking_issues
        validator["openmanus_report"] = openmanus_report if openmanus_report
        changes << write_json(validator_path, validator, false)

        result_payload = agent_run_openmanus_result_payload(
          status: status,
          exit_code: exit_code,
          changed_source_files: changed_source_files,
          diff_path: relative(diff_path),
          patch_hash: patch_hash,
          base_hashes: contract.dig("context", "base_hashes"),
          blocking_issues: blocking_issues,
          stdout_path: relative(stdout_path),
          stderr_path: relative(stderr_path),
          context_path: relative(context_path),
          validator_path: relative(validator_path),
          network_log_path: relative(network_log_path),
          browser_log_path: relative(browser_log_path),
          denied_access_log_path: relative(denied_access_log_path),
          tool_broker_log_path: relative(tool_broker_log_path),
          openmanus_report: openmanus_report
        )
        changes << write_json(result_path, result_payload, false)

        metadata = agent_run_run_metadata(
          run_id: run_id,
          agent: "openmanus",
          task_source: task_source,
          context: context,
          command: command.join(" "),
          context_path: relative(context_path),
          started_at: started_at,
          finished_at: now,
          exit_code: exit_code,
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          metadata_path: relative(metadata_path),
          diff_path: relative(diff_path),
          source_paths: source_paths,
          dry_run: false,
          approved: true,
          blocking_issues: blocking_issues,
          status: status,
          changed_source_files: changed_source_files
        )
        metadata["mode"] = "approved"
        metadata["permission_profile"] = "implementation-local-no-network"
        metadata["openmanus"] = contract.merge(
          "result_path" => relative(result_path),
          "validator_path" => relative(validator_path),
          "patch_hash" => patch_hash,
          "evidence" => result_payload.fetch("evidence")
        )
        changes << write_json(metadata_path, metadata, false)
        changes.concat(changed_source_files)

        state["implementation"]["latest_agent_run"] = relative(metadata_path)
        state["implementation"]["last_diff"] = relative(diff_path)
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)

        payload = agent_run_payload(
          state: state,
          metadata: metadata,
          changed_files: compact_changes(changes),
          planned_changes: [],
          action_taken: status == "passed" ? "ran openmanus patch" : (status == "no_changes" ? "openmanus produced no source diff" : "openmanus agent run failed"),
          blocking_issues: blocking_issues,
          next_action: agent_run_next_action(metadata)
        )
      end
      payload
    end

    def agent_run_openmanus_prompt(context:, contract_context:)
      [
        "You are OpenManus running as a bounded aiweb implementation adapter.",
        "You are not the project director. aiweb owns state, gates, QA, and deploy.",
        "Patch only the allowed source files copied into this workspace.",
        "Do not read secret surfaces, environment files, browser profiles, package credentials, or provider CLI auth stores.",
        "Do not install packages, run deploy/provider CLIs, use MCP, or contact external networks.",
        "The contract JSON is available at AIWEB_AGENT_RUN_CONTEXT_PATH.",
        "",
        "## Contract",
        JSON.pretty_generate(contract_context),
        "",
        agent_run_prompt(context: context)
      ].join("\n")
    end

    def agent_run_prepare_openmanus_workspace(workspace_dir, source_paths)
      blockers = []
      return ["openmanus workspace already exists and will not be reused: #{relative(workspace_dir)}"] if File.exist?(workspace_dir) || File.symlink?(workspace_dir)

      base_dir = File.dirname(workspace_dir)
      FileUtils.mkdir_p(base_dir)
      return ["openmanus workspace base is unsafe: #{relative(base_dir)}"] if File.symlink?(base_dir)

      Dir.mkdir(workspace_dir)
      FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb"))
      FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb", "home"))
      FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb", "tmp"))
      base_real = File.realpath(base_dir)
      workspace_real = File.realpath(workspace_dir)
      unless workspace_real == base_real || workspace_real.start_with?(base_real + File::SEPARATOR)
        return ["openmanus workspace escaped expected base: #{relative(workspace_dir)}"]
      end
      source_paths.each do |path|
        normalized = agent_run_normalized_relative_path(path)
        source = File.join(root, normalized)
        target = File.join(workspace_dir, normalized)
        if unsafe_secret_surface_path?(normalized) || File.symlink?(source)
          blockers << "openmanus workspace refused unsafe source path: #{normalized}"
          next
        end
        if File.file?(source) && File.lstat(source).nlink.to_i > 1
          blockers << "openmanus workspace refused hardlinked source path: #{normalized}"
          next
        end
        unless File.file?(source)
          blockers << "openmanus workspace source file is missing: #{normalized}"
          next
        end
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(source, target)
      end
      blockers
    rescue SystemCallError => e
      ["openmanus workspace preparation failed: #{e.message}"]
    end

    def agent_run_capture_openmanus(command:, prompt:, workspace_dir:, timeout_sec:, context_path:, result_path:, source_paths:, run_id:, metadata_path:, diff_path:)
      env = agent_run_clean_openmanus_env(
        context_path: context_path,
        result_path: result_path,
        workspace_dir: workspace_dir,
        source_paths: source_paths,
        run_id: run_id,
        metadata_path: metadata_path,
        diff_path: diff_path,
        sandbox_mode: agent_run_openmanus_sandbox_mode(command)
      )
      stdout_data = +""
      stderr_data = +""
      exit_code = nil
      blocking_issues = []
      success = false
      timed_out = false
      Open3.popen3(env, *command, chdir: workspace_dir, unsetenv_others: true) do |stdin, stdout, stderr, wait_thr|
        stdin.write(prompt)
        stdin.close
        stdout_reader = Thread.new { stdout.read.to_s rescue "" }
        stderr_reader = Thread.new { stderr.read.to_s rescue "" }
        unless wait_thr.join(timeout_sec.to_i)
          timed_out = true
          agent_run_kill_process(wait_thr.pid)
          agent_run_close_stream(stdout)
          agent_run_close_stream(stderr)
        end
        stdout_data = agent_run_limit_process_output(stdout_reader.value.to_s)
        stderr_data = agent_run_limit_process_output(stderr_reader.value.to_s)
        status = wait_thr.value if wait_thr.join(1)
        exit_code = status&.exitstatus
        success = status&.success? == true
      end
      if timed_out
        blocking_issues << "openmanus timed out after #{timeout_sec}s"
      elsif !success
        blocking_issues << "openmanus exited with status #{exit_code || "unknown"}"
      end
      {
        stdout: stdout_data,
        stderr: stderr_data,
        exit_code: exit_code,
        success: success,
        blocking_issues: blocking_issues
      }
    rescue SystemCallError => e
      {
        stdout: stdout_data,
        stderr: "#{stderr_data}#{e.message}\n",
        exit_code: exit_code,
        success: false,
        blocking_issues: ["openmanus subprocess failed: #{e.message}"]
      }
    end

    def agent_run_validate_openmanus_workspace(workspace_dir:, source_paths:, base_hashes:)
      allowed = source_paths.to_set
      blockers = []
      changed = []
      extra_files = []
      workspace_files = []
      Find.find(workspace_dir) do |path|
        next if File.directory?(path)

        relative_path = path.sub(/^#{Regexp.escape(workspace_dir)}[\\\/]?/, "").tr("\\", "/")
        next if relative_path.start_with?("_aiweb/")

        workspace_files << relative_path
        if File.symlink?(path) || unsafe_secret_surface_path?(relative_path)
          blockers << "openmanus produced unsafe workspace file: #{relative_path}"
          next
        end
        blockers << "openmanus produced hardlinked workspace file: #{relative_path}" if File.lstat(path).nlink.to_i > 1
        if allowed.include?(relative_path) && agent_run_binary_file?(path)
          blockers << "openmanus produced binary content for source file: #{relative_path}"
        end
        extra_files << relative_path unless allowed.include?(relative_path)
      end
      missing = source_paths.reject { |path| File.file?(File.join(workspace_dir, path)) }
      missing.each { |path| blockers << "openmanus deleted allowed source file: #{path}" }
      extra_files.each { |path| blockers << "openmanus produced unapproved file: #{path}" }
      source_paths.each do |path|
        source = File.join(root, path)
        workspace = File.join(workspace_dir, path)
        next unless File.file?(source) && File.file?(workspace)

        expected = base_hashes[path].to_s.sub(/\Asha256:/, "")
        current = Digest::SHA256.file(source).hexdigest
        blockers << "source changed during openmanus run before apply: #{path}" unless expected.empty? || current == expected
        blockers << "openmanus copy-back target is hardlinked and unsafe: #{path}" if File.lstat(source).nlink.to_i > 1
        if !windows? && File.executable?(workspace) && !File.executable?(source)
          blockers << "openmanus attempted to add executable mode to source file: #{path}"
        end
        changed << path unless Digest::SHA256.file(workspace).hexdigest == expected
      end
      validator = {
        "schema_version" => 1,
        "workspace_files" => workspace_files.sort,
        "allowed_source_paths" => source_paths,
        "extra_files" => extra_files.sort,
        "missing_files" => missing,
        "changed_source_files" => changed,
        "blocking_issues" => blockers
      }
      [changed, blockers.uniq, validator]
    rescue SystemCallError => e
      [[], ["openmanus workspace validation failed: #{e.message}"], { "schema_version" => 1, "blocking_issues" => [e.message] }]
    end

    def agent_run_apply_openmanus_changes(workspace_dir, changed_source_files)
      changed_source_files.each do |path|
        source = File.join(workspace_dir, path)
        target = File.join(root, path)
        raise UserError.new("openmanus copy-back target is hardlinked and unsafe: #{path}", 5) if File.file?(target) && File.lstat(target).nlink.to_i > 1

        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(source, target)
      end
    end

    def agent_run_binary_file?(path)
      File.open(path, "rb") { |file| file.read(4096).to_s.include?("\x00") }
    rescue SystemCallError
      false
    end

    def agent_run_openmanus_result_payload(status:, exit_code:, changed_source_files:, diff_path:, patch_hash:, base_hashes:, blocking_issues:, stdout_path:, stderr_path:, context_path:, validator_path:, network_log_path:, browser_log_path:, denied_access_log_path:, tool_broker_log_path:, openmanus_report: nil)
      {
        "schema_version" => 1,
        "status" => status,
        "mode" => "approved",
        "agent" => "openmanus",
        "exit_code" => exit_code,
        "agent_version" => "openmanus:unknown",
        "permission_profile" => "implementation-local-no-network",
        "changed_source_files" => changed_source_files,
        "diff_path" => diff_path,
        "patch_hash" => patch_hash,
        "patch_base_hashes" => base_hashes || {},
        "redactions" => ["secret-like stdout/stderr values", "unsafe .env references"],
        "blocking_issues" => blocking_issues,
        "error_code" => blocking_issues.empty? ? nil : "OPENMANUS_AGENT_RUN_BLOCKED",
        "openmanus_report" => openmanus_report,
        "evidence" => {
          "stdout_log" => stdout_path,
          "stderr_log" => stderr_path,
          "context_manifest" => context_path,
          "validator_result" => validator_path,
          "network_log" => network_log_path,
          "browser_request_log" => browser_log_path,
          "tool_broker_log" => tool_broker_log_path,
          "denied_access_log" => denied_access_log_path
        }
      }
    end

    def agent_run_clean_openmanus_env(context_path:, result_path:, workspace_dir:, source_paths:, run_id:, metadata_path:, diff_path:, sandbox_mode:)
      allowed = subprocess_path_env
      allowed.merge(
        "AIWEB_AGENT_RUN_CONTEXT_PATH" => context_path,
        "AIWEB_AGENT_RUN_ALLOWED_SOURCE_PATHS_JSON" => JSON.generate(source_paths),
        "AIWEB_AGENT_RUN_TASK_PATH" => "",
        "AIWEB_AGENT_RUN_APPROVED" => "1",
        "AIWEB_AGENT_RUN_DRY_RUN" => "0",
        "AIWEB_AGENT_RUN_RUN_ID" => run_id,
        "AIWEB_AGENT_RUN_DIFF_PATH" => relative(diff_path),
        "AIWEB_AGENT_RUN_METADATA_PATH" => relative(metadata_path),
        "AIWEB_OPENMANUS_WORKSPACE" => workspace_dir,
        "AIWEB_OPENMANUS_RESULT_PATH" => result_path,
        "AIWEB_OPENMANUS_SANDBOX" => sandbox_mode,
        "AIWEB_TOOL_BROKER_EVENTS_PATH" => File.join(workspace_dir, "_aiweb", "tool-broker-events.jsonl"),
        "AIWEB_TOOL_BROKER_REAL_PATH" => ENV.fetch("PATH", ""),
        "HOME" => File.join(workspace_dir, "_aiweb", "home"),
        "USERPROFILE" => File.join(workspace_dir, "_aiweb", "home"),
        "TMPDIR" => File.join(workspace_dir, "_aiweb", "tmp"),
        "TMP" => File.join(workspace_dir, "_aiweb", "tmp"),
        "TEMP" => File.join(workspace_dir, "_aiweb", "tmp"),
        "AIWEB_NETWORK_ALLOWED" => "0",
        "AIWEB_MCP_ALLOWED" => "0",
        "AIWEB_ENV_ACCESS_ALLOWED" => "0"
      )
    end

    def agent_run_openmanus_tool_broker_log(workspace_dir)
      events = engine_run_workspace_tool_broker_events(workspace_dir)
      return "" if events.empty?

      events.map { |event| JSON.generate(engine_run_redact_event_value(event)) }.join("\n") + "\n"
    end

    def agent_run_kill_process(pid)
      Process.kill("TERM", pid)
      sleep 0.2
      Process.kill("KILL", pid)
    rescue Errno::ESRCH, Errno::EPERM, ArgumentError, NotImplementedError
      nil
    end

    def agent_run_close_stream(stream)
      stream.close unless stream.closed?
    rescue IOError
      nil
    end

    def agent_run_limit_process_output(text, max_bytes = 200_000)
      string = text.to_s
      return string if string.bytesize <= max_bytes

      "#{string.byteslice(0, max_bytes)}\n[truncated process output at #{max_bytes} bytes]\n"
    end

    def agent_run_openmanus_timeout
      value = ENV.fetch("AIWEB_OPENMANUS_TIMEOUT", "180").to_i
      value.positive? ? [value, 600].min : 180
    end

    def agent_run_read_openmanus_report(path, source_paths)
      return [nil, ["openmanus did not write required result JSON"]] unless File.file?(path)

      report = JSON.parse(File.read(path, 64 * 1024))
      return [nil, ["openmanus result JSON must be an object"]] unless report.is_a?(Hash)

      blockers = []
      blockers << "openmanus result schema_version must be 1" unless report["schema_version"].to_i == 1
      status = report["status"].to_s
      blockers << "openmanus result status is required" if status.empty?
      blockers << "openmanus result reported failure status: #{status}" if %w[failed blocked error].include?(status)
      allowed = source_paths.to_set
      Array(report["changed_source_files"]).each do |path|
        normalized = agent_run_normalized_relative_path(path)
        blockers << "openmanus result reports unapproved changed source file: #{normalized}" unless allowed.include?(normalized)
      end
      Array(report["blocking_issues"]).each do |issue|
        text = issue.to_s.strip
        blockers << "openmanus result blocking issue: #{text}" unless text.empty?
      end
      [report, blockers]
    rescue JSON::ParserError => e
      [nil, ["openmanus result JSON is malformed: #{e.message}"]]
    rescue SystemCallError => e
      [nil, ["openmanus result JSON could not be read: #{e.message}"]]
    end

    def agent_run_openmanus_workspace_diff(workspace_dir, changed_source_files)
      changed_source_files.map do |path|
        source = File.join(root, path)
        workspace = File.join(workspace_dir, path)
        agent_run_full_file_diff(path, source, workspace)
      end.join
    end

    def agent_run_denied_globs
      %w[
        .env*
        .git/**
        node_modules/**
        .ssh/**
        .aws/**
        .vercel/**
        .netlify/**
        *.pem
        *.key
        id_rsa
        id_dsa
        id_ed25519
        **/*secret*
        **/*credential*
      ]
    end

    def unsafe_secret_surface_path?(path)
      normalized = path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
      return true if unsafe_env_path?(normalized)
      return true if secret_looking_path?(normalized)

      parts = normalized.split("/")
      return true if parts.any? { |part| %w[.ssh .aws .vercel .netlify].include?(part) }
      return true if parts.any? { |part| %w[.npmrc .yarnrc .pypirc].include?(part) }
      return true if File.basename(normalized).match?(/\A(?:id_rsa|id_dsa|id_ed25519)\z/i)
      return true if File.extname(normalized).match?(/\A\.(?:pem|key)\z/i)

      false
    end

    def windows?
      RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/i)
    end

  end
end
