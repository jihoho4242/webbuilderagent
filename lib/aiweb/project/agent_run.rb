# frozen_string_literal: true

module Aiweb
  module ProjectAgentRun
    def agent_run(task: "latest", agent: "codex", approved: false, dry_run: false)
      assert_initialized!

      agent_name = agent.to_s.strip.empty? ? "codex" : agent.to_s.strip
      raise UserError.new("agent-run currently supports only --agent codex", 1) unless agent_name == "codex"

      state = load_state
      ensure_implementation_state_defaults!(state)

      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      run_id = "agent-run-#{timestamp}"
      run_dir = File.join(aiweb_dir, "runs", run_id)
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      metadata_path = File.join(run_dir, "agent-run.json")
      diff_path = File.join(aiweb_dir, "diffs", "#{run_id}.patch")
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
      blockers << "codex executable is missing from PATH" if !dry_run && approved && executable_path(agent_name).nil?
      blockers.concat(agent_run_forbidden_path_blockers(task_text, component_map_text))
      blockers.concat(agent_run_target_allowlist_blockers(target_allowlist, component_map))

      planned_changes = [
        relative(run_dir),
        relative(stdout_path),
        relative(stderr_path),
        relative(metadata_path),
        relative(diff_path)
      ]

      metadata = agent_run_run_metadata(
        run_id: run_id,
        agent: agent_name,
        task_source: task_source,
        context: context,
        command: agent_name,
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

      if dry_run || !blockers.empty?
        return agent_run_payload(
          state: state,
          metadata: metadata,
          changed_files: [],
          planned_changes: blockers.empty? ? planned_changes : [],
          action_taken: blockers.empty? ? "planned agent run" : "agent run blocked",
          blocking_issues: blockers.uniq,
          next_action: blockers.empty? ? "rerun aiweb agent-run --task latest --agent codex --approved to execute the local codex patch run" : "add a safe source target to the task packet or component map, then rerun aiweb agent-run --task latest --agent codex --approved"
        )
      end

      changes = []
      payload = nil
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << relative(run_dir)
        started_at = now
        prompt = agent_run_prompt(context: context)
        before_snapshot = agent_run_workspace_snapshot
        stdout = ""
        stderr = ""
        exit_code = nil
        status = "blocked"

        stdout, stderr, process_status = Open3.capture3(
          { "AIWEB_AGENT_RUN_CONTEXT_JSON" => JSON.pretty_generate(context), "AIWEB_AGENT_RUN_ALLOWED_SOURCE_PATHS_JSON" => JSON.generate(source_paths), "AIWEB_AGENT_RUN_TASK_PATH" => task_source["relative"].to_s, "AIWEB_AGENT_RUN_APPROVED" => "1", "AIWEB_AGENT_RUN_DRY_RUN" => "0", "AIWEB_AGENT_RUN_RUN_ID" => run_id, "AIWEB_AGENT_RUN_DIFF_PATH" => relative(diff_path), "AIWEB_AGENT_RUN_METADATA_PATH" => relative(metadata_path) },
          agent_name,
          stdin_data: prompt,
          chdir: root
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
        changes << write_file(diff_path, diff_patch, false)

        metadata = agent_run_run_metadata(
          run_id: run_id,
          agent: agent_name,
          task_source: task_source,
          context: context,
          command: agent_name,
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
          status: if status == "failed"
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

    def agent_run_default_source_targets
      component_map_source_paths.select { |path| agent_run_source_path_allowed?(path) }
    rescue StandardError
      []
    end

    def resolve_agent_run_task_source(task, state)
      requested = task.to_s.strip
      requested = "latest" if requested.empty?

      if requested == "latest"
        latest = state.dig("implementation", "current_task").to_s.strip
        latest = latest_agent_run_task_artifact.to_s.strip if latest.empty?
        return { "relative" => nil, "path" => nil, "reason" => "no implementation task artifact is available" } if latest.empty?

        reject_env_file_segment!(latest, "agent-run refuses to read .env or .env.* task paths")
        path = File.expand_path(latest, root)
        return { "relative" => latest, "path" => nil, "reason" => "task packet #{latest} is missing" } unless File.file?(path)

        return { "relative" => relative(path), "path" => path, "reason" => nil }
      end

      reject_env_file_segment!(requested, "agent-run refuses to read .env or .env.* task paths")
      path = File.expand_path(requested, root)
      unless File.file?(path)
        return { "relative" => requested, "path" => nil, "reason" => "task packet #{requested} is missing" }
      end

      { "relative" => relative(path), "path" => path, "reason" => nil }
    end

    def latest_agent_run_task_artifact
      Dir.glob(File.join(aiweb_dir, "tasks", "*.md")).max_by { |path| File.mtime(path) }
    rescue SystemCallError
      nil
    end

    def load_agent_run_component_map
      path = File.join(aiweb_dir, "component-map.json")
      return nil unless File.file?(path)

      load_component_map_for_visual_edit(path)
    end

    def agent_run_source_paths(task_text, component_map, target_allowlist: nil)
      allowlist_paths = agent_run_target_allowlist_source_paths(target_allowlist)
      unless allowlist_paths.empty?
        return allowlist_paths.uniq.select { |path| agent_run_source_path_allowed?(path) }.first(10)
      end

      paths = []
      paths.concat(agent_run_paths_from_text(task_text))
      paths.concat(agent_run_component_map_source_paths(component_map)) if component_map
      paths.uniq.select { |path| agent_run_source_path_allowed?(path) }.first(10)
    end

    def agent_run_target_allowlist(task_text)
      candidates = agent_run_json_blocks(task_text)
      candidates.find { |candidate| agent_run_target_allowlist?(candidate) }
    end

    def agent_run_json_blocks(text)
      return [] if text.to_s.strip.empty?

      blocks = []
      text.to_s.scan(/```(?:json)?\s*(.*?)```/m) do |match|
        raw = match.first.to_s.strip
        next if raw.empty?

        begin
          parsed = JSON.parse(raw)
          blocks << parsed if parsed.is_a?(Hash)
        rescue JSON::ParserError
          next
        end
      end
      blocks
    end

    def agent_run_target_allowlist?(value)
      return false unless value.is_a?(Hash)

      value["type"].to_s == "visual_edit_target_allowlist" ||
        (value["strict"] == true && (value.key?("source_paths") || value.key?("data_aiweb_ids") || value.key?("data_aiweb_id")))
    end

    def agent_run_target_allowlist_source_paths(target_allowlist)
      return [] unless target_allowlist.is_a?(Hash)

      Array(target_allowlist["source_paths"]).map { |path| agent_run_normalized_relative_path(path) }.reject(&:empty?)
    end

    def agent_run_target_allowlist_ids(target_allowlist)
      return [] unless target_allowlist.is_a?(Hash)

      ids = Array(target_allowlist["data_aiweb_ids"])
      ids << target_allowlist["data_aiweb_id"] if target_allowlist["data_aiweb_id"]
      ids.map { |id| id.to_s.strip }.reject(&:empty?).uniq
    end

    def agent_run_target_allowlist_blockers(target_allowlist, component_map)
      return [] unless target_allowlist

      blockers = []
      blockers << "target allowlist must be strict for visual-edit agent-run handoffs" unless target_allowlist["strict"] == true
      ids = agent_run_target_allowlist_ids(target_allowlist)
      blockers << "target allowlist must identify exactly one data-aiweb-id" unless ids.length == 1
      paths = agent_run_target_allowlist_source_paths(target_allowlist)
      blockers << "target allowlist must include at least one source_path" if paths.empty?

      paths.each do |path|
        blockers << "target allowlist source path is unsafe or not editable: #{path}" unless agent_run_source_path_allowed?(path)
      end

      return blockers unless ids.length == 1

      unless component_map
        blockers << "target allowlist requires a component map"
        return blockers
      end

      matches = component_map_components(component_map, ids.first)
      blockers << "target data-aiweb-id not found in component map: #{ids.first}" if matches.empty?
      blockers << "target data-aiweb-id is ambiguous in component map: #{ids.first}" if matches.length > 1
      return blockers unless matches.length == 1

      component = matches.first
      blockers << "target data-aiweb-id is not editable: #{ids.first}" if component["editable"] == false
      component_path = agent_run_normalized_relative_path(component["source_path"])
      if component_path.empty?
        blockers << "target component source path is missing for data-aiweb-id: #{ids.first}"
      elsif !agent_run_source_path_allowed?(component_path)
        blockers << "target component source path is unsafe or not editable: #{component_path}"
      elsif !paths.include?(component_path)
        blockers << "target allowlist does not include selected component source path: #{component_path}"
      end

      blockers
    end

    def agent_run_normalized_relative_path(path)
      path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "").strip
    end

    def agent_run_paths_from_text(text)
      return [] if text.to_s.strip.empty?

      text.scan(%r{(?<![\w.-])(?:\.{1,2}/)?(?:[\w.-]+/)*[\w.-]+\.[A-Za-z0-9]+}).flatten.map do |path|
        agent_run_normalized_relative_path(path.sub(/[),.;:]+$/, ""))
      end.uniq.select { |path| File.exist?(File.join(root, path)) }
    end

    def agent_run_component_map_source_paths(component_map)
      Array(component_map.fetch("components", [])).each_with_object([]) do |component, memo|
        next unless component.is_a?(Hash)

        path = component["source_path"].to_s.strip
        next if path.empty?
        next unless File.exist?(File.join(root, path))

        memo << path
      end.uniq
    rescue KeyError
      []
    end

    def agent_run_source_path_allowed?(path)
      normalized = agent_run_normalized_relative_path(path)
      parts = normalized.split("/")
      return false if normalized.empty? || normalized.start_with?("/") || parts.any? { |part| part == ".." }
      return false if parts.any? { |part| part.start_with?(".env") }
      return false if secret_looking_path?(normalized)
      return false if normalized.start_with?(".ai-web/")

      File.exist?(File.join(root, normalized))
    end

    def agent_run_requires_selected_design?(source_paths)
      Array(source_paths).any? do |path|
        normalized = path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
        normalized.match?(%r{\A(?:src|app|components|pages|public|styles|lib|package\.json|astro\.config|next\.config|tailwind\.config|vite\.config)})
      end
    end

    def agent_run_task_packet_blockers(task_source, task_text, source_paths, target_allowlist: nil)
      blockers = []
      return blockers if task_text.to_s.strip.empty?

      relative = task_source["relative"].to_s.tr("\\", "/")
      unless relative.match?(%r{\A\.ai-web/tasks/[A-Za-z0-9_.-]+\.md\z})
        blockers << "agent-run task packet must live under .ai-web/tasks/*.md; got #{relative.empty? ? "unknown" : relative}"
      end
      return blockers if target_allowlist && task_text.include?("Visual Edit Handoff")

      required_markers = {
        "# Task Packet" => "Task Packet heading",
        "## Goal" => "Goal section",
        "## Inputs" => "Inputs section",
        "## Constraints" => "Constraints section",
        "## Machine Constraints" => "Machine Constraints section"
      }
      required_markers.each do |marker, label|
        blockers << "agent-run task packet schema missing #{label} (#{marker})" unless task_text.include?(marker)
      end
      unless task_text.include?(".ai-web/DESIGN.md")
        blockers << "agent-run task packet schema requires .ai-web/DESIGN.md as an implementation input"
      end
      unless task_text.each_line.any? { |line| agent_run_negative_env_guardrail_line?(line) }
        blockers << "agent-run task packet schema requires an explicit no .env/.env.* access constraint"
      end
      {
        "shell_allowed: false" => "shell_allowed false",
        "network_allowed: false" => "network_allowed false",
        "env_access_allowed: false" => "env_access_allowed false",
        "allowed_source_paths:" => "allowed_source_paths"
      }.each do |marker, label|
        blockers << "agent-run task packet schema missing machine constraint #{label}" unless task_text.include?(marker)
      end
      blockers << "agent-run task packet schema requires at least one safe source target" if Array(source_paths).empty?

      blockers
    end

    def agent_run_forbidden_path_blockers(task_text, component_map_text)
      blockers = []
      blockers.concat(agent_run_forbidden_paths_from_text(task_text))
      blockers.concat(agent_run_secret_path_blockers(task_text))
      blockers.concat(agent_run_shell_request_blockers(task_text))
      blockers.uniq
    end

    def agent_run_forbidden_paths_from_text(text)
      return [] if text.to_s.strip.empty?

      text.each_line.each_with_object([]) do |line, blockers|
        next if agent_run_negative_env_guardrail_line?(line)

        line.scan(%r{(?<![\w.-])(?:\.{1,2}/)?(?:[\w.-]+/)*\.env(?:\.[\w.-]+)?(?:/[^\s`"'<>]*)?}).flatten.each do |path|
          normalized = path.sub(/[),.;:]+$/, "")
          next if normalized.empty?

          blockers << normalized
        end
      end.uniq
    end

    def agent_run_secret_path_blockers(text)
      return [] if text.to_s.strip.empty?

      text.each_line.each_with_object([]) do |line, blockers|
        next if agent_run_negative_guardrail_line?(line)

        line.scan(%r{(?<![\w.-])(?:\.{1,2}/)?(?:[\w.-]+/)*[\w.-]+\.[A-Za-z0-9]+(?:/[^\s`"'<>]*)?}).flatten.each do |path|
          normalized = path.sub(/[),.;:]+$/, "").tr("\\", "/").sub(%r{\A(?:\./)+}, "")
          next if normalized.empty?

          blockers << "agent-run refuses unsafe secret-looking task path: #{normalized}" if secret_looking_path?(normalized)
        end
        line.scan(%r{(?<![\w.-])(?:\.ssh|secrets?|credentials?)(?:/[^\s`"'<>]+)?}).flatten.each do |path|
          normalized = path.sub(/[),.;:]+$/, "").tr("\\", "/").sub(%r{\A(?:\./)+}, "")
          blockers << "agent-run refuses unsafe secret-looking task path: #{normalized}" unless normalized.empty?
        end
      end.uniq
    end

    def agent_run_shell_request_blockers(text)
      return [] if text.to_s.strip.empty?

      text.each_line.each_with_object([]) do |line, blockers|
        next if agent_run_negative_guardrail_line?(line)
        next unless line.match?(self.class::AGENT_RUN_SHELL_REQUEST_PATTERN)

        blockers << "agent-run task packet requests unsafe shell/network/package/deploy command execution; agent-run only accepts source patch instructions"
      end.uniq
    end

    def agent_run_negative_guardrail_line?(line)
      normalized = line.to_s.downcase
      normalized.match?(/\b(?:do not|don't|dont|must not|never|no |without|forbid|forbidden|disallow|blocked)\b/)
    end

    def agent_run_negative_env_guardrail_line?(line)
      normalized = line.to_s.downcase
      return false unless normalized.include?(".env")

      normalized.match?(/\b(do not|don't|dont|no)\b.*\.env/) || normalized.match?(/\.env.*\b(not allowed|forbidden|must not|never)\b/)
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

    def agent_run_source_diff(source_paths)
      changed_files = agent_run_changed_files(source_paths)
      return ["", []] if changed_files.empty?

      patch = changed_files.flat_map do |entry|
        path = entry["path"]
        if entry["untracked"]
          stdout, stderr, status = Open3.capture3("git", "diff", "--no-color", "--binary", "--no-index", "--", "/dev/null", path, chdir: root)
          next stdout if status.success? && !stdout.empty?
          next [stdout, stderr].join
        else
          stdout, stderr, status = Open3.capture3("git", "diff", "--no-color", "--binary", "--", path, chdir: root)
          next stdout if status.success? && !stdout.empty?
          next [stdout, stderr].join
        end
      end.join

      [patch, changed_files.map { |entry| entry["path"] }]
    end

    def agent_run_changed_files(source_paths)
      stdout, _stderr, status = Open3.capture3("git", "status", "--porcelain=v1", "-uall", chdir: root)
      return source_paths.map { |path| { "path" => path, "untracked" => false } } if !status.success?

      changed = stdout.lines.each_with_object([]) do |line, memo|
        code = line[0, 2]
        path = line[3..].to_s.strip
        path = path.split(" -> ").last.to_s.strip if line.start_with?("R", "C")
        path = line[3..].to_s.strip if code == "??"
        next if path.empty?
        next unless source_paths.include?(path)
        next unless agent_run_source_path_allowed?(path)

        memo << { "path" => path, "untracked" => code == "??" }
      end
      changed.uniq { |entry| entry["path"] }
    end

    def agent_run_workspace_snapshot
      snapshot = {}
      Find.find(root) do |path|
        relative_path = relative(path)
        if File.directory?(path)
          parts = relative_path.split("/")
          Find.prune if parts.any? { |part| self.class::AGENT_RUN_SNAPSHOT_PRUNE_DIRS.include?(part) } || relative_path.start_with?(".ai-web/runs", ".ai-web/diffs", ".ai-web/snapshots")
          next
        end
        next unless File.file?(path) || File.symlink?(path)
        next if relative_path.start_with?(".ai-web/runs/", ".ai-web/diffs/", ".ai-web/snapshots/")

        stat = File.lstat(path)
        snapshot[relative_path] = if unsafe_env_path?(relative_path) || secret_looking_path?(relative_path) || File.symlink?(path)
                                    "#{stat.file? ? "file" : "other"}:#{stat.size}:#{stat.mtime.to_i}:#{stat.mode}"
                                  else
                                    Digest::SHA256.file(path).hexdigest
                                  end
      end
      snapshot
    end

    def agent_run_unauthorized_workspace_changes(before_snapshot, after_snapshot, allowed_source_paths)
      allowed = Array(allowed_source_paths).map { |path| path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "") }.to_set
      all_paths = (before_snapshot.keys + after_snapshot.keys).uniq
      all_paths.each_with_object([]) do |path, memo|
        next if allowed.include?(path)
        next if before_snapshot[path] == after_snapshot[path]

        memo << path
      end.sort
    end

    def agent_run_redact_process_output(text)
      text.to_s.gsub(self.class::AGENT_RUN_SECRET_VALUE_PATTERN, "[redacted]").lines.map do |line|
        unsafe_env_path?(line) ? "[excluded unsafe .env reference]\n" : line
      end.join
    end

    def agent_run_run_metadata(run_id:, agent:, task_source:, context:, command:, started_at:, finished_at:, exit_code:, stdout_log:, stderr_log:, metadata_path:, diff_path:, source_paths:, dry_run:, approved:, blocking_issues:, status:, changed_source_files: [])
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
      case metadata["status"]
      when "passed"
        "review #{metadata["metadata_path"]} and #{metadata["diff_path"]} before accepting the patch"
      when "no_changes"
        "inspect #{metadata["stdout_log"]} and #{metadata["stderr_log"]}; rerun with better source hints if the patch should have changed files"
      when "failed"
        "inspect #{metadata["stdout_log"]} and #{metadata["stderr_log"]}, then repair the source task and rerun aiweb agent-run --task latest --agent codex --approved"
      else
        "add a safe source target to the task packet or component map, then rerun aiweb agent-run --task latest --agent codex --approved"
      end
    end

  end
end
