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
