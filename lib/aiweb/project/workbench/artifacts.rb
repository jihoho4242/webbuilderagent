# frozen_string_literal: true

require "find"
require "json"

module Aiweb
  module ProjectWorkbench
    def workbench_artifact_summaries(state)
      return [] unless state

      (state["artifacts"] || {}).sort.map do |name, meta|
        meta = {} unless meta.is_a?(Hash)
        path = meta["path"].to_s
        next if workbench_excluded_path?(path)

        full = File.join(root, path)
        {
          "id" => name,
          "path" => path,
          "status" => meta["status"],
          "exists" => File.exist?(full),
          "directory" => File.directory?(full),
          "size_bytes" => File.file?(full) ? File.size(full) : nil
        }
      end.compact
    end

    def workbench_design_candidates(state)
      refs = Array(state&.dig("design_candidates", "candidates"))
      refs.map do |candidate|
        next unless candidate.is_a?(Hash)
        path = candidate["path"].to_s
        next if workbench_excluded_path?(path)
        full = File.join(root, path)
        candidate.slice("id", "path", "status", "strategy_id", "score", "rubric_scores", "first_view", "proof_pattern", "cta_flow", "mobile_behavior", "risks").merge(
          "exists" => File.exist?(full),
          "size_bytes" => File.file?(full) ? File.size(full) : nil
        )
      end.compact
    end

    def workbench_selected_design(state)
      selected = state&.dig("design_candidates", "selected_candidate")
      design_md = File.join(aiweb_dir, "DESIGN.md")
      selected_md = File.join(aiweb_dir, "design-candidates", "selected.md")
      selected_ref = Array(state&.dig("design_candidates", "candidates")).find { |candidate| candidate.is_a?(Hash) && candidate["id"] == selected }
      {
        "status" => selected.to_s.empty? ? "empty" : "ready",
        "selected_candidate" => selected,
        "strategy_id" => selected_ref && selected_ref["strategy_id"],
        "score" => selected_ref && selected_ref["score"],
        "risks" => selected_ref && selected_ref["risks"],
        "design_md" => { "path" => ".ai-web/DESIGN.md", "exists" => File.file?(design_md), "substantive" => File.file?(design_md) && !stub_file?(design_md) },
        "selected_notes" => { "path" => ".ai-web/design-candidates/selected.md", "exists" => File.file?(selected_md) }
      }
    end

    def workbench_file_tree
      entries = []
      return entries unless File.directory?(root)

      Find.find(root) do |path|
        rel = relative(path)
        next if rel.empty?
        if workbench_excluded_path?(rel)
          Find.prune if File.directory?(path)
          next
        end
        entries << {
          "path" => rel,
          "type" => File.directory?(path) ? "directory" : "file",
          "size_bytes" => File.file?(path) ? File.size(path) : nil
        }
        Find.prune if entries.length >= 200
      end
      entries
    end

    def bounded_observability_limit(limit)
      value = limit.to_i
      value = 20 unless value.positive?
      [[value, 1].max, 50].min
    end

    def workbench_run_timeline(limit = 20)
      bounded_limit = bounded_observability_limit(limit)
      Dir.glob(File.join(aiweb_dir, "runs", "*", "*.json"))
         .reject { |path| unsafe_env_path?(relative(path)) }
         .sort_by { |path| [File.mtime(path), path] }
         .last(bounded_limit)
         .map do |path|
        workbench_json_summary(relative(path), allow_runs: true)
      end.compact
    end

    def workbench_verify_loop_status(state)
      implementation = state&.dig("implementation").is_a?(Hash) ? state.dig("implementation") : {}
      latest_path = implementation["latest_verify_loop"]
      latest = latest_path && !unsafe_env_path?(latest_path) ? workbench_json_summary(latest_path, allow_runs: true) : nil
      {
        "status" => implementation["verify_loop_status"] || (latest ? latest["status"] : "empty"),
        "latest_verify_loop" => latest_path,
        "cycle_count" => implementation["verify_loop_cycle_count"],
        "latest_blocker" => implementation["latest_blocker"],
        "latest" => latest
      }
    end

    def workbench_agent_runtime_status(state)
      implementation = state&.dig("implementation").is_a?(Hash) ? state.dig("implementation") : {}
      latest_path = implementation["latest_agent_runtime"]
      latest_path ||= latest_agent_runtime_report_path
      latest_path ||= implementation["latest_engine_run"]
      latest = latest_path && !unsafe_env_path?(latest_path) ? workbench_json_summary(latest_path, allow_runs: true) : nil
      {
        "status" => implementation["agent_runtime_status"] || (latest ? latest["status"] : "empty"),
        "latest_agent_runtime" => latest_path,
        "latest_engine_run" => implementation["latest_engine_run"],
        "run_id" => implementation["agent_runtime_run_id"] || latest&.dig("agent_session", "run_id"),
        "mode" => implementation["agent_runtime_mode"] || latest&.dig("mode"),
        "profile" => implementation["agent_runtime_profile"] || latest&.dig("profile"),
        "latest" => latest
      }
    end

    def latest_agent_runtime_report_path
      path = Dir.glob(File.join(aiweb_dir, "runs", "agent-session-*", "final-report.json")).sort.last
      path ? relative(path) : nil
    end

    def workbench_latest_json(pattern)
      path = Dir.glob(File.join(root, pattern)).sort.last
      path ? workbench_json_summary(relative(path)) : nil
    end

    def workbench_json_summary(path, allow_runs: false)
      return nil if workbench_excluded_path?(path) && !(allow_runs && path.to_s.start_with?(".ai-web/runs/"))

      full = File.expand_path(path, root)
      data = JSON.parse(File.read(full))
      summary = workbench_safe_metadata(data)
      summary["path"] = relative(full)
      summary["size_bytes"] = File.size(full) if File.file?(full)
      summary
    rescue JSON::ParserError, SystemCallError
      { "path" => path, "status" => "unreadable" }
    end

    def workbench_safe_metadata(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), memo|
          key = key.to_s
          next if key.match?(/secret|token|password|api[_-]?key|credential/i)
          next if workbench_excluded_path?(item.to_s)

          memo[key] = workbench_safe_metadata(item)
        end
      when Array
        value.first(20).map { |item| workbench_safe_metadata(item) }
      when String
        workbench_excluded_path?(value) ? "[excluded]" : value[0, 300]
      else
        value
      end
    end

    def workbench_excluded_path?(path)
      value = path.to_s
      return true if value.empty? && path
      return true if secret_surface_path?(value)

      normalized = value.sub(%r{\A\./}, "")
      self.class::WORKBENCH_FILE_TREE_EXCLUDES.any? do |excluded|
        normalized == excluded || normalized.start_with?(excluded + "/")
      end
    end
  end
end
