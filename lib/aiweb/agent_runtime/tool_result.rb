# frozen_string_literal: true

module Aiweb
  module AgentRuntime
    module ToolResult
      module_function

      def planned(tool, action)
        { "tool" => tool, "status" => "planned", "dry_run" => true, "blocking_issues" => [], "action" => action }
      end

      def pending_approval(tool, action, mode)
        {
          "tool" => tool,
          "status" => "pending_approval",
          "dry_run" => false,
          "blocking_issues" => [],
          "pending_approval" => true,
          "reason" => "#{tool} is an approved local runtime action; mode #{mode.inspect} requires --approved before execution.",
          "action" => action
        }
      end
    end
  end
end
