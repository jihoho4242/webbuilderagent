# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "shellwords"

module FakeExecutableTooling
  def write_fake_executable(dir, name, body)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    FileUtils.chmod("+x", path)
    write_fake_windows_executable(dir, name, body) if windows?
    path
  end

  def write_fake_provider_cli(dir, name:, marker:, stdout_lines: [], stderr_lines: [], exit_code: 0)
    script_path = File.join(dir, "#{name}-fake-provider.rb")
    File.write(
      script_path,
      <<~RUBY
        # frozen_string_literal: true

        require "fileutils"

        puts ["fake #{name} deploy", *ARGV].join(" ")
        #{stdout_lines.inspect}.each { |line| puts line }
        #{stderr_lines.inspect}.each { |line| warn line }
        FileUtils.touch(#{marker.inspect})
        exit #{exit_code.to_i}
      RUBY
    )
    FileUtils.chmod("+x", script_path)
    executable_path = File.join(dir, windows? ? "#{name}.cmd" : name)
    if windows?
      File.write(executable_path, "@echo off\r\n\"#{RbConfig.ruby}\" \"#{script_path}\" %*\r\n")
    else
      File.write(executable_path, "#!/bin/sh\nexec #{RbConfig.ruby.shellescape} #{script_path.shellescape} \"$@\"\n")
    end
    FileUtils.chmod("+x", executable_path)
    executable_path
  end

  def windows?
    RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/i)
  end

  def refute_windows_process_command_includes(fragment)
    return unless windows?

    stdout, _stderr, status = Open3.capture3(
      "powershell",
      "-NoProfile",
      "-Command",
      "Get-CimInstance Win32_Process | Select-Object -ExpandProperty CommandLine"
    )
    return unless status.success?

    refute_includes stdout.tr("\\", "/"), fragment.tr("\\", "/")
  end

  def write_fake_windows_executable(dir, name, body)
    script_path = File.join(dir, "#{name}-fake.rb")
    cmd_path = File.join(dir, "#{name}.cmd")
    File.write(script_path, fake_windows_executable_source(name, body))
    File.write(cmd_path, "@echo off\r\n\"#{RbConfig.ruby}\" \"#{script_path}\" %*\r\n")
    FileUtils.chmod("+x", script_path)
    FileUtils.chmod("+x", cmd_path)
    cmd_path
  end

  def fake_windows_executable_source(name, body)
    <<~RUBY
      # frozen_string_literal: true

      require "fileutils"
      require "shellwords"

      TOOL = #{name.inspect}
      BODY = #{body.inspect}

      def env(name, default = "")
        value = ENV[name].to_s
        value.empty? ? default : value
      end

      def write_text(path, text, append: false)
        return if path.to_s.empty?
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir) unless dir == "." || Dir.exist?(dir)
        File.open(path, append ? "a" : "w") { |file| file.write(text) }
      end

      def touch_path(path)
        return if path.to_s.empty?
        dir = File.dirname(path)
        FileUtils.mkdir_p(dir) unless dir == "." || Dir.exist?(dir)
        FileUtils.touch(path)
      end

      def parsed_exit(default = 0)
        matches = BODY.scan(/exit\\s+(\\d+)/).flatten
        matches.empty? ? default : matches.last.to_i
      end

      def setup_install_exit(default = 0)
        BODY[/install\\).*?exit\\s+(\\d+)/m, 1]&.to_i || parsed_exit(default)
      end

      def shell_path(raw)
        Shellwords.split(raw.to_s.strip).first.to_s
      rescue ArgumentError
        raw.to_s.strip.gsub(/\\A['"]|['"]\\z/, "")
      end

      def first_touched_path
        raw = BODY[/touch\\s+(.+?)(?:\\s*;|\\n|\\z)/m, 1]
        shell_path(raw)
      end

      def first_redirect_path
        raw = BODY[/echo\\s+ran\\s*>\\s*(.+?)(?:\\s*;|\\n|\\z)/m, 1]
        shell_path(raw)
      end

      def generic_fake
        if (path = first_redirect_path) && !path.empty?
          write_text(path, "ran\\n")
        end
        touch_path(first_touched_path)
        if BODY.include?("fake vercel deploy")
          puts "fake vercel deploy \#{ARGV.join(" ")}".rstrip
        elsif BODY.include?("should-not-run")
          warn "should-not-run"
        end
        exit parsed_exit(0)
      end

      def fake_setup_pnpm
        case ARGV.first
        when "list"
          puts env("FAKE_PNPM_LIST_JSON", '[{"name":"fixture","version":"1.0.0","dependencies":{}}]')
          exit env("FAKE_PNPM_LIST_EXIT_STATUS", "0").to_i
        when "audit"
          puts env("FAKE_PNPM_AUDIT_JSON", '{"metadata":{"vulnerabilities":{"critical":0,"high":0,"moderate":0,"low":0}},"vulnerabilities":{}}')
          exit env("FAKE_PNPM_AUDIT_EXIT_STATUS", "0").to_i
        when "install"
          # handled below
        else
          warn "unexpected pnpm command: \#{ARGV.join(" ")}"
          exit 64
        end
        lines = BODY.lines.map(&:strip)
        stdout_line = lines.find { |line| line.start_with?("echo ") && !line.include?(">&2") }
        stderr_line = lines.find { |line| line.start_with?("echo ") && line.include?(">&2") }
        stdout = stdout_line ? Shellwords.split(stdout_line.sub(/\\Aecho\\s+/, "")).first.to_s : "fake pnpm install stdout"
        stderr = stderr_line ? Shellwords.split(stderr_line.sub(/\\Aecho\\s+/, "").sub(/\\s+>&2\\z/, "")).first.to_s : "fake pnpm install stderr"
        package_json_after = env("FAKE_PNPM_PACKAGE_JSON_AFTER")
        write_text("package.json", package_json_after) unless package_json_after.empty?
        lockfile_after = env("FAKE_PNPM_LOCKFILE_AFTER")
        write_text("pnpm-lock.yaml", lockfile_after) unless lockfile_after.empty?
        puts stdout
        warn stderr
        exit setup_install_exit(0)
      end

      def fake_build_pnpm
        exit 64 unless ARGV.first == "build"
        puts "fake astro build stdout"
        warn "fake astro build stderr"
        FileUtils.mkdir_p("dist")
        write_text(File.join("dist", "index.html"), "built")
        exit 0
      end

      def fake_dev_pnpm
        exit 64 unless ARGV.first == "dev"
        puts "fake astro dev stdout"
        warn "fake astro dev stderr"
        loop { sleep 1 }
      end

      def fake_playwright_pnpm
        unless ARGV[0, 3] == %w[exec playwright test]
          warn "expected pnpm exec playwright test"
          exit 64
        end
        if env("PLAYWRIGHT_FAKE_STATUS", "passed") == "failed"
          puts '{"status":"failed","suites":[],"stats":{"expected":0,"unexpected":1,"flaky":0,"skipped":0}}'
          warn "fake playwright failure"
          exit 1
        end
        puts '{"status":"passed","suites":[],"stats":{"expected":1,"unexpected":0,"flaky":0,"skipped":0}}'
        warn "fake playwright pass"
        exit 0
      end

      def fake_screenshot_pnpm(prefix = "fake screenshot")
        unless ARGV[0, 3] == %w[exec playwright screenshot]
          warn "expected pnpm exec playwright screenshot"
          exit 64
        end
        wrote = false
        ARGV.each do |arg|
          next unless arg.end_with?(".png")
          write_text(arg, "\#{prefix} for \#{arg}\\n")
          wrote = true
        end
        if env("QA_SCREENSHOT_FAKE_STATUS", "passed") == "failed"
          warn "\#{prefix} failure"
          exit 1
        end
        unless wrote
          warn "no png output path provided"
          exit 64
        end
        warn "\#{prefix} pass"
        exit 0
      end

      def fake_static_qa_pnpm(prefix = "fake")
        unless ARGV[0] == "exec" && %w[axe lighthouse].include?(ARGV[1])
          warn "unexpected qa tool \#{ARGV[1]}"
          exit 64
        end
        tool = ARGV[1]
        status = env("AIWEB_STATIC_QA_STATUS", "passed")
        status = env("A11Y_FAKE_STATUS", status) if tool == "axe"
        status = env("LIGHTHOUSE_FAKE_STATUS", status) if tool == "lighthouse"
        ARGV.each do |arg|
          next unless arg.start_with?("--output-path=")
          write_text(arg.split("=", 2).last, "{\\"tool\\":\\"\#{tool}\\",\\"status\\":\\"\#{status}\\"}\\n")
        end
        puts "{\\"tool\\":\\"\#{tool}\\",\\"status\\":\\"\#{status}\\"}"
        if status == "failed"
          warn "\#{prefix} \#{tool} failure"
          exit 1
        end
        warn "\#{prefix} \#{tool} pass"
        exit 0
      end

      def fake_verify_loop_pnpm
        case ARGV.first
        when "build"
          FileUtils.mkdir_p("dist")
          write_text(File.join("dist", "index.html"), "<h1>fake verify-loop build</h1>\\n")
          puts "fake verify-loop build pass"
          exit env("BUILD_FAKE_EXIT_STATUS", "0").to_i
        when "dev"
          puts "fake verify-loop preview start"
          exit 0
        when "exec"
          tool = ARGV[1]
          if tool == "playwright" && ARGV[2] == "test"
            if env("PLAYWRIGHT_FAKE_STATUS", "passed") == "failed"
              puts '{"status":"failed","suites":[],"stats":{"unexpected":1}}'
              warn "fake verify-loop playwright failure"
              exit 1
            end
            puts '{"status":"passed","suites":[],"stats":{"expected":1}}'
            warn "fake verify-loop playwright pass"
            exit 0
          elsif tool == "playwright" && ARGV[2] == "screenshot"
            ARGV.drop(3).each { |arg| write_text(arg, "fake verify-loop screenshot for \#{arg}\\n") if arg.end_with?(".png") }
            if env("QA_SCREENSHOT_FAKE_STATUS", "passed") == "failed"
              warn "fake verify-loop screenshot failure"
              exit 1
            end
            warn "fake verify-loop screenshot pass"
            exit 0
          elsif %w[axe lighthouse].include?(tool)
            fake_static_qa_pnpm("fake verify-loop")
          end
        end
        warn "unexpected fake verify-loop pnpm command: \#{ARGV.join(" ")}"
        exit 64
      end

      def fake_pnpm
        if BODY.include?("fake verify-loop")
          fake_verify_loop_pnpm
        elsif BODY.include?("fake astro build stdout")
          fake_build_pnpm
        elsif BODY.include?("fake astro dev stdout")
          fake_dev_pnpm
        elsif BODY.include?("unexpected pnpm command") && BODY.include?("install")
          fake_setup_pnpm
        elsif BODY.include?("PLAYWRIGHT_FAKE_STATUS") && BODY.include?("--reporter=json")
          fake_playwright_pnpm
        elsif BODY.include?("QA_SCREENSHOT_FAKE_STATUS")
          fake_screenshot_pnpm
        elsif BODY.include?("unexpected qa tool")
          fake_static_qa_pnpm
        else
          generic_fake
        end
      end

      def fake_codex
        return generic_fake unless BODY.include?("FAKE_CODEX_")
        input = STDIN.read
        prompt_path = ENV["FAKE_CODEX_PROMPT_PATH"].to_s
        write_text(prompt_path, input) unless prompt_path.empty?
        verify_loop = BODY.include?("fake verify-loop codex")
        puts env("FAKE_CODEX_STDOUT", verify_loop ? "fake verify-loop codex stdout" : "fake codex stdout")
        warn env("FAKE_CODEX_STDERR", verify_loop ? "fake verify-loop codex stderr" : "fake codex stderr")
        patch_path = ENV["FAKE_CODEX_PATCH_PATH"].to_s
        if !patch_path.empty? && File.file?(patch_path)
          write_text(patch_path, verify_loop ? "\\n<!-- patched by fake verify-loop codex -->\\n" : "\\n<!-- patched by fake codex -->\\n", append: true)
        end
        marker = ENV["FAKE_CODEX_MARKER"].to_s
        if !marker.empty?
          verify_loop ? write_text(marker, "run\\n", append: true) : touch_path(marker)
        end
        exit env("FAKE_CODEX_EXIT_STATUS", "0").to_i
      end

      case TOOL
      when "pnpm" then fake_pnpm
      when "codex" then fake_codex
      else generic_fake
      end
    RUBY
  end

end
