# frozen_string_literal: true

require_relative "agent_run/constants"
require_relative "agent_run/openmanus_sandbox"
require_relative "agent_run/openmanus_workspace"
require_relative "agent_run/openmanus_runtime"
require_relative "agent_run/openmanus_contract"
require_relative "agent_run/openmanus"
require_relative "agent_run/source_policy"
require_relative "agent_run/diff_policy"
require_relative "agent_run/codex_runner"
require_relative "agent_run/metadata_payload"
require_relative "agent_run/context_builder"

module Aiweb
  module ProjectAgentRun
    def agent_run(task: "latest", agent: "codex", approved: false, approval_hash: nil, dry_run: false, sandbox: nil)
      assert_initialized!

      agent_name = agent.to_s.strip.empty? ? "codex" : agent.to_s.strip
      supported_agents = %w[codex openmanus]
      raise UserError.new("agent-run currently supports --agent codex or --agent openmanus", 1) unless supported_agents.include?(agent_name)

      state = load_state
      ensure_implementation_state_defaults!(state)

      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      run_id = "agent-run-#{timestamp}"
      run_dir = File.join(aiweb_dir, "runs", run_id)
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      metadata_path = File.join(run_dir, "agent-run.json")
      context_path = File.join(run_dir, "agent-run-context.json")
      diff_path = File.join(aiweb_dir, "diffs", "#{run_id}.patch")
      side_effect_broker_path = File.join(run_dir, "side-effect-broker.jsonl")
      openmanus_context_path = File.join(run_dir, "openmanus-context.json")
      openmanus_prompt_path = File.join(run_dir, "openmanus-prompt.md")
      openmanus_validator_path = File.join(run_dir, "openmanus-validator.json")
      openmanus_result_path = File.join(run_dir, "openmanus-result.json")
      openmanus_network_log_path = File.join(run_dir, "network.log")
      openmanus_browser_log_path = File.join(run_dir, "browser-requests.log")
      openmanus_denied_access_log_path = File.join(run_dir, "denied-access.log")
      openmanus_tool_broker_log_path = File.join(run_dir, "tool-broker-events.jsonl")
      openmanus_workspace_path = File.join(aiweb_dir, "tmp", "openmanus", run_id)
      openmanus_sandbox = agent_name == "openmanus" ? agent_run_openmanus_sandbox_name(sandbox) : nil
      blockers = []

      task_source = resolve_agent_run_task_source(task, state)
      component_map = nil
      component_map_error = nil
      begin
        component_map = load_agent_run_component_map
      rescue UserError => e
        component_map_error = e.message
      end
      task_text = nil
      begin
        task_text = task_source["path"] ? File.read(task_source["path"]) : nil
      rescue SystemCallError => e
        blockers << "agent-run cannot read task packet: #{e.message}"
      end
      design_path = File.join(aiweb_dir, "DESIGN.md")
      design_text = nil
      begin
        design_text = File.file?(design_path) ? File.read(design_path) : nil
      rescue SystemCallError => e
        blockers << "agent-run cannot read DESIGN.md: #{e.message}"
      end
      component_map_text = nil
      begin
        component_map_text = component_map ? File.read(File.join(aiweb_dir, "component-map.json")) : nil
      rescue SystemCallError => e
        blockers << "agent-run cannot read component-map.json: #{e.message}"
      end
      target_allowlist = agent_run_target_allowlist(task_text)
      source_paths = agent_run_source_paths(task_text, component_map, target_allowlist: target_allowlist)
      blockers.concat(agent_run_task_packet_blockers(task_source, task_text, source_paths, target_allowlist: target_allowlist))
      selected = state.dig("design_candidates", "selected_candidate").to_s.strip
      if agent_run_requires_selected_design?(source_paths) && selected.empty?
        blockers << "agent-run source implementation requires a selected design candidate; run aiweb design --candidates 3 then aiweb select-design candidate-01|candidate-02|candidate-03 before source edits"
      elsif agent_run_requires_selected_design?(source_paths)
        selected_path = selected_candidate_artifact_path(state, selected)
        unless selected_path && File.file?(selected_path)
          blockers << "agent-run source implementation requires selected design artifact #{selected_path ? relative(selected_path) : ".ai-web/design-candidates/#{selected}.html"}"
        end
      end
      context = agent_run_context_manifest(
        task_source: task_source,
        design_text: design_text,
        component_map_text: component_map_text,
        source_paths: source_paths,
        target_allowlist: target_allowlist
      )
      capability = agent_run_capability_envelope(
        run_id: run_id,
        agent: agent_name,
        sandbox: openmanus_sandbox,
        task_source: task_source,
        context: context,
        source_paths: source_paths,
        target_allowlist: target_allowlist
      )
      expected_hash = agent_run_approval_hash(capability)
      blockers << task_source["reason"] if task_source["path"].nil?
      blockers << "agent-run task packet does not identify any safe source targets" if source_paths.empty?
      blockers << "agent-run component map is malformed" if component_map_error
      blockers << "agent-run requires --approved for real command execution" if !dry_run && !approved
      if !dry_run && approved && approval_hash.to_s.strip.empty?
        blockers << "--approval-hash is required for real agent-run execution"
      elsif !approval_hash.to_s.strip.empty? && approval_hash.to_s.strip != expected_hash
        blockers << "approval hash does not match the current agent-run capability envelope"
      end
      blockers.concat(agent_run_source_security_blockers(source_paths))
      openmanus_command_env = agent_name == "openmanus" ? agent_run_openmanus_command_env(
        sandbox: openmanus_sandbox,
        source_paths: source_paths,
        task_source: task_source,
        run_id: run_id,
        diff_path: diff_path,
        metadata_path: metadata_path
      ) : {}
      agent_command = agent_run_command(agent_name, sandbox: openmanus_sandbox, workspace_dir: openmanus_workspace_path, openmanus_env: openmanus_command_env)
      if agent_name == "openmanus"
        blockers.concat(agent_run_openmanus_sandbox_blockers(agent_command, sandbox: openmanus_sandbox, workspace_dir: openmanus_workspace_path)) if !dry_run && approved
      elsif !dry_run && approved && agent_command.empty?
        blockers << "#{agent_name} executable is missing from PATH"
      end
      blockers.concat(agent_run_forbidden_path_blockers(task_text, component_map_text))
      blockers.concat(agent_run_target_allowlist_blockers(target_allowlist, component_map))

      planned_changes = [
        relative(run_dir),
        relative(stdout_path),
        relative(stderr_path),
        relative(context_path),
        relative(metadata_path),
        relative(diff_path)
      ]
      if agent_name == "openmanus"
        planned_changes.concat([
          relative(openmanus_workspace_path),
          relative(openmanus_context_path),
          relative(openmanus_prompt_path),
          relative(openmanus_validator_path),
          relative(openmanus_result_path),
          relative(openmanus_network_log_path),
          relative(openmanus_browser_log_path),
          relative(openmanus_denied_access_log_path),
          relative(openmanus_tool_broker_log_path)
        ])
      else
        planned_changes << relative(side_effect_broker_path)
      end

      openmanus_contract = agent_name == "openmanus" ? agent_run_openmanus_contract(
        run_id: run_id,
        run_dir: run_dir,
        context_path: openmanus_context_path,
        prompt_path: openmanus_prompt_path,
        validator_path: openmanus_validator_path,
        result_path: openmanus_result_path,
        network_log_path: openmanus_network_log_path,
        browser_log_path: openmanus_browser_log_path,
        denied_access_log_path: openmanus_denied_access_log_path,
        tool_broker_log_path: openmanus_tool_broker_log_path,
        task_source: task_source,
        context: context,
        source_paths: source_paths,
        command: agent_command,
        dry_run: dry_run,
        approved: approved
      ) : nil

      metadata = agent_run_run_metadata(
        run_id: run_id,
        agent: agent_name,
        task_source: task_source,
        context: context,
        command: agent_command.empty? ? agent_name : agent_command.join(" "),
        context_path: relative(context_path),
        started_at: nil,
        finished_at: nil,
        exit_code: nil,
        stdout_log: relative(stdout_path),
        stderr_log: relative(stderr_path),
        metadata_path: relative(metadata_path),
        diff_path: relative(diff_path),
        source_paths: source_paths,
        dry_run: dry_run,
        approved: approved,
        approval_hash: expected_hash,
        capability: capability,
        blocking_issues: blockers.uniq,
        status: blockers.empty? ? "planned" : "blocked"
      )
      metadata["mode"] = dry_run ? "dry_run" : (approved ? "approved" : "blocked")
      metadata["permission_profile"] = "implementation-local-no-network" if agent_name == "openmanus"
      metadata["openmanus"] = openmanus_contract if openmanus_contract

      if dry_run || !blockers.empty?
        return agent_run_payload(
          state: state,
          metadata: metadata,
          changed_files: [],
          planned_changes: blockers.empty? ? planned_changes : [],
          action_taken: blockers.empty? ? "planned agent run" : "agent run blocked",
          blocking_issues: blockers.uniq,
          next_action: blockers.empty? ? agent_run_approved_next_action(agent_name, openmanus_sandbox, expected_hash) : "resolve blockers, rerun aiweb agent-run --task latest --agent #{agent_name} --dry-run, and review the lower-level adapter approval_hash; use aiweb agent or engine-run for user-facing web-building work"
        )
      end

      if agent_name == "openmanus"
        return agent_run_openmanus(
          state: state,
          task_source: task_source,
          context: context,
          source_paths: source_paths,
          run_id: run_id,
          run_dir: run_dir,
          stdout_path: stdout_path,
          stderr_path: stderr_path,
          metadata_path: metadata_path,
          diff_path: diff_path,
          context_path: openmanus_context_path,
          prompt_path: openmanus_prompt_path,
          validator_path: openmanus_validator_path,
          result_path: openmanus_result_path,
          network_log_path: openmanus_network_log_path,
          browser_log_path: openmanus_browser_log_path,
          denied_access_log_path: openmanus_denied_access_log_path,
          tool_broker_log_path: openmanus_tool_broker_log_path,
          command: agent_command,
          contract: openmanus_contract,
          approval_hash: expected_hash,
          capability: capability
        )
      end

      agent_run_codex(
        state: state,
        agent_name: agent_name,
        task_source: task_source,
        context: context,
        source_paths: source_paths,
        run_id: run_id,
        run_dir: run_dir,
        stdout_path: stdout_path,
        stderr_path: stderr_path,
        context_path: context_path,
        metadata_path: metadata_path,
        diff_path: diff_path,
        side_effect_broker_path: side_effect_broker_path,
        approval_hash: expected_hash,
        capability: capability
      )
    end

    private

    def agent_run_command(agent_name, sandbox: nil, workspace_dir: nil, openmanus_env: {})
      if agent_name == "openmanus"
        return [] if sandbox.to_s.empty?
        return agent_run_openmanus_container_command(sandbox, workspace_dir, openmanus_env)
      end

      executable_path(agent_name) ? [agent_name] : []
    rescue ArgumentError
      []
    end

    def agent_run_process_env(context_path:, source_paths:, task_source:, run_id:, diff_path:, metadata_path:, side_effect_broker_path: nil)
      subprocess_path_env.merge(
        "AIWEB_AGENT_RUN_CONTEXT_PATH" => context_path,
        "AIWEB_AGENT_RUN_ALLOWED_SOURCE_PATHS_JSON" => JSON.generate(source_paths),
        "AIWEB_AGENT_RUN_TASK_PATH" => task_source["relative"].to_s,
        "AIWEB_AGENT_RUN_APPROVED" => "1",
        "AIWEB_AGENT_RUN_DRY_RUN" => "0",
        "AIWEB_AGENT_RUN_RUN_ID" => run_id,
        "AIWEB_AGENT_RUN_DIFF_PATH" => relative(diff_path),
        "AIWEB_AGENT_RUN_METADATA_PATH" => relative(metadata_path)
      ).tap do |env|
        env["AIWEB_AGENT_RUN_SIDE_EFFECT_BROKER_PATH"] = relative(side_effect_broker_path) if side_effect_broker_path
      end
    end


  end
end
