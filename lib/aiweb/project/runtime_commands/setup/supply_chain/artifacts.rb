# frozen_string_literal: true

module Aiweb
  module ProjectRuntimeCommands
    private

    def setup_supply_chain_not_executed_artifact(kind:, status:, package_manager:, command_argv:, reason:)
      {
        "schema_version" => 1,
        "artifact_kind" => kind,
        "status" => status,
        "recorded_at" => now,
        "package_manager" => package_manager,
        "command" => command_argv,
        "reason" => reason
      }
    end

    def setup_supply_chain_sbom_artifact(package_manager:, command_result:, dependency_snapshot:)
      parsed = setup_parse_json(command_result["stdout"])
      components = setup_supply_chain_components(parsed)
      status = command_result["status"] == "passed" && parsed ? "generated" : "failed"
      {
        "schema_version" => 1,
        "artifact_kind" => "sbom",
        "status" => status,
        "recorded_at" => now,
        "package_manager" => package_manager,
        "format" => "aiweb-pnpm-list-sbom-v1",
        "command" => command_result["command"],
        "exit_code" => command_result["exit_code"],
        "component_count" => components.length,
        "components" => components,
        "dependency_files" => dependency_snapshot,
        "stderr" => command_result["stderr"],
        "raw" => parsed
      }
    end

    def setup_supply_chain_cyclonedx_sbom_artifact(package_manager:, sbom_artifact:)
      unless sbom_artifact["status"] == "generated"
        return setup_supply_chain_not_executed_artifact(
          kind: "cyclonedx_sbom",
          status: "failed",
          package_manager: package_manager,
          command_argv: setup_supply_chain_sbom_argv(package_manager),
          reason: "source dependency inventory SBOM was not generated"
        )
      end

      {
        "$schema" => "https://cyclonedx.org/schema/bom-1.5.schema.json",
        "bomFormat" => "CycloneDX",
        "specVersion" => "1.5",
        "serialNumber" => "urn:uuid:#{SecureRandom.uuid}",
        "version" => 1,
        "metadata" => {
          "timestamp" => now,
          "tools" => {
            "components" => [
              {
                "type" => "application",
                "name" => "aiweb",
                "version" => defined?(Aiweb::VERSION) ? Aiweb::VERSION : "unknown"
              }
            ]
          }
        },
        "components" => setup_supply_chain_cyclonedx_components(sbom_artifact["components"])
      }
    end

    def setup_supply_chain_cyclonedx_status(cyclonedx_sbom_artifact)
      if cyclonedx_sbom_artifact["bomFormat"] == "CycloneDX" &&
          cyclonedx_sbom_artifact["specVersion"] == "1.5" &&
          cyclonedx_sbom_artifact["components"].is_a?(Array)
        "generated"
      else
        cyclonedx_sbom_artifact["status"].to_s
      end
    end

    def setup_supply_chain_cyclonedx_components(components)
      Array(components).filter_map do |component|
        name = component["name"].to_s
        version = component["version"].to_s
        next if name.empty? || version.empty?

        {
          "type" => "library",
          "name" => name,
          "version" => version
        }
      end
    end

    def setup_supply_chain_spdx_sbom_artifact(package_manager:, sbom_artifact:)
      unless sbom_artifact["status"] == "generated"
        return setup_supply_chain_not_executed_artifact(
          kind: "spdx_sbom",
          status: "failed",
          package_manager: package_manager,
          command_argv: setup_supply_chain_sbom_argv(package_manager),
          reason: "source dependency inventory SBOM was not generated"
        )
      end

      timestamp = now
      {
        "spdxVersion" => "SPDX-2.3",
        "dataLicense" => "CC0-1.0",
        "SPDXID" => "SPDXRef-DOCUMENT",
        "name" => "aiweb-setup-#{package_manager}-dependencies",
        "documentNamespace" => "https://aiweb.local/spdx/#{SecureRandom.uuid}",
        "creationInfo" => {
          "created" => timestamp,
          "creators" => ["Tool: aiweb-#{defined?(Aiweb::VERSION) ? Aiweb::VERSION : "unknown"}"]
        },
        "packages" => setup_supply_chain_spdx_packages(sbom_artifact["components"])
      }
    end

    def setup_supply_chain_spdx_status(spdx_sbom_artifact)
      if spdx_sbom_artifact["spdxVersion"] == "SPDX-2.3" &&
          spdx_sbom_artifact["dataLicense"] == "CC0-1.0" &&
          spdx_sbom_artifact["SPDXID"] == "SPDXRef-DOCUMENT" &&
          !spdx_sbom_artifact["name"].to_s.empty? &&
          spdx_sbom_artifact["documentNamespace"].to_s.start_with?("https://aiweb.local/spdx/") &&
          spdx_sbom_artifact.dig("creationInfo", "created").to_s.match?(/\A\d{4}-\d{2}-\d{2}T/) &&
          Array(spdx_sbom_artifact.dig("creationInfo", "creators")).any? { |creator| creator.to_s.start_with?("Tool: aiweb-") } &&
          spdx_sbom_artifact["packages"].is_a?(Array)
        "generated"
      else
        spdx_sbom_artifact["status"].to_s
      end
    end

    def setup_supply_chain_spdx_packages(components)
      Array(components).each_with_index.filter_map do |component, index|
        name = component["name"].to_s
        version = component["version"].to_s
        next if name.empty? || version.empty?

        {
          "name" => name,
          "SPDXID" => "SPDXRef-Package-#{index + 1}",
          "versionInfo" => version,
          "downloadLocation" => "NOASSERTION",
          "filesAnalyzed" => false,
          "licenseConcluded" => "NOASSERTION",
          "licenseDeclared" => "NOASSERTION",
          "copyrightText" => "NOASSERTION"
        }
      end
    end

    def setup_audit_exception_plan(audit_exception_path)
      path_info = setup_audit_exception_path_info(audit_exception_path)
      {
        "schema_version" => 1,
        "status" => path_info["status"] == "provided" ? "planned" : path_info["status"],
        "required" => false,
        "path" => path_info["path"],
        "policy" => "critical/high audit findings require an approved unexpired exception with rollback plan",
        "blocking_issues" => path_info["blocking_issues"]
      }.compact
    end

    def setup_audit_exception_evidence(audit_exception_path, audit_artifact:, package_manager:)
      active_severities = setup_audit_exception_active_severities(audit_artifact)
      path_info = setup_audit_exception_path_info(audit_exception_path)
      base = {
        "schema_version" => 1,
        "status" => path_info["status"],
        "required" => active_severities.any?,
        "path" => path_info["path"],
        "active_blocked_severities" => active_severities,
        "policy" => "critical/high audit findings require an approved unexpired exception with rollback plan",
        "blocking_issues" => Array(path_info["blocking_issues"])
      }
      if path_info["status"] == "not_requested"
        base["blocking_issues"] << "setup audit exception was not supplied for critical/high vulnerability findings" if active_severities.any?
        return base
      end
      return base.merge("status" => "invalid") unless base.fetch("blocking_issues").empty?

      unless File.file?(path_info.fetch("full_path"))
        base["blocking_issues"] << "setup audit exception file is missing: #{path_info["path"]}"
        return base.merge("status" => "invalid")
      end

      real_path = File.realpath(path_info.fetch("full_path"))
      real_relative = relative(real_path).tr("\\", "/")
      unless real_relative.start_with?(".ai-web/approvals/") && !unsafe_env_path?(real_relative) && !secret_looking_path?(real_relative)
        base["blocking_issues"] << "setup audit exception resolved path must stay inside .ai-web/approvals"
        return base.merge("status" => "invalid")
      end

      raw = File.read(real_path)
      if redact_side_effect_process_output(raw) != raw
        base["blocking_issues"] << "setup audit exception contains secret-looking content"
        return base.merge("status" => "invalid")
      end

      data = JSON.parse(raw)
      unless data.is_a?(Hash)
        base["blocking_issues"] << "setup audit exception root must be a JSON object"
        return base.merge("status" => "invalid")
      end

      blockers = setup_audit_exception_blockers(data, active_severities, package_manager, audit_artifact)
      evidence = base.merge(
        "status" => blockers.empty? ? "accepted" : "invalid",
        "approved" => data["approved"] == true,
        "accepted_risk" => data["accepted_risk"] == true,
        "approval_kind" => data["approval_kind"],
        "approved_by" => data["approved_by"].to_s,
        "approved_at" => data["approved_at"].to_s,
        "expires_at" => data["expires_at"].to_s,
        "reason" => data["reason"].to_s,
        "accepted_severities" => setup_audit_exception_declared_severities(data),
        "active_findings" => setup_audit_blocking_findings(audit_artifact),
        "audit_artifact_sha256" => setup_audit_artifact_sha256(audit_artifact),
        "accepted_findings" => setup_audit_exception_declared_findings(data),
        "rollback_plan" => setup_audit_exception_rollback_evidence(data["rollback_plan"])
      )
      evidence["blocking_issues"] = blockers
      evidence
    rescue JSON::ParserError => e
      base.merge("status" => "invalid", "blocking_issues" => base.fetch("blocking_issues") + ["setup audit exception JSON is invalid: #{e.message}"])
    rescue SystemCallError => e
      base.merge("status" => "invalid", "blocking_issues" => base.fetch("blocking_issues") + ["setup audit exception could not be read: #{e.message}"])
    end

    def setup_audit_exception_path_info(audit_exception_path)
      raw_path = audit_exception_path.to_s.strip
      return { "status" => "not_requested", "path" => nil, "blocking_issues" => [] } if raw_path.empty?

      full_path = File.expand_path(raw_path, root)
      root_path = File.expand_path(root)
      relative_path = full_path.start_with?(root_path + File::SEPARATOR) ? relative(full_path).tr("\\", "/") : raw_path.tr("\\", "/")
      blockers = []
      blockers << "setup audit exception path must stay inside the project" unless full_path.start_with?(root_path + File::SEPARATOR)
      blockers << "setup audit exception path must be under .ai-web/approvals" unless relative_path.start_with?(".ai-web/approvals/")
      blockers << "setup audit exception path must not target .env files" if unsafe_env_path?(relative_path)
      blockers << "setup audit exception path must not be secret-looking" if secret_looking_path?(relative_path)
      {
        "status" => blockers.empty? ? "provided" : "invalid",
        "path" => relative_path,
        "full_path" => full_path,
        "blocking_issues" => blockers
      }
    end

    def setup_audit_exception_active_severities(audit_artifact)
      counts = audit_artifact["severity_counts"].is_a?(Hash) ? audit_artifact["severity_counts"] : {}
      %w[critical high].select { |severity| counts[severity].to_i.positive? }
    end

    def setup_audit_exception_blockers(data, active_severities, package_manager, audit_artifact)
      blockers = []
      blockers << "setup audit exception schema_version must be 1" unless data["schema_version"] == 1
      blockers << "setup audit exception approval_kind must be setup_audit_exception" unless data["approval_kind"] == "setup_audit_exception"
      blockers << "setup audit exception must set approved: true" unless data["approved"] == true
      blockers << "setup audit exception must set accepted_risk: true" unless data["accepted_risk"] == true
      blockers << "setup audit exception approved_by is required" if data["approved_by"].to_s.strip.empty?
      blockers << "setup audit exception reason is required" if data["reason"].to_s.strip.empty?
      blockers.concat(setup_audit_exception_time_blockers(data["approved_at"], data["expires_at"]))
      declared_severities = setup_audit_exception_declared_severities(data)
      missing_severities = active_severities - declared_severities
      blockers << "setup audit exception does not cover active blocked severities: #{missing_severities.join(", ")}" unless missing_severities.empty?
      applies_package_manager = data.dig("applies_to", "package_manager").to_s
      blockers << "setup audit exception package_manager does not match #{package_manager}" unless applies_package_manager == package_manager
      finding_blockers = setup_audit_exception_finding_blockers(data, audit_artifact)
      blockers.concat(finding_blockers)
      rollback_blockers = setup_audit_exception_rollback_blockers(data["rollback_plan"])
      blockers.concat(rollback_blockers)
      blockers
    end

    def setup_audit_exception_declared_severities(data)
      Array(data.dig("applies_to", "blocked_severities") || data["blocked_severities"]).map(&:to_s).select { |severity| %w[critical high].include?(severity) }.uniq
    end

    def setup_audit_exception_time_blockers(approved_at, expires_at)
      blockers = []
      approved_time = nil
      expires_time = nil
      begin
        approved_time = Time.iso8601(approved_at.to_s)
        blockers << "setup audit exception approved_at must not be in the future" if approved_time > Time.now.utc
      rescue ArgumentError
        blockers << "setup audit exception approved_at must be ISO-8601"
      end
      begin
        expires_time = Time.iso8601(expires_at.to_s)
        blockers << "setup audit exception expires_at must be in the future" unless expires_time > Time.now.utc
      rescue ArgumentError
        blockers << "setup audit exception expires_at must be ISO-8601"
      end
      if approved_time && expires_time
        blockers << "setup audit exception expires_at must be after approved_at" unless expires_time > approved_time
      end
      blockers
    end

    def setup_audit_exception_finding_blockers(data, audit_artifact)
      expected_hash = setup_audit_artifact_sha256(audit_artifact)
      declared_hash = data.dig("applies_to", "audit_artifact_sha256").to_s
      return [] if !declared_hash.empty? && declared_hash == expected_hash

      blockers = []
      blockers << "setup audit exception audit_artifact_sha256 does not match active audit artifact" unless declared_hash.empty?
      active_findings = setup_audit_blocking_findings(audit_artifact)
      if active_findings.empty?
        blockers << "setup audit exception must bind to active audit artifact hash when detailed findings are unavailable"
        return blockers
      end

      declared_findings = setup_audit_exception_declared_findings(data)
      missing = active_findings.reject do |finding|
        declared_findings.any? { |declared| setup_audit_exception_finding_matches?(declared, finding) }
      end
      unless missing.empty?
        blockers << "setup audit exception does not cover active findings: #{missing.map { |finding| setup_audit_finding_label(finding) }.join(", ")}"
      end
      blockers
    end

    def setup_audit_exception_declared_findings(data)
      Array(data.dig("applies_to", "findings") || data["findings"]).filter_map do |finding|
        next unless finding.is_a?(Hash)

        {
          "package_name" => finding["package_name"].to_s.empty? ? finding["package"].to_s : finding["package_name"].to_s,
          "severity" => finding["severity"].to_s.downcase,
          "advisory_id" => finding["advisory_id"].to_s.empty? ? finding["id"].to_s : finding["advisory_id"].to_s
        }.reject { |_, value| value.to_s.empty? }
      end
    end

    def setup_audit_exception_finding_matches?(declared, active)
      return false unless declared["package_name"] == active["package_name"]
      return false unless declared["severity"] == active["severity"]

      active_advisory = active["advisory_id"].to_s
      active_advisory.empty? || declared["advisory_id"].to_s == active_advisory
    end

    def setup_audit_artifact_sha256(audit_artifact)
      Digest::SHA256.hexdigest(JSON.generate(audit_artifact["raw"] || {}))
    end

    def setup_audit_blocking_findings(audit_artifact)
      setup_audit_findings(audit_artifact["raw"]).select { |finding| %w[critical high].include?(finding["severity"]) }
    end

    def setup_audit_findings(raw)
      return [] unless raw.is_a?(Hash)

      findings = []
      vulnerabilities = raw["vulnerabilities"]
      if vulnerabilities.is_a?(Hash)
        vulnerabilities.each do |key, value|
          next unless value.is_a?(Hash)

          finding = setup_audit_finding_from_hash(value, fallback_name: key)
          findings << finding if finding
        end
      end
      advisories = raw["advisories"]
      if advisories.is_a?(Hash)
        advisories.each do |key, value|
          next unless value.is_a?(Hash)

          finding = setup_audit_finding_from_hash(value, fallback_advisory: key)
          findings << finding if finding
        end
      end
      findings.uniq
    end

    def setup_audit_finding_from_hash(value, fallback_name: nil, fallback_advisory: nil)
      severity = value["severity"].to_s.downcase
      return nil unless %w[critical high moderate low].include?(severity)

      name = value["name"] || value["packageName"] || value["module_name"] || value["moduleName"] || fallback_name
      advisory = value["id"] || value["advisory_id"] || value["advisoryId"] || value["source"] || value["url"] || fallback_advisory
      {
        "package_name" => name.to_s,
        "severity" => severity,
        "advisory_id" => advisory.to_s,
        "current_version" => (value["version"] || value["current"] || value["installedVersion"]).to_s
      }.reject { |_, child| child.to_s.empty? }
    end

    def setup_audit_finding_label(finding)
      [
        finding["package_name"],
        finding["severity"],
        finding["advisory_id"]
      ].compact.join("@")
    end

    def setup_audit_exception_rollback_blockers(rollback_plan)
      return ["setup audit exception rollback_plan must be an object"] unless rollback_plan.is_a?(Hash)

      blockers = []
      blockers << "setup audit exception rollback_plan.summary is required" if rollback_plan["summary"].to_s.strip.empty?
      steps = Array(rollback_plan["steps"])
      blockers << "setup audit exception rollback_plan.steps must include at least one step" if steps.empty? || steps.all? { |step| step.to_s.strip.empty? }
      blockers
    end

    def setup_audit_exception_rollback_evidence(rollback_plan)
      return nil unless rollback_plan.is_a?(Hash)

      {
        "summary" => redact_side_effect_process_output(rollback_plan["summary"].to_s),
        "steps" => Array(rollback_plan["steps"]).map { |step| redact_side_effect_process_output(step.to_s) }.reject(&:empty?)
      }
    end

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

    def setup_parse_json(text)
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      nil
    end

    def setup_supply_chain_components(value, components = [], seen = {})
      case value
      when Array
        value.each { |item| setup_supply_chain_components(item, components, seen) }
      when Hash
        name = value["name"] || value["packageName"]
        version = value["version"]
        key = [name, version].join("@")
        if name && version && !seen[key]
          seen[key] = true
          components << {
            "name" => name,
            "version" => version,
            "path" => value["path"],
            "private" => value["private"] == true
          }.compact
        end
        dependencies = value["dependencies"]
        if dependencies.is_a?(Hash)
          dependencies.each_value { |dependency| setup_supply_chain_components(dependency, components, seen) }
        elsif dependencies.is_a?(Array)
          setup_supply_chain_components(dependencies, components, seen)
        end
      end
      components
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

    def setup_supply_chain_sbom_argv(package_manager)
      case package_manager.to_s
      when "pnpm" then ["pnpm", "list", "--json", "--depth", "Infinity"]
      else [package_manager.to_s, "list", "--json"]
      end
    end

    def setup_supply_chain_audit_argv(package_manager)
      case package_manager.to_s
      when "pnpm" then ["pnpm", "audit", "--json"]
      else [package_manager.to_s, "audit", "--json"]
      end
    end
  end
end
