# frozen_string_literal: true

require "digest"
require "json"
require "yaml"

module Aiweb
  module Constitution
    class Loader
      DEFAULT_PATH = File.expand_path("../../../configs/constitution.yaml", __dir__)

      def initialize(path = DEFAULT_PATH)
        @path = path
      end

      attr_reader :path

      def load
        YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
      end

      def content
        File.read(path)
      end

      def content_hash
        "sha256:#{Digest::SHA256.hexdigest(content)}"
      end

      def evidence
        data = load
        {
          "schema_version" => 1,
          "constitution_id" => data.fetch("constitution_id"),
          "constitution_version" => data.fetch("constitution_version"),
          "immutable" => data.fetch("immutable"),
          "content_hash" => content_hash,
          "path" => relative_path(path),
          "critical_rule_ids" => Array(data["rules"]).map { |rule| rule["id"] },
          "change_process" => data.fetch("change_process", {})
        }
      end

      private

      def relative_path(value)
        root = File.expand_path("../../..", __dir__)
        File.expand_path(value).sub(/^#{Regexp.escape(root)}[\\\/]?/, "").tr("\\", "/")
      end
    end
  end
end
