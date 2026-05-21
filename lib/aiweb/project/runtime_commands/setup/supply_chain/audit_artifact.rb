# frozen_string_literal: true

module Aiweb
  module ProjectRuntimeCommands
    private

    def setup_supply_chain_audit_artifact(package_manager:, command_result:)
      parsed = setup_parse_json(command_result["stdout"])
      severity_counts = setup_audit_severity_counts(parsed)
      critical_high = severity_counts.fetch("critical", 0).to_i + severity_counts.fetch("high", 0).to_i
      parsed_ok = !parsed.nil?
      recognized_audit_payload = setup_audit_payload?(parsed)
      command_failed = command_result["status"] != "passed"
      status =
        if !parsed_ok || (command_failed && !recognized_audit_payload)
          "failed"
        elsif critical_high.positive?
          "blocked"
        else
          "passed"
        end
      {
        "schema_version" => 1,
        "artifact_kind" => "package_audit",
        "status" => status,
        "recorded_at" => now,
        "package_manager" => package_manager,
        "command" => command_result["command"],
        "exit_code" => command_result["exit_code"],
        "severity_counts" => severity_counts,
        "active_findings" => setup_audit_blocking_findings("raw" => parsed),
        "audit_artifact_sha256" => Digest::SHA256.hexdigest(JSON.generate(parsed || {})),
        "vulnerability_gate" => critical_high.positive? ? "blocked" : (status == "failed" ? "failed" : "passed"),
        "blocked_severities" => %w[critical high],
        "stderr" => command_result["stderr"],
        "raw" => parsed
      }
    end

    def setup_audit_payload?(value)
      return false unless value.is_a?(Hash)

      value.dig("metadata", "vulnerabilities").is_a?(Hash) ||
        value["vulnerabilities"].is_a?(Hash) ||
        value["advisories"].is_a?(Hash) ||
        value.key?("auditReportVersion")
    end

    def setup_audit_severity_counts(value)
      counts = { "critical" => 0, "high" => 0, "moderate" => 0, "low" => 0 }
      setup_collect_audit_severities(value).each do |severity|
        next unless counts.key?(severity)

        counts[severity] += 1
      end
      metadata_counts = value.is_a?(Hash) ? value.dig("metadata", "vulnerabilities") : nil
      if metadata_counts.is_a?(Hash)
        counts.keys.each { |severity| counts[severity] = [counts[severity], metadata_counts[severity].to_i].max }
      end
      counts
    end

    def setup_collect_audit_severities(value, severities = [])
      case value
      when Array
        value.each { |item| setup_collect_audit_severities(item, severities) }
      when Hash
        severity = value["severity"].to_s.downcase
        severities << severity if %w[critical high moderate low].include?(severity)
        value.each_value { |child| setup_collect_audit_severities(child, severities) if child.is_a?(Hash) || child.is_a?(Array) }
      end
      severities
    end
  end
end
