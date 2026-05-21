# frozen_string_literal: true

require "fileutils"
require "json"
require "timeout"

module Aiweb
  module ProjectRuntimePreview
    def preview(dry_run: false, stop: false)
      assert_initialized!

      return stop_preview(dry_run: dry_run) if stop

      context = runtime_readiness_context(capability: :preview)
      state = context.fetch(:state)
      scaffold = context.fetch(:scaffold)
      blockers = context.fetch(:blockers)
      return preview_blocked_payload(state, blockers, dry_run: dry_run) unless blockers.empty?

      running = running_preview_metadata
      return preview_already_running_payload(state, running, dry_run: dry_run) if running

      run_id = "preview-#{Time.now.utc.strftime("%Y%m%dT%H%M%SZ")}"
      run_dir = File.join(aiweb_dir, "runs", run_id)
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      metadata_path = File.join(run_dir, "preview.json")
      command = preview_command(scaffold)
      port = preview_port(command)
      url = "http://127.0.0.1:#{port}/"
      planned_changes = [relative(run_dir), relative(stdout_path), relative(stderr_path), relative(metadata_path)]

      if dry_run
        return preview_payload(
          state: state,
          metadata: preview_run_metadata(
            run_id: run_id,
            status: "dry_run",
            command: command,
            started_at: nil,
            finished_at: nil,
            exit_code: nil,
            pid: nil,
            port: port,
            url: url,
            stdout_log: relative(stdout_path),
            stderr_log: relative(stderr_path),
            metadata_path: relative(metadata_path),
            blocking_issues: [],
            dry_run: true
          ),
          changed_files: planned_changes,
          action_taken: "planned scaffold preview",
          blocking_issues: [],
          next_action: "rerun aiweb preview without --dry-run to start #{command.inspect}"
        )
      end

      changes = []
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << relative(run_dir)
        started_at = now
        status = "blocked"
        blocking_issues = []
        pid = nil
        exit_code = nil

        if executable_path("pnpm").nil?
          blocking_issues << "pnpm executable is missing; install project dependencies outside aiweb preview, then rerun."
          changes << write_file(stdout_path, "", false)
          changes << write_file(stderr_path, blocking_issues.join("\n") + "\n", false)
        elsif !File.directory?(File.join(root, "node_modules"))
          blocking_issues << "node_modules is missing; run pnpm install outside aiweb preview after reviewing package.json, then rerun."
          changes << write_file(stdout_path, "", false)
          changes << write_file(stderr_path, blocking_issues.join("\n") + "\n", false)
        else
          FileUtils.touch(stdout_path)
          FileUtils.touch(stderr_path)
          stdout_file = File.open(stdout_path, "ab")
          stderr_file = File.open(stderr_path, "ab")
          begin
            pid = Aiweb::Runtime::ProcessLauncher.spawn(
              spec: Aiweb::Runtime::LaunchSpec.new(
                argv: preview_command_argv(command),
                cwd: root,
                env: subprocess_path_env,
                stdout: stdout_file,
                stderr: stderr_file,
                risk_class: "scaffold_preview_server",
                description: "scaffold preview server"
              )
            )
            Process.detach(pid)
            status = "running"
          ensure
            stdout_file.close
            stderr_file.close
          end
          changes << relative(stdout_path)
          changes << relative(stderr_path)
        end

        metadata = preview_run_metadata(
          run_id: run_id,
          status: status,
          command: command,
          started_at: started_at,
          finished_at: status == "running" ? nil : now,
          exit_code: exit_code,
          pid: pid,
          port: port,
          url: url,
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          metadata_path: relative(metadata_path),
          blocking_issues: blocking_issues,
          dry_run: false
        )
        changes << write_json(metadata_path, metadata, false)
        return preview_payload(
          state: state,
          metadata: metadata,
          changed_files: compact_changes(changes),
          action_taken: status == "running" ? "started scaffold preview" : "scaffold preview blocked",
          blocking_issues: blocking_issues,
          next_action: preview_next_action(status)
        )
      end
    end

    private

    def preview_blocked_payload(state, blockers, dry_run:)
      preview_payload(
        state: state,
        metadata: {
          "schema_version" => 1,
          "status" => "blocked",
          "command" => "pnpm dev --host 127.0.0.1",
          "dry_run" => dry_run,
          "blocking_issues" => blockers
        },
        changed_files: [],
        action_taken: "scaffold preview blocked",
        blocking_issues: blockers,
        next_action: "resolve runtime-plan blockers, then rerun aiweb preview"
      )
    end

    def preview_already_running_payload(state, metadata, dry_run:)
      payload_metadata = metadata.merge(
        "status" => "already_running",
        "dry_run" => dry_run,
        "blocking_issues" => []
      )
      preview_payload(
        state: state,
        metadata: payload_metadata,
        changed_files: [],
        action_taken: "scaffold preview already running",
        blocking_issues: [],
        next_action: "open #{payload_metadata["url"] || payload_metadata["preview_url"]} or run aiweb preview --stop before starting another preview"
      )
    end

    def preview_payload(state:, metadata:, changed_files:, action_taken:, blocking_issues:, next_action:)
      runtime_command_payload(key: "preview", state: state, metadata: metadata, changed_files: changed_files, action_taken: action_taken, blocking_issues: blocking_issues, next_action: next_action)
    end

    def preview_run_metadata(run_id:, status:, command:, started_at:, finished_at:, exit_code:, pid:, port:, url:, stdout_log:, stderr_log:, metadata_path:, blocking_issues:, dry_run:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "command" => command,
        "cwd" => root,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "exit_code" => exit_code,
        "pid" => pid,
        "port" => port,
        "url" => url,
        "preview_url" => url,
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "metadata_path" => metadata_path,
        "dry_run" => dry_run,
        "blocking_issues" => blocking_issues
      }
    end

    def preview_next_action(status)
      case status
      when "running" then "open the preview_url locally; run aiweb preview --stop when finished"
      when "stopped" then "rerun aiweb preview to start a new local preview"
      when "not_running" then "run aiweb preview to start the local preview"
      when "blocked" then "resolve the blocked local preview precondition, then rerun aiweb preview"
      else "inspect .ai-web/runs preview logs, fix the scaffold, then rerun aiweb preview"
      end
    end

    def preview_command(scaffold)
      base = scaffold["dev_command"].to_s.strip
      base = "pnpm dev" if base.empty?
      base.match?(/--host(?:\s|=)/) ? base : "#{base} --host 127.0.0.1"
    end

    def preview_command_argv(command)
      parts = Aiweb::Runtime::CommandSpec.argv_from_command(command, default: ["pnpm", "dev", "--host", "127.0.0.1"])
      executable = executable_path(parts.fetch(0))
      [executable || parts.fetch(0), *parts.drop(1)]
    rescue IndexError
      ["pnpm", "dev", "--host", "127.0.0.1"]
    end

    def preview_port(command)
      match = command.match(/(?:--port(?:=|\s+))(\d+)/)
      match ? match[1].to_i : 4321
    end

    def running_preview_metadata
      preview_metadata_files.reverse_each do |path|
        metadata = read_preview_metadata(path)
        next unless metadata
        next unless metadata["status"] == "running"

        pid = metadata["pid"].to_i
        next unless live_process?(pid)

        metadata["metadata_path"] ||= relative(path)
        return metadata
      end
      nil
    end

    def latest_preview_metadata
      preview_metadata_files.reverse_each do |path|
        metadata = read_preview_metadata(path)
        next unless metadata

        metadata["metadata_path"] ||= relative(path)
        return [metadata, path]
      end
      nil
    end

    def preview_metadata_files
      Dir.glob(File.join(aiweb_dir, "runs", "preview-*", "preview.json")).sort
    end

    def read_preview_metadata(path)
      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def live_process?(pid)
      return false unless pid.positive?

      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def stop_preview(dry_run:)
      state, = runtime_state_snapshot
      latest = latest_preview_metadata
      metadata, path = latest if latest
      live = metadata && metadata["status"] == "running" && live_process?(metadata["pid"].to_i)

      if dry_run
        planned = metadata ? [metadata["metadata_path"] || relative(path)] : []
        status = live ? "dry_run" : "not_running"
        preview = (metadata || { "schema_version" => 1 }).merge(
          "status" => status,
          "dry_run" => true,
          "would_stop_pid" => live ? metadata["pid"] : nil,
          "blocking_issues" => []
        )
        return preview_payload(
          state: state,
          metadata: preview,
          changed_files: planned,
          action_taken: live ? "planned scaffold preview stop" : "scaffold preview not running",
          blocking_issues: [],
          next_action: live ? "rerun aiweb preview --stop without --dry-run to stop the recorded preview pid" : preview_next_action("not_running")
        )
      end

      return preview_payload(
        state: state,
        metadata: { "schema_version" => 1, "status" => "not_running", "dry_run" => false, "blocking_issues" => [] },
        changed_files: [],
        action_taken: "scaffold preview not running",
        blocking_issues: [],
        next_action: preview_next_action("not_running")
      ) unless live

      mutation(dry_run: false) do
        pid = metadata["pid"].to_i
        stop_process_tree(pid)
        begin
          Timeout.timeout(5) do
            sleep 0.05 while live_process?(pid)
          end
        rescue Timeout::Error
          # Leave the process alone after TERM timeout; metadata still records the stop request.
        end
        stopped = metadata.merge(
          "status" => "stopped",
          "pid" => nil,
          "stopped_pid" => pid,
          "finished_at" => now,
          "dry_run" => false,
          "blocking_issues" => []
        )
        write_json(path, stopped, false)
        preview_payload(
          state: state,
          metadata: stopped,
          changed_files: [relative(path)],
          action_taken: "stopped scaffold preview",
          blocking_issues: [],
          next_action: preview_next_action("stopped")
        )
      end
    end

    def stop_process_tree(pid)
      if windows?
        taskkill = File.join(ENV["WINDIR"].to_s.empty? ? "C:/Windows" : ENV["WINDIR"], "System32", "taskkill.exe")
        return if File.executable?(taskkill) && runtime_taskkill_process_tree(pid, taskkill)
        return if runtime_taskkill_process_tree(pid, "taskkill.exe")

        Process.kill("KILL", pid)
      else
        Process.kill("TERM", pid)
      end
    rescue Errno::ESRCH, Errno::EINVAL
      nil
    end

    def runtime_taskkill_process_tree(pid, command)
      result = runtime_process_runner.capture(
        Aiweb::Runtime::CommandSpec.new(
          argv: [command, "/PID", pid.to_s, "/T", "/F"],
          cwd: root,
          timeout: 10,
          max_output_bytes: 16_000,
          risk_class: "local_process_tree_cleanup",
          description: "taskkill preview process tree"
        )
      )
      result.success?
    rescue ArgumentError
      false
    end
  end
end
