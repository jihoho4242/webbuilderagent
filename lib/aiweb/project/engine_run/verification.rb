# frozen_string_literal: true

require "json"

module Aiweb
  module ProjectEngineRunVerification
    private

    def engine_run_verification_result(workspace_dir, capability, paths, events, agent:, sandbox:)
      package_path = File.join(workspace_dir, "package.json")
      return { "schema_version" => 1, "status" => "skipped", "checks" => [], "blocking_issues" => [], "reason" => "package.json is missing in staged workspace" } unless File.file?(package_path)

      package = JSON.parse(File.read(package_path))
      scripts = package["scripts"].is_a?(Hash) ? package["scripts"] : {}
      checks = []
      blockers = []
      %w[build test].each do |script|
        next unless scripts.key?(script)
        command = engine_run_package_command(workspace_dir, script, agent: agent, sandbox: sandbox)
        unless command
          checks << { "name" => script, "status" => "skipped", "reason" => "package manager executable missing" }
          next
        end
        tool_request = engine_run_tool_request("package.#{script}", command, workspace_dir, capability, risk_class: "local_verification", expected_outputs: [relative(paths.fetch(:verification_path))])
        engine_run_event(paths.fetch(:events_path), events, "tool.requested", "verification requested sandbox #{script}", tool_request)
        engine_run_event(paths.fetch(:events_path), events, "policy.decision", "tool broker approved sandbox #{script}", tool_request.merge("decision" => "approved", "reason" => "package script exists in staged workspace"))
        engine_run_event(paths.fetch(:events_path), events, "tool.started", "starting sandbox #{script}", command: command.join(" "))
        broker_event_offset = engine_run_tool_broker_event_count(workspace_dir)
        stdout, stderr, status = engine_run_capture_command(command, workspace_dir, 120, env: engine_run_verification_env(workspace_dir, paths, sandbox))
        engine_run_emit_workspace_tool_broker_events(workspace_dir, paths.fetch(:events_path), events, cycle: "verification:#{script}", offset: broker_event_offset)
        check_status = status == 0 ? "passed" : "failed"
        checks << {
          "name" => script,
          "status" => check_status,
          "command" => command.join(" "),
          "exit_code" => status,
          "stdout" => agent_run_redact_process_output(stdout)[0, 2000],
          "stderr" => agent_run_redact_process_output(stderr)[0, 2000]
        }
        blockers << "#{script} failed with exit code #{status}" unless status == 0
        engine_run_event(paths.fetch(:events_path), events, "tool.finished", "finished sandbox #{script}", status: check_status, exit_code: status)
      end
      {
        "schema_version" => 1,
        "status" => if !blockers.empty?
                       "failed"
                     elsif checks.empty?
                       "skipped"
                     else
                       "passed"
                     end,
        "checks" => checks,
        "blocking_issues" => blockers,
        "reason" => checks.empty? ? "package.json has no build or test script" : nil
      }
    rescue JSON::ParserError => e
      { "schema_version" => 1, "status" => "failed", "checks" => [], "blocking_issues" => ["package.json is malformed in staged workspace: #{e.message}"] }
    end

    def engine_run_package_command(workspace_dir, script, agent:, sandbox:)
      manager = if File.file?(File.join(workspace_dir, "pnpm-lock.yaml"))
                  "pnpm"
                elsif File.file?(File.join(workspace_dir, "yarn.lock"))
                  "yarn"
                else
                  "npm"
                end
      return nil if sandbox.to_s.strip.empty? && executable_path(manager).nil?

      command = case manager
                when "npm" then [manager, "run", script]
                else [manager, script]
                end
      if engine_run_container_worker_agent?(agent) && !sandbox.to_s.strip.empty?
        return engine_run_sandbox_tool_command(sandbox, workspace_dir, command, agent: agent)
      end
      command
    end
  end
end
