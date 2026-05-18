# frozen_string_literal: true

module Aiweb
  module ProfilePolicy
    class Contract
      attr_reader :id, :display_name, :framework, :framework_detail, :metadata_path,
        :required_files, :expected_scripts, :expected_dependencies, :package_manager,
        :dev_command, :build_command, :runtime_readiness, :capabilities,
        :forbidden_actions, :env_policy, :documentation_summary

      def initialize(id:, display_name:, framework:, framework_detail:, metadata_path:, required_files:,
        expected_scripts:, expected_dependencies:, package_manager:, dev_command:, build_command:,
        runtime_readiness:, capabilities:, forbidden_actions:, env_policy:, documentation_summary:)
        @id = id
        @display_name = display_name
        @framework = framework
        @framework_detail = framework_detail
        @metadata_path = metadata_path
        @required_files = required_files.freeze
        @expected_scripts = expected_scripts.freeze
        @expected_dependencies = expected_dependencies.freeze
        @package_manager = package_manager
        @dev_command = dev_command
        @build_command = build_command
        @runtime_readiness = runtime_readiness
        @capabilities = capabilities.freeze
        @forbidden_actions = forbidden_actions.freeze
        @env_policy = env_policy.freeze
        @documentation_summary = documentation_summary
      end

      def supports?(capability)
        @capabilities.fetch(capability.to_sym, false) == true
      end

      def expected_metadata
        {
          "profile" => id,
          "framework" => framework,
          "package_manager" => package_manager,
          "dev_command" => dev_command,
          "build_command" => build_command
        }
      end

      def to_h
        {
          "id" => id,
          "display_name" => display_name,
          "framework" => framework,
          "framework_detail" => framework_detail,
          "metadata_path" => metadata_path,
          "required_files" => required_files,
          "expected_scripts" => expected_scripts,
          "expected_dependencies" => expected_dependencies,
          "package_manager" => package_manager,
          "dev_command" => dev_command,
          "build_command" => build_command,
          "runtime_readiness" => runtime_readiness,
          "capabilities" => capabilities.transform_keys(&:to_s),
          "forbidden_actions" => forbidden_actions,
          "env_policy" => env_policy,
          "documentation_summary" => documentation_summary
        }
      end
    end
  end
end
