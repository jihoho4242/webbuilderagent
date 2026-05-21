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

    def setup_parse_json(text)
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      nil
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
