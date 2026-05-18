# frozen_string_literal: true

require "digest"
require "open3"
require "timeout"

module Aiweb
  class Project
    module Deploy
      private

    def deploy_workspace_provenance(state, include_tool_versions:)
      output_directory = deploy_output_directory(state)
      {
        "schema_version" => 1,
        "captured_at" => now,
        "workspace" => {
          "git" => git_workspace_provenance(deploy_git_provenance_paths(output_directory)),
          "source" => deploy_source_tree_provenance,
          "package" => deploy_package_provenance
        },
        "output" => deploy_output_provenance(output_directory),
        "tool_versions" => include_tool_versions ? deploy_tool_versions : {}
      }
    end

    def deploy_provenance_comparison(expected, current)
      checks = [
        ["git.commit_sha", expected.dig("workspace", "git", "commit_sha"), current.dig("workspace", "git", "commit_sha")],
        ["git.dirty", expected.dig("workspace", "git", "dirty"), current.dig("workspace", "git", "dirty")],
        ["git.status_sha256", expected.dig("workspace", "git", "status_sha256"), current.dig("workspace", "git", "status_sha256")],
        ["source.sha256", expected.dig("workspace", "source", "sha256"), current.dig("workspace", "source", "sha256")],
        ["package.sha256", expected.dig("workspace", "package", "sha256"), current.dig("workspace", "package", "sha256")],
        ["output.directory", expected.dig("output", "directory"), current.dig("output", "directory")],
        ["output.sha256", expected.dig("output", "sha256"), current.dig("output", "sha256")]
      ]
      expected_tools = expected["tool_versions"].is_a?(Hash) ? expected["tool_versions"] : {}
      current_tools = current["tool_versions"].is_a?(Hash) ? current["tool_versions"] : {}
      (expected_tools.keys | current_tools.keys).sort.each do |tool|
        checks << ["tool_versions.#{tool}", expected_tools[tool], current_tools[tool]]
      end

      mismatches = checks.each_with_object([]) do |(field, expected_value, current_value), memo|
        next if expected_value == current_value

        memo << {
          "field" => field,
          "expected" => expected_value,
          "current" => current_value
        }
      end
      {
        "status" => mismatches.empty? ? "matched" : "mismatched",
        "mismatches" => mismatches,
        "blocking_issues" => mismatches.map { |entry| "verify-loop provenance mismatch for #{entry.fetch("field")}; rerun aiweb verify-loop --max-cycles 3 --approved before deploy" }
      }
    end

    def git_workspace_provenance(paths)
      commit = git_commit_sha
      scope_paths = Array(paths).map { |path| path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "") }
                                .reject { |path| path.empty? || unsafe_env_path?(path) || deploy_hash_excluded_path?(path) }
                                .uniq
                                .sort
      stdout, _stderr, status = Open3.capture3("git", "status", "--porcelain=v1", "-uall", "--", *scope_paths, chdir: root)
      if status.success?
        normalized = stdout.lines.map(&:chomp).sort.join("\n")
        {
          "available" => true,
          "commit_sha" => commit,
          "dirty" => !normalized.empty?,
          "status_sha256" => Digest::SHA256.hexdigest(normalized),
          "scope_paths" => scope_paths
        }
      else
        {
          "available" => false,
          "commit_sha" => commit,
          "dirty" => nil,
          "status_sha256" => nil,
          "scope_paths" => scope_paths
        }
      end
    rescue StandardError
      {
        "available" => false,
        "commit_sha" => "unknown",
        "dirty" => nil,
        "status_sha256" => nil,
        "scope_paths" => []
      }
    end

    def deploy_git_provenance_paths(output_directory)
      paths = deploy_source_provenance_paths + %w[package.json pnpm-lock.yaml package-lock.json yarn.lock bun.lockb]
      paths << output_directory unless output_directory.to_s.empty?
      paths.select { |path| File.exist?(File.join(root, path)) }
    end

    def deploy_source_tree_provenance
      deploy_hash_paths(deploy_source_provenance_paths, "source")
    end

    def deploy_package_provenance
      deploy_hash_paths(%w[package.json pnpm-lock.yaml package-lock.json yarn.lock bun.lockb], "package")
    end

    def deploy_output_provenance(output_directory)
      return { "directory" => nil, "exists" => false, "file_count" => 0, "sha256" => nil } if output_directory.to_s.empty?

      deploy_hash_paths([output_directory], "output").merge("directory" => output_directory)
    end

    def deploy_source_provenance_paths
      candidates = %w[
        src
        public
        astro.config.mjs
        astro.config.js
        next.config.js
        next.config.mjs
        tsconfig.json
        tailwind.config.js
        tailwind.config.mjs
        vite.config.js
        vite.config.mjs
      ]
      candidates.select { |path| File.exist?(File.join(root, path)) }
    end

    def deploy_hash_paths(paths, label)
      files = deploy_hashable_files(paths)
      digest = Digest::SHA256.new
      files.each do |path|
        full = File.join(root, path)
        digest.update("#{path}\0")
        digest.update(Digest::SHA256.file(full).hexdigest)
        digest.update("\0")
      end
      {
        "label" => label,
        "exists" => !files.empty?,
        "file_count" => files.length,
        "sha256" => files.empty? ? nil : digest.hexdigest
      }
    end

    def deploy_hashable_files(paths)
      Array(paths).flat_map do |path|
        normalized = path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
        next [] if normalized.empty? || unsafe_env_path?(normalized)

        full = File.join(root, normalized)
        if File.file?(full)
          [normalized]
        elsif File.directory?(full)
          files = []
          Find.find(full) do |entry|
            rel = relative(entry)
            if deploy_hash_excluded_path?(rel)
              Find.prune if File.directory?(entry)
              next
            end
            files << rel if File.file?(entry)
          end
          files
        else
          []
        end
      end.compact.uniq.sort
    end

    def deploy_hash_excluded_path?(path)
      normalized = path.to_s.tr("\\", "/")
      return true if normalized.empty?
      return true if unsafe_env_path?(normalized)

      normalized.split("/").any? { |part| %w[.git .ai-web node_modules].include?(part) }
    end

    def deploy_tool_versions
      {
        "ruby" => RUBY_VERSION,
        "pnpm" => executable_version("pnpm", "--version"),
        "playwright" => executable_version(File.join("node_modules", ".bin", "playwright"), "--version"),
        "axe" => executable_version(File.join("node_modules", ".bin", "axe"), "--version"),
        "lighthouse" => executable_version(File.join("node_modules", ".bin", "lighthouse"), "--version")
      }
    end

    def executable_version(executable, *args)
      command = if executable.include?(File::SEPARATOR)
                  path = File.join(root, executable)
                  return nil unless File.executable?(path)

                  [path, *args]
                else
                  path = executable_path(executable)
                  return nil unless path

                  [path, *args]
                end
      stdout = ""
      Timeout.timeout(2) do
        stdout, _stderr, status = Open3.capture3(subprocess_path_env, *command, chdir: root, unsetenv_others: true)
        return nil unless status.success?
      end
      stdout.lines.first.to_s.strip[0, 120]
    rescue StandardError
      nil
    end

    end
  end
end
