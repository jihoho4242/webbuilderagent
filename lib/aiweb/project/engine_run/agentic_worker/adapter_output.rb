# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    def engine_run_worker_adapter_output_violations(agent_result, workspace_dir, expected_adapter: nil)
      return [] unless agent_result.is_a?(Hash)

      issues = Array(agent_result["blocking_issues"]).map(&:to_s)
      if %w[openhands langgraph openai_agents_sdk].include?(expected_adapter.to_s)
        required = %w[schema_version adapter status structured_events artifact_refs changed_file_manifest proposed_tool_requests risk_notes blocking_issues]
        missing = required.reject { |field| agent_result.key?(field) }
        issues << "worker adapter contract violation: #{expected_adapter} result missing required field(s): #{missing.join(", ")}" unless missing.empty?
        issues << "worker adapter contract violation: #{expected_adapter} result adapter must be #{expected_adapter}" unless agent_result["adapter"].to_s == expected_adapter.to_s
        %w[structured_events artifact_refs changed_file_manifest proposed_tool_requests risk_notes blocking_issues].each do |field|
          issues << "worker adapter contract violation: #{expected_adapter} result #{field} must be an array" if agent_result.key?(field) && !agent_result[field].is_a?(Array)
        end
      end
      if agent_result["status"].to_s == "reported" && agent_result.key?("raw")
        issues << "worker adapter contract violation: output was not structured JSON or was redacted before parsing"
      end
      strings = engine_run_collect_json_strings(agent_result)
      strings.each do |value|
        next if value.strip.empty?

        if engine_run_worker_adapter_host_absolute_path?(value, workspace_dir)
          issues << "worker adapter contract violation: output contained host absolute path"
        end
        if value.match?(ENGINE_RUN_SECRET_VALUE_PATTERN) || value.match?(/\b(?:OPENAI_API_KEY|ANTHROPIC_API_KEY|AWS_SECRET_ACCESS_KEY|SECRET|TOKEN|PASSWORD)=/i)
          issues << "worker adapter contract violation: output contained raw secret or environment value"
        end
      end
      if agent_result.key?("raw_env") || agent_result.key?("environment") || agent_result.key?("env")
        issues << "worker adapter contract violation: output included raw environment payload"
      end
      issues.map(&:to_s).reject(&:empty?).uniq
    end

    def engine_run_collect_json_strings(value)
      case value
      when Hash
        value.flat_map { |key, child| [key.to_s, *engine_run_collect_json_strings(child)] }
      when Array
        value.flat_map { |child| engine_run_collect_json_strings(child) }
      when String
        [value]
      else
        []
      end
    end

    def engine_run_worker_adapter_host_absolute_path?(value, workspace_dir)
      text = value.to_s.strip
      return false if text.empty?
      return false if text.start_with?("/workspace", "file:///workspace")

      if text.match?(%r{\A[A-Za-z]:[\\/]})
        workspace = File.expand_path(workspace_dir).tr("\\", "/").downcase
        candidate = text.tr("\\", "/").downcase
        return !candidate.start_with?(workspace)
      end
      return true if text.start_with?("/") && !text.start_with?("/workspace/")
      return true if text.start_with?("file:///") && !text.start_with?("file:///workspace")

      false
    end
  end
end
