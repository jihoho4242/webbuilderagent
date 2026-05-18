# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "time"
require "yaml"

require_relative "../constitution"

module Aiweb
  module Tools
    class Registry
      DEFAULT_PATH = File.expand_path("../../../configs/tool_registry.yaml", __dir__)

      def initialize(path = DEFAULT_PATH)
        @path = path
      end

      def load
        YAML.safe_load(File.read(@path), permitted_classes: [], aliases: false)
      end

      def version
        "sha256:#{Digest::SHA256.hexdigest(File.read(@path))}"
      end

      def fetch(tool_name)
        data = load
        data.fetch("tools", {}).fetch(tool_name.to_s) do
          raise KeyError, "unknown tool #{tool_name}"
        end
      end

      def known?(tool_name)
        load.fetch("tools", {}).key?(tool_name.to_s)
      end
    end
  end
end
