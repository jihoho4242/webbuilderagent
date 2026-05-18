# frozen_string_literal: true

require "fileutils"
require "json"

module Aiweb
  module Runtime
    class ArtifactStore
      def initialize(root:, run_id:)
        @root = File.expand_path(root)
        @run_id = PathPolicy.validate_relative!(run_id, label: "run id")
        @run_dir = File.join(@root, ".ai-web", "runs", @run_id)
      end

      attr_reader :run_dir

      def write_json(relative_name, payload)
        relative_name = PathPolicy.validate_relative!(relative_name, label: "artifact name")
        path = File.expand_path(File.join(@run_dir, relative_name))
        ensure_inside_run_dir!(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(payload) + "\n")
        relative(path)
      end

      def write_jsonl(relative_name, events)
        relative_name = PathPolicy.validate_relative!(relative_name, label: "artifact name")
        path = File.expand_path(File.join(@run_dir, relative_name))
        ensure_inside_run_dir!(path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, Array(events).map { |event| JSON.generate(event) }.join("\n") + "\n")
        relative(path)
      end

      def relative(path)
        File.expand_path(path).delete_prefix(@root + File::SEPARATOR).tr("\\", "/")
      end

      private

      def ensure_inside_run_dir!(path)
        run_prefix = @run_dir.end_with?(File::SEPARATOR) ? @run_dir : "#{@run_dir}#{File::SEPARATOR}"
        expanded = File.expand_path(path)
        return if expanded == @run_dir || expanded.start_with?(run_prefix)

        raise ArgumentError, "artifact path escaped run directory"
      end
    end
  end
end
