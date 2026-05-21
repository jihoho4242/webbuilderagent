# frozen_string_literal: true

require "fileutils"
require "time"
require "yaml"

require_relative "../json_safety"
require_relative "../runtime"

module Aiweb
  module ProjectIoHelpers
    def write_file(path, content, dry_run)
      rel = relative(path)
      return rel if dry_run
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      rel
    end

    def write_yaml(path, data, dry_run)
      write_file(path, YAML.dump(data), dry_run)
    end

    def executable_path(name)
      suffixes = [""]
      if windows? && File.extname(name.to_s).empty?
        suffixes.concat(ENV.fetch("PATHEXT", ".COM;.EXE;.BAT;.CMD").split(";"))
      end
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).flat_map do |dir|
        suffixes.map { |suffix| File.join(dir, "#{name}#{suffix}") }
      end.find { |path| File.executable?(path) && !File.directory?(path) }
    end

    def executable_version(name, *args)
      executable = executable_path(name)
      return nil unless executable

      result = Aiweb::Runtime::ProcessRunner.new.capture(
        Aiweb::Runtime::CommandSpec.new(
          argv: [executable, *args.map(&:to_s)],
          cwd: root,
          env: subprocess_path_env,
          timeout: 10,
          max_output_bytes: 4_096,
          risk_class: "executable_version_probe",
          description: "#{name} version probe"
        )
      )
      return nil unless result.success?

      result.stdout.to_s.lines.first.to_s.strip
    end

    def subprocess_path_env
      %w[PATH PATHEXT SYSTEMROOT WINDIR COMSPEC].each_with_object({}) do |key, env|
        env[key] = ENV[key] if ENV[key]
      end
    end

    def local_executable_path(path)
      suffixes = [""]
      if windows? && File.extname(path.to_s).empty?
        suffixes.concat(ENV.fetch("PATHEXT", ".COM;.EXE;.BAT;.CMD").split(";"))
      end
      suffixes.map { |suffix| "#{path}#{suffix}" }.find { |candidate| File.executable?(candidate) && !File.directory?(candidate) }
    end

    def write_json(path, data, dry_run)
      write_file(path, json_pretty_generate(data) + "\n", dry_run)
    end

    def json_generate(data)
      Aiweb::JsonSafety.generate(data)
    end

    def json_pretty_generate(data)
      Aiweb::JsonSafety.pretty_generate(data)
    end

    def create_dir(path, dry_run)
      rel = relative(path)
      FileUtils.mkdir_p(path) unless dry_run
      rel
    end

    def compact_changes(changes)
      changes.flatten.compact.uniq.reject(&:empty?)
    end

    def relative(path)
      path = File.expand_path(path)
      path.sub(/^#{Regexp.escape(root)}\/?/, "")
    end

    def now
      Time.now.utc.iso8601
    end

    def default_project_id
      slug(File.basename(root))
    end

    def slug(value)
      value.to_s.downcase.gsub(/[^a-z0-9가-힣._-]+/i, "-").gsub(/^-|-$/, "")
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

  end
end
