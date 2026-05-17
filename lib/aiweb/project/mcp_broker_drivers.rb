# frozen_string_literal: true

require "digest"
require "pathname"

module Aiweb
  module ProjectMcpBroker
    module Drivers
      private

      def implementation_mcp_broker_call_lazyweb(request)
        client = LazywebClient.new(endpoint: request.fetch("endpoint_raw"), timeout_seconds: 5)
        case request.fetch("tool")
        when "lazyweb_health"
          client.health
        when "lazyweb_search"
          client.search(query: request.dig("arguments", "query"), limit: request.dig("arguments", "limit"), max_per_company: 1)
        else
          raise UserError.new("unsupported implementation MCP broker tool: #{request.fetch("tool")}", 1)
        end
      end

      def implementation_mcp_broker_call_driver(request)
        case request.fetch("server")
        when IMPLEMENTATION_MCP_ALLOWED_SERVER
          implementation_mcp_broker_call_lazyweb(request)
        when IMPLEMENTATION_MCP_PROJECT_FILES_SERVER
          implementation_mcp_broker_call_project_files(request)
        else
          raise UserError.new("unsupported implementation MCP broker server: #{request.fetch("server")}", 1)
        end
      end

      def implementation_mcp_broker_call_project_files(request)
        relative_path = implementation_mcp_project_file_normalized_path(request.dig("arguments", "path"))
        return implementation_mcp_broker_call_project_file_list(relative_path, request.dig("arguments", "limit")) if request.fetch("tool") == "project_file_list"
        return implementation_mcp_broker_call_project_file_excerpt(relative_path, request.dig("arguments", "max_lines")) if request.fetch("tool") == "project_file_excerpt"
        return implementation_mcp_broker_call_project_file_search(relative_path, request.dig("arguments", "pattern"), request.dig("arguments", "limit")) if request.fetch("tool") == "project_file_search"

        path = File.expand_path(relative_path, root)
        stat = File.lstat(path)
        raise UserError.new("project_file_metadata refuses symlink path: #{relative_path}", 5) if stat.symlink?
        raise UserError.new("project_file_metadata requires a regular file: #{relative_path}", 5) unless stat.file?

        {
          "schema_version" => 1,
          "tool" => "project_file_metadata",
          "path" => relative_path,
          "kind" => "file",
          "bytes" => stat.size,
          "sha256" => "sha256:#{Digest::SHA256.file(path).hexdigest}",
          "mtime_utc" => stat.mtime.utc.iso8601,
          "content_included" => false,
          "network_used" => false
        }
      end

      def implementation_mcp_broker_call_project_file_list(relative_path, limit)
        path = File.expand_path(relative_path, root)
        stat = File.lstat(path)
        raise UserError.new("project_file_list refuses symlink path: #{relative_path}", 5) if stat.symlink?

        candidates = if stat.directory?
                       Dir.children(path).sort.map { |child| File.join(relative_path, child).tr("\\", "/").sub(%r{\A\./}, "") }
                     elsif stat.file?
                       [relative_path]
                     else
                       raise UserError.new("project_file_list requires a regular file or directory: #{relative_path}", 5)
                     end
        safe_candidates = candidates.reject { |candidate| implementation_mcp_project_file_list_entry_excluded?(candidate) }
        entries = safe_candidates.first(limit.to_i).map { |candidate| implementation_mcp_project_file_list_entry(candidate) }.compact
        {
          "schema_version" => 1,
          "tool" => "project_file_list",
          "path" => relative_path,
          "kind" => stat.directory? ? "directory" : "file",
          "entry_count" => entries.length,
          "limit" => limit.to_i,
          "truncated" => safe_candidates.length > entries.length,
          "excluded_count" => candidates.length - safe_candidates.length,
          "entries" => entries,
          "content_included" => false,
          "network_used" => false
        }
      end

      def implementation_mcp_project_file_list_entry(relative_path)
        path = File.expand_path(relative_path, root)
        stat = File.lstat(path)
        return nil if stat.symlink?

        {
          "path" => relative_path,
          "kind" => stat.directory? ? "directory" : (stat.file? ? "file" : "other"),
          "bytes" => stat.file? ? stat.size : nil,
          "sha256" => stat.file? ? "sha256:#{Digest::SHA256.file(path).hexdigest}" : nil,
          "mtime_utc" => stat.mtime.utc.iso8601,
          "content_included" => false
        }.compact
      rescue SystemCallError
        nil
      end

      def implementation_mcp_broker_call_project_file_excerpt(relative_path, max_lines)
        path = File.expand_path(relative_path, root)
        stat = File.lstat(path)
        raise UserError.new("project_file_excerpt refuses symlink path: #{relative_path}", 5) if stat.symlink?
        raise UserError.new("project_file_excerpt requires a regular file: #{relative_path}", 5) unless stat.file?

        text = implementation_mcp_project_file_excerpt_text(path)
        selected = text.lines.first(max_lines.to_i)
        excerpt = selected.join
        {
          "schema_version" => 1,
          "tool" => "project_file_excerpt",
          "path" => relative_path,
          "kind" => "file",
          "bytes" => stat.size,
          "sha256" => "sha256:#{Digest::SHA256.file(path).hexdigest}",
          "mtime_utc" => stat.mtime.utc.iso8601,
          "content_included" => true,
          "content_policy" => "bounded_safe_utf8_excerpt_no_secret_like_content",
          "max_lines" => max_lines.to_i,
          "excerpt_line_count" => selected.length,
          "truncated" => text.lines.length > selected.length,
          "excerpt" => excerpt,
          "network_used" => false
        }
      end

      def implementation_mcp_broker_call_project_file_search(relative_path, pattern, limit)
        path = File.expand_path(relative_path, root)
        stat = File.lstat(path)
        raise UserError.new("project_file_search refuses symlink path: #{relative_path}", 5) if stat.symlink?
        raise UserError.new("project_file_search requires a regular file or directory: #{relative_path}", 5) unless stat.file? || stat.directory?

        candidates = implementation_mcp_project_file_search_candidates(relative_path, path, stat)
        matches = []
        skipped = 0
        candidates.each do |candidate|
          break if matches.length >= limit.to_i

          candidate_path = File.expand_path(candidate, root)
          blockers = implementation_mcp_project_file_excerpt_content_blockers(candidate)
          if !blockers.empty?
            skipped += 1
            next
          end
          text = implementation_mcp_project_file_excerpt_text(candidate_path)
          text.lines.each_with_index do |line, index|
            next unless line.include?(pattern)

            matches << {
              "path" => candidate,
              "line" => index + 1,
              "excerpt" => redact_side_effect_process_output(line.chomp)[0, 240],
              "content_included" => true
            }
            break if matches.length >= limit.to_i
          end
        rescue SystemCallError, ArgumentError, Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
          skipped += 1
        end

        {
          "schema_version" => 1,
          "tool" => "project_file_search",
          "path" => relative_path,
          "pattern_sha256" => "sha256:#{Digest::SHA256.hexdigest(pattern)}",
          "literal_match" => true,
          "file_scan_limit" => IMPLEMENTATION_MCP_PROJECT_FILE_SEARCH_MAX_FILES,
          "scanned_file_count" => candidates.length,
          "skipped_file_count" => skipped,
          "match_count" => matches.length,
          "limit" => limit.to_i,
          "truncated" => matches.length >= limit.to_i || candidates.length >= IMPLEMENTATION_MCP_PROJECT_FILE_SEARCH_MAX_FILES,
          "matches" => matches,
          "content_policy" => "bounded_literal_utf8_search_no_secret_like_content",
          "content_included" => true,
          "network_used" => false
        }
      end
      def implementation_mcp_project_file_path_blockers(value)
        policy = implementation_mcp_project_file_path_policy(value, tool: "project_file_metadata", block_secret_looking: false)
        blockers = policy.fetch(:blockers)
        blockers.concat(implementation_mcp_project_file_existing_blockers(policy, tool: "project_file_metadata", allow_directory: false)) if blockers.empty?
        blockers
      end

      def implementation_mcp_project_file_list_path_blockers(value)
        policy = implementation_mcp_project_file_path_policy(value, tool: "project_file_list", block_secret_looking: true)
        blockers = policy.fetch(:blockers)
        blockers.concat(implementation_mcp_project_file_existing_blockers(policy, tool: "project_file_list", allow_directory: true)) if blockers.empty?
        blockers
      end

      def implementation_mcp_project_file_excerpt_path_blockers(value)
        policy = implementation_mcp_project_file_path_policy(value, tool: "project_file_excerpt", block_secret_looking: true)
        blockers = policy.fetch(:blockers)
        blockers.concat(implementation_mcp_project_file_existing_blockers(policy, tool: "project_file_excerpt", allow_directory: false)) if blockers.empty?
        blockers
      end

      def implementation_mcp_project_file_excerpt_content_blockers(value)
        normalized = implementation_mcp_project_file_normalized_path(value)
        path = File.expand_path(normalized, root)
        return ["project_file_excerpt refuses files larger than #{IMPLEMENTATION_MCP_PROJECT_FILE_EXCERPT_MAX_BYTES} bytes"] if File.size(path) > IMPLEMENTATION_MCP_PROJECT_FILE_EXCERPT_MAX_BYTES

        text = implementation_mcp_project_file_excerpt_text(path)
        blockers = []
        blockers << "project_file_excerpt refuses binary files" if text.include?("\x00")
        blockers << "project_file_excerpt refuses file with secret-like content" if redact_side_effect_process_output(text) != text
        blockers
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        ["project_file_excerpt refuses non-UTF-8 text"]
      rescue SystemCallError, ArgumentError
        ["project_file_excerpt could not safely read file"]
      end

      def implementation_mcp_project_file_search_blockers(path_value, pattern_value)
        policy = implementation_mcp_project_file_path_policy(path_value, tool: "project_file_search", block_secret_looking: true)
        pattern = pattern_value.to_s
        blockers = policy.fetch(:blockers)
        blockers << "project_file_search pattern is required" if pattern.empty?
        blockers << "project_file_search pattern must be at most 80 characters" if pattern.length > 80
        blockers << "project_file_search pattern must not contain NUL bytes" if pattern.include?("\x00")
        blockers << "project_file_search pattern must not be secret-like" if redact_side_effect_process_output(pattern) != pattern
        blockers.concat(implementation_mcp_project_file_existing_blockers(policy, tool: "project_file_search", allow_directory: true)) if blockers.empty?
        blockers
      end

      def implementation_mcp_project_file_search_candidates(relative_path, path, stat)
        raw_candidates = if stat.file?
                           [relative_path]
                         else
                           Dir.glob(File.join(path, "**", "*"), File::FNM_DOTMATCH).sort.map do |entry|
                             entry.sub(File.expand_path(root) + File::SEPARATOR, "").tr("\\", "/")
                           end
                         end
        raw_candidates.each_with_object([]) do |candidate, memo|
          next if implementation_mcp_project_file_list_entry_excluded?(candidate)
          next unless File.file?(File.expand_path(candidate, root))

          memo << candidate
          break memo if memo.length >= IMPLEMENTATION_MCP_PROJECT_FILE_SEARCH_MAX_FILES
        end
      end

      def implementation_mcp_project_file_excerpt_text(path)
        raw = File.binread(path, IMPLEMENTATION_MCP_PROJECT_FILE_EXCERPT_MAX_BYTES + 1)
        raise ArgumentError, "file too large" if raw.bytesize > IMPLEMENTATION_MCP_PROJECT_FILE_EXCERPT_MAX_BYTES

        text = raw.dup.force_encoding(Encoding::UTF_8)
        raise Encoding::InvalidByteSequenceError, "invalid UTF-8" unless text.valid_encoding?

        text
      end

      def implementation_mcp_project_file_list_entry_excluded?(relative_path)
        policy = implementation_mcp_project_file_path_policy(relative_path, tool: "project_file_list", block_secret_looking: true)
        return true unless policy.fetch(:blockers).empty?

        File.symlink?(policy.fetch(:path))
      end

      def implementation_mcp_project_file_path_policy(value, tool:, block_secret_looking:)
        normalized = implementation_mcp_project_file_normalized_path(value)
        parts = normalized.split("/")
        path = File.expand_path(normalized, root)
        root_path = File.expand_path(root)
        blockers = []
        blockers << "#{tool} path must be relative" if normalized.empty? || Pathname.new(normalized).absolute?
        blockers << "#{tool} path must not traverse outside project" if parts.include?("..")
        blockers << "#{tool} path must not reference .env/.env.*" if implementation_mcp_project_file_env_path?(parts)
        blockers << "#{tool} path must not reference .git, node_modules, or generated run artifacts" if implementation_mcp_project_file_generated_path?(normalized, parts)
        blockers << "#{tool} path must not be secret-looking" if block_secret_looking && secret_looking_path?(normalized)
        blockers << "#{tool} path escapes project root" unless implementation_mcp_project_file_project_root_path?(path, root_path)
        { normalized: normalized, parts: parts, path: path, root_path: root_path, blockers: blockers }
      end

      def implementation_mcp_project_file_existing_blockers(policy, tool:, allow_directory:)
        path = policy.fetch(:path)
        blockers = []
        allowed_type = allow_directory ? File.file?(path) || File.directory?(path) : File.file?(path)
        blockers << "#{tool} requires an existing #{allow_directory ? "regular file or directory" : "regular file"}" unless allowed_type
        blockers << "#{tool} refuses symlink paths" if File.symlink?(path)
        blockers
      end

      def implementation_mcp_project_file_env_path?(parts)
        parts.any? { |part| part == ".env" || part.start_with?(".env.") }
      end

      def implementation_mcp_project_file_generated_path?(normalized, parts)
        parts.any? { |part| %w[.git node_modules].include?(part) } || implementation_mcp_project_file_runs_path?(normalized)
      end

      def implementation_mcp_project_file_project_root_path?(path, root_path)
        path == root_path || path.start_with?(root_path + File::SEPARATOR)
      end

      def implementation_mcp_project_file_runs_path?(normalized)
        normalized == ".ai-web/runs" || normalized.start_with?(".ai-web/runs/")
      end

      def implementation_mcp_project_file_normalized_path(value)
        value.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "").strip
    end
    end
  end
end
