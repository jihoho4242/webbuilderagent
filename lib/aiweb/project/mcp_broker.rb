# frozen_string_literal: true

require "digest"
require "pathname"
require "time"

require_relative "../constitution/loader"
require_relative "../tools/decision_packet"
require_relative "mcp_broker_drivers"
require_relative "mcp_broker_policy"
require_relative "mcp_broker/execution"

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

    include Drivers
    include Policy

    def mcp_broker(action: "call", server: nil, tool: nil, query: nil, limit: 1, endpoint: nil, approved: false, approval_hash: nil, dry_run: false, force: false)
      assert_initialized!
      normalized_action = action.to_s.strip.empty? ? "call" : action.to_s.strip
      raise UserError.new("mcp-broker action must be call", 1) unless normalized_action == "call"

      request = implementation_mcp_broker_request(server: server, tool: tool, query: query, limit: limit, endpoint: endpoint, approved: approved)
      capability = implementation_mcp_broker_approval_capability(request)
      expected_hash = implementation_mcp_broker_approval_hash(capability)
      run_id = "mcp-broker-#{Time.now.utc.strftime("%Y%m%dT%H%M%S%6NZ")}-#{SecureRandom.hex(4)}"
      run_dir = File.join(aiweb_dir, "runs", run_id)
      broker_path = File.join(run_dir, "side-effect-broker.jsonl")
      metadata_path = File.join(run_dir, "mcp-broker.json")
      blockers = implementation_mcp_broker_blockers(request)
      blockers.concat(implementation_mcp_broker_approval_blockers(approved: approved, supplied_hash: approval_hash, expected_hash: expected_hash)) unless dry_run
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
        capability: capability,
        approval_hash: expected_hash,
        supplied_approval_hash: approval_hash,
        broker: broker,
        blockers: blockers,
        result: nil
      )
      return implementation_mcp_broker_payload(record, changed_files: [], dry_run: true) if dry_run

      implementation_mcp_broker_execute_record(
        record: record,
        request: request,
        broker: broker,
        broker_path: broker_path,
        metadata_path: metadata_path,
        approved: approved,
        blocked: blocked,
        blockers: blockers
      )
      implementation_mcp_broker_payload(record, changed_files: compact_changes([relative(metadata_path), relative(broker_path)]), dry_run: false)
    end

    private

    def implementation_mcp_broker_record(run_id:, status:, request:, broker_path:, metadata_path:, capability:, approval_hash:, supplied_approval_hash:, broker:, blockers:, result:)
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
        "approval_hash" => approval_hash,
        "supplied_approval_hash" => supplied_approval_hash.to_s.strip.empty? ? nil : supplied_approval_hash.to_s,
        "approval_capability" => capability,
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
      when "planned" then "review approval_hash #{record["approval_hash"]}; brokered MCP execution is a lower-level ops action and not a friendly web-building runbook"
      when "blocked" then "inspect #{record["side_effect_broker_path"]} and approval/policy blockers"
      when "passed" then "use #{record["metadata_path"]} as brokered MCP call evidence"
      else "inspect #{record["metadata_path"]}"
      end
    end

    def implementation_mcp_broker_approval_capability(request)
      {
        "schema_version" => 1,
        "capability" => "aiweb.mcp_broker.call.v1",
        "constitution_hash" => Aiweb::Constitution::Loader.new.content_hash,
        "policy_kernel_version" => Aiweb::Tools::DecisionPacket::POLICY_KERNEL_VERSION,
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
        "connector_policy" => implementation_mcp_broker_connector_policy(request),
        "state_sha256" => File.file?(state_path) ? Digest::SHA256.file(state_path).hexdigest : nil,
        "execution_boundary" => {
          "requires_dry_run_review" => true,
          "requires_matching_approval_hash" => true,
          "writes_under" => %w[.ai-web/runs/mcp-broker-*],
          "forbidden" => %w[generic_mcp_runner unknown_connectors env_read raw_secret_output unbrokered_network unbrokered_file_content]
        }
      }
    end

    def implementation_mcp_broker_approval_hash(capability)
      Digest::SHA256.hexdigest(JSON.generate(capability))
    end

    def implementation_mcp_broker_approval_blockers(approved:, supplied_hash:, expected_hash:)
      return [] unless approved
      return ["mcp-broker approved execution requires --approval-hash HASH from the matching dry-run capability envelope"] if supplied_hash.to_s.strip.empty?
      return ["mcp-broker approval hash does not match the current broker capability envelope"] unless supplied_hash.to_s.strip == expected_hash

      []
    end

  end
end
