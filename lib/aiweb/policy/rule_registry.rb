# frozen_string_literal: true

require "yaml"

module Aiweb
  module Policy
    class RuleRegistry
      DEFAULT_PATH = File.expand_path("../../../configs/policy_rule_registry.yaml", __dir__)

      def initialize(path = DEFAULT_PATH)
        @path = path
      end

      def load
        YAML.safe_load(File.read(@path), permitted_classes: [], aliases: false)
      end
    end
  end
end
