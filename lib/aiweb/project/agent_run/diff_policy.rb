# frozen_string_literal: true

module Aiweb
  module ProjectAgentRun
    private

    def agent_run_source_diff(source_paths)
      changed_files = agent_run_changed_files(source_paths)
      return ["", []] if changed_files.empty?

      patch = changed_files.flat_map do |entry|
        path = entry["path"]
        result = agent_run_git_diff_result(path, untracked: entry["untracked"])
        next result.stdout if result.success? && !result.stdout.empty?
        next [result.stdout, result.stderr].join
      rescue ArgumentError, SystemCallError
        next agent_run_full_file_diff(path, nil, File.join(root, path))
      end.join

      [patch, changed_files.map { |entry| entry["path"] }]
    end

    def agent_run_git_diff_result(path, untracked:)
      argv = if untracked
               ["git", "diff", "--no-color", "--binary", "--no-index", "--", "/dev/null", path]
             else
               ["git", "diff", "--no-color", "--binary", "--", path]
             end
      runtime_process_runner.capture(
        Aiweb::Runtime::CommandSpec.new(
          argv: argv,
          cwd: root,
          timeout: 30,
          max_output_bytes: 500_000,
          risk_class: "agent_run_read_only_git_evidence",
          description: "agent-run git diff evidence"
        )
      )
    end

    def agent_run_full_file_diff(relative_path, before_path, after_path)
      before_lines = before_path && File.file?(before_path) ? File.readlines(before_path) : []
      after_lines = after_path && File.file?(after_path) ? File.readlines(after_path) : []
      return "" if before_lines == after_lines

      old_start = before_lines.empty? ? 0 : 1
      new_start = after_lines.empty? ? 0 : 1
      lines = [
        "diff --git a/#{relative_path} b/#{relative_path}\n",
        "--- a/#{relative_path}\n",
        "+++ b/#{relative_path}\n",
        "@@ -#{old_start},#{before_lines.length} +#{new_start},#{after_lines.length} @@\n"
      ]
      before_lines.each { |line| lines << agent_run_diff_body_line("-", line) }
      after_lines.each { |line| lines << agent_run_diff_body_line("+", line) }
      lines.join
    rescue SystemCallError
      ""
    end

    def agent_run_diff_body_line(prefix, line)
      text = line.to_s
      text = "#{text}\n" unless text.end_with?("\n")
      "#{prefix}#{text}"
    end

    def agent_run_validate_source_diff(diff_patch, allowed_source_paths)
      return [] if diff_patch.to_s.strip.empty?

      allowed = Array(allowed_source_paths).map { |path| agent_run_normalized_relative_path(path) }.to_set
      blockers = []
      diff_patch.each_line do |line|
        case line
        when /\Adiff --git a\/(.+) b\/(.+)\s*\z/
          [$1, $2].each do |path|
            normalized = agent_run_normalized_relative_path(path)
            blockers << "agent-run diff touches path outside allowed source paths: #{normalized}" unless allowed.include?(normalized)
            blockers << "agent-run diff contains unsafe path: #{normalized}" if unsafe_secret_surface_path?(normalized) || normalized.split("/").any? { |part| part == ".." }
          end
        when /\A(?:rename from|rename to|copy from|copy to|similarity index|dissimilarity index)\b/
          blockers << "agent-run diff contains rename/copy metadata, which is not allowed"
        when /\A(?:deleted file mode|new file mode|old mode|new mode)\b/
          blockers << "agent-run diff contains file mode changes, which are not allowed"
        when /\A(?:Binary files|GIT binary patch)\b/
          blockers << "agent-run diff contains binary patch content, which is not allowed"
        when /\A@@ /
          blockers << "agent-run diff contains malformed hunk header: #{line.strip}" unless line.match?(/\A@@ -\d+(?:,\d+)? \+\d+(?:,\d+)? @@/)
        when /\A(?:---|\+\+\+) (.+)\s*\z/
          marker_path = $1.to_s
          next if marker_path == "/dev/null"

          normalized = agent_run_normalized_relative_path(marker_path.sub(%r{\A[ab]/}, ""))
          blockers << "agent-run diff header touches path outside allowed source paths: #{normalized}" unless allowed.include?(normalized)
        end
      end
      blockers.uniq
    end

    def agent_run_changed_files(source_paths)
      result = runtime_process_runner.capture(
        Aiweb::Runtime::CommandSpec.new(
          argv: ["git", "status", "--porcelain=v1", "-uall"],
          cwd: root,
          timeout: 30,
          max_output_bytes: 500_000,
          risk_class: "agent_run_read_only_git_evidence",
          description: "agent-run git status evidence"
        )
      )
      return source_paths.map { |path| { "path" => path, "untracked" => false } } unless result.success?

      changed = result.stdout.lines.each_with_object([]) do |line, memo|
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
    rescue ArgumentError, SystemCallError
      source_paths.map { |path| { "path" => path, "untracked" => false } }
    end

    def agent_run_workspace_snapshot
      snapshot = {}
      Find.find(root) do |path|
        relative_path = relative(path)
        if File.directory?(path)
          parts = relative_path.split("/")
          Find.prune if parts.any? { |part| self.class::AGENT_RUN_SNAPSHOT_PRUNE_DIRS.include?(part) } || relative_path.start_with?(".ai-web/runs", ".ai-web/diffs", ".ai-web/snapshots", ".ai-web/tmp")
          next
        end
        next unless File.file?(path) || File.symlink?(path)
        next if relative_path.start_with?(".ai-web/runs/", ".ai-web/diffs/", ".ai-web/snapshots/", ".ai-web/tmp/")

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

  end
end
