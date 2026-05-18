# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"
require "shellwords"

module FakeAiwebCliRuntimeTooling
  def write_fake_pnpm_install_tooling(root, exit_status: 0, stdout: "fake pnpm install stdout", stderr: "fake pnpm install stderr", list_json: nil, audit_json: nil, audit_exit_status: 0, package_json_after: nil, lockfile_after: :default, env_probe_path: nil)
    bin_dir = File.join(root, "fake-setup-bin")
    FileUtils.mkdir_p(bin_dir)
    list_json ||= JSON.generate([{ "name" => "fixture", "version" => "1.0.0", "dependencies" => {} }])
    audit_json ||= JSON.generate("metadata" => { "vulnerabilities" => { "critical" => 0, "high" => 0, "moderate" => 0, "low" => 0 } }, "vulnerabilities" => {})
    lockfile_after = <<~YAML if lockfile_after == :default
      lockfileVersion: '9.0'
      importers:
        .:
          dependencies: {}
      packages: {}
    YAML
    script_path = File.join(bin_dir, "pnpm-fake-setup.rb")
    File.write(
      script_path,
      <<~SH
        # frozen_string_literal: true

        require "fileutils"
        require "json"

        PACKAGE_JSON_AFTER = #{package_json_after.inspect}
        LOCKFILE_AFTER = #{lockfile_after.inspect}
        ENV_PROBE_PATH = #{env_probe_path.inspect}

        def write_optional(path, body)
          return if body.nil?
          FileUtils.mkdir_p(File.dirname(path)) unless File.dirname(path) == "."
          File.write(path, body)
        end

        case ARGV.first
        when "install"
          write_optional("package.json", PACKAGE_JSON_AFTER)
          write_optional("pnpm-lock.yaml", LOCKFILE_AFTER)
          if ENV_PROBE_PATH
            FileUtils.mkdir_p(File.dirname(ENV_PROBE_PATH))
            File.write(
              ENV_PROBE_PATH,
              JSON.generate(
                "SECRET" => ENV["SECRET"],
                "NPM_TOKEN" => ENV["NPM_TOKEN"],
                "AIWEB_SETUP_APPROVED" => ENV["AIWEB_SETUP_APPROVED"]
              )
            )
          end
          puts #{stdout.inspect}
          warn #{stderr.inspect}
          exit #{exit_status.to_i}
        when "list"
          puts #{list_json.inspect}
          exit 0
        when "audit"
          puts #{audit_json.inspect}
          exit #{audit_exit_status.to_i}
        else
          warn "unexpected pnpm command: \#{ARGV.join(" ")}"
          exit 64
        end
      SH
    )
    FileUtils.chmod("+x", script_path)
    executable_path = File.join(bin_dir, windows? ? "pnpm.cmd" : "pnpm")
    if windows?
      File.write(executable_path, "@echo off\r\n\"#{RbConfig.ruby}\" \"#{script_path}\" %*\r\n")
    else
      File.write(executable_path, "#!/bin/sh\nexec #{RbConfig.ruby.shellescape} #{script_path.shellescape} \"$@\"\n")
    end
    FileUtils.chmod("+x", executable_path)
    bin_dir
  end
end
