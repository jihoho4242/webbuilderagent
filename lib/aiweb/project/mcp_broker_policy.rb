# frozen_string_literal: true

require "json"
require "uri"

module Aiweb
  module ProjectMcpBroker
    module Policy
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
end
