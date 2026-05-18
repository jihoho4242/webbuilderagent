# frozen_string_literal: true

module Aiweb
  module ProjectAgentRun
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

      explicit_paths = agent_run_allowed_source_paths_from_task(task_text)
      unless explicit_paths.empty?
        return explicit_paths.uniq.select { |path| agent_run_source_path_allowed?(path) }.first(10)
      end

      paths = []
      paths.concat(agent_run_paths_from_text(task_text))
      paths.concat(agent_run_component_map_source_paths(component_map)) if component_map
      paths.uniq.select { |path| agent_run_source_path_allowed?(path) }.first(10)
    end

    def agent_run_allowed_source_paths_from_task(task_text)
      collecting = false
      task_text.to_s.each_line.each_with_object([]) do |line, memo|
        stripped = line.strip
        if stripped == "allowed_source_paths:"
          collecting = true
          next
        end
        next unless collecting
        break memo if stripped.empty? || stripped.start_with?("## ") || stripped.match?(/\A[A-Za-z_][\w-]*:\s*(?:false|true|\d+|".*"|'.*')?\z/)
        next unless stripped.start_with?("- ")

        path = stripped.sub(/\A-\s+/, "").sub(/[),.;:]+$/, "").delete("`\"'")
        memo << agent_run_normalized_relative_path(path)
      end
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

      expanded = File.expand_path(normalized, root)
      root_prefix = File.expand_path(root)
      comparison_expanded = windows? ? expanded.downcase : expanded
      comparison_root = windows? ? root_prefix.downcase : root_prefix
      return false unless comparison_expanded == comparison_root || comparison_expanded.start_with?(comparison_root + File::SEPARATOR)
      return false if File.symlink?(expanded)
      return false if File.file?(expanded) && File.lstat(expanded).nlink.to_i > 1

      File.exist?(expanded)
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

  end
end
