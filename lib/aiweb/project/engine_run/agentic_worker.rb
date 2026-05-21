# frozen_string_literal: true

require "fileutils"
require "json"

require_relative "../../runtime"

module Aiweb
  module ProjectEngineRun
    def engine_run_empty_agent_result
      {
        stdout: +"",
        stderr: +"",
        exit_code: nil,
        success: false,
        cycles_completed: 0,
        blocking_issues: []
      }
    end

    def engine_run_merge_agent_results(previous, current)
      {
        stdout: previous.fetch(:stdout).to_s + current.fetch(:stdout).to_s,
        stderr: previous.fetch(:stderr).to_s + current.fetch(:stderr).to_s,
        exit_code: current[:exit_code],
        success: current.fetch(:success),
        cycles_completed: previous.fetch(:cycles_completed).to_i + current.fetch(:cycles_completed).to_i,
        blocking_issues: (previous.fetch(:blocking_issues) + current.fetch(:blocking_issues)).uniq
      }
    end

    def engine_run_execute_agentic_loop(run_id:, capability:, paths:, stage:, agent:, sandbox:, cycle_limit:, events:, cycle_offset: 0)
      stdout = +""
      stderr = +""
      exit_code = nil
      success = false
      blocking_issues = []
      cycles_completed = 0
      engine_run_event(paths.fetch(:events_path), events, "plan.created", "created sandbox task plan", max_cycles: cycle_limit)

      cycle_limit.times do |index|
        cycles_completed = index + 1
        event_cycle = cycle_offset.to_i + cycles_completed
        break if run_cancel_requested?(run_id)

        broker_event_offset = engine_run_tool_broker_event_count(paths.fetch(:workspace_dir))
        engine_run_event(paths.fetch(:events_path), events, "step.started", "starting agentic cycle", cycle: event_cycle)
        design_repair_cycle = File.file?(File.join(paths.fetch(:workspace_dir), "_aiweb", "repair-observation.json"))
        engine_run_event(paths.fetch(:events_path), events, "design.repair.started", "starting design repair cycle", cycle: event_cycle) if design_repair_cycle
        command = engine_run_agent_command(agent, sandbox, paths.fetch(:workspace_dir))
        prompt = engine_run_agent_prompt(capability, stage.fetch(:manifest), paths)
        tool_request = engine_run_tool_request("worker.act", command, paths.fetch(:workspace_dir), capability, risk_class: "sandbox_worker", expected_outputs: [relative(paths.fetch(:agent_result_path)), relative(paths.fetch(:diff_path))])
        engine_run_event(paths.fetch(:events_path), events, "tool.requested", "worker requested sandbox action", tool_request)
        engine_run_event(paths.fetch(:events_path), events, "policy.decision", "tool broker approved sandbox worker action", tool_request.merge("decision" => "approved", "reason" => "inside approved sandbox capability envelope"))
        engine_run_event(paths.fetch(:events_path), events, "tool.started", "starting #{agent} inside staged sandbox", cycle: event_cycle, command: command.join(" "))
        captured = engine_run_capture_agent(command: command, prompt: prompt, workspace_dir: paths.fetch(:workspace_dir), paths: paths, agent: agent, sandbox: sandbox)
        engine_run_emit_workspace_tool_broker_events(paths.fetch(:workspace_dir), paths.fetch(:events_path), events, cycle: event_cycle, offset: broker_event_offset)
        stdout << captured.fetch(:stdout).to_s
        stderr << captured.fetch(:stderr).to_s
        exit_code = captured[:exit_code]
        success = captured.fetch(:success)
        blocking_issues.concat(captured.fetch(:blocking_issues))
        engine_run_event(paths.fetch(:events_path), events, "tool.finished", "finished #{agent} sandbox cycle", cycle: event_cycle, exit_code: exit_code, success: success)
        engine_run_event(paths.fetch(:events_path), events, "design.repair.finished", "finished design repair cycle", cycle: event_cycle, success: success) if design_repair_cycle
        break if success

        engine_run_event(paths.fetch(:events_path), events, "repair.planned", "agent cycle failed; scheduling another sandbox attempt", cycle: event_cycle, exit_code: exit_code) if index + 1 < cycle_limit && !run_cancel_requested?(run_id)
      end

      if run_cancel_requested?(run_id)
        blocking_issues << "engine-run cancellation requested for #{run_id}"
      elsif !success
        blocking_issues << "#{agent} did not complete successfully inside the staged sandbox" if blocking_issues.empty?
      end
      {
        stdout: agent_run_redact_process_output(stdout),
        stderr: agent_run_redact_process_output(stderr),
        exit_code: exit_code,
        success: success,
        cycles_completed: cycles_completed,
        blocking_issues: blocking_issues.uniq
      }
    end

    def engine_run_should_repair?(final_status, result, policy, verification, preview, design_verdict, cycle_limit)
      return false unless final_status == "failed"
      return false unless result.fetch(:success)
      return false unless policy.fetch("blocking_issues").empty? && policy.fetch("approval_issues").empty?
      repairable = verification.fetch("status") == "failed" ||
                   preview.fetch("status") == "failed" ||
                   design_verdict.fetch("status") == "failed"
      return false unless repairable

      result.fetch(:cycles_completed).to_i < cycle_limit.to_i
    end

    def engine_run_agent_prompt(capability, manifest, paths)
      [
        "You are the agentic WebBuilderAgent sandbox worker.",
        "You own the staged workspace only. The host project is protected by aiweb copy-back validation.",
        "Work like a careful human developer: inspect the project, plan, edit, run local build/test/preview/QA when useful, observe failures, and retry within the approved capability envelope.",
        "If _aiweb/repair-observation.json exists, read it first; it contains the previous verification failure and copy-back state for the next repair attempt.",
        "Do not read .env, credentials, provider auth stores, browser profiles, or any path excluded from the staged manifest.",
        "Do not use external network, package install, provider CLI, deploy, or git push. If needed, report that as waiting_approval in the result JSON.",
        "Write a short JSON result to _aiweb/engine-result.json when possible.",
        "",
        "## Capability",
        json_pretty_generate(capability),
        "",
        "## Staged Manifest Summary",
        json_pretty_generate(
          "workspace_root" => manifest["workspace_root"],
          "file_count" => manifest.fetch("files").length,
          "excluded_count" => manifest.fetch("excluded").length,
          "writable_globs" => capability["writable_globs"],
          "result_path" => "_aiweb/engine-result.json"
        ),
        "",
        "## Evidence Paths",
        json_pretty_generate(
          "stdout_log" => relative(paths.fetch(:stdout_path)),
          "stderr_log" => relative(paths.fetch(:stderr_path)),
          "worker_adapter_contract_path" => "_aiweb/worker-adapter-contract.json",
          "project_index_path" => relative(paths.fetch(:project_index_path)),
          "diff_path" => relative(paths.fetch(:diff_path)),
          "events_path" => relative(paths.fetch(:events_path)),
          "verification_path" => relative(paths.fetch(:verification_path)),
          "agent_result_path" => relative(paths.fetch(:agent_result_path))
        )
      ].join("\n")
    end

    def engine_run_agent_result(workspace_dir)
      path = File.join(workspace_dir, "_aiweb", "engine-result.json")
      return nil unless File.file?(path)

      text = File.read(path, 200_000)
      if text.match?(ENGINE_RUN_SECRET_VALUE_PATTERN)
        return {
          "schema_version" => 1,
          "status" => "redacted",
          "blocking_issues" => ["agent result contained secret-like content and was not persisted verbatim"]
        }
      end
      parsed = JSON.parse(agent_run_redact_process_output(text))
      parsed.is_a?(Hash) ? parsed : { "schema_version" => 1, "status" => "reported", "value" => parsed }
    rescue JSON::ParserError
      { "schema_version" => 1, "status" => "reported", "raw" => agent_run_redact_process_output(text.to_s)[0, 20_000] }
    rescue SystemCallError, ArgumentError => e
      { "schema_version" => 1, "status" => "unreadable", "blocking_issues" => ["agent result could not be read: #{e.message}"] }
    end

    def engine_run_worker_adapter_output_violations(agent_result, workspace_dir, expected_adapter: nil)
      return [] unless agent_result.is_a?(Hash)

      issues = Array(agent_result["blocking_issues"]).map(&:to_s)
      if %w[openhands langgraph openai_agents_sdk].include?(expected_adapter.to_s)
        required = %w[schema_version adapter status structured_events artifact_refs changed_file_manifest proposed_tool_requests risk_notes blocking_issues]
        missing = required.reject { |field| agent_result.key?(field) }
        issues << "worker adapter contract violation: #{expected_adapter} result missing required field(s): #{missing.join(", ")}" unless missing.empty?
        issues << "worker adapter contract violation: #{expected_adapter} result adapter must be #{expected_adapter}" unless agent_result["adapter"].to_s == expected_adapter.to_s
        %w[structured_events artifact_refs changed_file_manifest proposed_tool_requests risk_notes blocking_issues].each do |field|
          issues << "worker adapter contract violation: #{expected_adapter} result #{field} must be an array" if agent_result.key?(field) && !agent_result[field].is_a?(Array)
        end
      end
      if agent_result["status"].to_s == "reported" && agent_result.key?("raw")
        issues << "worker adapter contract violation: output was not structured JSON or was redacted before parsing"
      end
      strings = engine_run_collect_json_strings(agent_result)
      strings.each do |value|
        next if value.strip.empty?

        if engine_run_worker_adapter_host_absolute_path?(value, workspace_dir)
          issues << "worker adapter contract violation: output contained host absolute path"
        end
        if value.match?(ENGINE_RUN_SECRET_VALUE_PATTERN) || value.match?(/\b(?:OPENAI_API_KEY|ANTHROPIC_API_KEY|AWS_SECRET_ACCESS_KEY|SECRET|TOKEN|PASSWORD)=/i)
          issues << "worker adapter contract violation: output contained raw secret or environment value"
        end
      end
      if agent_result.key?("raw_env") || agent_result.key?("environment") || agent_result.key?("env")
        issues << "worker adapter contract violation: output included raw environment payload"
      end
      issues.map(&:to_s).reject(&:empty?).uniq
    end

    def engine_run_collect_json_strings(value)
      case value
      when Hash
        value.flat_map { |key, child| [key.to_s, *engine_run_collect_json_strings(child)] }
      when Array
        value.flat_map { |child| engine_run_collect_json_strings(child) }
      when String
        [value]
      else
        []
      end
    end

    def engine_run_worker_adapter_host_absolute_path?(value, workspace_dir)
      text = value.to_s.strip
      return false if text.empty?
      return false if text.start_with?("/workspace", "file:///workspace")

      if text.match?(%r{\A[A-Za-z]:[\\/]})
        workspace = File.expand_path(workspace_dir).tr("\\", "/").downcase
        candidate = text.tr("\\", "/").downcase
        return !candidate.start_with?(workspace)
      end
      return true if text.start_with?("/") && !text.start_with?("/workspace/")
      return true if text.start_with?("file:///") && !text.start_with?("file:///workspace")

      false
    end

    def engine_run_write_repair_observation(workspace_dir, verification, policy, preview: nil, screenshot_evidence: nil, design_verdict: nil, opendesign_contract: nil)
      path = File.join(workspace_dir, "_aiweb", "repair-observation.json")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(
        path,
        json_pretty_generate(
          "schema_version" => 1,
          "written_at" => now,
          "verification" => verification,
          "copy_back_policy" => {
            "status" => policy["status"],
            "safe_changes" => policy["safe_changes"],
            "approval_changes" => policy["approval_changes"],
            "blocked_changes" => policy["blocked_changes"],
            "blocking_issues" => policy["blocking_issues"],
            "approval_issues" => policy["approval_issues"]
          },
          "preview" => preview,
          "screenshot_evidence" => screenshot_evidence,
          "design_verdict" => design_verdict,
          "opendesign_contract" => engine_run_checkpoint_opendesign_contract(opendesign_contract),
          "design_repair_instructions" => Array(design_verdict && design_verdict["repair_instructions"])
        )
      )
      path
    end

    def engine_run_capture_agent(command:, prompt:, workspace_dir:, paths:, agent:, sandbox:)
      engine_run_prepare_container_scratch_dirs(workspace_dir)
      if agent.to_s == "openhands"
        task_path = File.join(workspace_dir, "_aiweb", "openhands-task.md")
        FileUtils.mkdir_p(File.dirname(task_path))
        File.write(task_path, prompt)
      elsif agent.to_s == "langgraph"
        FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb"))
        File.write(File.join(workspace_dir, "_aiweb", "langgraph-task.md"), prompt)
        File.write(File.join(workspace_dir, "_aiweb", "langgraph-worker.py"), engine_run_langgraph_worker_source)
      elsif agent.to_s == "openai_agents_sdk"
        FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb"))
        File.write(File.join(workspace_dir, "_aiweb", "openai-agents-task.md"), prompt)
        File.write(File.join(workspace_dir, "_aiweb", "openai-agents-worker.py"), engine_run_openai_agents_sdk_worker_source)
      end
      env = engine_run_clean_env(workspace_dir, paths, sandbox)
      stdout_data = +""
      stderr_data = +""
      exit_code = nil
      success = false
      result = runtime_process_runner.capture(
        Aiweb::Runtime::CommandSpec.new(
          argv: Array(command).map(&:to_s),
          cwd: workspace_dir,
          env: env,
          stdin_data: prompt,
          timeout: 600,
          max_output_bytes: 200_000,
          risk_class: "engine_run_agent_worker",
          description: "engine-run agent worker"
        )
      )
      stdout_data = agent_run_limit_process_output(result.stdout)
      stderr_data = agent_run_limit_process_output(result.stderr)
      exit_code = result.exit_code
      success = result.success?
      blockers = []
      blockers << "#{agent} timed out after 600s" if result.status == "timeout"
      blockers << "#{agent} exited with status #{exit_code || "unknown"}" if result.status != "timeout" && !success
      blockers << "quarantine: agent output contained secret-like content" if stdout_data.match?(ENGINE_RUN_SECRET_VALUE_PATTERN) || stderr_data.match?(ENGINE_RUN_SECRET_VALUE_PATTERN)
      {
        stdout: stdout_data,
        stderr: stderr_data,
        exit_code: exit_code,
        success: success,
        blocking_issues: blockers
      }
    rescue ArgumentError, SystemCallError => e
      {
        stdout: stdout_data,
        stderr: "#{stderr_data}#{e.message}\n",
        exit_code: exit_code,
        success: false,
        blocking_issues: ["engine-run subprocess failed: #{e.message}"]
      }
    end

    def engine_run_clean_env(workspace_dir, paths, sandbox)
      allowed = subprocess_path_env
      clean = allowed.merge(
        "AIWEB_ENGINE_RUN_WORKSPACE" => workspace_dir,
        "AIWEB_ENGINE_RUN_RESULT_PATH" => File.join(workspace_dir, "_aiweb", "engine-result.json"),
        "AIWEB_OPENMANUS_RESULT_PATH" => File.join(workspace_dir, "_aiweb", "engine-result.json"),
        "AIWEB_ENGINE_RUN_EVENTS_PATH" => paths.fetch(:events_path),
        "AIWEB_OPENMANUS_SANDBOX" => sandbox.to_s,
        "AIWEB_NETWORK_ALLOWED" => "0",
        "AIWEB_MCP_ALLOWED" => "0",
        "AIWEB_ENV_ACCESS_ALLOWED" => "0",
        "AIWEB_TOOL_BROKER_EVENTS_PATH" => "/workspace/_aiweb/tool-broker-events.jsonl",
        "AIWEB_TOOL_BROKER_REAL_PATH" => "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      )
      return clean if %w[docker podman].include?(sandbox.to_s)

      clean.merge(
        "HOME" => File.join(workspace_dir, "_aiweb", "home"),
        "USERPROFILE" => File.join(workspace_dir, "_aiweb", "home"),
        "TMPDIR" => File.join(workspace_dir, "_aiweb", "tmp"),
        "TMP" => File.join(workspace_dir, "_aiweb", "tmp"),
        "TEMP" => File.join(workspace_dir, "_aiweb", "tmp")
      )
    end

    def engine_run_prepare_container_scratch_dirs(workspace_dir)
      [
        File.join(workspace_dir, "_aiweb"),
        File.join(workspace_dir, "_aiweb", "home"),
        File.join(workspace_dir, "_aiweb", "tmp")
      ].each do |path|
        FileUtils.mkdir_p(path)
        FileUtils.chmod(0o777, path) unless windows?
      end
    end
  end
end
