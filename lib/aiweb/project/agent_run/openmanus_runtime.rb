# frozen_string_literal: true

require "json"
require "open3"
require "timeout"

module Aiweb
  module ProjectAgentRun
    private

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
      result = runtime_process_runner.capture(
        Aiweb::Runtime::CommandSpec.new(
          argv: Array(command).map(&:to_s),
          cwd: workspace_dir,
          env: env,
          stdin_data: prompt,
          timeout: timeout_sec.to_i,
          max_output_bytes: 200_000,
          risk_class: "agent_run_openmanus_sandbox_worker",
          description: "agent-run OpenManus sandbox worker"
        )
      )
      stdout_data = agent_run_limit_process_output(result.stdout)
      stderr_data = agent_run_limit_process_output(result.stderr)
      exit_code = result.exit_code
      success = result.success?
      if result.status == "timeout"
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
    rescue ArgumentError, SystemCallError => e
      {
        stdout: stdout_data,
        stderr: "#{stderr_data}#{e.message}\n",
        exit_code: exit_code,
        success: false,
        blocking_issues: ["openmanus subprocess failed: #{e.message}"]
      }
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

  end
end
