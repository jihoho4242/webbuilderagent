# frozen_string_literal: true

require_relative "agent_run/openmanus"
require_relative "agent_run/source_policy"
require_relative "agent_run/diff_policy"

module Aiweb
  module ProjectAgentRun
    def agent_run(task: "latest", agent: "codex", approved: false, dry_run: false, sandbox: nil)
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
      blockers << task_source["reason"] if task_source["path"].nil?
      blockers << "agent-run task packet does not identify any safe source targets" if source_paths.empty?
      blockers << "agent-run component map is malformed" if component_map_error
      blockers << "agent-run requires --approved for real command execution" if !dry_run && !approved
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
          next_action: blockers.empty? ? agent_run_approved_next_action(agent_name, openmanus_sandbox) : "add a safe source target to the task packet or component map, then rerun #{agent_run_approved_command(agent_name, openmanus_sandbox)}"
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
          contract: openmanus_contract
        )
      end

      changes = []
      payload = nil
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << relative(run_dir)
        started_at = now
        prompt = agent_run_prompt(context: context)
        changes << write_json(context_path, context, false)
        before_snapshot = agent_run_workspace_snapshot
        stdout = ""
        stderr = ""
        exit_code = nil
        status = "blocked"

        stdout, stderr, process_status = Open3.capture3(
          agent_run_process_env(context_path: context_path, source_paths: source_paths, task_source: task_source, run_id: run_id, diff_path: diff_path, metadata_path: metadata_path),
          agent_name,
          stdin_data: prompt,
          chdir: root,
          unsetenv_others: true
        )
        after_snapshot = agent_run_workspace_snapshot
        unauthorized_changes = agent_run_unauthorized_workspace_changes(before_snapshot, after_snapshot, source_paths)
        stdout = agent_run_redact_process_output(stdout)
        stderr = agent_run_redact_process_output(stderr)
        exit_code = process_status.exitstatus
        status = process_status.success? && unauthorized_changes.empty? ? "passed" : "failed"
        blocking_issues = []
        blocking_issues << "#{agent_name} exited with status #{exit_code}" unless process_status.success?
        unless unauthorized_changes.empty?
          blocking_issues << "agent-run rejected changes outside allowed source paths: #{unauthorized_changes.join(", ")}"
        end

        changes << write_file(stdout_path, stdout, false)
        changes << write_file(stderr_path, stderr, false)
        diff_patch, changed_source_files = agent_run_source_diff(source_paths)
        blocking_issues.concat(agent_run_validate_source_diff(diff_patch, source_paths))
        changes << write_file(diff_path, diff_patch, false)

        metadata = agent_run_run_metadata(
          run_id: run_id,
          agent: agent_name,
          task_source: task_source,
          context: context,
          command: agent_name,
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
          status: if status == "failed" || !blocking_issues.empty?
                    "failed"
                  elsif changed_source_files.empty? || diff_patch.to_s.strip.empty?
                    "no_changes"
                  else
                    "passed"
                  end,
          changed_source_files: changed_source_files
        )
        changes.concat(changed_source_files)
        changes << write_json(metadata_path, metadata, false)
        state["implementation"]["latest_agent_run"] = relative(metadata_path)
        state["implementation"]["last_diff"] = relative(diff_path)
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)

        payload = agent_run_payload(
          state: state,
          metadata: metadata,
          changed_files: compact_changes(changes),
          planned_changes: [],
          action_taken: metadata["status"] == "passed" ? "ran agent patch" : (metadata["status"] == "no_changes" ? "agent run produced no source diff" : "agent run failed"),
          blocking_issues: metadata["blocking_issues"],
          next_action: agent_run_next_action(metadata)
        )
      end
      payload
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

    def agent_run_process_env(context_path:, source_paths:, task_source:, run_id:, diff_path:, metadata_path:)
      subprocess_path_env.merge(
        "AIWEB_AGENT_RUN_CONTEXT_PATH" => context_path,
        "AIWEB_AGENT_RUN_ALLOWED_SOURCE_PATHS_JSON" => JSON.generate(source_paths),
        "AIWEB_AGENT_RUN_TASK_PATH" => task_source["relative"].to_s,
        "AIWEB_AGENT_RUN_APPROVED" => "1",
        "AIWEB_AGENT_RUN_DRY_RUN" => "0",
        "AIWEB_AGENT_RUN_RUN_ID" => run_id,
        "AIWEB_AGENT_RUN_DIFF_PATH" => relative(diff_path),
        "AIWEB_AGENT_RUN_METADATA_PATH" => relative(metadata_path)
      )
    end

    def agent_run_context_manifest(task_source:, design_text:, component_map_text:, source_paths:, target_allowlist: nil)
      context_files = []

      if task_source["path"]
        context_files << agent_run_context_file(task_source["path"], "task")
      end

      design_path = File.join(aiweb_dir, "DESIGN.md")
      if File.file?(design_path)
        context_files << agent_run_context_file(design_path, "design")
      end

      component_map_path = File.join(aiweb_dir, "component-map.json")
      if File.file?(component_map_path)
        context_files << agent_run_context_file(component_map_path, "component_map")
      end

      selected = selected_candidate_id
      selected_design_files = []
      if selected
        selected_md = File.join(aiweb_dir, "design-candidates", "selected.md")
        candidate_html = File.join(aiweb_dir, "design-candidates", "#{selected}.html")
        candidate_md = File.join(aiweb_dir, "design-candidates", "#{selected}.md")
        selected_design_files << agent_run_context_file(selected_md, "selected_design") if File.file?(selected_md)
        if File.file?(candidate_html)
          selected_design_files << agent_run_context_file(candidate_html, "selected_candidate")
        elsif File.file?(candidate_md)
          selected_design_files << agent_run_context_file(candidate_md, "selected_candidate")
        end
        context_files.concat(selected_design_files)
      end

      source_files = source_paths.map { |path| agent_run_context_file(path, "source") }
      {
        "task" => task_source["path"] ? agent_run_context_file(task_source["path"], "task") : nil,
        "design" => design_text ? agent_run_context_file(design_path, "design") : nil,
        "component_map" => component_map_text ? agent_run_context_file(component_map_path, "component_map") : nil,
        "selected_candidate" => selected,
        "selected_design_files" => selected_design_files,
        "source_files" => source_files,
        "context_files" => context_files.compact,
        "source_paths" => source_paths,
        "target_allowlist" => target_allowlist,
        "targeted_edit" => !!target_allowlist,
        "safe_context_only" => true
      }
    end

    def agent_run_context_file(path, kind)
      expanded = File.expand_path(path, root)
      {
        "kind" => kind,
        "path" => relative(expanded),
        "bytes" => File.size(expanded),
        "sha256" => Digest::SHA256.file(expanded).hexdigest,
        "content" => File.read(expanded)
      }
    rescue SystemCallError
      {
        "kind" => kind,
        "path" => relative(path),
        "bytes" => nil,
        "sha256" => nil,
        "content" => nil
      }
    end

    def agent_run_prompt(context:)
      lines = []
      lines << "You are the local source-patch agent for aiweb."
      lines << "Follow AGENTS.md and patch only the approved source files listed below."
      lines << "Do not read or print .env or .env.* files."
      lines << "Do not run build, preview, QA, deploy, or package install commands."
      lines << ""
      lines << "## Task packet"
      lines << (context["task"] && context["task"]["content"]).to_s
      if context["design"] && context["design"]["content"]
        lines << ""
        lines << "## DESIGN.md"
        lines << context["design"]["content"].to_s
      end
      if context["component_map"] && context["component_map"]["content"]
        lines << ""
        lines << "## component-map.json"
        lines << context["component_map"]["content"].to_s
      end
      if context["target_allowlist"]
        lines << ""
        lines << "## Targeted visual edit allowlist"
        lines << JSON.pretty_generate(context["target_allowlist"])
      end
      if context["selected_candidate"]
        lines << ""
        lines << "## Selected design"
        lines << "Selected candidate: #{context["selected_candidate"]}"
        Array(context["selected_design_files"]).each do |file|
          lines << ""
          lines << "### #{file["path"]}"
          lines << file["content"].to_s
        end
      end
      Array(context["source_files"]).each do |file|
        lines << ""
        lines << "## #{file["path"]}"
        lines << file["content"].to_s
      end
      lines << ""
      lines << "## Instructions"
      lines << "- Make the minimal safe source patch needed for the task."
      if context["target_allowlist"]
        lines << "- Patch only the strict source_paths listed in the targeted visual edit allowlist."
        lines << "- Do not regenerate the full page."
        lines << "- Do not edit unrelated components or pages even if they appear in component-map.json."
      end
      lines << "- Leave .ai-web run artifacts, logs, and diff evidence to the wrapper."
      lines << "- Return by exiting after the patch is complete."
      lines.join("\n")
    end

    def agent_run_run_metadata(run_id:, agent:, task_source:, context:, command:, context_path:, started_at:, finished_at:, exit_code:, stdout_log:, stderr_log:, metadata_path:, diff_path:, source_paths:, dry_run:, approved:, blocking_issues:, status:, changed_source_files: [])
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "agent" => agent,
        "command" => command,
        "cwd" => root,
        "task_path" => task_source["relative"],
        "task_sha256" => task_source["path"] ? Digest::SHA256.file(task_source["path"]).hexdigest : nil,
        "context" => {
          "safe_context_only" => context["safe_context_only"] == true,
          "context_files" => context["context_files"],
          "selected_candidate" => context["selected_candidate"],
          "selected_design_files" => context["selected_design_files"],
          "source_paths" => source_paths,
          "targeted_edit" => context["targeted_edit"] == true,
          "target_allowlist" => context["target_allowlist"]
        },
        "source_paths" => source_paths,
        "changed_source_files" => changed_source_files,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "exit_code" => exit_code,
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "context_path" => context_path,
        "metadata_path" => metadata_path,
        "diff_path" => diff_path,
        "dry_run" => dry_run,
        "approved" => approved,
        "requires_approval" => !approved && !dry_run,
        "blocking_issues" => blocking_issues
      }
    end

    def agent_run_payload(state:, metadata:, changed_files:, planned_changes:, action_taken:, blocking_issues:, next_action:)
      payload = status_hash(state: state, changed_files: changed_files)
      payload["action_taken"] = action_taken
      payload["blocking_issues"] = blocking_issues
      payload["planned_changes"] = planned_changes unless planned_changes.empty?
      payload["agent_run"] = metadata
      payload["next_action"] = next_action
      payload
    end

    def agent_run_next_action(metadata)
      agent = metadata["agent"].to_s.empty? ? "codex" : metadata["agent"]
      case metadata["status"]
      when "passed"
        "review #{metadata["metadata_path"]} and #{metadata["diff_path"]} before accepting the patch"
      when "no_changes"
        "inspect #{metadata["stdout_log"]} and #{metadata["stderr_log"]}; rerun with better source hints if the patch should have changed files"
      when "failed"
        "inspect #{metadata["stdout_log"]} and #{metadata["stderr_log"]}, then repair the source task and rerun aiweb agent-run --task latest --agent #{agent} --approved"
      else
        "add a safe source target to the task packet or component map, then rerun aiweb agent-run --task latest --agent #{agent} --approved"
      end
    end

  end
end
