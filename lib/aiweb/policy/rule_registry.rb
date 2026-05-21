# frozen_string_literal: true

require "digest"
require "yaml"

module Aiweb
  module Policy
    class RuleRegistry
      DEFAULT_PATH = File.expand_path("../../../configs/policy_rule_registry.yaml", __dir__)
      DEFAULT_CAPABILITY_MATRIX_PATH = File.expand_path("../../../configs/capability_matrix.yaml", __dir__)

      def initialize(path = DEFAULT_PATH, capability_matrix_path = DEFAULT_CAPABILITY_MATRIX_PATH)
        @path = path
        @capability_matrix_path = capability_matrix_path
      end

      def load
        data = YAML.safe_load(File.read(@path), permitted_classes: [], aliases: false)
        validate_registry!(data)
        data
      end

      def capability_matrix
        data = YAML.safe_load(File.read(@capability_matrix_path), permitted_classes: [], aliases: false)
        validate_capability_matrix!(data)
        data
      end

      def version
        "sha256:#{Digest::SHA256.hexdigest(File.read(@path))}"
      end

      def capability_matrix_version
        "sha256:#{Digest::SHA256.hexdigest(File.read(@capability_matrix_path))}"
      end

      private

      def validate_registry!(data)
        raise KeyError, "policy registry schema_version missing" unless data.is_a?(Hash) && data["schema_version"]
        raise KeyError, "policy registry rules missing" unless data["rules"].is_a?(Array) && data["rules"].any?

        data["rules"].each do |rule|
          %w[id match decision].each { |field| raise KeyError, "policy registry rule missing #{field}" unless rule[field].to_s.strip != "" }
        end
      end

      def validate_capability_matrix!(data)
        raise KeyError, "capability matrix schema_version missing" unless data.is_a?(Hash) && data["schema_version"]
        tiers = data["permission_tiers"]
        raise KeyError, "capability matrix permission_tiers missing" unless tiers.is_a?(Hash)

        %w[L0 L1 L2 L3 L4 L5].each { |tier| raise KeyError, "capability matrix missing #{tier}" unless tiers.key?(tier) }
        auto_allow = data["autonomous_local_auto_allow_max_tier"].to_s
        raise KeyError, "capability matrix autonomous_local_auto_allow_max_tier missing" unless tiers.key?(auto_allow)
      end
    end
  end
end
