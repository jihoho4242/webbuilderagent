# frozen_string_literal: true

module Aiweb
  module ProjectRuntimePreview
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

  end
end
