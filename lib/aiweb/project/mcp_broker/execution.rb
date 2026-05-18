# frozen_string_literal: true

module Aiweb
  module ProjectMcpBroker
    private

    def implementation_mcp_broker_execute_record(record:, request:, broker:, broker_path:, metadata_path:, approved:, blocked:, blockers:)
      events = []
      mutation(dry_run: false) do
        event_context = implementation_mcp_broker_event_context(request, approved: approved)
        append_side_effect_broker_event(broker_path, events, "tool.requested", event_context)
        if blocked
          append_side_effect_broker_event(broker_path, events, "policy.decision", event_context.merge("decision" => "deny", "blocking_issues" => blockers))
          append_side_effect_broker_event(broker_path, events, "tool.blocked", event_context.merge("status" => "blocked", "blocking_issues" => blockers))
        else
          implementation_mcp_broker_execute_driver(record, request, broker_path, events, event_context)
        end
        record["side_effect_broker"] = implementation_mcp_broker_summary(broker, events)
        write_json(metadata_path, record, false)
      end
    end

    def implementation_mcp_broker_execute_driver(record, request, broker_path, events, event_context)
      append_side_effect_broker_event(broker_path, events, "policy.decision", event_context.merge("decision" => "allow"))
      append_side_effect_broker_event(broker_path, events, "tool.started", event_context.merge("status" => "running"))
      result = implementation_mcp_broker_call_driver(request)
      record["status"] = "passed"
      record["result"] = implementation_mcp_broker_redact_value(result)
      append_side_effect_broker_event(broker_path, events, "tool.finished", event_context.merge("status" => "passed"))
    rescue StandardError => e
      record["status"] = "failed"
      record["blocking_issues"] = ["implementation MCP broker call failed: #{LazywebClient.redact("#{e.class}: #{e.message}")}"]
      append_side_effect_broker_event(broker_path, events, "tool.failed", event_context.merge("status" => "failed", "error_class" => e.class.name, "error" => LazywebClient.redact(e.message)))
    end
  end
end
