# frozen_string_literal: true

require "digest"
require "fileutils"

module Aiweb
  module ProjectAgentRun
    private

    def agent_run_prepare_openmanus_workspace(workspace_dir, source_paths)
      blockers = []
      return ["openmanus workspace already exists and will not be reused: #{relative(workspace_dir)}"] if File.exist?(workspace_dir) || File.symlink?(workspace_dir)

      base_dir = File.dirname(workspace_dir)
      FileUtils.mkdir_p(base_dir)
      return ["openmanus workspace base is unsafe: #{relative(base_dir)}"] if File.symlink?(base_dir)

      Dir.mkdir(workspace_dir)
      FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb"))
      FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb", "home"))
      FileUtils.mkdir_p(File.join(workspace_dir, "_aiweb", "tmp"))
      base_real = File.realpath(base_dir)
      workspace_real = File.realpath(workspace_dir)
      unless workspace_real == base_real || workspace_real.start_with?(base_real + File::SEPARATOR)
        return ["openmanus workspace escaped expected base: #{relative(workspace_dir)}"]
      end
      source_paths.each do |path|
        normalized = agent_run_normalized_relative_path(path)
        source = File.join(root, normalized)
        target = File.join(workspace_dir, normalized)
        if unsafe_secret_surface_path?(normalized) || File.symlink?(source)
          blockers << "openmanus workspace refused unsafe source path: #{normalized}"
          next
        end
        if File.file?(source) && File.lstat(source).nlink.to_i > 1
          blockers << "openmanus workspace refused hardlinked source path: #{normalized}"
          next
        end
        unless File.file?(source)
          blockers << "openmanus workspace source file is missing: #{normalized}"
          next
        end
        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(source, target)
      end
      blockers
    rescue SystemCallError => e
      ["openmanus workspace preparation failed: #{e.message}"]
    end

    def agent_run_validate_openmanus_workspace(workspace_dir:, source_paths:, base_hashes:)
      allowed = source_paths.to_set
      blockers = []
      changed = []
      extra_files = []
      workspace_files = []
      Find.find(workspace_dir) do |path|
        next if File.directory?(path)

        relative_path = path.sub(/^#{Regexp.escape(workspace_dir)}[\\\/]?/, "").tr("\\", "/")
        next if relative_path.start_with?("_aiweb/")

        workspace_files << relative_path
        if File.symlink?(path) || unsafe_secret_surface_path?(relative_path)
          blockers << "openmanus produced unsafe workspace file: #{relative_path}"
          next
        end
        blockers << "openmanus produced hardlinked workspace file: #{relative_path}" if File.lstat(path).nlink.to_i > 1
        if allowed.include?(relative_path) && agent_run_binary_file?(path)
          blockers << "openmanus produced binary content for source file: #{relative_path}"
        end
        extra_files << relative_path unless allowed.include?(relative_path)
      end
      missing = source_paths.reject { |path| File.file?(File.join(workspace_dir, path)) }
      missing.each { |path| blockers << "openmanus deleted allowed source file: #{path}" }
      extra_files.each { |path| blockers << "openmanus produced unapproved file: #{path}" }
      source_paths.each do |path|
        source = File.join(root, path)
        workspace = File.join(workspace_dir, path)
        next unless File.file?(source) && File.file?(workspace)

        expected = base_hashes[path].to_s.sub(/\Asha256:/, "")
        current = Digest::SHA256.file(source).hexdigest
        blockers << "source changed during openmanus run before apply: #{path}" unless expected.empty? || current == expected
        blockers << "openmanus copy-back target is hardlinked and unsafe: #{path}" if File.lstat(source).nlink.to_i > 1
        if !windows? && File.executable?(workspace) && !File.executable?(source)
          blockers << "openmanus attempted to add executable mode to source file: #{path}"
        end
        changed << path unless Digest::SHA256.file(workspace).hexdigest == expected
      end
      validator = {
        "schema_version" => 1,
        "workspace_files" => workspace_files.sort,
        "allowed_source_paths" => source_paths,
        "extra_files" => extra_files.sort,
        "missing_files" => missing,
        "changed_source_files" => changed,
        "blocking_issues" => blockers
      }
      [changed, blockers.uniq, validator]
    rescue SystemCallError => e
      [[], ["openmanus workspace validation failed: #{e.message}"], { "schema_version" => 1, "blocking_issues" => [e.message] }]
    end

    def agent_run_apply_openmanus_changes(workspace_dir, changed_source_files)
      changed_source_files.each do |path|
        source = File.join(workspace_dir, path)
        target = File.join(root, path)
        raise UserError.new("openmanus copy-back target is hardlinked and unsafe: #{path}", 5) if File.file?(target) && File.lstat(target).nlink.to_i > 1

        FileUtils.mkdir_p(File.dirname(target))
        FileUtils.cp(source, target)
      end
    end

    def agent_run_binary_file?(path)
      File.open(path, "rb") { |file| file.read(4096).to_s.include?("\x00") }
    rescue SystemCallError
      false
    end

    def agent_run_openmanus_workspace_diff(workspace_dir, changed_source_files)
      changed_source_files.map do |path|
        source = File.join(root, path)
        workspace = File.join(workspace_dir, path)
        agent_run_full_file_diff(path, source, workspace)
      end.join
    end

    def agent_run_denied_globs
      %w[
        .env*
        .git/**
        node_modules/**
        .ssh/**
        .aws/**
        .vercel/**
        .netlify/**
        *.pem
        *.key
        id_rsa
        id_dsa
        id_ed25519
        **/*secret*
        **/*credential*
      ]
    end

    def unsafe_secret_surface_path?(path)
      secret_surface_path?(path)
    end

    def windows?
      RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/i)
    end

  end
end
