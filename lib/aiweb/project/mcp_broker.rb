# frozen_string_literal: true

require "digest"
require "pathname"
require "time"

module Aiweb
  module ProjectMcpBroker
    IMPLEMENTATION_MCP_BROKER_ID = "aiweb.implementation_mcp_broker"
    IMPLEMENTATION_MCP_BROKER_SCOPE = "implementation_worker.mcp.lazyweb"
    IMPLEMENTATION_MCP_PROJECT_FILES_SCOPE = "implementation_worker.mcp.project_files"
    IMPLEMENTATION_MCP_DENIED_SCOPE = "implementation_worker.mcp.denied"
    IMPLEMENTATION_MCP_ALLOWED_SERVER = "lazyweb"
    IMPLEMENTATION_MCP_PROJECT_FILES_SERVER = "project_files"
    IMPLEMENTATION_MCP_ALLOWED_TOOLS = %w[lazyweb_health lazyweb_search].freeze
    IMPLEMENTATION_MCP_PROJECT_FILES_TOOLS = %w[project_file_metadata project_file_list project_file_excerpt project_file_search].freeze
    IMPLEMENTATION_MCP_PROJECT_FILE_EXCERPT_MAX_BYTES = 32 * 1024
    IMPLEMENTATION_MCP_PROJECT_FILE_SEARCH_MAX_FILES = 200
    IMPLEMENTATION_MCP_MISSING_DRIVER_REQUIRED_FIELDS = %w[
      mcp_server
      tool_names
      allowed_args_schema
      credential_source
      delegated_identity
      network_destinations
      output_redaction
      per_call_audit
      side_effect_broker_path
      result_schema
      rollback_or_replay_policy
    ].freeze

    def mcp_broker(action: "call", server: nil, tool: nil, query: nil, limit: 1, endpoint: nil, approved: false, dry_run: false, force: false)
      assert_initialized!
      normalized_action = action.to_s.strip.empty? ? "call" : action.to_s.strip
      raise UserError.new("mcp-broker action must be call", 1) unless normalized_action == "call"

      request = implementation_mcp_broker_request(server: server, tool: tool, query: query, limit: limit, endpoint: endpoint, approved: approved)
      run_id = "mcp-broker-#{Time.now.utc.strftime("%Y%m%dT%H%M%S%6NZ")}-#{SecureRandom.hex(4)}"
      run_dir = File.join(aiweb_dir, "runs", run_id)
      broker_path = File.join(run_dir, "side-effect-broker.jsonl")
      metadata_path = File.join(run_dir, "mcp-broker.json")
      blockers = implementation_mcp_broker_blockers(request)
      blocked = !blockers.empty?
      broker = side_effect_broker_plan(
        broker: IMPLEMENTATION_MCP_BROKER_ID,
        scope: implementation_mcp_broker_scope(request),
        target: "#{request.fetch("server")}.#{request.fetch("tool")}",
        command: implementation_mcp_broker_command(request),
        broker_path: broker_path,
        dry_run: dry_run,
        approved: approved == true,
        blocked: blocked,
        blockers: blockers,
        risk_class: "delegated_identity_and_connector_data_access",
        policy_extra: implementation_mcp_broker_policy(request)
      )
      record = implementation_mcp_broker_record(
        run_id: run_id,
        status: dry_run ? "planned" : (blocked ? "blocked" : "ready"),
        request: request,
        broker_path: broker_path,
        metadata_path: metadata_path,
        broker: broker,
        blockers: blockers,
        result: nil
      )
      return implementation_mcp_broker_payload(record, changed_files: [], dry_run: true) if dry_run

      events = []
      mutation(dry_run: false) do
        append_side_effect_broker_event(broker_path, events, "tool.requested", implementation_mcp_broker_event_context(request, approved: approved))
        if blocked
          append_side_effect_broker_event(broker_path, events, "policy.decision", implementation_mcp_broker_event_context(request, approved: approved).merge("decision" => "deny", "blocking_issues" => blockers))
          append_side_effect_broker_event(broker_path, events, "tool.blocked", implementation_mcp_broker_event_context(request, approved: approved).merge("status" => "blocked", "blocking_issues" => blockers))
        else
          append_side_effect_broker_event(broker_path, events, "policy.decision", implementation_mcp_broker_event_context(request, approved: approved).merge("decision" => "allow"))
          append_side_effect_broker_event(broker_path, events, "tool.started", implementation_mcp_broker_event_context(request, approved: approved).merge("status" => "running"))
          begin
            result = implementation_mcp_broker_call_driver(request)
            record["status"] = "passed"
            record["result"] = implementation_mcp_broker_redact_value(result)
            append_side_effect_broker_event(broker_path, events, "tool.finished", implementation_mcp_broker_event_context(request, approved: approved).merge("status" => "passed"))
          rescue StandardError => e
            record["status"] = "failed"
            record["blocking_issues"] = ["implementation MCP broker call failed: #{LazywebClient.redact("#{e.class}: #{e.message}")}"]
            append_side_effect_broker_event(broker_path, events, "tool.failed", implementation_mcp_broker_event_context(request, approved: approved).merge("status" => "failed", "error_class" => e.class.name, "error" => LazywebClient.redact(e.message)))
          end
        end
        record["side_effect_broker"] = implementation_mcp_broker_summary(broker, events)
        write_json(metadata_path, record, false)
      end
      implementation_mcp_broker_payload(record, changed_files: compact_changes([relative(metadata_path), relative(broker_path)]), dry_run: false)
    end

    private

    def implementation_mcp_broker_request(server:, tool:, query:, limit:, endpoint:, approved:)
      normalized_server = server.to_s.strip.empty? ? IMPLEMENTATION_MCP_ALLOWED_SERVER : server.to_s.strip
      normalized_tool = tool.to_s.strip.empty? ? (normalized_server == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER ? "project_file_metadata" : "lazyweb_health") : tool.to_s.strip
      normalized_limit = Integer(limit)
      raise UserError.new("mcp-broker --limit must be between 1 and 20", 1) unless normalized_limit.between?(1, 20)
      endpoint_raw = endpoint.to_s.strip.empty? ? LazywebClient::DEFAULT_ENDPOINT : endpoint.to_s.strip
      endpoint_host = normalized_server == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER ? nil : URI.parse(endpoint_raw).host.to_s

      {
        "schema_version" => 1,
        "server" => normalized_server,
        "tool" => normalized_tool,
        "arguments" => implementation_mcp_broker_arguments(normalized_tool, query: query, limit: normalized_limit),
        "endpoint" => normalized_server == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER ? "local-project-filesystem" : LazywebClient.redact(endpoint_raw),
        "endpoint_raw" => endpoint_raw,
        "approved" => approved == true,
        "credential_source" => implementation_mcp_broker_credential_source(normalized_server, normalized_tool),
        "delegated_identity" => "project-local implementation worker approval",
        "network_destinations" => endpoint_host ? [endpoint_host] : [],
        "output_redaction" => implementation_mcp_broker_output_redaction(normalized_server, normalized_tool),
        "per_call_audit" => true
      }
    rescue ArgumentError, TypeError
      raise UserError.new("mcp-broker --limit must be an integer between 1 and 20", 1)
    rescue URI::InvalidURIError => e
      raise UserError.new("mcp-broker --endpoint is invalid: #{e.message}", 1)
    end

    def implementation_mcp_broker_arguments(tool, query:, limit:)
      return {} if tool == "lazyweb_health"
      return { "path" => query.to_s.strip } if tool == "project_file_metadata"
      return { "path" => query.to_s.strip, "limit" => limit } if tool == "project_file_list"
      return { "path" => query.to_s.strip, "max_lines" => limit } if tool == "project_file_excerpt"
      return implementation_mcp_project_file_search_arguments(query, limit) if tool == "project_file_search"

      {
        "query" => query.to_s.strip,
        "limit" => limit
      }
    end

    def implementation_mcp_project_file_search_arguments(query, limit)
      raw = query.to_s.strip
      if raw.include?("::")
        path, pattern = raw.split("::", 2)
        { "path" => path.to_s.strip, "pattern" => pattern.to_s, "limit" => limit }
      else
        { "path" => ".", "pattern" => raw, "limit" => limit }
      end
    end

    def implementation_mcp_broker_blockers(request)
      blockers = []
      allowed_tools = implementation_mcp_broker_allowed_drivers.fetch(request.fetch("server"), [])
      blockers << "implementation MCP broker only supports servers #{implementation_mcp_broker_allowed_drivers.keys.join(", ")}" unless implementation_mcp_broker_allowed_drivers.key?(request.fetch("server"))
      blockers << "implementation MCP broker tool must be one of #{allowed_tools.join(", ")}" unless allowed_tools.include?(request.fetch("tool"))
      blockers << "implementation MCP connector #{request.fetch("server")}.#{request.fetch("tool")} is missing a broker driver and remains fail-closed" unless implementation_mcp_broker_known_driver?(request)
      blockers << "implementation MCP broker lazyweb_search requires --query" if request.fetch("tool") == "lazyweb_search" && request.dig("arguments", "query").to_s.empty?
      blockers << "implementation MCP broker project_file_metadata requires --query RELATIVE_SAFE_FILE_PATH" if request.fetch("tool") == "project_file_metadata" && request.dig("arguments", "path").to_s.empty?
      blockers << "implementation MCP broker project_file_list requires --query RELATIVE_SAFE_PATH" if request.fetch("tool") == "project_file_list" && request.dig("arguments", "path").to_s.empty?
      blockers << "implementation MCP broker project_file_excerpt requires --query RELATIVE_SAFE_FILE_PATH" if request.fetch("tool") == "project_file_excerpt" && request.dig("arguments", "path").to_s.empty?
      blockers << "implementation MCP broker project_file_search requires --query [RELATIVE_SAFE_PATH::]LITERAL_TEXT" if request.fetch("tool") == "project_file_search" && request.dig("arguments", "pattern").to_s.empty?
      blockers.concat(implementation_mcp_project_file_path_blockers(request.dig("arguments", "path"))) if request.fetch("server") == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER && request.fetch("tool") == "project_file_metadata"
      blockers.concat(implementation_mcp_project_file_list_path_blockers(request.dig("arguments", "path"))) if request.fetch("server") == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER && request.fetch("tool") == "project_file_list"
      if request.fetch("server") == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER && request.fetch("tool") == "project_file_excerpt"
        excerpt_path_blockers = implementation_mcp_project_file_excerpt_path_blockers(request.dig("arguments", "path"))
        blockers.concat(excerpt_path_blockers)
        blockers.concat(implementation_mcp_project_file_excerpt_content_blockers(request.dig("arguments", "path"))) if excerpt_path_blockers.empty?
      end
      if request.fetch("server") == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER && request.fetch("tool") == "project_file_search"
        blockers.concat(implementation_mcp_project_file_search_blockers(request.dig("arguments", "path"), request.dig("arguments", "pattern")))
      end
      blockers << "implementation MCP broker call requires --approved" unless request.fetch("approved") == true
      blockers << "Lazyweb token is not configured" if request.fetch("server") == IMPLEMENTATION_MCP_ALLOWED_SERVER && request.fetch("approved") == true && !LazywebClient.new(endpoint: request.fetch("endpoint_raw"), token_sources: LazywebClient::TOKEN_SOURCES, timeout_seconds: 5).configured?
      blockers.uniq
    rescue StandardError => e
      ["implementation MCP broker configuration failed: #{LazywebClient.redact("#{e.class}: #{e.message}")}"]
    end

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

    def implementation_mcp_broker_command(request)
      ["mcp", request.fetch("server"), request.fetch("tool"), JSON.generate(implementation_mcp_broker_redact_value(request.fetch("arguments")))]
    end

    def implementation_mcp_broker_known_driver?(request)
      implementation_mcp_broker_allowed_drivers.fetch(request.fetch("server"), []).include?(request.fetch("tool"))
    end

    def implementation_mcp_broker_scope(request)
      return IMPLEMENTATION_MCP_DENIED_SCOPE unless implementation_mcp_broker_known_driver?(request)
      return IMPLEMENTATION_MCP_PROJECT_FILES_SCOPE if request.fetch("server") == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER

      IMPLEMENTATION_MCP_BROKER_SCOPE
    end

    def implementation_mcp_broker_allowed_drivers
      {
        IMPLEMENTATION_MCP_ALLOWED_SERVER => IMPLEMENTATION_MCP_ALLOWED_TOOLS,
        IMPLEMENTATION_MCP_PROJECT_FILES_SERVER => IMPLEMENTATION_MCP_PROJECT_FILES_TOOLS
      }
    end

    def implementation_mcp_broker_connector_policy(request)
      known_driver = implementation_mcp_broker_known_driver?(request)
      driver_status = if known_driver && request.fetch("server") == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER && request.fetch("tool") == "project_file_search"
                        "implemented_for_approved_project_file_search"
                      elsif known_driver && request.fetch("server") == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER && request.fetch("tool") == "project_file_excerpt"
                        "implemented_for_approved_project_file_excerpt"
                      elsif known_driver && request.fetch("server") == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER && request.fetch("tool") == "project_file_list"
                        "implemented_for_approved_project_file_list"
                      elsif known_driver && request.fetch("server") == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER
                        "implemented_for_approved_project_file_metadata"
                      elsif known_driver
                        "implemented_for_approved_lazyweb_health_search"
                      else
                        "missing_broker_driver_fail_closed"
                      end
      {
        "policy" => "aiweb.implementation_mcp_broker.connector_policy.v1",
        "server" => request.fetch("server"),
        "tool" => request.fetch("tool"),
        "known_driver" => known_driver,
        "driver_status" => driver_status,
        "fail_closed" => !known_driver,
        "deny_by_default_for_unknown_connectors" => true,
        "missing_driver_required_fields" => known_driver ? [] : IMPLEMENTATION_MCP_MISSING_DRIVER_REQUIRED_FIELDS,
        "implemented_driver" => known_driver ? {
          "server" => request.fetch("server"),
          "tools" => implementation_mcp_broker_allowed_drivers.fetch(request.fetch("server")),
          "side_effect_broker" => IMPLEMENTATION_MCP_BROKER_ID,
          "scope" => implementation_mcp_broker_scope(request)
        } : nil
      }.compact
    end

    def implementation_mcp_broker_policy(request)
      {
        "allowed_server" => request.fetch("server"),
        "allowed_servers" => implementation_mcp_broker_allowed_drivers.keys,
        "allowed_tools" => implementation_mcp_broker_allowed_drivers.fetch(request.fetch("server"), []),
        "allowed_args_schema" => {
          "lazyweb_health" => {},
          "lazyweb_search" => { "required" => %w[query limit], "limit" => "1..20" },
          "project_file_metadata" => { "required" => %w[path], "path_policy" => "relative regular file; no .env/.git/node_modules/.ai-web/runs, no traversal, no symlink, metadata only" },
          "project_file_list" => { "required" => %w[path limit], "path_policy" => "relative regular file or directory; no .env/.git/node_modules/.ai-web/runs, no traversal, no symlink, metadata only", "limit" => "1..20 entries" },
          "project_file_excerpt" => { "required" => %w[path max_lines], "path_policy" => "relative regular text file; no .env/.git/node_modules/.ai-web/runs/secret-looking paths, no traversal, no symlink", "limit" => "1..20 lines", "max_bytes" => IMPLEMENTATION_MCP_PROJECT_FILE_EXCERPT_MAX_BYTES, "content_policy" => "blocked if binary, invalid UTF-8, oversized, or secret-like content" },
          "project_file_search" => { "required" => %w[path pattern limit], "query_format" => "[RELATIVE_SAFE_PATH::]LITERAL_TEXT", "path_policy" => "relative regular text file or directory; no .env/.git/node_modules/.ai-web/runs/secret-looking paths, no traversal, no symlink", "limit" => "1..20 matches", "file_scan_limit" => IMPLEMENTATION_MCP_PROJECT_FILE_SEARCH_MAX_FILES, "content_policy" => "literal UTF-8 search; skips files that are binary, invalid UTF-8, oversized, or secret-like" }
        },
        "credential_source" => request.fetch("credential_source"),
        "delegated_identity" => request.fetch("delegated_identity"),
        "network_destinations" => request.fetch("network_destinations"),
        "output_redaction" => request.fetch("output_redaction"),
        "per_call_audit" => true,
        "connector_policy" => implementation_mcp_broker_connector_policy(request),
        "connector_driver_status" => implementation_mcp_broker_connector_policy(request).fetch("driver_status"),
        "missing_driver_required_fields" => implementation_mcp_broker_connector_policy(request).fetch("missing_driver_required_fields"),
        "deny_by_default_for_unknown_connectors" => true
      }
    end

    def implementation_mcp_project_file_path_blockers(value)
      normalized = implementation_mcp_project_file_normalized_path(value)
      blockers = []
      parts = normalized.split("/")
      blockers << "project_file_metadata path must be relative" if normalized.empty? || Pathname.new(normalized).absolute?
      blockers << "project_file_metadata path must not traverse outside project" if parts.include?("..")
      blockers << "project_file_metadata path must not reference .env/.env.*" if parts.any? { |part| part == ".env" || part.start_with?(".env.") }
      blockers << "project_file_metadata path must not reference .git, node_modules, or generated run artifacts" if parts.any? { |part| %w[.git node_modules].include?(part) } || implementation_mcp_project_file_runs_path?(normalized)
      path = File.expand_path(normalized, root)
      root_path = File.expand_path(root)
      blockers << "project_file_metadata path escapes project root" unless path == root_path || path.start_with?(root_path + File::SEPARATOR)
      if blockers.empty?
        blockers << "project_file_metadata requires an existing regular file" unless File.file?(path)
        blockers << "project_file_metadata refuses symlink paths" if File.symlink?(path)
      end
      blockers
    end

    def implementation_mcp_project_file_list_path_blockers(value)
      normalized = implementation_mcp_project_file_normalized_path(value)
      blockers = []
      parts = normalized.split("/")
      blockers << "project_file_list path must be relative" if normalized.empty? || Pathname.new(normalized).absolute?
      blockers << "project_file_list path must not traverse outside project" if parts.include?("..")
      blockers << "project_file_list path must not reference .env/.env.*" if parts.any? { |part| part == ".env" || part.start_with?(".env.") }
      blockers << "project_file_list path must not reference .git, node_modules, or generated run artifacts" if parts.any? { |part| %w[.git node_modules].include?(part) } || implementation_mcp_project_file_runs_path?(normalized)
      blockers << "project_file_list path must not be secret-looking" if secret_looking_path?(normalized)
      path = File.expand_path(normalized, root)
      root_path = File.expand_path(root)
      blockers << "project_file_list path escapes project root" unless path == root_path || path.start_with?(root_path + File::SEPARATOR)
      if blockers.empty?
        blockers << "project_file_list requires an existing regular file or directory" unless File.file?(path) || File.directory?(path)
        blockers << "project_file_list refuses symlink paths" if File.symlink?(path)
      end
      blockers
    end

    def implementation_mcp_project_file_excerpt_path_blockers(value)
      normalized = implementation_mcp_project_file_normalized_path(value)
      blockers = []
      parts = normalized.split("/")
      blockers << "project_file_excerpt path must be relative" if normalized.empty? || Pathname.new(normalized).absolute?
      blockers << "project_file_excerpt path must not traverse outside project" if parts.include?("..")
      blockers << "project_file_excerpt path must not reference .env/.env.*" if parts.any? { |part| part == ".env" || part.start_with?(".env.") }
      blockers << "project_file_excerpt path must not reference .git, node_modules, or generated run artifacts" if parts.any? { |part| %w[.git node_modules].include?(part) } || implementation_mcp_project_file_runs_path?(normalized)
      blockers << "project_file_excerpt path must not be secret-looking" if secret_looking_path?(normalized)
      path = File.expand_path(normalized, root)
      root_path = File.expand_path(root)
      blockers << "project_file_excerpt path escapes project root" unless path == root_path || path.start_with?(root_path + File::SEPARATOR)
      if blockers.empty?
        blockers << "project_file_excerpt requires an existing regular file" unless File.file?(path)
        blockers << "project_file_excerpt refuses symlink paths" if File.symlink?(path)
      end
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
      normalized = implementation_mcp_project_file_normalized_path(path_value)
      pattern = pattern_value.to_s
      blockers = []
      parts = normalized.split("/")
      blockers << "project_file_search path must be relative" if normalized.empty? || Pathname.new(normalized).absolute?
      blockers << "project_file_search path must not traverse outside project" if parts.include?("..")
      blockers << "project_file_search path must not reference .env/.env.*" if parts.any? { |part| part == ".env" || part.start_with?(".env.") }
      blockers << "project_file_search path must not reference .git, node_modules, or generated run artifacts" if parts.any? { |part| %w[.git node_modules].include?(part) } || implementation_mcp_project_file_runs_path?(normalized)
      blockers << "project_file_search path must not be secret-looking" if secret_looking_path?(normalized)
      blockers << "project_file_search pattern is required" if pattern.empty?
      blockers << "project_file_search pattern must be at most 80 characters" if pattern.length > 80
      blockers << "project_file_search pattern must not contain NUL bytes" if pattern.include?("\x00")
      blockers << "project_file_search pattern must not be secret-like" if redact_side_effect_process_output(pattern) != pattern
      full_path = File.expand_path(normalized, root)
      root_path = File.expand_path(root)
      blockers << "project_file_search path escapes project root" unless full_path == root_path || full_path.start_with?(root_path + File::SEPARATOR)
      if blockers.empty?
        blockers << "project_file_search requires an existing regular file or directory" unless File.file?(full_path) || File.directory?(full_path)
        blockers << "project_file_search refuses symlink paths" if File.symlink?(full_path)
      end
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
      normalized = implementation_mcp_project_file_normalized_path(relative_path)
      parts = normalized.split("/")
      return true if normalized.empty? || Pathname.new(normalized).absolute?
      return true if parts.include?("..")
      return true if parts.any? { |part| part == ".env" || part.start_with?(".env.") }
      return true if parts.any? { |part| %w[.git node_modules].include?(part) } || implementation_mcp_project_file_runs_path?(normalized)
      return true if secret_looking_path?(normalized)

      path = File.expand_path(normalized, root)
      root_path = File.expand_path(root)
      return true unless path == root_path || path.start_with?(root_path + File::SEPARATOR)

      File.symlink?(path)
    end

    def implementation_mcp_project_file_runs_path?(normalized)
      normalized == ".ai-web/runs" || normalized.start_with?(".ai-web/runs/")
    end

    def implementation_mcp_project_file_normalized_path(value)
      value.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "").strip
    end

    def implementation_mcp_broker_event_context(request, approved:)
      side_effect_broker_context(
        broker: IMPLEMENTATION_MCP_BROKER_ID,
        scope: implementation_mcp_broker_scope(request),
        target: "#{request.fetch("server")}.#{request.fetch("tool")}",
        command: implementation_mcp_broker_command(request),
        risk_class: "delegated_identity_and_connector_data_access",
        approved: approved == true,
        extra: implementation_mcp_broker_policy(request).merge(
          "server" => request.fetch("server"),
          "mcp_tool" => request.fetch("tool"),
          "arguments" => implementation_mcp_broker_redact_value(request.fetch("arguments")),
          "endpoint" => request.fetch("endpoint")
        )
      )
    end

    def implementation_mcp_broker_record(run_id:, status:, request:, broker_path:, metadata_path:, broker:, blockers:, result:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "broker_driver" => IMPLEMENTATION_MCP_BROKER_ID,
        "scope" => implementation_mcp_broker_scope(request),
        "server" => request.fetch("server"),
        "tool" => request.fetch("tool"),
        "arguments" => implementation_mcp_broker_redact_value(request.fetch("arguments")),
        "endpoint" => request.fetch("endpoint"),
        "credential_source" => request.fetch("credential_source"),
        "delegated_identity" => request.fetch("delegated_identity"),
        "network_destinations" => request.fetch("network_destinations"),
        "output_redaction" => request.fetch("output_redaction"),
        "per_call_audit" => true,
        "side_effect_broker_path" => relative(broker_path),
        "metadata_path" => relative(metadata_path),
        "side_effect_broker" => broker,
        "connector_policy" => implementation_mcp_broker_connector_policy(request),
        "blocking_issues" => blockers,
        "result" => result,
        "limitations" => [
          "approved Lazyweb health/search and project_files metadata/list/excerpt/search implementation-worker MCP calls only",
          "project_file_list returns bounded metadata only and never file contents",
          "project_file_excerpt returns bounded safe UTF-8 excerpts only after path and secret-content gates pass",
          "project_file_search returns bounded literal UTF-8 matches only after path and secret-content gates pass",
          "not a generic MCP connector runner",
          "not exposed to default engine-run sandbox without explicit approval"
        ]
      }
    end

    def implementation_mcp_broker_summary(plan, events)
      plan.merge(
        "status" => events.any? { |event| event["event"] == "tool.failed" } ? "failed" : (events.any? { |event| event["event"] == "tool.blocked" } ? "blocked" : "passed"),
        "events_recorded" => !events.empty?,
        "event_count" => events.length,
        "policy" => plan.fetch("policy").merge("decision" => events.any? { |event| event["event"] == "policy.decision" && event["decision"] == "allow" } ? "allow" : "deny")
      )
    end

    def implementation_mcp_broker_payload(record, changed_files:, dry_run:)
      {
        "schema_version" => 1,
        "current_phase" => load_state.dig("phase", "current"),
        "action_taken" => dry_run ? "planned implementation MCP broker call" : "recorded implementation MCP broker call",
        "changed_files" => changed_files,
        "blocking_issues" => Array(record["blocking_issues"]),
        "mcp_broker" => record,
        "next_action" => implementation_mcp_broker_next_action(record)
      }
    end

    def implementation_mcp_broker_next_action(record)
      case record["status"]
      when "planned" then "rerun with --approved to execute the brokered MCP call"
      when "blocked" then "inspect #{record["side_effect_broker_path"]} and approval/policy blockers"
      when "passed" then "use #{record["metadata_path"]} as brokered MCP call evidence"
      else "inspect #{record["metadata_path"]}"
      end
    end

    def implementation_mcp_broker_redact_value(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), memo| memo[key.to_s] = implementation_mcp_broker_redact_value(item) }
      when Array
        value.map { |item| implementation_mcp_broker_redact_value(item) }
      when String
        LazywebClient.redact(redact_side_effect_process_output(value))
      else
        value
      end
    end

    def implementation_mcp_broker_credential_source(server, tool)
      return "none_local_safe_file_search" if server == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER && tool == "project_file_search"
      return "none_local_safe_file_excerpt" if server == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER && tool == "project_file_excerpt"
      return "none_local_metadata_only" if server == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER

      "LAZYWEB_MCP_TOKEN or configured Lazyweb token file"
    end

    def implementation_mcp_broker_output_redaction(server, tool)
      return "bounded_safe_search_secret_scan_plus_side_effect_broker_redaction" if server == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER && tool == "project_file_search"
      return "bounded_safe_excerpt_secret_scan_plus_side_effect_broker_redaction" if server == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER && tool == "project_file_excerpt"
      return "metadata_only_no_file_content_plus_side_effect_broker_redaction" if server == IMPLEMENTATION_MCP_PROJECT_FILES_SERVER

      "LazywebClient.redact plus side-effect broker redaction"
    end
  end
end
