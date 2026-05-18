# frozen_string_literal: true

module Aiweb
  module AgentRuntime
    class SourcePatchGuard
      DEFAULT_ALLOWED_ROOTS = %w[
        src
        public
        test
        tests
        docs
        package.json
        astro.config.mjs
        next.config.mjs
        tsconfig.json
        tailwind.config.mjs
      ].freeze

      DEFAULT_FORBIDDEN_ROOTS = %w[
        .git
        .env
        node_modules
        dist
        build
        coverage
        .ai-web/runs
        .ai-web/workbench
        .ai-web/snapshots
      ].freeze

      def validate(manifest:, changed_files:, patch_bytes: 0)
        manifest = manifest.is_a?(Hash) ? manifest : {}
        allowed = Array(manifest["allowed_source_paths"] || DEFAULT_ALLOWED_ROOTS).map { |path| normalize(path) }
        max_files = positive_integer(manifest["max_changed_files"], 20)
        max_bytes = positive_integer(manifest["max_patch_bytes"], 200_000)
        changes = Array(changed_files).map { |path| normalize(path) }.reject(&:empty?)
        blockers = []

        blockers << "source patch manifest is absent" if manifest.empty?
        blockers << "changed file count #{changes.length} exceeds max_changed_files #{max_files}" if changes.length > max_files
        blockers << "patch size #{patch_bytes.to_i} exceeds max_patch_bytes #{max_bytes}" if patch_bytes.to_i > max_bytes

        changes.each do |path|
          blockers << "unsafe changed path #{path}" unless Aiweb::Runtime::PathPolicy.safe_relative_path?(path)
          blockers << "forbidden changed path #{path}" if forbidden_path?(path)
          blockers << "changed path #{path} is outside manifest allowed_source_paths" unless allowed_path?(path, allowed)
        end

        {
          "schema_version" => 1,
          "status" => blockers.empty? ? "passed" : "blocked",
          "changed_files" => changes,
          "max_changed_files" => max_files,
          "max_patch_bytes" => max_bytes,
          "patch_bytes" => patch_bytes.to_i,
          "blocking_issues" => blockers.uniq,
          "copy_back_allowed" => blockers.empty?
        }
      end

      private

      def normalize(path)
        Aiweb::Runtime::PathPolicy.normalize_relative(path)
      end

      def positive_integer(value, default)
        integer = value.to_i
        integer.positive? ? integer : default
      end

      def forbidden_path?(path)
        DEFAULT_FORBIDDEN_ROOTS.any? do |root|
          path == root || path.start_with?("#{root}/")
        end
      end

      def allowed_path?(path, allowed)
        allowed.any? do |root|
          path == root || path.start_with?("#{root}/")
        end
      end
    end
  end
end
