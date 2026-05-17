# frozen_string_literal: true

require "fileutils"
require "digest"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "yaml"

require_relative "support/test_helper"
require_relative "support/fake_mcp_http_server"

require "aiweb/project"
require "aiweb/cli"

class AiwebCliTest < Minitest::Test
  AIWEB = File.expand_path("../bin/aiweb", __dir__)
  WEBBUILDER = File.expand_path("../bin/webbuilder", __dir__)
  KOREAN_WEBBUILDER = File.expand_path("../bin/\uC6F9\uBE4C\uB354", __dir__)
  REPO_ROOT = File.expand_path("..", __dir__)

  def in_tmp
    dir = Dir.mktmpdir("aiweb-test-")
    begin
      Dir.chdir(dir) { yield(dir) }
    ensure
      Dir.chdir(REPO_ROOT) if File.expand_path(Dir.pwd).start_with?(File.expand_path(dir))
      remove_test_tmp_dir(dir)
    end
  end

  def remove_test_tmp_dir(dir)
    return unless File.exist?(dir)
    raise "refusing to remove non-test temp dir: #{dir}" unless File.basename(dir).start_with?("aiweb-test-")

    5.times do |attempt|
      begin
        FileUtils.chmod_R(0o700, dir, force: true)
        FileUtils.rm_rf(dir)
        return unless File.exist?(dir)
      rescue Errno::EACCES, Errno::EPERM
        sleep(0.1 * (attempt + 1))
      end
    end
    FileUtils.rm_rf(dir)
  end

  def with_fake_lazyweb_mcp_server
    FakeMcpHttpServer.open(method(:fake_lazyweb_mcp_response)) do |endpoint, received|
      yield endpoint, received
    end
  end

  def fake_lazyweb_mcp_response(payload)
    case payload.fetch("method")
    when "initialize"
      { "jsonrpc" => "2.0", "id" => payload.fetch("id"), "result" => { "capabilities" => {} } }
    when "notifications/initialized"
      { "jsonrpc" => "2.0", "result" => {} }
    when "tools/call"
      query = payload.dig("params", "arguments", "query").to_s
      {
        "jsonrpc" => "2.0",
        "id" => payload.fetch("id"),
        "result" => {
          "content" => [{ "type" => "text", "text" => JSON.generate("results" => [
            {
              "screenshot_id" => "#{query.hash.abs}-a",
              "company" => "Acme",
              "category" => "Developer Tools",
              "platform" => "web",
              "image_url" => "https://lazyweb.test/image.png?token=secret-token",
              "vision_description" => "Hero CTA pricing layout with mobile responsive hierarchy"
            },
            {
              "screenshot_id" => "#{query.hash.abs}-b",
              "company" => "Beta",
              "category" => "Developer Tools",
              "platform" => "web",
              "image_url" => "https://lazyweb.test/image2.png?access_token=secret-token",
              "vision_description" => "Dashboard onboarding layout with visual typography and decisive signup CTA"
            }
          ]) }]
        }
      }
    else
      flunk "unexpected MCP method #{payload.fetch("method")}"
    end
  end

  def run_aiweb(*args)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, AIWEB, *args.map(&:to_s))
    [stdout, stderr, status.exitstatus]
  end

  def run_aiweb_env(env, *args)
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, AIWEB, *args.map(&:to_s))
    [stdout, stderr, status.exitstatus]
  end

  def with_env_values(values)
    old = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

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

  def run_aiweb_with_env(env, *args)
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, AIWEB, *args.map(&:to_s))
    [stdout, stderr, status.exitstatus]
  end

  def write_fake_playwright_tooling(root)
    FileUtils.mkdir_p(File.join(root, "node_modules", ".bin"))
    write_fake_executable(
      File.join(root, "node_modules", ".bin"),
      "playwright",
      "echo local playwright shim >/dev/null"
    )

    bin_dir = File.join(root, "fake-bin")
    FileUtils.mkdir_p(bin_dir)
    write_fake_executable(
      bin_dir,
      "pnpm",
      <<~'SH'
        [ "$1" = "exec" ] || { echo "expected pnpm exec" >&2; exit 64; }
        [ "$2" = "playwright" ] || { echo "expected playwright" >&2; exit 64; }
        [ "$3" = "test" ] || { echo "expected test" >&2; exit 64; }
        case "$*" in
          *" --reporter=json"*) ;;
          *) echo "missing json reporter" >&2; exit 64 ;;
        esac
        if [ "${PLAYWRIGHT_FAKE_STATUS:-passed}" = "failed" ]; then
          echo '{"status":"failed","suites":[],"stats":{"expected":0,"unexpected":1,"flaky":0,"skipped":0}}'
          echo 'fake playwright failure' >&2
          exit 1
        fi
        echo '{"status":"passed","suites":[],"stats":{"expected":1,"unexpected":0,"flaky":0,"skipped":0}}'
        echo 'fake playwright pass' >&2
        exit 0
      SH
    )
    bin_dir
  end

  def write_fake_pr12_qa_tooling(root)
    write_fake_static_qa_tooling(root)
  end

  def write_fake_qa_screenshot_tooling(root)
    FileUtils.mkdir_p(File.join(root, "node_modules", ".bin"))
    write_fake_executable(
      File.join(root, "node_modules", ".bin"),
      "playwright",
      "echo local playwright shim >/dev/null"
    )

    bin_dir = File.join(root, "fake-screenshot-bin")
    FileUtils.mkdir_p(bin_dir)
    write_fake_executable(
      bin_dir,
      "pnpm",
      <<~'SH'
        [ "$1" = "exec" ] || { echo "expected pnpm exec" >&2; exit 64; }
        [ "$2" = "playwright" ] || { echo "expected playwright" >&2; exit 64; }
        shift 2
        wrote=0
        for arg in "$@"; do
          case "$arg" in
            *.png)
              mkdir -p "$(dirname "$arg")"
              printf 'fake screenshot for %s
' "$arg" > "$arg"
              wrote=1
              ;;
          esac
        done
        if [ "${QA_SCREENSHOT_FAKE_STATUS:-passed}" = "failed" ]; then
          echo 'fake screenshot failure' >&2
          exit 1
        fi
        [ "$wrote" = 1 ] || { echo "no png output path provided" >&2; exit 64; }
        echo 'fake screenshot pass' >&2
        exit 0
      SH
    )
    bin_dir
  end

  def write_fake_static_qa_tooling(root)
    FileUtils.mkdir_p(File.join(root, "node_modules", ".bin"))
    %w[axe lighthouse].each do |name|
      write_fake_executable(
        File.join(root, "node_modules", ".bin"),
        name,
        "echo local #{name} shim >/dev/null"
      )
    end

    bin_dir = File.join(root, "fake-static-qa-bin")
    FileUtils.mkdir_p(bin_dir)
    write_fake_executable(
      bin_dir,
      "pnpm",
      <<~'SH'
        [ "$1" = "exec" ] || { echo "expected pnpm exec" >&2; exit 64; }
        tool="$2"
        [ "$tool" = "axe" ] || [ "$tool" = "lighthouse" ] || { echo "unexpected qa tool $tool" >&2; exit 64; }
        status="${AIWEB_STATIC_QA_STATUS:-passed}"
        [ "$tool" = "axe" ] && status="${A11Y_FAKE_STATUS:-$status}"
        [ "$tool" = "lighthouse" ] && status="${LIGHTHOUSE_FAKE_STATUS:-$status}"
        if [ "$status" = "failed" ]; then
          echo "{\"tool\":\"$tool\",\"status\":\"failed\"}"
          echo "fake $tool failure" >&2
          exit 1
        fi
        echo "{\"tool\":\"$tool\",\"status\":\"passed\"}"
        echo "fake $tool pass" >&2
        exit 0
      SH
    )
    bin_dir
  end

  def run_webbuilder(*args, input: nil)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, WEBBUILDER, *args.map(&:to_s), stdin_data: input)
    [stdout, stderr, status.exitstatus]
  end

  def run_korean_webbuilder_env(env, *args)
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, KOREAN_WEBBUILDER, *args.map(&:to_s))
    [stdout, stderr, status.exitstatus]
  end

  def run_webbuilder_env(env, *args)
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, WEBBUILDER, *args.map(&:to_s))
    [stdout, stderr, status.exitstatus]
  end

  def json_cmd(*args)
    stdout, stderr, code = run_aiweb(*args, "--json")
    assert_equal "", stderr, "stderr should be empty for JSON command: #{stderr}"
    [JSON.parse(stdout), code]
  end

  def json_cmd_with_env(env, *args)
    stdout, stderr, code = run_aiweb_with_env(env, *args, "--json")
    assert_equal "", stderr, "stderr should be empty for JSON command: #{stderr}"
    [JSON.parse(stdout), code]
  end

  def mark_engine_run_scheduler_resume_candidate!(run_id)
    run_dir = File.join(".ai-web", "runs", run_id)
    [File.join(run_dir, "engine-run.json"), File.join(run_dir, "checkpoint.json"), File.join(run_dir, "lifecycle.json")].each do |path|
      payload = JSON.parse(File.read(path))
      payload["status"] = "running"
      File.write(path, JSON.pretty_generate(payload) + "\n")
    end
  end

  def test_extracted_backend_modules_load_with_expected_public_boundaries
    script = <<~'RUBY'
      require "aiweb"

      project_public = %i[
        runtime_plan setup build preview qa_playwright browser_qa qa_screenshot
        qa_a11y qa_lighthouse engine_run agent_run verify_loop
      ]
      missing_project_methods = project_public.reject { |method| Aiweb::Project.instance_methods.include?(method) }
      raise "missing Project methods: #{missing_project_methods.inspect}" unless missing_project_methods.empty?

      leaked_project_helpers = %i[setup_blocked_payload runtime_state_snapshot agent_run_source_paths]
        .select { |method| Aiweb::Project.public_instance_methods.include?(method) }
      raise "Project helpers leaked as public: #{leaked_project_helpers.inspect}" unless leaked_project_helpers.empty?

      leaked_cli_helpers = %i[dispatch emit_result exit_code_for human_result]
        .select { |method| Aiweb::CLI.public_instance_methods.include?(method) }
      raise "CLI helpers leaked as public: #{leaked_cli_helpers.inspect}" unless leaked_cli_helpers.empty?

      raise "missing daemon bridge" unless defined?(Aiweb::CodexCliBridge)
      raise "missing backend app" unless defined?(Aiweb::LocalBackendApp)
      raise "missing backend daemon" unless defined?(Aiweb::LocalBackendDaemon)
    RUBY

    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-I",
      File.join(REPO_ROOT, "lib"),
      "-e",
      script,
      chdir: REPO_ROOT
    )

    assert status.success?, "module load/visibility check failed\nstdout=#{stdout}\nstderr=#{stderr}"
  end

  def test_cli_dispatch_smoke_routes_extracted_runtime_and_agent_commands
    in_tmp do |dir|
      init_payload, init_code = json_cmd("--path", dir, "init")
      assert_equal 0, init_code
      assert_equal "initialized director workspace", init_payload["action_taken"]

      [
        [["runtime-plan"], "runtime_plan", "reported runtime plan", 1],
        [["setup", "--install", "--dry-run"], "setup", "setup install blocked", 1],
        [["build", "--dry-run"], "build", "scaffold build blocked", 1],
        [["preview", "--dry-run"], "preview", "scaffold preview blocked", 1],
        [["engine-run", "--goal", "smoke", "--dry-run"], "engine_run", "planned engine run", 0],
        [["agent-run", "--task", "latest", "--agent", "codex", "--dry-run"], "agent_run", "agent run blocked", 5]
      ].each do |args, payload_key, action_taken, expected_code|
        payload, code = json_cmd("--path", dir, *args)

        assert_equal expected_code, code, "unexpected exit code for #{args.join(" ")}"
        assert_equal action_taken, payload["action_taken"]
        assert payload[payload_key], "expected #{payload_key.inspect} payload for #{args.join(" ")}"
      end
    end
  end

  def write_human_baseline_corpus(path, fixture_id:, reviewer_count: 2, average_score: 92.5, secret_note: nil)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(
      path,
      JSON.pretty_generate(
        "schema_version" => 1,
        "corpus_metadata" => {
          "source" => "manual-human-review",
          "review_protocol" => "two reviewer fixture calibration",
          "reviewer_count" => [reviewer_count, 1].max
        },
        "fixtures" => {
          fixture_id => {
            "fixture_id" => fixture_id,
            "average_score" => average_score,
            "reviewer_count" => reviewer_count,
            "human_scores" => {
              "hierarchy" => 94,
              "spacing" => 91
            },
            "human_ratings" => [
              {
                "reviewer_id" => "reviewer-a",
                "overall_score" => average_score,
                "scores" => {
                  "hierarchy" => 94,
                  "spacing" => 91
                },
                "notes" => secret_note || "human visual review baseline"
              }
            ]
          }
        }
      )
    )
  end

  def test_eval_baseline_validate_records_redacted_human_calibration_evidence_without_importing
    in_tmp do |dir|
      _payload, code = json_cmd("--path", dir, "init")
      assert_equal 0, code
      fixture_id = "design-fixture-#{"a" * 16}"
      source = ".ai-web/eval/candidate-human-baselines.json"
      write_human_baseline_corpus(source, fixture_id: fixture_id)

      payload, code = json_cmd("eval-baseline", "validate", "--path", source)

      assert_equal 0, code, payload.inspect
      assert_equal "validated human eval baseline", payload["action_taken"]
      baseline = payload.fetch("eval_baseline")
      assert_equal "validated", baseline["status"]
      assert_equal "validate", baseline["action"]
      assert_equal 1, baseline["fixture_count"]
      assert_equal 1, baseline["calibrated_fixture_count"]
      assert_equal 0, baseline["invalid_fixture_count"]
      assert_equal [".ai-web/eval/human-baseline-validation.json"], payload["changed_files"]
      assert File.file?(".ai-web/eval/human-baseline-validation.json")
      refute File.exist?(".ai-web/eval/human-baselines.json"), "validate must not import the candidate corpus"

      artifact = JSON.parse(File.read(".ai-web/eval/human-baseline-validation.json"))
      assert_equal "validated", artifact["status"]
      assert_equal source, artifact["source_path"]
      assert_equal fixture_id, artifact.dig("fixtures", 0, "fixture_id")
      refute_match(Regexp.escape(dir), JSON.generate(artifact), "validation evidence must not leak absolute project paths")
    end
  end

  def test_eval_baseline_validate_records_multi_fixture_production_readiness
    in_tmp do |dir|
      _payload, code = json_cmd("--path", dir, "init")
      assert_equal 0, code
      source = ".ai-web/eval/candidate-human-baselines.json"
      FileUtils.mkdir_p(File.dirname(source))
      fixture_ids = ["design-fixture-#{"1" * 16}", "design-fixture-#{"2" * 16}"]
      fixtures = fixture_ids.to_h do |fixture_id|
        [fixture_id, {
          "fixture_id" => fixture_id,
          "average_score" => 91.5,
          "reviewer_count" => 2,
          "human_scores" => {
            "hierarchy" => 93,
            "spacing" => 90
          },
          "human_ratings" => [
            {
              "reviewer_id" => "human-reviewer-a",
              "overall_score" => 92,
              "scores" => { "hierarchy" => 94, "spacing" => 90 },
              "notes" => "reviewed fixture screenshot and browser evidence"
            },
            {
              "reviewer_id" => "human-reviewer-b",
              "overall_score" => 91,
              "scores" => { "hierarchy" => 92, "spacing" => 90 },
              "notes" => "independent human calibration"
            }
          ]
        }]
      end
      File.write(
        source,
        JSON.pretty_generate(
          "schema_version" => 1,
          "corpus_metadata" => {
            "source" => "manual-human-review",
            "collected_at" => "2026-05-17T00:00:00Z",
            "review_protocol" => "two independent human reviewers per fixture",
            "reviewer_count" => 2
          },
          "fixtures" => fixtures
        ) + "\n"
      )

      payload, code = json_cmd("eval-baseline", "validate", "--path", source)

      assert_equal 0, code, payload.inspect
      readiness = payload.dig("eval_baseline", "corpus_readiness")
      assert_equal "production_ready_multi_fixture", readiness.fetch("status")
      assert_equal true, readiness.fetch("production_ready")
      assert_equal 2, readiness.fetch("minimum_calibrated_fixture_count")
      assert_equal 2, readiness.fetch("calibrated_fixture_count")
      assert_equal 2, readiness.fetch("unique_reviewer_count")
      assert_equal %w[human-reviewer-a human-reviewer-b], readiness.fetch("reviewer_ids")
      artifact = JSON.parse(File.read(".ai-web/eval/human-baseline-validation.json"))
      assert_equal readiness, artifact.fetch("corpus_readiness")
    end
  end

  def test_eval_baseline_import_requires_approval_and_writes_target_when_approved
    in_tmp do |dir|
      _payload, code = json_cmd("--path", dir, "init")
      assert_equal 0, code
      fixture_id = "design-fixture-#{"b" * 16}"
      source = ".ai-web/eval/candidate-human-baselines.json"
      target = ".ai-web/eval/human-baselines.json"
      write_human_baseline_corpus(source, fixture_id: fixture_id)

      blocked_payload, blocked_code = json_cmd("eval-baseline", "import", "--path", source)
      assert_equal 5, blocked_code
      assert_equal "blocked", blocked_payload.dig("eval_baseline", "status")
      refute File.exist?(target), "unapproved import must not write target corpus"
      refute File.exist?(".ai-web/eval/human-baseline-validation.json"), "unapproved import must not write validation evidence"

      dry_payload, dry_code = json_cmd("eval-baseline", "import", "--path", source, "--approved", "--dry-run")
      assert_equal 0, dry_code
      assert_equal "dry_run", dry_payload.dig("eval_baseline", "status")
      refute File.exist?(target), "dry-run import must not write target corpus"

      payload, code = json_cmd("eval-baseline", "import", "--path", source, "--approved")
      assert_equal 0, code, payload.inspect
      assert_equal "imported", payload.dig("eval_baseline", "status")
      assert File.file?(target)
      assert File.file?(".ai-web/eval/human-baseline-validation.json")
      imported = JSON.parse(File.read(target))
      assert_equal 92.5, imported.dig("fixtures", fixture_id, "average_score")
      assert_equal 2, imported.dig("fixtures", fixture_id, "reviewer_count")
      readiness = payload.dig("eval_baseline", "corpus_readiness")
      assert_equal "calibrated_but_not_production_corpus", readiness.fetch("status")
      assert_equal false, readiness.fetch("production_ready")
      assert_match(/at least 2 calibrated fixtures/, readiness.fetch("blocking_issues").join("\n"))
    end
  end

  def test_eval_baseline_import_blocks_secret_or_uncalibrated_corpus_without_copy
    in_tmp do |dir|
      _payload, code = json_cmd("--path", dir, "init")
      assert_equal 0, code
      fixture_id = "design-fixture-#{"c" * 16}"
      source = ".ai-web/eval/candidate-human-baselines.json"
      secret = "AIWEB_TEST_API_KEY=fake-redaction-test-value"
      write_human_baseline_corpus(source, fixture_id: fixture_id, reviewer_count: 0, secret_note: secret)

      payload, code = json_cmd("eval-baseline", "import", "--path", source, "--approved")

      assert_equal 5, code
      assert_equal "blocked", payload.dig("eval_baseline", "status")
      issues = payload.fetch("blocking_issues").join("\n")
      assert_match(/secret|environment/i, issues)
      assert_match(/not human-calibrated|positive reviewer_count/i, issues)
      refute File.exist?(".ai-web/eval/human-baselines.json"), "blocked import must not write target corpus"
      refute_match(secret, JSON.generate(payload), "blocked payload must not echo raw secrets")
      assert File.file?(".ai-web/eval/human-baseline-validation.json")
      refute_match(secret, File.read(".ai-web/eval/human-baseline-validation.json"), "validation artifact must not echo raw secrets")
    end
  end

  def test_eval_baseline_review_pack_creates_placeholder_only_human_collection_packet
    in_tmp do |dir|
      _payload, code = json_cmd("--path", dir, "init")
      assert_equal 0, code
      fixture_id = "design-fixture-#{"d" * 16}"

      payload, code = json_cmd("eval-baseline", "review-pack", "--fixture-id", fixture_id)

      assert_equal 0, code, payload.inspect
      assert_equal "created human eval review pack", payload["action_taken"]
      baseline = payload.fetch("eval_baseline")
      assert_equal "created", baseline["status"]
      assert_equal "review-pack", baseline["action"]
      assert_equal ".ai-web/eval/human-review-pack.json", baseline["review_pack_path"]
      assert_equal ".ai-web/eval/candidate-human-baselines.json", baseline["candidate_path"]
      assert_equal [".ai-web/eval/human-review-pack.json"], payload["changed_files"]
      refute File.exist?(".ai-web/eval/human-baselines.json"), "review-pack must not import a human baseline"

      artifact = JSON.parse(File.read(".ai-web/eval/human-review-pack.json"))
      assert_equal "ready", artifact["status"]
      assert_equal fixture_id, artifact["fixture_id"]
      assert_equal false, artifact.dig("human_input_contract", "prepopulated_human_scores")
      assert_equal true, artifact.dig("anti_fabrication_policy", "requires_human_reviewer_evidence")
      assert_equal true, artifact.dig("anti_fabrication_policy", "agent_must_not_fill_scores")
      assert_includes artifact.dig("human_input_contract", "required_human_fields"), "fixtures.<fixture_id>.human_ratings[].reviewer_id"
      assert_equal "<human average 0..100>", artifact.dig("candidate_baseline_template", "fixtures", fixture_id, "average_score")
      assert_equal "<human reviewer id>", artifact.dig("candidate_baseline_template", "fixtures", fixture_id, "human_ratings", 0, "reviewer_id")
      refute_match(/reviewer-a|designer-1|92\.5/, JSON.generate(artifact), "review pack must not contain fabricated reviewer evidence or numeric human scores")
    end
  end

  def test_eval_baseline_review_pack_dry_run_writes_nothing_and_blocks_unsafe_output
    in_tmp do |dir|
      _payload, code = json_cmd("--path", dir, "init")
      assert_equal 0, code
      fixture_id = "design-fixture-#{"e" * 16}"

      dry_payload, dry_code = json_cmd("eval-baseline", "review-pack", "--fixture-id", fixture_id, "--output", ".ai-web/eval/custom-review-pack.json", "--dry-run")
      assert_equal 0, dry_code, dry_payload.inspect
      assert_equal "dry_run", dry_payload.dig("eval_baseline", "status")
      assert_equal ".ai-web/eval/custom-review-pack.json", dry_payload.dig("eval_baseline", "planned_review_pack_path")
      refute File.exist?(".ai-web/eval/custom-review-pack.json"), "dry-run review-pack must write nothing"

      blocked_payload, blocked_code = json_cmd("eval-baseline", "review-pack", "--fixture-id", fixture_id, "--output", ".ai-web/eval/human-baselines.json")
      assert_equal 5, blocked_code
      assert_equal "blocked", blocked_payload.dig("eval_baseline", "status")
      assert_match(/must not overwrite/i, blocked_payload.fetch("blocking_issues").join("\n"))
      refute File.exist?(".ai-web/eval/human-baselines.json"), "blocked review-pack must not overwrite the import target"
    end
  end

  def path_without_executable(executable)
    path_parts = ENV["PATH"].to_s.split(File::PATH_SEPARATOR)
    filtered = path_parts.select { |part| !File.exist?(File.join(part, executable)) }
    filtered.empty? ? ENV["PATH"] : filtered.join(File::PATH_SEPARATOR)
  end

  def write_registry_fixture(root)
    FileUtils.mkdir_p(File.join(root, "design-systems", "aurora"))
    File.write(
      File.join(root, "design-systems", "aurora", "metadata.json"),
      JSON.pretty_generate(
        "id" => "aurora",
        "title" => "Aurora Design System",
        "description" => "Editorial gradients and motion primitives"
      )
    )

    FileUtils.mkdir_p(File.join(root, "design-systems", "open-design"))
    File.write(
      File.join(root, "design-systems", "open-design", "DESIGN.md"),
      "# Open Design System\n\nOpen-design primitives for flexible site composition.\n"
    )

    FileUtils.mkdir_p(File.join(root, "skills", "conversion-copy"))
    File.write(
      File.join(root, "skills", "conversion-copy", "README.md"),
      "# Conversion Copy\n\nLanding-page persuasion patterns.\n"
    )

    FileUtils.mkdir_p(File.join(root, "skills", "premium-landing"))
    File.write(
      File.join(root, "skills", "premium-landing", "SKILL.md"),
      "# Premium Landing Skill\n\nHigh-end landing page structure and conversion patterns.\n"
    )

    FileUtils.mkdir_p(File.join(root, "craft"))
    File.write(
      File.join(root, "craft", "hero-pattern.md"),
      "# Hero Pattern\n\nAbove-the-fold composition recipe.\n"
    )
  end

  def expected_repo_registry_ids
    {
      "design-systems" => %w[conversion-saas local-service-trust luxury-editorial mobile-commerce],
      "skills" => %w[ecommerce-category-page premium-landing-page saas-product-page service-business-site],
      "craft" => %w[anti-ai-slop color spacing-responsive typography]
    }
  end

  def load_state
    YAML.load_file(".ai-web/state.yaml")
  end

  def write_state(state)
    File.write(".ai-web/state.yaml", YAML.dump(state))
  end

  def set_phase(phase)
    state = load_state
    state["phase"]["current"] = phase
    write_state(state)
  end

  def deploy_provenance_fixture(output_directory: "dist")
    {
      "schema_version" => 1,
      "captured_at" => Time.now.utc.iso8601,
      "workspace" => {
        "git" => {
          "available" => false,
          "commit_sha" => "unknown",
          "dirty" => nil,
          "status_sha256" => nil
        },
        "source" => hash_paths_fixture(%w[src public astro.config.mjs astro.config.js next.config.js next.config.mjs tsconfig.json tailwind.config.js tailwind.config.mjs vite.config.js vite.config.mjs], "source"),
        "package" => hash_paths_fixture(%w[package.json pnpm-lock.yaml package-lock.json yarn.lock bun.lockb], "package")
      },
      "output" => hash_paths_fixture([output_directory], "output").merge("directory" => output_directory),
      "tool_versions" => {
        "ruby" => RUBY_VERSION,
        "pnpm" => nil,
        "playwright" => nil,
        "axe" => nil,
        "lighthouse" => nil
      }
    }
  end

  def hash_paths_fixture(paths, label)
    files = Array(paths).flat_map { |path| hashable_files_fixture(path) }.uniq.sort
    digest = Digest::SHA256.new
    files.each do |path|
      digest.update("#{path}\0")
      digest.update(Digest::SHA256.file(path).hexdigest)
      digest.update("\0")
    end
    {
      "label" => label,
      "exists" => !files.empty?,
      "file_count" => files.length,
      "sha256" => files.empty? ? nil : digest.hexdigest
    }
  end

  def hashable_files_fixture(path)
    normalized = path.to_s.tr("\\", "/").sub(%r{\A(?:\./)+}, "")
    return [] if normalized.empty? || normalized.split("/").any? { |part| part.start_with?(".env") || %w[.git .ai-web node_modules].include?(part) }
    return [normalized] if File.file?(normalized)
    return [] unless File.directory?(normalized)

    Dir.glob(File.join(normalized, "**", "*"), File::FNM_DOTMATCH).select { |entry| File.file?(entry) }.map { |entry| entry.tr("\\", "/") }.reject do |entry|
      entry.split("/").any? { |part| part.start_with?(".env") || %w[.git .ai-web node_modules].include?(part) }
    end
  end

  def approve_quality_contract
    quality = YAML.load_file(".ai-web/quality.yaml")
    quality["quality"]["approved"] = true
    File.write(".ai-web/quality.yaml", YAML.dump(quality))
  end

  def append_open_failure(check_id: "F-QA", task_id: "golden", severity: "high", blocking: true)
    state = load_state
    state["qa"]["open_failures"] << {
      "id" => "#{check_id}-seed",
      "source_result" => ".ai-web/qa/results/seed.json",
      "check_id" => check_id,
      "task_id" => task_id,
      "severity" => severity,
      "blocking" => blocking,
      "accepted_risk_id" => nil
    }
    write_state(state)
  end

  def add_completed_tasks(*tasks)
    state = load_state
    state["implementation"]["completed_tasks"].concat(tasks)
    write_state(state)
  end

  def design_brief_sections(markdown)
    sections = {}
    current = nil
    markdown.each_line do |line|
      if (match = line.match(/\A## (.+?)\s*\z/))
        current = match[1]
        sections[current] = +""
      elsif current
        sections[current] << line
      end
    end
    sections.transform_values(&:strip)
  end


  def design_system_sections(markdown)
    sections = {}
    current = nil
    markdown.each_line do |line|
      if (match = line.match(/\A## (.+?)\s*\z/))
        current = match[1]
        sections[current] = +""
      elsif current
        sections[current] << line
      end
    end
    sections.transform_values(&:strip)
  end

  def assert_design_system_complete(markdown)
    required = [
      "Source Route",
      "Downstream Constraints",
      "First-view Obligations",
      "Component and Token Guardrails",
      "PR4 Design Brief",
      "Selected Design System: local-service-trust",
      "Relevant Craft Rules",
      "Candidate Generation Contract",
      "Implementation Contract"
    ]
    sections = design_system_sections(markdown)
    required.each do |section|
      assert sections.key?(section), "missing DESIGN.md section #{section.inspect}"
      refute_empty sections[section], "section #{section.inspect} must be non-empty"
    end
  end

  def assert_design_brief_complete(markdown)
    required = [
      "Product Type",
      "Audience",
      "Emotional Target",
      "Brand Adjectives",
      "Preferred Mood",
      "Non-preferred Mood",
      "Typography Direction",
      "Color Direction",
      "Layout Density",
      "Imagery/Icon Direction",
      "Motion Intensity",
      "First-view Obligations",
      "Forbidden Patterns",
      "Reference Research Intent",
      "Candidate Generation Instructions"
    ]
    sections = design_brief_sections(markdown)
    required.each do |section|
      assert sections.key?(section), "missing design brief section #{section.inspect}"
      refute_empty sections[section], "section #{section.inspect} must be non-empty"
    end
  end

  def test_init_profile_d_creates_director_workspace_without_app_scaffold
    in_tmp do
      payload, code = json_cmd("init", "--profile", "D")
      assert_equal 0, code
      assert_equal "phase-0", payload["current_phase"]
      assert File.exist?(".ai-web/state.yaml")
      assert File.exist?(".ai-web/intent.yaml")
      assert File.exist?(".ai-web/intent.schema.json")
      assert File.exist?(".ai-web/quality.yaml")
      assert File.exist?(".ai-web/qa/final-report.md")
      assert File.exist?(".ai-web/deploy.md")
      assert File.exist?(".ai-web/post-launch-backlog.md")
      assert File.exist?("AGENTS.md")
      assert File.exist?("DESIGN.md")
      assert_match(/Wrong Interpretations to Avoid/, File.read(".ai-web/product.md"))
      assert_match(/Wrong Interpretations to Avoid/, File.read(".ai-web/DESIGN.md"))
      assert_match(/Wrong Interpretations to Avoid/, File.read("DESIGN.md"))
      refute File.exist?("package.json"), "init must not scaffold app code"

      state = load_state
      assert_equal "D", state.dig("implementation", "stack_profile")
      assert_match(/Astro \+ MDX\/Content Collections \+ Cloudflare Pages \+ Tailwind \+ sitemap\/RSS/, state.dig("implementation", "scaffold_target"))
      assert_equal "subscription_usage", state.dig("budget", "cost_mode")
      assert_equal 10, state.dig("budget", "max_design_candidates")
      assert_equal 60, state.dig("budget", "max_qa_runtime_minutes")
      assert_equal "opportunistic", state.dig("research", "design_research", "policy")
      assert_equal "lazyweb", state.dig("research", "design_research", "provider")
      assert_equal ".ai-web/design-reference-brief.md", state.dig("research", "design_research", "reference_brief_path")
      assert_equal ".ai-web/research/lazyweb/results.json", state.dig("artifacts", "design_reference_results", "path")
      assert_equal false, state.dig("adapters", "implementation_agent", "network_allowed")
      assert_equal [], state.dig("adapters", "implementation_agent", "mcp_servers_allowed")
      assert_equal true, state.dig("adapters", "design_research", "network_allowed")
      assert_equal ["lazyweb"], state.dig("adapters", "design_research", "mcp_servers_allowed")
      assert_equal false, state.dig("adapters", "design_research", "token_storage_allowed_in_repo")
    end
  end

  def test_status_upgrades_research_contract_defaults_for_existing_state
    in_tmp do
      _payload, code = json_cmd("init", "--profile", "D")
      assert_equal 0, code

      state = load_state
      state.delete("research")
      state["artifacts"].delete("design_reference_brief")
      state["artifacts"].delete("design_reference_results")
      state["artifacts"].delete("design_pattern_matrix")
      state["adapters"].delete("design_research")
      write_state(state)

      payload, status_code = json_cmd("status")
      assert_equal 0, status_code
      refute payload.key?("validation_errors"), payload["validation_errors"].inspect
      refute_includes payload["blocking_issues"].join("\n"), "state validation failed"
    end
  end

  def test_design_research_with_configured_lazyweb_writes_artifacts_and_updates_state
    with_fake_lazyweb_mcp_server do |endpoint, received|
      in_tmp do
        _payload, code = json_cmd("init", "--profile", "D")
        assert_equal 0, code
        _payload, code = json_cmd("interview", "--idea", "developer API monitoring SaaS")
        assert_equal 0, code

        state = load_state
        state["adapters"]["design_research"]["endpoint"] = endpoint
        write_state(state)

        payload, research_code = json_cmd_with_env({ "LAZYWEB_MCP_TOKEN" => "secret-token" }, "design-research", "--provider", "lazyweb", "--limit", "5", "--force")

        assert_equal 0, research_code, payload.inspect
        assert_equal "completed design research", payload["action_taken"]
        assert_includes payload["changed_files"], ".ai-web/design-reference-brief.md"
        assert_includes payload["changed_files"], ".ai-web/research/lazyweb/results.json"
        assert_includes payload["changed_files"], ".ai-web/research/lazyweb/pattern-matrix.md"
        assert_includes payload["changed_files"], ".ai-web/research/lazyweb/latest.json"
        assert_includes payload["changed_files"], ".ai-web/state.yaml"
        assert_equal "ready", payload.dig("design_research", "status")
        assert_equal true, payload.dig("design_research", "token_configured")
        assert_operator payload.dig("design_research", "accepted_references"), :>, 0

        state = load_state
        assert_equal "ready", state.dig("research", "design_research", "status")
        assert_nil state.dig("research", "design_research", "skipped_reason")
        assert_equal "draft", state.dig("artifacts", "design_reference_brief", "status")
        assert_equal "draft", state.dig("artifacts", "design_reference_results", "status")
        assert_equal "draft", state.dig("artifacts", "design_pattern_matrix", "status")

        results_json = File.read(".ai-web/research/lazyweb/results.json")
        refute_includes results_json, "secret-token"
        assert_includes File.read(".ai-web/design-reference-brief.md"), "Reference-backed Pattern Constraints"
        assert received.any? { |request| request.fetch("authorization") == "Bearer secret-token" }
      end
    end
  end

  def test_registry_list_commands_scan_repo_root_directories_as_json
    in_tmp do |dir|
      write_registry_fixture(dir)

      payload, code = json_cmd("--path", dir, "design-systems", "list")
      assert_equal 0, code
      assert_equal "design-systems", payload.dig("registry", "name")
      assert_equal true, payload.dig("registry", "exists")
      assert_equal 2, payload.dig("registry", "count")
      aurora_item = payload.dig("registry", "items").find { |item| item["id"] == "aurora" }
      assert_equal(
        {
          "id" => "aurora",
          "title" => "Aurora Design System",
          "description" => "Editorial gradients and motion primitives",
          "path" => "design-systems/aurora",
          "kind" => "directory",
          "metadata_path" => "design-systems/aurora/metadata.json"
        },
        aurora_item
      )
      open_design_item = payload.dig("registry", "items").find { |item| item["id"] == "open-design" }
      assert_equal "Open Design System", open_design_item["title"]
      assert_equal "Open-design primitives for flexible site composition.", open_design_item["description"]
      assert_equal "design-systems/open-design/DESIGN.md", open_design_item["metadata_path"]

      skills_payload, skills_code = json_cmd("--path", dir, "skills", "list")
      assert_equal 0, skills_code
      conversion_item = skills_payload.dig("registry", "items").find { |item| item["id"] == "conversion-copy" }
      assert_equal "Conversion Copy", conversion_item["title"]
      assert_equal "Landing-page persuasion patterns.", conversion_item["description"]
      premium_item = skills_payload.dig("registry", "items").find { |item| item["id"] == "premium-landing" }
      assert_equal "Premium Landing Skill", premium_item["title"]
      assert_equal "High-end landing page structure and conversion patterns.", premium_item["description"]
      assert_equal "skills/premium-landing/SKILL.md", premium_item["metadata_path"]

      craft_payload, craft_code = json_cmd("--path", dir, "craft", "list")
      assert_equal 0, craft_code
      assert_equal "hero-pattern", craft_payload.dig("registry", "items", 0, "id")
      assert_equal "Hero Pattern", craft_payload.dig("registry", "items", 0, "title")
    end
  end

  def test_registry_list_commands_emit_human_output_and_handle_missing_directories
    in_tmp do |dir|
      write_registry_fixture(dir)

      stdout, stderr, code = run_aiweb("--path", dir, "design-systems", "list")
      assert_equal 0, code
      assert_equal "", stderr
      assert_match(/Design systems \(2\)/, stdout)
      assert_match(/aurora: Aurora Design System/, stdout)
      assert_match(%r{design-systems/aurora}, stdout)

      missing_stdout, missing_stderr, missing_code = run_aiweb("--path", dir, "unknown-registry", "list")
      assert_equal 1, missing_code
      assert_equal "", missing_stdout
      assert_match(/unknown command/, missing_stderr)

      empty_dir = File.join(dir, "empty")
      FileUtils.mkdir_p(empty_dir)
      empty_payload, empty_code = json_cmd("--path", empty_dir, "craft", "list")
      assert_equal 0, empty_code
      assert_equal false, empty_payload.dig("registry", "exists")
      assert_equal ["craft"], empty_payload["missing_artifacts"]
    end
  end

  def test_registry_list_commands_are_ready_for_repo_assets_when_present
    expected_repo_registry_ids.each do |command, expected_ids|
      payload, code = json_cmd("--path", REPO_ROOT, command, "list")

      assert_equal 0, code
      assert_empty payload["validation_errors"]
      assert_equal command, payload.dig("registry", "directory")
      assert_equal expected_ids.length, payload.dig("registry", "count")
      assert_equal expected_ids, payload.dig("registry", "items").map { |item| item["id"] }
      payload.dig("registry", "items").each do |item|
        assert item["title"].to_s.length >= 8, "#{item["id"]} should ship a descriptive title"
        assert item["description"].to_s.length >= 40, "#{item["id"]} should ship non-thin metadata"
        assert item["metadata_path"].to_s.length.positive?, "#{item["id"]} should expose a metadata source"
        assert File.exist?(File.join(REPO_ROOT, item["path"]))
      end
    end
  end

  def test_registry_list_reports_invalid_structured_metadata
    in_tmp do |dir|
      FileUtils.mkdir_p(File.join(dir, "design-systems", "broken-json"))
      File.write(File.join(dir, "design-systems", "broken-json", "metadata.json"), "{ broken json")

      payload, code = json_cmd("--path", dir, "design-systems", "list")
      assert_equal 5, code
      assert payload["validation_errors"].any? { |error| error.include?("design-systems/broken-json/metadata.json") && error.include?("invalid JSON") }
      assert payload["warnings"].any? { |warning| warning.include?("metadata could not be loaded") }
      assert_match(/registry metadata validation failed/, payload["blocking_issues"].join("\n"))
      assert_equal "broken-json", payload.dig("registry", "items", 0, "id")

      FileUtils.mkdir_p(File.join(dir, "skills", "broken-yaml"))
      File.write(File.join(dir, "skills", "broken-yaml", "metadata.yml"), "id: [unterminated")

      yaml_payload, yaml_code = json_cmd("--path", dir, "skills", "list")
      assert_equal 1, yaml_code
      assert yaml_payload["validation_errors"].any? { |error| error.include?("skills/broken-yaml/metadata.yml") && error.include?("invalid YAML") }
      assert yaml_payload["warnings"].any? { |warning| warning.include?("metadata could not be loaded") }
    end
  end

  def test_registry_list_rejects_extra_positional_arguments
    in_tmp do |dir|
      write_registry_fixture(dir)

      payload, code = json_cmd("--path", dir, "design-systems", "list", "extra")
      refute_equal 0, code
      assert_match(/does not accept extra positional arguments: extra/, payload.dig("error", "message"))
    end
  end

  def test_start_preserves_chat_assistant_intent_as_app_not_landing_page
    in_tmp do |dir|
      target = File.join(dir, "jubi-assistant")

      payload, code = json_cmd(
        "start",
        "--path", target,
        "--idea", "Jubi conversational stock assistant for domestic stock investors"
      )

      assert_equal 0, code
      assert_includes payload["changed_files"], ".ai-web/intent.yaml"

      intent = YAML.load_file(File.join(target, ".ai-web", "intent.yaml"))
      assert_equal "Jubi conversational stock assistant for domestic stock investors", intent["original_intent"]
      assert_equal "chat-assistant-webapp", intent["archetype"]
      assert_equal "app", intent["surface"]
      assert_equal "landing-page", intent["not_surface"]
      assert_includes intent["must_have_first_view"], "chat_input"
      assert_includes intent["must_have_first_view"], "stock_status_panel"
      assert_includes intent["must_not_have"], "landing_page_hero_as_primary_experience"
    end
  end

  def test_start_creates_target_project_interviews_and_advances_to_quality_gate
    in_tmp do |dir|
      target = File.join(dir, "dogfood-cafe")

      payload, code = json_cmd(
        "start",
        "--path", target,
        "--idea", "cozy local cafe website"
      )

      assert_equal 0, code
      assert_equal "phase-0.25", payload["current_phase"]
      assert_equal "started director workspace and advanced to quality gate", payload["action_taken"]
      assert_match(/quality\.approved/, payload["next_action"])
      assert_includes payload["start_steps"], "aiweb init --profile B"
      assert File.exist?(File.join(target, ".ai-web", "state.yaml"))
      assert File.exist?(File.join(target, ".ai-web", "project.md"))
      assert_match(/Wrong interpretations to avoid/, File.read(File.join(target, ".ai-web", "product.md")))
      assert_match(/generic landing page/, File.read(File.join(target, ".ai-web", "product.md")))
      refute File.exist?(File.join(target, "package.json")), "start must not scaffold app code"

      state = YAML.load_file(File.join(target, ".ai-web", "state.yaml"))
      assert_equal "B", state.dig("implementation", "stack_profile")
      assert_match(/./m, File.read(File.join(target, ".ai-web", "project.md")))
    end
  end

  def test_start_uses_router_profile_unless_explicit_profile_is_given
    in_tmp do |dir|
      auto_target = File.join(dir, "auto-profile")
      _payload, auto_code = json_cmd(
        "start",
        "--path", auto_target,
        "--idea", "SaaS login portal for regulated medical account payments",
        "--no-advance"
      )
      assert_equal 0, auto_code
      auto_state = YAML.load_file(File.join(auto_target, ".ai-web", "state.yaml"))
      assert_equal "A", auto_state.dig("implementation", "stack_profile")

      explicit_target = File.join(dir, "explicit-profile")
      _explicit_payload, explicit_code = json_cmd(
        "start",
        "--path", explicit_target,
        "--profile", "D",
        "--idea", "SaaS login portal for regulated medical account payments",
        "--no-advance"
      )
      assert_equal 0, explicit_code
      explicit_state = YAML.load_file(File.join(explicit_target, ".ai-web", "state.yaml"))
      assert_equal "D", explicit_state.dig("implementation", "stack_profile")
    end
  end

  def test_start_dry_run_does_not_create_target_directory
    in_tmp do |dir|
      target = File.join(dir, "dry-run-cafe")

      stdout, stderr, code = run_aiweb(
        "start",
        "--path", target,
        "--idea", "dry-run cafe website",
        "--dry-run",
        "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal "planned director start", payload["action_taken"]
      assert_equal true, payload["dry_run"]
      assert_match(/would create/, payload["next_action"])
      refute Dir.exist?(target)
    end
  end

  def test_start_requires_idea
    in_tmp do |dir|
      payload, code = json_cmd("start", "--path", File.join(dir, "missing-idea"))

      refute_equal 0, code
      assert_match(/start requires --idea/, payload.dig("error", "message"))
      refute Dir.exist?(File.join(dir, "missing-idea"))
    end
  end

  def test_global_path_runs_followup_commands_against_target_project
    in_tmp do |dir|
      target = File.join(dir, "path-target")
      start_payload, start_code = json_cmd("start", "--path", target, "--idea", "neighborhood hospital website")
      assert_equal 0, start_code
      assert_equal "phase-0.25", start_payload["current_phase"]

      status_stdout, status_stderr, status_code = run_aiweb("--path", target, "status", "--json")
      status_payload = JSON.parse(status_stdout)
      assert_equal 0, status_code
      assert_equal "", status_stderr
      assert_equal "phase-0.25", status_payload["current_phase"]

      dry_run_stdout, dry_run_stderr, dry_run_code = run_aiweb("--path=#{target}", "advance", "--dry-run", "--json")
      dry_run_payload = JSON.parse(dry_run_stdout)
      assert_equal 2, dry_run_code
      assert_equal "", dry_run_stderr
      assert_match(/quality contract.*approved/i, dry_run_payload["blocking_issues"].join("\n"))
    end
  end

  def test_webbuilder_direct_idea_starts_from_zero
    in_tmp do |dir|
      target = File.join(dir, "webbuilder-cafe")

      stdout, stderr, code = run_webbuilder("--path", target, "--json", "cozy cafe website")
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal "phase-0.25", payload["current_phase"]
      assert File.exist?(File.join(target, ".ai-web", "state.yaml"))
      state = YAML.load_file(File.join(target, ".ai-web", "state.yaml"))
      assert_equal "B", state.dig("implementation", "stack_profile")
      refute File.exist?(File.join(target, "package.json"))
    end
  end

  def test_webbuilder_interactive_launcher_collects_idea_path_profile_and_advance
    in_tmp do |dir|
      target = File.join(dir, "interactive-cafe")
      input = [
        "neighborhood cafe website",
        target,
        "D",
        "Y"
      ].join("\n") + "\n"

      stdout, stderr, code = run_webbuilder(input: input)

      assert_equal 0, code
      assert_equal "", stderr
      assert_match(/./m, stdout)
      assert_match(/./m, stdout)
      assert File.exist?(File.join(target, ".ai-web", "state.yaml"))
      state = YAML.load_file(File.join(target, ".ai-web", "state.yaml"))
      assert_equal "phase-0.25", state.dig("phase", "current")
    end
  end

  def test_webbuilder_passthrough_commands_use_aiweb_engine
    in_tmp do |dir|
      target = File.join(dir, "passthrough-cafe")
      _payload, start_code = json_cmd("start", "--path", target, "--idea", "neighborhood cafe website")
      assert_equal 0, start_code

      stdout, stderr, code = run_webbuilder("--path", target, "status", "--json")
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal "phase-0.25", payload["current_phase"]

      write_registry_fixture(target)
      registry_stdout, registry_stderr, registry_code = run_webbuilder("--path", target, "design-systems", "list", "--json")
      registry_payload = JSON.parse(registry_stdout)

      assert_equal 0, registry_code
      assert_equal "", registry_stderr
      assert_equal "design-systems", registry_payload.dig("registry", "name")
      assert_equal "Open Design System", registry_payload.dig("registry", "items").find { |item| item["id"] == "open-design" }["title"]
    end
  end

  def test_webbuilder_help_explains_zero_start_workflow
    stdout, stderr, code = run_webbuilder("--help")

    assert_equal 0, code
    assert_equal "", stderr
    assert_match(/./m, stdout)
    assert_match(/Phase 0/, stdout)
    assert_match(/./m, stdout)
  end

  def test_webbuilder_version_passes_through_to_aiweb
    stdout, stderr, code = run_webbuilder("--version")

    assert_equal 0, code
    assert_equal "", stderr
    assert_match(/aiweb \d+\.\d+\.\d+/, stdout)
  end

  def test_init_dry_run_writes_nothing_and_outputs_planned_changes
    in_tmp do
      payload, code = json_cmd("init", "--profile", "D", "--dry-run")
      assert_equal 0, code
      refute File.exist?(".ai-web")
      assert_includes payload["changed_files"], ".ai-web/state.yaml"
      assert_includes payload["changed_files"], ".ai-web/intent.yaml"
      assert_includes payload["changed_files"], ".ai-web/intent.schema.json"
      assert_equal true, payload["dry_run"]
    end
  end


  def test_interview_detects_basic_archetypes_and_writes_first_view_contract
    cases = {
      "AI chat assistant for domestic stock questions" => "chat-assistant-webapp",
      "Operations dashboard for warehouse metrics" => "dashboard",
      "Invoice calculator tool for freelancers" => "tool",
      "Online shop commerce site for handmade tea" => "commerce",
      "Playable browser game with score" => "game",
      "Landing page for a neighborhood yoga studio" => "landing-page"
    }

    cases.each do |idea, expected_archetype|
      in_tmp do
        json_cmd("init", "--profile", "D")
        payload, code = json_cmd("interview", "--idea", idea)

        assert_equal 0, code
        assert_includes payload["changed_files"], ".ai-web/intent.yaml"
        assert_includes payload["changed_files"], ".ai-web/first-view-contract.md"

        intent = YAML.load_file(".ai-web/intent.yaml")
        assert_equal expected_archetype, intent["archetype"]
        refute_empty intent["must_have_first_view"]
        assert_match(/#{Regexp.escape(expected_archetype)}/, File.read(".ai-web/first-view-contract.md"))
      end
    end
  end

  def test_chat_assistant_qa_checklist_rejects_landing_page_first_screen
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "Jubi chat-style domestic stock assistant")
      set_phase("phase-10")

      payload, code = json_cmd("qa-checklist")
      assert_equal 0, code
      assert_includes payload["changed_files"], ".ai-web/qa/current-checklist.md"

      checklist = File.read(".ai-web/qa/current-checklist.md")
      assert_match(/chat input/i, checklist)
      assert_match(/not landing-page/i, checklist)
      assert_match(/first-view-contract/, checklist)
    end
  end

  def test_status_json_reports_validation_error_for_unknown_top_level_key
    in_tmp do
      json_cmd("init")
      state = load_state
      state["unexpected"] = true
      write_state(state)

      payload, code = json_cmd("status")
      refute_equal 0, code
      assert payload["validation_errors"].any? { |error| error.include?("unknown top-level") }
      assert_match(/repair/, payload["next_action"])
    end
  end

  def test_interview_then_advance_phase_zero
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "local cafe website")
      payload, code = json_cmd("advance")
      assert_equal 0, code
      assert_equal "phase-0.25", payload["current_phase"]
      assert_empty payload["blocking_issues"]
    end
  end

  def test_interview_product_artifact_names_safety_mocked_blocked_excluded_scope
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "주비?? conversational domestic stock assistant")

      product = File.read(".ai-web/product.md")
      assert_match(/Mocked \/ blocked \/ excluded for safety/, product)
      assert_match(/Mocked: external account data/, product)
      assert_match(/Locked\/preview only: order, payment, or broker actions/, product)
      assert_match(/Blocked: credential collection, real account tokens, approval keys.*real order execution/, product)
      assert_match(/Excluded: medical, legal, financial, investment/, product)
    end
  end

  def test_phase_3_5_blocks_with_one_candidate_pending_gate_and_missing_selection
    in_tmp do
      json_cmd("init")
      set_phase("phase-3.5")
      json_cmd("ingest-design", "--title", "Candidate one")

      payload, code = json_cmd("advance")
      assert_equal 2, code
      joined = payload["blocking_issues"].join("\n")
      assert_match(/design candidates must be >= 2/, joined)
      assert_match(/selected design candidate is required/, joined)
      assert_match(/Gate 2 design approval is pending/, joined)
    end
  end

  def test_ingest_design_enforces_cap_of_ten_candidates
    in_tmp do
      json_cmd("init")
      set_phase("phase-3.5")
      10.times do |i|
        _payload, code = json_cmd("ingest-design", "--title", "Candidate #{i + 1}")
        assert_equal 0, code
      end
      payload, code = json_cmd("ingest-design", "--title", "Candidate 11")
      assert_equal 3, code
      assert_match(/candidate cap reached/, payload.dig("error", "message"))

      update_payload, update_code = json_cmd("ingest-design", "--id", "candidate-01", "--title", "Candidate 1 update")
      assert_equal 0, update_code
      assert_match(/candidate-01/, update_payload["action_taken"])

      custom_payload, custom_code = json_cmd("ingest-design", "--id", "custom-11", "--title", "Custom 11")
      assert_equal 3, custom_code
      assert_match(/candidate cap reached/, custom_payload.dig("error", "message"))
    end
  end

  def test_ingest_reference_dry_run_plans_reference_brief_without_writing
    in_tmp do
      json_cmd("init", "--profile", "D")
      set_phase("phase-3")

      payload, code = json_cmd("ingest-reference", "--type", "gpt-image-2", "--title", "Moody hero", "--source", "gpt-image-2://local-output", "--notes", "large editorial hero with layered cards", "--dry-run")

      assert_equal 0, code
      assert_equal true, payload["dry_run"]
      assert_equal "ingested gpt-image-2 reference", payload["action_taken"]
      assert_includes payload["changed_files"], ".ai-web/design-reference-brief.md"
      refute File.exist?(".ai-web/design-reference-brief.md")
      assert_equal true, payload.dig("reference_ingestion", "pattern_constraints_only")
      assert payload.dig("reference_ingestion", "no_copy_guardrails").any? { |guardrail| guardrail.match?(/Do not reproduce exact screenshot layout/i) }
    end
  end

  def test_ingest_reference_writes_pattern_only_no_copy_brief_and_state
    in_tmp do
      json_cmd("init", "--profile", "D")
      set_phase("phase-3.5")

      payload, code = json_cmd("ingest-reference", "--type", "image", "--title", "Reference dashboard", "--source", "references/dashboard.png", "--notes", "Dense KPI header\nCard grid rhythm")

      assert_equal 0, code
      assert_includes payload["changed_files"], ".ai-web/design-reference-brief.md"
      assert_includes payload["changed_files"], ".ai-web/state.yaml"

      brief = File.read(".ai-web/design-reference-brief.md")
      assert_match(/Reference dashboard/, brief)
      assert_match(/Interpret as pattern constraint: Dense KPI header/, brief)
      assert_match(/pattern evidence only/i, brief)
      assert_match(/not implementation source/i, brief)
      assert_match(/Do not reproduce exact screenshot layout, visual asset, copy, prices, logos, trademarks/i, brief)

      state = load_state
      assert_equal "lazyweb", state.dig("research", "design_research", "provider"), "manual reference ingestion must not disable the Lazyweb research adapter"
      assert_equal "ready", state.dig("research", "design_research", "status")
      refute state.dig("research", "reference_ingestion"), "manual reference metadata must stay schema-compatible"
      assert_equal "draft", state.dig("artifacts", "design_reference_brief", "status")
    end
  end

  def test_ingest_reference_rejects_env_and_secret_paths_without_reading_secret
    [".env", "nested/.env.local/ref.png", "secrets/reference.png", "config/credentials.yml"].each do |forbidden_path|
      in_tmp do
        json_cmd("init", "--profile", "D")
        set_phase("phase-3")
        File.write(".env", "SECRET=do-not-print\n")

        stdout, stderr, code = run_aiweb("ingest-reference", "--source", forbidden_path, "--notes", "safe notes", "--json")
        payload = JSON.parse(stdout)

        assert_equal 1, code, forbidden_path
        assert_equal "", stderr, forbidden_path
        assert_match(/\.env|secret/i, payload.dig("error", "message"), forbidden_path)
        refute_includes stdout, "do-not-print", forbidden_path
        refute File.exist?(".ai-web/design-reference-brief.md"), forbidden_path
        assert_equal "SECRET=do-not-print\n", File.read(".env"), forbidden_path
      end
    end
  end

  def test_qa_timeout_creates_failure_and_fix_packet
    in_tmp do
      json_cmd("init")
      set_phase("phase-10")
      payload, code = json_cmd("qa-report", "--status", "failed", "--task-id", "golden", "--duration-minutes", "61")
      assert_equal 0, code
      failure = payload["open_failures"].find { |item| item["check_id"] == "F-QA-TIMEOUT" }
      refute_nil failure
      fix = payload["changed_files"].find { |path| path.include?("fix-F-QA-TIMEOUT") }
      refute_nil fix
      assert_match(/Timeout recovery loop/, File.read(fix))

      state = load_state
      assert_equal "F-QA-TIMEOUT", state.dig("qa", "open_failures", 0, "check_id")

      status_payload, status_code = json_cmd("status")
      assert_equal 0, status_code
      assert_nil status_payload["validation_errors"]
    end
  end

  def test_qa_timeout_recovery_cap_blocks_before_new_failure_or_fix_packet
    in_tmp do
      json_cmd("init")
      set_phase("phase-10")
      state = load_state
      state["budget"]["max_qa_timeout_recovery_cycles"] = 2
      state["qa"]["open_failures"] = 2.times.map do |index|
        {
          "id" => "F-QA-TIMEOUT-seed-#{index + 1}",
          "source_result" => ".ai-web/qa/results/seed-#{index + 1}.json",
          "check_id" => "F-QA-TIMEOUT",
          "task_id" => "golden",
          "severity" => "high",
          "blocking" => true,
          "accepted_risk_id" => nil
        }
      end
      write_state(state)

      before_state = File.read(".ai-web/state.yaml")
      before_fix_packets = Dir.glob(".ai-web/tasks/fix-F-QA-TIMEOUT*")
      payload, code = json_cmd("qa-report", "--status", "failed", "--task-id", "golden", "--duration-minutes", "61")

      assert_equal 3, code
      assert_match(/timeout recovery budget exceeded/i, payload.dig("error", "message"))
      assert_equal before_state, File.read(".ai-web/state.yaml")
      assert_equal before_fix_packets, Dir.glob(".ai-web/tasks/fix-F-QA-TIMEOUT*")
      assert_empty Dir.glob(".ai-web/qa/results/*.json")
    end
  end

  def test_qa_report_rejects_env_from_paths_without_reading_or_printing_secret
    [".env", ".env/qa.json", "nested/.env.local/qa.json"].each do |forbidden_path|
      in_tmp do
        json_cmd("init")
        set_phase("phase-10")
        File.write(".env", "SECRET=do-not-print\n")
        FileUtils.mkdir_p(File.dirname(forbidden_path)) unless File.dirname(forbidden_path) == "." || File.exist?(File.dirname(forbidden_path))
        File.write(forbidden_path, JSON.pretty_generate(valid_qa_result.merge("notes" => "SECRET=do-not-print"))) if forbidden_path.include?("/") && File.dirname(forbidden_path) != ".env"

        stdout, stderr, code = run_aiweb("qa-report", "--from", forbidden_path, "--json")
        payload = JSON.parse(stdout)

        assert_equal 1, code, forbidden_path
        assert_equal "", stderr, forbidden_path
        assert_match(/\.env|unsafe|refus/i, payload.dig("error", "message"), forbidden_path)
        refute_includes stdout, "do-not-print", forbidden_path
        assert_equal "SECRET=do-not-print\n", File.read(".env"), forbidden_path
        assert_empty Dir.glob(".ai-web/qa/results/*.json"), forbidden_path
      end
    end
  end

  def test_qa_report_rejects_invalid_nested_schema
    in_tmp do
      json_cmd("init")
      set_phase("phase-10")
      invalid = valid_qa_result.merge(
        "checks" => [
          {
            "id" => "broken",
            "category" => "accessibility",
            "severity" => "urgent",
            "status" => "failed",
            "expected" => "valid severity",
            "actual" => "urgent",
            "evidence" => [],
            "notes" => "",
            "accepted_risk_id" => nil
          }
        ]
      )
      File.write("invalid-qa.json", JSON.pretty_generate(invalid))
      payload, code = json_cmd("qa-report", "--from", "invalid-qa.json")
      refute_equal 0, code
      assert_match(/QA result schema failed/, payload.dig("error", "message"))
      assert_empty Dir.glob(".ai-web/qa/results/*.json")
    end
  end

  def test_passed_top_level_with_failed_critical_check_creates_open_failure
    in_tmp do
      json_cmd("init")
      set_phase("phase-10")
      result = valid_qa_result.merge(
        "status" => "passed",
        "recommended_action" => "advance",
        "checks" => [
          {
            "id" => "hero-visible",
            "category" => "content",
            "severity" => "critical",
            "status" => "failed",
            "expected" => "Hero CTA visible",
            "actual" => "CTA missing",
            "evidence" => ["screenshots/mobile.png"],
            "notes" => "",
            "accepted_risk_id" => nil
          }
        ]
      )
      File.write("qa-critical.json", JSON.pretty_generate(result))
      payload, code = json_cmd("qa-report", "--from", "qa-critical.json")
      assert_equal 0, code
      failure = payload["open_failures"].find { |item| item["check_id"] == "hero-visible" }
      refute_nil failure
      assert_equal "critical", failure["severity"]
      assert_equal true, failure["blocking"]
    end
  end



  def test_repair_uninitialized_returns_json_error_without_creating_workspace
    in_tmp do
      stdout, stderr, code = run_aiweb("repair", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "error", payload["status"]
      assert_match(/init|initialized|workspace/i, payload.dig("error", "message"))
      refute Dir.exist?(".ai-web")
    end
  end

  def test_repair_dry_run_from_latest_failed_qa_plans_bounded_loop_without_writes
    in_tmp do
      json_cmd("init")
      set_phase("phase-10")
      FileUtils.mkdir_p("src")
      File.write("src/app.js", "console.log('before repair');\n")
      File.write(".env", "SECRET=do-not-touch\n")
      _qa_payload, qa_code = json_cmd("qa-report", "--status", "failed", "--task-id", "golden")
      assert_equal 0, qa_code

      before_state = File.read(".ai-web/state.yaml")
      before_source = File.read("src/app.js")
      before_env = File.read(".env")
      payload, code = json_cmd("repair", "--from-qa", "latest", "--dry-run")

      assert_equal 0, code
      assert_equal true, payload["dry_run"]
      repair_loop = payload.fetch("repair_loop")
      assert_equal true, repair_loop["dry_run"]
      assert_includes %w[planned ready], repair_loop["status"]
      assert_match(%r{\.ai-web/snapshots/}, repair_loop.fetch("planned_snapshot_path"))
      assert_match(%r{\.ai-web/repairs/}, repair_loop.fetch("planned_repair_record_path"))
      assert_match(%r{\.ai-web/tasks/fix-}, repair_loop.fetch("planned_fix_task_path"))
      assert_equal before_state, File.read(".ai-web/state.yaml")
      assert_equal before_source, File.read("src/app.js")
      assert_equal before_env, File.read(".env")
      assert_empty Dir.glob(".ai-web/repairs/*.json")
      assert_empty Dir.glob(".ai-web/snapshots/*")
    end
  end

  def test_repair_from_latest_failed_qa_creates_record_snapshot_and_current_fix_task_without_source_patch
    in_tmp do
      json_cmd("init")
      set_phase("phase-10")
      FileUtils.mkdir_p("src")
      File.write("src/app.js", "console.log('before repair');\n")
      File.write(".env", "SECRET=do-not-touch\n")
      _qa_payload, qa_code = json_cmd("qa-report", "--status", "blocked", "--task-id", "golden")
      assert_equal 0, qa_code

      before_source = File.read("src/app.js")
      before_env = File.read(".env")
      payload, code = json_cmd("repair", "--from-qa", "latest")

      assert_equal 0, code
      repair_loop = payload.fetch("repair_loop")
      assert_equal "created", repair_loop["status"]
      assert_match(%r{\.ai-web/qa/results/qa-}, repair_loop.fetch("source_result"))
      assert_match(%r{\.ai-web/snapshots/}, repair_loop.fetch("pre_repair_snapshot"))
      assert_match(%r{\.ai-web/repairs/repair-}, repair_loop.fetch("repair_record"))
      assert_match(%r{\.ai-web/tasks/fix-}, repair_loop.fetch("fix_task"))
      assert_includes payload["changed_files"], repair_loop["repair_record"]
      assert File.exist?(repair_loop["repair_record"])
      assert File.exist?(File.join(repair_loop["pre_repair_snapshot"], "manifest.json"))
      assert File.exist?(repair_loop["fix_task"])
      assert_equal before_source, File.read("src/app.js")
      assert_equal before_env, File.read(".env")

      state = load_state
      assert_equal repair_loop["fix_task"], state.dig("implementation", "current_task")
      refute_empty state.dig("qa", "open_failures")
      repair_record = JSON.parse(File.read(repair_loop["repair_record"]))
      assert_equal repair_loop["source_result"], repair_record["source_result"]
      assert_equal repair_loop["fix_task"], repair_record["fix_task"]
      assert_equal true, repair_record["guardrails"].any? { |guardrail| guardrail =~ /no source auto-patch/i }
    end
  end

  def test_repair_blocks_for_passing_or_missing_latest_qa_without_writes
    in_tmp do
      json_cmd("init")
      set_phase("phase-10")

      missing_payload, missing_code = json_cmd("repair", "--from-qa", "latest")
      assert_includes [1, 2, 3], missing_code
      assert_equal "blocked", missing_payload.fetch("repair_loop").fetch("status")
      assert_empty Dir.glob(".ai-web/repairs/*.json")
      assert_empty Dir.glob(".ai-web/snapshots/*")

      _qa_payload, qa_code = json_cmd("qa-report", "--status", "passed", "--task-id", "golden")
      assert_equal 0, qa_code
      before_state = File.read(".ai-web/state.yaml")
      passing_payload, passing_code = json_cmd("repair", "--from-qa", "latest")

      assert_includes [1, 2, 3], passing_code
      assert_equal "blocked", passing_payload.fetch("repair_loop").fetch("status")
      assert_match(/no blocking|no failed|passed/i, passing_payload["blocking_issues"].join("\n"))
      assert_equal before_state, File.read(".ai-web/state.yaml")
      assert_empty Dir.glob(".ai-web/repairs/*.json")
      assert_empty Dir.glob(".ai-web/snapshots/*")
    end
  end

  def test_repair_cycle_cap_blocks_before_new_snapshot_record_or_fix_task
    in_tmp do
      json_cmd("init")
      set_phase("phase-10")
      _qa_payload, qa_code = json_cmd("qa-report", "--status", "failed", "--task-id", "golden")
      assert_equal 0, qa_code
      first_payload, first_code = json_cmd("repair", "--from-qa", "latest", "--max-cycles", "1")
      assert_equal 0, first_code

      before_state = File.read(".ai-web/state.yaml")
      before_repairs = Dir.glob(".ai-web/repairs/*.json")
      before_snapshots = Dir.glob(".ai-web/snapshots/*")
      before_fix_tasks = Dir.glob(".ai-web/tasks/fix-*.md")
      blocked_payload, blocked_code = json_cmd("repair", "--from-qa", "latest", "--max-cycles", "1")

      assert_includes [1, 2, 3], blocked_code
      assert_equal "blocked", blocked_payload.fetch("repair_loop").fetch("status")
      assert_match(/cycle|cap|max/i, blocked_payload["blocking_issues"].join("\n"))
      assert_equal before_state, File.read(".ai-web/state.yaml")
      assert_equal before_repairs, Dir.glob(".ai-web/repairs/*.json")
      assert_equal before_snapshots, Dir.glob(".ai-web/snapshots/*")
      assert_equal before_fix_tasks, Dir.glob(".ai-web/tasks/fix-*.md")
    end
  end

  def test_repair_rejects_env_path_without_reading_or_printing_secret
    in_tmp do
      json_cmd("init")
      set_phase("phase-10")
      File.write(".env", "SECRET=do-not-print\n")

      [".env", ".env/qa.json", "nested/.env.local/qa.json"].each do |forbidden_path|
        FileUtils.mkdir_p(File.dirname(forbidden_path)) unless File.dirname(forbidden_path) == "." || File.exist?(File.dirname(forbidden_path))
        File.write(forbidden_path, JSON.pretty_generate(valid_qa_result.merge("notes" => "SECRET=do-not-print"))) if forbidden_path.include?("/") && File.dirname(forbidden_path) != ".env"

        stdout, stderr, code = run_aiweb("repair", "--from-qa", forbidden_path, "--json")
        payload = JSON.parse(stdout)

        assert_equal 1, code, forbidden_path
        assert_equal "", stderr, forbidden_path
        assert_match(/\.env|unsafe|refus/i, payload.dig("error", "message"), forbidden_path)
        refute_includes stdout, "do-not-print", forbidden_path
        assert_equal "SECRET=do-not-print\n", File.read(".env"), forbidden_path
        assert_empty Dir.glob(".ai-web/repairs/*.json"), forbidden_path
        assert_empty Dir.glob(".ai-web/snapshots/*"), forbidden_path
      end
    end
  end

  def test_webbuilder_repair_passes_through_to_aiweb_engine
    in_tmp do |dir|
      target = File.join(dir, "repair-cafe")
      _start_payload, start_code = json_cmd("start", "--path", target, "--idea", "neighborhood cafe website")
      assert_equal 0, start_code
      set_phase_path = File.join(target, ".ai-web", "state.yaml")
      state = YAML.load_file(set_phase_path)
      state["phase"]["current"] = "phase-10"
      File.write(set_phase_path, YAML.dump(state))
      _qa_payload, qa_code = json_cmd("--path", target, "qa-report", "--status", "failed", "--task-id", "golden")
      assert_equal 0, qa_code

      stdout, stderr, code = run_webbuilder("--path", target, "repair", "--from-qa", "latest", "--json")
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal "created", payload.fetch("repair_loop").fetch("status")
      assert File.exist?(File.join(target, payload.fetch("repair_loop").fetch("repair_record")))
    end
  end

  def test_phase_11_qa_report_updates_final_report
    in_tmp do
      json_cmd("init")
      set_phase("phase-11")

      payload, code = json_cmd("qa-report", "--status", "passed", "--task-id", "release")
      assert_equal 0, code
      assert_includes payload["changed_files"], ".ai-web/qa/final-report.md"
      assert_match(/Final QA Report/, File.read(".ai-web/qa/final-report.md"))
      assert_match(/Status: passed/, File.read(".ai-web/qa/final-report.md"))
    end
  end

  def test_phase_sensitive_commands_are_guarded_with_force_override
    in_tmp do
      json_cmd("init")

      blocked_prompt, prompt_code = json_cmd("design-prompt")
      assert_equal 2, prompt_code
      assert_match(/design-prompt requires current phase/, blocked_prompt.dig("error", "message"))
      refute File.exist?(".ai-web/design-prompt.md")

      forced_prompt, forced_code = json_cmd("design-prompt", "--force")
      assert_equal 0, forced_code
      assert_includes forced_prompt["changed_files"], ".ai-web/design-prompt.md"
      assert_match(/wrong-interpretations-to-avoid/, File.read(".ai-web/design-prompt.md"))

      blocked_ingest, ingest_code = json_cmd("ingest-design", "--title", "Too early")
      assert_equal 2, ingest_code
      assert_match(/ingest-design requires current phase/, blocked_ingest.dig("error", "message"))

      blocked_task, task_code = json_cmd("next-task")
      assert_equal 2, task_code
      assert_match(/next-task requires current phase/, blocked_task.dig("error", "message"))

      forced_task, forced_task_code = json_cmd("next-task", "--force")
      assert_equal 0, forced_task_code
      assert forced_task["changed_files"].any? { |path| path.include?(".ai-web/tasks/task-") }

      blocked_checklist, checklist_code = json_cmd("qa-checklist")
      assert_equal 2, checklist_code
      assert_match(/qa-checklist requires current phase/, blocked_checklist.dig("error", "message"))

      forced_checklist, forced_checklist_code = json_cmd("qa-checklist", "--force")
      assert_equal 0, forced_checklist_code
      assert_includes forced_checklist["changed_files"], ".ai-web/qa/current-checklist.md"

      blocked_qa, qa_code = json_cmd("qa-report", "--status", "passed", "--task-id", "too-early")
      assert_equal 2, qa_code
      assert_match(/qa-report requires current phase/, blocked_qa.dig("error", "message"))
    end
  end

  def test_qa_checklist_adds_stock_assistant_semantic_safety_checks
    in_tmp do
      json_cmd("init")
      json_cmd(
        "interview",
        "--idea",
        "Jubi stock assistant app showing stock questions, answers, and order preview only"
      )
      set_phase("phase-9")

      payload, code = json_cmd("qa-checklist")

      assert_equal 0, code
      assert_includes payload["changed_files"], ".ai-web/qa/current-checklist.md"
      checklist = File.read(".ai-web/qa/current-checklist.md")
      assert_match(/Semantic intent checks/, checklist)
      assert_match(/not a marketing-only landing page/, checklist)
      assert_match(/preview\/confirmation UI and cannot submit a real broker order/, checklist)
      assert_match(/Real account numbers, access tokens, approval keys, broker credentials/, checklist)
      assert_match(/real trading\/account access is locked, unavailable, mocked, or sandbox-only/, checklist)
    end
  end

  def test_qa_checklist_omits_stock_semantic_safety_checks_for_generic_sites
    in_tmp do
      json_cmd("init")
      json_cmd("interview", "--idea", "cozy local cafe website")
      set_phase("phase-9")

      _payload, code = json_cmd("qa-checklist")

      assert_equal 0, code
      checklist = File.read(".ai-web/qa/current-checklist.md")
      refute_match(/Semantic intent checks/, checklist)
      refute_match(/real broker order/, checklist)
      refute_match(/access tokens, approval keys/, checklist)
    end
  end

  def test_snapshot_and_rollback_record_recoverable_state
    in_tmp do
      json_cmd("init")
      snap_payload, snap_code = json_cmd("snapshot", "--reason", "pre gate")
      assert_equal 0, snap_code
      manifest = snap_payload["changed_files"].find { |path| path.end_with?("manifest.json") }
      refute_nil manifest
      assert File.exist?(manifest)

      rollback_payload, rollback_code = json_cmd("rollback", "--to", "phase-0", "--failure", "F-QA", "--reason", "test rollback")
      assert_equal 0, rollback_code
      assert_equal "phase-0", rollback_payload["current_phase"]
      state = load_state
      assert_equal true, state.dig("phase", "blocked")
      assert_equal "F-QA", state.dig("invalidations", -1, "failure")
    end
  end

  def test_rollback_blocks_advance_until_resolved
    in_tmp do
      json_cmd("init")
      json_cmd("interview", "--idea", "local cafe website")
      rollback_payload, rollback_code = json_cmd("rollback", "--to", "phase-0", "--failure", "F-QA", "--reason", "QA root cause")
      assert_equal 0, rollback_code
      assert_equal "phase-0", rollback_payload["current_phase"]

      blocked_payload, blocked_code = json_cmd("advance")
      assert_equal 2, blocked_code
      assert_equal "phase-0", blocked_payload["current_phase"]
      assert_match(/rollback/i, blocked_payload["blocking_issues"].join("\n"))
      assert_equal true, load_state.dig("phase", "blocked")

      blocked_again_payload, blocked_again_code = json_cmd("advance")
      assert_equal 2, blocked_again_code
      assert_equal 1, blocked_again_payload["blocking_issues"].join("\n").scan(/resolve-blocker/).length

      resolved_payload, resolved_code = json_cmd("resolve-blocker", "--reason", "root cause fixed and evidence recorded")
      assert_equal 0, resolved_code
      assert_equal false, load_state.dig("phase", "blocked")
      assert_equal "resolved phase blocker", resolved_payload["action_taken"]

      advanced_payload, advanced_code = json_cmd("advance")
      assert_equal 0, advanced_code
      assert_equal "phase-0.25", advanced_payload["current_phase"]
    end
  end

  def test_phase_7_advance_requires_design_token_primitives_and_audit_evidence
    in_tmp do
      json_cmd("init")
      set_phase("phase-7")

      blocked_payload, blocked_code = json_cmd("advance")
      assert_equal 2, blocked_code
      joined = blocked_payload["blocking_issues"].join("\n")
      assert_match(/design tokens/i, joined)
      assert_match(/component primitives/i, joined)
      assert_match(/component audit/i, joined)

      add_completed_tasks("design tokens implemented", "component primitives implemented", "component audit passed")
      advanced_payload, advanced_code = json_cmd("advance")
      assert_equal 0, advanced_code
      assert_equal "phase-8", advanced_payload["current_phase"]
    end
  end

  def test_phase_9_advance_requires_remaining_page_feature_completion_evidence
    in_tmp do
      json_cmd("init")
      set_phase("phase-9")

      blocked_payload, blocked_code = json_cmd("advance")
      assert_equal 2, blocked_code
      assert_match(/remaining page\/feature completion/i, blocked_payload["blocking_issues"].join("\n"))

      add_completed_tasks("phase-9 remaining page feature completion evidence")
      advanced_payload, advanced_code = json_cmd("advance")
      assert_equal 0, advanced_code
      assert_equal "phase-10", advanced_payload["current_phase"]
    end
  end

  def test_open_qa_failures_do_not_block_phase_zero_advance
    in_tmp do
      json_cmd("init")
      json_cmd("interview", "--idea", "local cafe website")
      append_open_failure

      payload, code = json_cmd("advance")
      assert_equal 0, code
      assert_equal "phase-0.25", payload["current_phase"]
      refute_match(/open QA failures/, payload["blocking_issues"].join("\n"))
    end
  end

  def test_existing_state_lock_preempts_mutation_without_cleanup
    in_tmp do
      json_cmd("init")
      before_state = File.read(".ai-web/state.yaml")
      File.write(".ai-web/.lock", "pid=seed\ncreated_at=seed\n")

      payload, code = json_cmd("interview", "--idea", "blocked mutation")
      assert_equal 1, code
      assert_match(/state lock exists/, payload.dig("error", "message"))
      assert File.exist?(".ai-web/.lock")
      assert_equal before_state, File.read(".ai-web/state.yaml")
      refute_match(/blocked mutation/, File.read(".ai-web/project.md"))
    end
  end

  def test_concurrent_mutation_lock_rejects_second_process
    skip "fork-based mutation lock test requires a POSIX Ruby" if RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/i)

    in_tmp do
      json_cmd("init")
      before_state = File.read(".ai-web/state.yaml")
      ready_reader, ready_writer = IO.pipe
      release_reader, release_writer = IO.pipe
      child_pid = nil

      begin
        child_pid = fork do
          ready_reader.close
          release_writer.close
          begin
            Aiweb::Project.new(Dir.pwd).send(:mutation, dry_run: false) do
              ready_writer.write("1")
              ready_writer.close
              release_reader.read
            end
            exit! 0
          rescue StandardError => e
            warn "#{e.class}: #{e.message}"
            exit! 1
          ensure
            ready_writer.close unless ready_writer.closed?
            release_reader.close unless release_reader.closed?
          end
        end
        ready_writer.close
        release_reader.close

        assert IO.select([ready_reader], nil, nil, 5), "child mutation did not acquire lock"
        assert_equal "1", ready_reader.read(1)
        assert File.exist?(".ai-web/.lock")

        payload, code = json_cmd("interview", "--idea", "concurrent mutation")
        assert_equal 1, code
        assert_match(/state lock exists/, payload.dig("error", "message"))
        assert_equal before_state, File.read(".ai-web/state.yaml")
        refute_match(/concurrent mutation/, File.read(".ai-web/project.md"))

        release_writer.write("1")
        release_writer.close
        _pid, status = Process.wait2(child_pid)
        child_pid = nil
        assert status.success?, "lock holder exited unsuccessfully"
        refute File.exist?(".ai-web/.lock")
      ensure
        ready_reader.close unless ready_reader.closed?
        unless release_writer.closed?
          begin
            release_writer.write("1")
          rescue IOError, Errno::EPIPE
          end
          release_writer.close
        end
        Process.wait(child_pid) if child_pid
      end
    end
  end

  def test_phase_0_25_blocks_until_quality_contract_is_approved
    in_tmp do
      json_cmd("init")
      json_cmd("interview", "--idea", "local cafe website")
      payload, code = json_cmd("advance")
      assert_equal 0, code
      assert_equal "phase-0.25", payload["current_phase"]

      blocked_payload, blocked_code = json_cmd("advance")
      assert_equal 2, blocked_code
      assert_match(/quality contract.*approved/i, blocked_payload["blocking_issues"].join("\n"))

      approve_quality_contract
      advanced_payload, advanced_code = json_cmd("advance")
      assert_equal 0, advanced_code
      assert_equal "phase-0.5", advanced_payload["current_phase"]
    end
  end

  def test_phase_0_25_blocks_when_design_quality_gate_is_weakened
    in_tmp do
      json_cmd("init")
      json_cmd("interview", "--idea", "premium clinic website")
      payload, code = json_cmd("advance")
      assert_equal 0, code
      assert_equal "phase-0.25", payload["current_phase"]

      quality = YAML.load_file(".ai-web/quality.yaml")
      quality["quality"]["approved"] = true
      quality["quality"]["design"].delete("phase_0_gate")
      File.write(".ai-web/quality.yaml", YAML.dump(quality))

      blocked_payload, blocked_code = json_cmd("advance")
      assert_equal 2, blocked_code
      assert_match(/phase_0_gate|human-grade design/i, blocked_payload["blocking_issues"].join("\n"))
    end
  end

  def test_help_and_cli_spec_include_option_surface
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr

    %w[start design-brief design-system design-prompt ingest-design next-task qa-checklist qa-report repair visual-polish rollback snapshot].each do |command|
      assert_includes stdout, command
    end

    ["start [--path PATH]", "--no-advance", "--path PATH", "design-brief [--force]", "design-system resolve [--force]", "ingest-design [--id ID]", "--selected", "rollback [--to PHASE] [--failure CODE]", "qa-report [--from PATH]", "repair [--from-qa PATH|latest]", "visual-polish --repair [--from-critique PATH|latest]", "--max-cycles N", "--duration-minutes N", "--timed-out"].each do |snippet|
      assert_includes stdout, snippet
    end

    assert_equal Aiweb::CLI::WEBBUILDER_COMMANDS.uniq, Aiweb::CLI::WEBBUILDER_COMMANDS
    %w[status qa-playwright verify-loop component-map deploy-plan intent].each do |command|
      assert_includes Aiweb::CLI::WEBBUILDER_COMMANDS, command
    end
  end

  def test_intent_router_golden_a_to_e_routes_are_deterministic
    cases = {
      "A regulated login app for medical account payments and admin workflows" => {
        "archetype" => "saas",
        "surface" => "app",
        "recommended_skill" => "saas-product-page",
        "recommended_design_system" => "conversion-saas",
        "recommended_profile" => "A",
        "safety_sensitive" => true
      },
      "Luxury editorial portfolio for a private brand" => {
        "archetype" => "premium",
        "surface" => "website",
        "recommended_skill" => "premium-landing-page",
        "recommended_design_system" => "luxury-editorial",
        "recommended_profile" => "B",
        "safety_sensitive" => false
      },
      "premium executive coaching landing page with trust, high-end consultation request, and polished brand mood" => {
        "archetype" => "premium",
        "surface" => "website",
        "recommended_skill" => "premium-landing-page",
        "recommended_design_system" => "luxury-editorial",
        "recommended_profile" => "B",
        "safety_sensitive" => false
      },
      "Mobile ecommerce collection for handmade tea products with shipping" => {
        "archetype" => "ecommerce",
        "surface" => "website",
        "recommended_skill" => "ecommerce-category-page",
        "recommended_design_system" => "mobile-commerce",
        "recommended_profile" => "C",
        "safety_sensitive" => false
      },
      "Resources-first blog and guide library for architects" => {
        "archetype" => "fallback",
        "surface" => "website",
        "recommended_skill" => "premium-landing-page",
        "recommended_design_system" => "luxury-editorial",
        "recommended_profile" => "D",
        "safety_sensitive" => false
      },
      "local hospital appointment insurance information service website" => {
        "archetype" => "service",
        "surface" => "website",
        "recommended_skill" => "service-business-site",
        "recommended_design_system" => "local-service-trust",
        "recommended_profile" => "A",
        "safety_sensitive" => true
      },
      "local hospital landing page with phone booking, location, hours, and care information" => {
        "archetype" => "service",
        "surface" => "website",
        "recommended_skill" => "service-business-site",
        "recommended_design_system" => "local-service-trust",
        "recommended_profile" => "B",
        "safety_sensitive" => true
      },
      "local physical therapy clinic website with phone booking, location, hours, reviews, and first-visit guide" => {
        "archetype" => "service",
        "surface" => "website",
        "recommended_skill" => "service-business-site",
        "recommended_design_system" => "local-service-trust",
        "recommended_profile" => "B",
        "safety_sensitive" => true
      },
      "neighborhood cafe reservation service website" => {
        "archetype" => "service",
        "surface" => "website",
        "recommended_skill" => "service-business-site",
        "recommended_design_system" => "local-service-trust",
        "recommended_profile" => "B",
        "safety_sensitive" => false
      }
    }

    cases.each do |idea, expected|
      payload, code = json_cmd("intent", "route", "--idea", idea)
      assert_equal 0, code
      route = payload.fetch("intent")
      expected.each { |key, value| assert_equal value, route[key], "#{idea} #{key}" }
      refute_empty route["framework"]
      refute_empty route["style_keywords"]
      refute_empty route["forbidden_design_patterns"]
    end
  end

  def test_intent_router_tie_breaks_ecommerce_before_saas_service_premium
    payload, code = json_cmd(
      "intent",
      "route",
      "--idea",
      "Premium tool service shop"
    )

    assert_equal 0, code
    route = payload.fetch("intent")
    assert_equal "ecommerce", route["archetype"]
    assert_equal "ecommerce-category-page", route["recommended_skill"]
    assert_equal "mobile-commerce", route["recommended_design_system"]
  end

  def test_intent_router_chooses_strongest_score_before_precedence
    cases = {
      "Premium boutique editorial brand portfolio with a tiny shop note" => "premium",
      "B2B SaaS platform dashboard analytics workflow for teams with cart recovery insight" => "saas",
      "Local dentist clinic appointment booking phone location hours service with shop style gift card note" => "service"
    }

    cases.each do |idea, expected_archetype|
      payload, code = json_cmd("intent", "route", "--idea", idea)
      assert_equal 0, code
      assert_equal expected_archetype, payload.dig("intent", "archetype"), idea
    end
  end

  def test_korean_medical_specialties_are_safety_sensitive
    %w[dentist dermatology orthopedics ophthalmology internal-medicine pediatrics ENT].each do |specialty|
      payload, code = json_cmd("intent", "route", "--idea", "local #{specialty} appointment information website")
      assert_equal 0, code
      assert_equal true, payload.dig("intent", "safety_sensitive"), specialty
    end
  end

  def test_intent_route_accepts_positional_idea_and_human_output
    stdout, stderr, code = run_aiweb("intent", "route", "neighborhood cafe reservation service website")

    assert_equal 0, code
    assert_equal "", stderr
    assert_match(/Intent route/, stdout)
    assert_match(/Archetype: service/, stdout)
    assert_match(/Recommended skill: service-business-site/, stdout)
    assert_match(/Recommended design system: local-service-trust/, stdout)
  end

  def test_intent_route_validates_input_and_does_not_mutate_project
    in_tmp do
      stdout, stderr, code = run_aiweb("intent", "route", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_match(/intent route requires --idea or a positional idea/, payload.dig("error", "message"))
      refute Dir.exist?(".ai-web")

      payload, code = json_cmd("intent", "route", "--idea", "SaaS dashboard for API analytics")
      assert_equal 0, code
      assert_empty payload["changed_files"]
      refute Dir.exist?(".ai-web")

      extra_payload, extra_code = json_cmd("intent", "route", "--idea", "SaaS dashboard", "extra")
      assert_equal 1, extra_code
      assert_match(/does not accept extra positional arguments/, extra_payload.dig("error", "message"))
      refute Dir.exist?(".ai-web")
    end
  end

  def test_webbuilder_passes_intent_route_through_to_aiweb
    stdout, stderr, code = run_webbuilder("intent", "route", "--idea", "online shop for stationery", "--json")
    payload = JSON.parse(stdout)

    assert_equal 0, code
    assert_equal "", stderr
    assert_equal "ecommerce", payload.dig("intent", "archetype")
    assert_equal "ecommerce-category-page", payload.dig("intent", "recommended_skill")
  end

  def test_intent_schema_keeps_router_fields_optional_for_v1_projects
    in_tmp do
      json_cmd("init", "--profile", "D")
      legacy_intent = {
        "schema_version" => 1,
        "original_intent" => "legacy landing page",
        "archetype" => "landing-page",
        "surface" => "website",
        "not_surface" => "app-dashboard",
        "primary_user" => "visitor",
        "primary_interaction" => "read and click",
        "must_have_first_view" => ["hero_headline"],
        "must_not_have" => ["fake_app_controls"],
        "semantic_risks" => ["generic copy"]
      }
      File.write(".ai-web/intent.yaml", YAML.dump(legacy_intent))

      payload, code = json_cmd("status")
      assert_equal 0, code
      assert_empty Array(payload["validation_errors"])
    end
  end

  def test_interview_merges_router_fields_into_intent_yaml
    in_tmp do
      json_cmd("init", "--profile", "D")
      payload, code = json_cmd("interview", "--idea", "SaaS product page for API analytics teams")

      assert_equal 0, code
      assert_includes payload["changed_files"], ".ai-web/intent.yaml"
      intent = YAML.load_file(".ai-web/intent.yaml")
      route = Aiweb::IntentRouter.route("SaaS product page for API analytics teams")
      assert_equal route["archetype"], intent["market_archetype"]
      assert_equal route["surface"], intent["surface"]
      assert_equal route["recommended_skill"], intent["recommended_skill"]
      assert_equal route["recommended_design_system"], intent["recommended_design_system"]
      assert_equal route["recommended_profile"], intent["recommended_profile"]
      assert_equal route["framework"], intent["framework"]
      assert_equal route["safety_sensitive"], intent["safety_sensitive"]
      refute_empty intent["style_keywords"]
      refute_empty intent["forbidden_design_patterns"]
    end
  end

  def test_interview_generates_non_placeholder_design_brief_with_required_sections
    in_tmp do
      json_cmd("init", "--profile", "D")
      payload, code = json_cmd("interview", "--idea", "cozy local cafe website")

      assert_equal 0, code
      assert_includes payload["changed_files"], ".ai-web/design-brief.md"
      brief = File.read(".ai-web/design-brief.md")
      assert_design_brief_complete(brief)
      refute_match(/\bTODO\b/, brief)
      assert_match(/service-business-site/, brief)
      assert_match(/local-service-trust/, brief)
      assert_match(/anti-ai-slop, color, typography, spacing-responsive/, brief)
    end
  end

  def test_start_generates_design_brief_from_existing_pr3_intent_without_reclassification
    in_tmp do |dir|
      target = File.join(dir, "stock-assistant")
      payload, code = json_cmd(
        "start",
        "--path", target,
        "--idea", "Jubi conversational stock assistant for domestic stock investors",
        "--no-advance"
      )

      assert_equal 0, code
      assert_includes payload["changed_files"], ".ai-web/design-brief.md"
      brief = File.read(File.join(target, ".ai-web", "design-brief.md"))
      assert_design_brief_complete(brief)
      assert_match(/Intent archetype: chat-assistant-webapp/, brief)
      assert_match(/Market route: fallback/, brief)
      assert_match(/Design system ID: luxury-editorial/, brief)
      assert_match(/Skill ID: premium-landing-page/, brief)
      assert_match(/Must show: chat_input/, brief)
      assert_match(/real_broker_order_execution/, brief)
      assert_match(/Safety overlay/, brief)
    end
  end

  def test_design_brief_prompt_specific_mood_overlays_are_deterministic
    examples = {
      "premium luxury boutique studio landing page" => [/luxurious/, /refined materials/],
      "cozy atmospheric cafe reservation website" => [/atmospheric/, /shareable detail/],
      "credible tax consulting website" => [/credible/, /stable hierarchy/]
    }

    examples.each do |idea, expectations|
      in_tmp do
        json_cmd("init", "--profile", "D")
        _payload, code = json_cmd("interview", "--idea", idea)
        assert_equal 0, code
        brief = File.read(".ai-web/design-brief.md")
        assert_design_brief_complete(brief)
        expectations.each { |pattern| assert_match(pattern, brief, idea) }
      end
    end
  end

  def test_design_brief_is_route_aware_for_all_pr2_design_systems_and_skills
    cases = {
      "SaaS product page for API analytics teams" => %w[conversion-saas saas-product-page product-led],
      "shoppable handmade goods collection page" => %w[mobile-commerce ecommerce-category-page Shoppable],
      "neighborhood dentist appointment inquiry website" => %w[local-service-trust service-business-site Local],
      "premium consulting landing page" => %w[luxury-editorial premium-landing-page Premium]
    }

    cases.each do |idea, expected|
      in_tmp do
        json_cmd("init", "--profile", "D")
        _payload, code = json_cmd("interview", "--idea", idea)
        assert_equal 0, code
        brief = File.read(".ai-web/design-brief.md")
        expected.each { |text| assert_includes brief, text, idea }
      end
    end
  end

  def test_design_prompt_generates_missing_design_brief_and_embeds_it
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "SaaS product page for API analytics teams")
      FileUtils.rm_f(".ai-web/design-brief.md")
      set_phase("phase-3")

      payload, code = json_cmd("design-prompt")

      assert_equal 0, code
      assert_includes payload["changed_files"], ".ai-web/design-brief.md"
      assert_includes payload["changed_files"], ".ai-web/design-prompt.md"
      brief = File.read(".ai-web/design-brief.md")
      prompt = File.read(".ai-web/design-prompt.md")
      assert_design_brief_complete(brief)
      assert_includes prompt, "## design-brief.md"
      assert_includes prompt, "## DESIGN.md"
      assert_includes prompt, "Design system ID: conversion-saas"
      assert_includes prompt, "Selected design system ID: conversion-saas"
      assert_includes prompt, "Skill ID: saas-product-page"
    end
  end

  def test_design_brief_preserves_custom_content_unless_force_regenerated
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "cozy local cafe website")
      custom = <<~MD
        # Design Brief

        ## Custom Direction
        Keep the founder's hand-drawn menu board aesthetic and one-off local references.
      MD
      File.write(".ai-web/design-brief.md", custom)
      set_phase("phase-3")

      _prompt_payload, prompt_code = json_cmd("design-prompt")
      assert_equal 0, prompt_code
      assert_equal custom, File.read(".ai-web/design-brief.md")

      forced_prompt_payload, forced_prompt_code = json_cmd("design-prompt", "--force")
      assert_equal 0, forced_prompt_code
      assert_includes forced_prompt_payload["changed_files"], ".ai-web/design-prompt.md"
      refute_includes forced_prompt_payload["changed_files"], ".ai-web/design-brief.md"
      assert_equal custom, File.read(".ai-web/design-brief.md")

      preserve_payload, preserve_code = json_cmd("design-brief")
      assert_equal 0, preserve_code
      refute_includes preserve_payload["changed_files"], ".ai-web/design-brief.md"
      assert_equal custom, File.read(".ai-web/design-brief.md")

      regen_payload, regen_code = json_cmd("design-brief", "--force")
      assert_equal 0, regen_code
      assert_includes regen_payload["changed_files"], ".ai-web/design-brief.md"
      regenerated = File.read(".ai-web/design-brief.md")
      refute_equal custom, regenerated
      assert_design_brief_complete(regenerated)
      assert_match(/local-service-trust/, regenerated)
    end
  end


  def test_design_system_resolve_synthesizes_design_source_of_truth_from_route_brief_assets_and_craft
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "neighborhood dentist appointment inquiry website")

      design = File.read(".ai-web/DESIGN.md")
      assert_design_system_complete(design)
      assert_includes design, "<!-- aiweb:design-system-resolved:v1 -->"
      assert_match(/Selected design system ID: local-service-trust/, design)
      assert_match(/Selected skill ID: service-business-site/, design)
      assert_match(/Craft rule IDs: anti-ai-slop, color, typography, spacing-responsive/, design)
      assert_match(/Must show: hero_headline|Must show: chat_input|Must show: featured_products|Must show: metric_cards|Must show: input_form/, design)
      assert_match(/data-aiweb-id/, design)
      assert_match(/Mobile-first/, design)
      assert_match(/No generic AI-slop/, design)
      assert_match(/Component\/token guardrails/i, design)
      assert_match(/# Local Service Trust Design System/, design)
      assert_match(/# Craft Rule: Typography/, design)
      assert_match(/# Craft Rule: Color/, design)
      assert_match(/# Craft Rule: Spacing and Responsive Layout/, design)
      assert_match(/# Craft Rule: Anti-AI-Slop/, design)
    end
  end

  def test_design_system_resolve_includes_reference_brief_when_present
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "SaaS product page for API analytics teams")
      File.write(".ai-web/design-reference-brief.md", <<~MD)
        # Design Reference Brief

        Companies: Linear, Stripe, Vercel.
        Pattern matrix: strong hierarchy, clear primary CTA, restrained dashboard proof, mobile-first trust cues.
        Copy risk: pattern-only; do not reproduce exact layouts, prices, trademarks, or copy.
      MD

      payload, code = json_cmd("design-system", "resolve", "--force")

      assert_equal 0, code
      assert_includes payload["changed_files"], ".ai-web/DESIGN.md"
      design = File.read(".ai-web/DESIGN.md")
      assert_match(/Reference-backed Pattern Constraints/, design)
      assert_match(/Linear, Stripe, Vercel/, design)
      assert_match(/pattern evidence only/i, design)
      assert_match(/Do not copy exact screenshots, layouts, copy, prices, trademarks, or brand-specific claims/, design)
    end
  end

  def test_design_system_resolve_preserves_custom_design_unless_force_regenerated
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "cozy local cafe website")
      custom = <<~MD
        # Custom DESIGN.md

        ## Human Direction
        Preserve the hand-painted sign, neighborhood map motif, and bespoke color names.
      MD
      File.write(".ai-web/DESIGN.md", custom)

      preserve_payload, preserve_code = json_cmd("design-system", "resolve")
      assert_equal 0, preserve_code
      refute_includes preserve_payload["changed_files"], ".ai-web/DESIGN.md"
      assert_equal custom, File.read(".ai-web/DESIGN.md")

      forced_payload, forced_code = json_cmd("design-system", "resolve", "--force")
      assert_equal 0, forced_code
      assert_includes forced_payload["changed_files"], ".ai-web/DESIGN.md"
      regenerated = File.read(".ai-web/DESIGN.md")
      refute_equal custom, regenerated
      assert_match(/Selected design system ID: local-service-trust/, regenerated)
      assert_match(/service-business-site/, regenerated)
    end
  end

  def test_design_system_resolve_preserves_template_shaped_custom_design_without_force
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "cozy local cafe website")
      custom = <<~MD
        # DESIGN.md

        ## Color Tokens
        Keep the founder's hand-mixed persimmon paint as `--color-founder-persimmon`.

        ## Forbidden Patterns
        Never replace the neighborhood map motif with generic cafe stock-photo cards.
      MD
      File.write(".ai-web/DESIGN.md", custom)

      preserve_payload, preserve_code = json_cmd("design-system", "resolve")

      assert_equal 0, preserve_code
      refute_includes preserve_payload["changed_files"], ".ai-web/DESIGN.md"
      assert_includes File.read(".ai-web/DESIGN.md"), "founder's hand-mixed persimmon paint"
      assert_equal custom, File.read(".ai-web/DESIGN.md")
    end
  end

  def test_design_prompt_generates_missing_design_system_and_embeds_design_source_of_truth
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "SaaS product page for API analytics teams")
      FileUtils.rm_f(".ai-web/DESIGN.md")
      set_phase("phase-3")

      payload, code = json_cmd("design-prompt")

      assert_equal 0, code
      assert_includes payload["changed_files"], ".ai-web/DESIGN.md"
      assert_includes payload["changed_files"], ".ai-web/design-prompt.md"
      design = File.read(".ai-web/DESIGN.md")
      prompt = File.read(".ai-web/design-prompt.md")
      assert_match(/Selected design system ID: conversion-saas/, design)
      assert_includes prompt, "## DESIGN.md"
      assert_includes prompt, "AI Web Design Source of Truth"
      assert_includes prompt, "data-aiweb-id"
      assert_includes prompt, "Selected design system ID: conversion-saas"
    end
  end

  def assert_candidate_html_contract(html, id, design_system, skill)
    assert_includes html, "<!-- aiweb:visual-contract:start #{id} -->"
    assert_includes html, "<!-- aiweb:visual-contract:end #{id} -->"
    assert_includes html, "data-aiweb-id=\"candidate.#{id}.first-view\""
    assert_includes html, "data-aiweb-design-system=\"#{design_system}\""
    assert_includes html, "data-aiweb-skill=\"#{skill}\""
    assert_match(/data-aiweb-route=/, html)
    assert_match(/No fake metrics, testimonials, logos, prices, or credentials/, html)
  end

  def test_design_generates_three_differentiated_html_candidates_and_comparison_from_design_source
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "neighborhood cafe reservation service website")

      payload, code = json_cmd("design", "--candidates", "3")

      assert_equal 0, code
      assert_equal "generated design candidates", payload["action_taken"]
      %w[candidate-01 candidate-02 candidate-03].each do |id|
        path = ".ai-web/design-candidates/#{id}.html"
        assert_includes payload["changed_files"], path
        assert File.exist?(path), "#{path} should exist"
        html = File.read(path)
        assert_candidate_html_contract(html, id, "local-service-trust", "service-business-site")
        assert_match(/hero headline|approved first-view contract|Primary interaction/i, html)
      end
      assert_equal 3, Dir.glob(".ai-web/design-candidates/candidate-*.html").length
      assert File.exist?(".ai-web/design-candidates/comparison.md")
      comparison = File.read(".ai-web/design-candidates/comparison.md")
      assert_match(/Mood/, comparison)
      assert_match(/Layout/, comparison)
      assert_match(/Strengths/, comparison)
      assert_match(/Tradeoffs/, comparison)
      assert_match(/local-service-trust/, comparison)
      %w[editorial-premium conversion-focused trust-minimal].each do |strategy|
        assert_match(/#{strategy}/, comparison)
      end

      bodies = %w[candidate-01 candidate-02 candidate-03].map { |id| File.read(".ai-web/design-candidates/#{id}.html") }
      assert_equal 3, bodies.uniq.length, "candidate HTML files must be differentiated"
      state = load_state
      assert_equal 3, state.dig("design_candidates", "candidates").length
      assert_equal %w[trust-minimal editorial-premium conversion-focused].sort, state.dig("design_candidates", "candidates").map { |candidate| candidate["strategy_id"] }.sort
      state.dig("design_candidates", "candidates").each do |candidate|
        assert_operator candidate["score"].to_i, :>=, 80
        assert_kind_of Hash, candidate["rubric_scores"]
        assert candidate["first_view"].to_s.length > 20
        assert candidate["risks"].is_a?(Array) && !candidate["risks"].empty?
      end
      assert_equal 3, state.dig("artifacts", "design_candidates", "count")
    end
  end

  def test_design_candidates_include_reference_basis_without_copying_references
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "SaaS product page for API analytics teams")
      File.write(".ai-web/design-reference-brief.md", <<~MD)
        # Design Reference Brief

        Companies: Linear, Stripe, Vercel.
        Accepted patterns: strong middle-plan emphasis, product proof panel, concise mobile CTA.
        Copy risk: pattern-only; do not reproduce exact layouts, prices, trademarks, or copy.
      MD

      payload, code = json_cmd("design", "--candidates", "3")

      assert_equal 0, code
      assert_equal "generated design candidates", payload["action_taken"]
      comparison = File.read(".ai-web/design-candidates/comparison.md")
      assert_match(/## Reference basis/, comparison)
      assert_match(/design-reference-brief\.md/, comparison)
      assert_match(/Companies: Linear, Stripe, Vercel/, comparison)
      assert_match(/avoid exact copying/i, comparison)
      html = File.read(".ai-web/design-candidates/candidate-01.html")
      assert_match(/Reference basis/, html)
      assert_match(/pattern grounding only/, html)
      assert_match(/Do not copy exact reference UI, copy, prices, trademarks, or signed image URLs/, html)
    end
  end

  def test_design_regenerates_when_only_one_candidate_exists
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "neighborhood cafe reservation service website")
      FileUtils.mkdir_p(".ai-web/design-candidates")
      File.write(".ai-web/design-candidates/candidate-01.html", "<html>partial draft</html>\n")

      payload, code = json_cmd("design", "--candidates", "3")

      assert_equal 0, code
      assert_equal "generated design candidates", payload["action_taken"]
      refute_equal "preserved existing design candidates", payload["action_taken"]
      %w[candidate-01 candidate-02 candidate-03].each do |id|
        path = ".ai-web/design-candidates/#{id}.html"
        assert_includes payload["changed_files"], path
        assert File.exist?(path), "#{path} should exist after regeneration"
        assert_candidate_html_contract(File.read(path), id, "local-service-trust", "service-business-site")
      end
      assert_includes payload["changed_files"], ".ai-web/design-candidates/comparison.md"
      assert File.exist?(".ai-web/design-candidates/comparison.md")
      assert_equal 3, load_state.dig("artifacts", "design_candidates", "count")
    end
  end

  def test_design_regenerates_when_comparison_missing_despite_all_candidates_existing
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "SaaS product page for API analytics teams")
      _payload, code = json_cmd("design", "--candidates", "3")
      assert_equal 0, code
      File.delete(".ai-web/design-candidates/comparison.md")

      payload, regenerate_code = json_cmd("design", "--candidates", "3")

      assert_equal 0, regenerate_code
      assert_equal "generated design candidates", payload["action_taken"]
      refute_equal "preserved existing design candidates", payload["action_taken"]
      assert_includes payload["changed_files"], ".ai-web/design-candidates/comparison.md"
      assert File.exist?(".ai-web/design-candidates/comparison.md")
      comparison = File.read(".ai-web/design-candidates/comparison.md")
      %w[candidate-01 candidate-02 candidate-03].each do |id|
        path = ".ai-web/design-candidates/#{id}.html"
        assert File.exist?(path), "#{path} should exist after regeneration"
        assert_includes comparison, "| #{id} |"
      end
      assert_equal 3, load_state.dig("artifacts", "design_candidates", "count")
    end
  end

  def test_design_preserves_existing_candidates_unless_force_regenerates
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "SaaS product page for API analytics teams")
      _payload, code = json_cmd("design", "--candidates", "3")
      assert_equal 0, code
      sentinel_path = ".ai-web/design-candidates/candidate-02.html"
      sentinel = File.read(sentinel_path) + "\n<!-- human review note: keep -->\n"
      File.write(sentinel_path, sentinel)

      preserve_payload, preserve_code = json_cmd("design", "--candidates", "3")
      assert_equal 0, preserve_code
      assert_equal "preserved existing design candidates", preserve_payload["action_taken"]
      assert_empty preserve_payload["changed_files"]
      assert_equal sentinel, File.read(sentinel_path)

      force_payload, force_code = json_cmd("design", "--candidates", "3", "--force")
      assert_equal 0, force_code
      assert_equal "regenerated design candidates", force_payload["action_taken"]
      refute_equal sentinel, File.read(sentinel_path)
      assert_includes force_payload["changed_files"], sentinel_path
      assert_equal 1, load_state.dig("design_candidates", "regeneration_rounds")
    end
  end

  def test_select_design_writes_selected_artifact_state_and_preserves_design_source
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "shoppable product collection page")
      custom = "# Custom DESIGN.md\n\nKeep a custom source of truth.\n"
      File.write(".ai-web/DESIGN.md", custom)
      json_cmd("design", "--candidates", "3")

      payload, code = json_cmd("select-design", "candidate-02")

      assert_equal 0, code
      assert_equal "selected design candidate candidate-02", payload["action_taken"]
      assert_includes payload["changed_files"], ".ai-web/design-candidates/selected.md"
      assert_equal custom, File.read(".ai-web/DESIGN.md")
      selected = File.read(".ai-web/design-candidates/selected.md")
      assert_match(/Selected candidate: candidate-02/, selected)
      assert_match(/DESIGN.md remains the source of truth/, selected)
      assert_match(/Strategy:/, selected)
      assert_match(/Rubric score:/, selected)
      refute_match(/TODO:/, selected)
      state = load_state
      assert_equal "candidate-02", state.dig("design_candidates", "selected_candidate")
      approved = state.dig("design_candidates", "candidates").find { |candidate| candidate["id"] == "candidate-02" }
      assert_equal "approved", approved["status"]
    end
  end

  def test_design_prompt_and_next_task_reference_selected_design_candidate
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "premium consulting landing page")
      File.write(".ai-web/design-reference-brief.md", <<~MD)
        # Design Reference Brief

        Companies: Aesop, Stripe.
        Patterns: editorial hierarchy, quiet CTA, mobile trust cues.
        Copy risk: pattern-only; do not reproduce exact layouts, trademarks, prices, or copy.
      MD
      json_cmd("design", "--candidates", "3")
      json_cmd("select-design", "candidate-03")
      set_phase("phase-3")

      prompt_payload, prompt_code = json_cmd("design-prompt")
      assert_equal 0, prompt_code
      assert_includes prompt_payload["changed_files"], ".ai-web/design-prompt.md"
      prompt = File.read(".ai-web/design-prompt.md")
      assert_match(/selected candidate `candidate-03`/, prompt)
      assert_match(/design-candidates\/candidate-03.html/, prompt)
      assert_match(/data-aiweb-id=\"candidate.candidate-03.first-view\"/, prompt)
      assert_match(/## design-reference-brief\.md/, prompt)
      assert_match(/Use `.ai-web\/design-reference-brief.md` only as pattern evidence/, prompt)

      set_phase("phase-6")
      task_payload, task_code = json_cmd("next-task")
      assert_equal 0, task_code
      task_path = task_payload["changed_files"].find { |path| path.include?(".ai-web/tasks/task-") }
      refute_nil task_path
      task_packet = File.read(task_path)
      assert_match(/design-candidates\/candidate-03.html/, task_packet)
      assert_match(/design-reference-brief\.md/, task_packet)
      assert_match(/Do not call external Lazyweb\/design-research services/, task_packet)
      assert_match(/Do not copy exact reference screenshots, layouts, copy, prices, trademarks, or brand-specific claims/, task_packet)
    end
  end

  def test_design_cli_help_webbuilder_passthrough_and_validation
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr
    assert_includes stdout, "design --candidates 3 [--force]"
    assert_includes stdout, "select-design candidate-01|candidate-02|candidate-03"

    in_tmp do |dir|
      target = File.join(dir, "passthrough-design")
      _payload, start_code = json_cmd("start", "--path", target, "--idea", "neighborhood cafe reservation service website", "--no-advance")
      assert_equal 0, start_code
      web_stdout, web_stderr, web_code = run_webbuilder("--path", target, "design", "--candidates", "3", "--json")
      web_payload = JSON.parse(web_stdout)
      assert_equal 0, web_code
      assert_equal "", web_stderr
      assert_equal "generated design candidates", web_payload["action_taken"]

      select_stdout, select_stderr, select_code = run_webbuilder("--path", target, "select-design", "candidate-01", "--json")
      select_payload = JSON.parse(select_stdout)
      assert_equal 0, select_code
      assert_equal "", select_stderr
      assert_equal "candidate-01", select_payload.dig("design_candidates", "selected_candidate")

      invalid_payload, invalid_code = json_cmd("--path", target, "design", "--candidates", "2", "--force")
      assert_equal 1, invalid_code
      assert_match(/exactly 3/, invalid_payload.dig("error", "message"))
    end
  end

  def test_design_system_resolve_cli_help_and_webbuilder_passthrough
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr
    assert_includes stdout, "design-system resolve [--force]"

    in_tmp do |dir|
      target = File.join(dir, "passthrough-design-system")
      _payload, start_code = json_cmd("start", "--path", target, "--idea", "neighborhood cafe reservation service website", "--no-advance")
      assert_equal 0, start_code
      File.write(File.join(target, ".ai-web", "DESIGN.md"), File.read(File.join(REPO_ROOT, "docs", "templates", "DESIGN.md")))

      web_stdout, web_stderr, web_code = run_webbuilder("--path", target, "design-system", "resolve", "--json")
      web_payload = JSON.parse(web_stdout)
      assert_equal 0, web_code
      assert_equal "", web_stderr
      assert_includes web_payload["changed_files"], ".ai-web/DESIGN.md"
      assert_match(/resolved design source of truth/, web_payload["action_taken"])
    end
  end


  def prepare_profile_d_design_flow
    json_cmd("init", "--profile", "D")
    json_cmd("interview", "--idea", "premium content marketing landing page")
    json_cmd("design-brief", "--force")
    File.write(".ai-web/DESIGN.md", "# Custom Design System\n\nUse editorial calm, clear hierarchy, and source-backed proof only.\n")
    json_cmd("design", "--candidates", "3")
    json_cmd("select-design", "candidate-02")
  end

  def prepare_profile_s_design_flow
    _init_payload, init_code = json_cmd("init", "--profile", "S")
    assert_equal 0, init_code
    _interview_payload, interview_code = json_cmd("interview", "--idea", "local Supabase app with member login and profile management")
    assert_equal 0, interview_code
    _brief_payload, brief_code = json_cmd("design-brief", "--force")
    assert_equal 0, brief_code
    File.write(".ai-web/DESIGN.md", "# Supabase App Design System\n\nUse authenticated app clarity, local-first data boundaries, and explicit secret handling.\n")
    _design_payload, design_code = json_cmd("design", "--candidates", "3")
    assert_equal 0, design_code
    _select_payload, select_code = json_cmd("select-design", "candidate-02")
    assert_equal 0, select_code
  end

  def assert_no_dot_env_files_created
    assert_empty Dir.glob(".env*"), "Profile S must not create .env, .env.*, or .env.example files"
  end

  def profile_s_generated_text
    Dir.glob("{package.json,next.config.mjs,tsconfig.json,src/**/*,supabase/**/*,.ai-web/scaffold-profile-S.json,.ai-web/qa/supabase-secret-qa.json,.ai-web/qa/supabase-local-verify.json}", File::FNM_DOTMATCH)
       .select { |path| File.file?(path) }
       .map { |path| "#{path}\n#{File.read(path)}" }
       .join("\n")
  end

  def refute_scaffold_outputs(*allowed_existing)
    scaffold_outputs = %w[
      package.json
      astro.config.mjs
      tailwind.config.mjs
      src/pages/index.astro
      src/components/Hero.astro
      src/components/SectionCard.astro
      src/content/site.json
      src/styles/global.css
      public/.gitkeep
      .ai-web/scaffold-profile-D.json
    ] - allowed_existing
    scaffold_outputs.each do |path|
      refute File.exist?(path), "#{path} should not be written when scaffold preflight fails"
    end
    state = load_state
    refute_equal true, state.dig("implementation", "scaffold_created")
  end

  def test_scaffold_profile_d_requires_substantive_design_source_before_writing
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "premium content marketing landing page")
      FileUtils.rm_f(".ai-web/DESIGN.md")

      missing_payload, missing_code = json_cmd("scaffold", "--profile", "D")
      assert_equal 1, missing_code
      assert_match(/requires substantive \.ai-web\/DESIGN\.md/, missing_payload.dig("error", "message"))
      refute_scaffold_outputs

      File.write(".ai-web/DESIGN.md", "# TODO\n\nTODO\n")
      stub_payload, stub_code = json_cmd("scaffold", "--profile", "D")
      assert_equal 1, stub_code
      assert_match(/requires substantive \.ai-web\/DESIGN\.md/, stub_payload.dig("error", "message"))
      refute_scaffold_outputs
    end
  end

  def test_scaffold_profile_d_requires_selected_candidate_before_writing
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "premium content marketing landing page")
      json_cmd("design-brief", "--force")
      File.write(".ai-web/DESIGN.md", "# Custom Design System\n\nUse editorial calm, clear hierarchy, and source-backed proof only.\n")
      json_cmd("design", "--candidates", "3")

      payload, code = json_cmd("scaffold", "--profile", "D")

      assert_equal 1, code
      assert_match(/requires design_candidates\.selected_candidate/, payload.dig("error", "message"))
      refute_scaffold_outputs
    end
  end

  def test_scaffold_profile_d_requires_selected_candidate_artifact_before_writing
    in_tmp do
      prepare_profile_d_design_flow
      FileUtils.rm_f(".ai-web/design-candidates/candidate-02.html")

      payload, code = json_cmd("scaffold", "--profile", "D")

      assert_equal 1, code
      assert_match(/requires selected candidate artifact \.ai-web\/design-candidates\/candidate-02\.html/, payload.dig("error", "message"))
      refute_scaffold_outputs
    end
  end

  def test_scaffold_profile_d_force_directory_conflict_fails_without_partial_writes
    in_tmp do
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("package.json")

      payload, code = json_cmd("scaffold", "--profile", "D", "--force")

      assert_equal 1, code
      assert_match(/directories conflict.*package\.json.*--force only overwrites regular files/, payload.dig("error", "message"))
      assert File.directory?("package.json")
      refute_scaffold_outputs("package.json")
    end
  end

  def test_scaffold_profile_d_creates_static_site_foundation_from_design_context
    in_tmp do
      prepare_profile_d_design_flow

      payload, code = json_cmd("scaffold", "--profile", "D")

      assert_equal 0, code
      assert_equal "generated scaffold profile D", payload["action_taken"]
      %w[
        package.json
        astro.config.mjs
        tailwind.config.mjs
        src/pages/index.astro
        src/components/Hero.astro
        src/content/site.json
        src/styles/global.css
        public/.gitkeep
        .ai-web/scaffold-profile-D.json
      ].each do |path|
        assert File.exist?(path), "expected #{path} to be created"
        assert_includes payload["changed_files"], path
      end
      refute File.exist?(".env"), "scaffold must never create .env"
      refute File.exist?(".env.example"), "profile D scaffold does not need env examples"

      package = JSON.parse(File.read("package.json"))
      assert_equal true, package["private"]
      assert_equal "astro dev", package.dig("scripts", "dev")
      assert_equal "astro build", package.dig("scripts", "build")
      assert_equal "latest", package.dig("dependencies", "astro")

      index = File.read("src/pages/index.astro")
      hero = File.read("src/components/Hero.astro")
      assert_match(/data-aiweb-id="page\.home"/, index)
      assert_match(/data-aiweb-id="component\.hero\.copy"/, hero)
      refute_match(/testimonial|customers|\d+%|\$\d+|trusted by/i, index)

      site = JSON.parse(File.read("src/content/site.json"))
      assert_equal "candidate-02", site["selected_candidate"]
      assert_equal ".ai-web/design-candidates/candidate-02.html", site["selected_candidate_path"]
      assert_match(/Custom Design System/, site["design_system_excerpt"])
      assert_match(/fake testimonials/, site["content_policy"])

      metadata = JSON.parse(File.read(".ai-web/scaffold-profile-D.json"))
      assert_equal "D", metadata["profile"]
      assert_equal "Astro", metadata["framework"]
      assert_equal "pnpm build", metadata["build_command"]
      assert_equal "pnpm dev", metadata["dev_command"]
      assert_equal "candidate-02", metadata["selected_candidate"]

      state = load_state
      assert_equal true, state.dig("implementation", "scaffold_created")
      assert_equal "D", state.dig("implementation", "scaffold_profile")
      assert_equal "Astro", state.dig("implementation", "scaffold_framework")
      assert_equal "pnpm build", state.dig("implementation", "scaffold_build_command")
      assert_equal ".ai-web/scaffold-profile-D.json", state.dig("implementation", "scaffold_metadata_path")
    end
  end

  def test_scaffold_profile_d_preserves_existing_files_and_force_overwrites_targets
    in_tmp do
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      File.write("src/pages/index.astro", "<!-- user edit -->\n")

      payload, code = json_cmd("scaffold", "--profile", "D")
      assert_equal 1, code
      assert_match(/existing files.*src\/pages\/index\.astro/, payload.dig("error", "message"))
      assert_equal "<!-- user edit -->\n", File.read("src/pages/index.astro")

      force_payload, force_code = json_cmd("scaffold", "--profile", "D", "--force")
      assert_equal 0, force_code
      assert_equal "regenerated scaffold profile D", force_payload["action_taken"]
      refute_equal "<!-- user edit -->\n", File.read("src/pages/index.astro")
      assert_match(/data-aiweb-id="page\.home"/, File.read("src/pages/index.astro"))
    end
  end

  def test_scaffold_profile_d_completes_partial_missing_safe_files
    in_tmp do
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      FileUtils.rm_f("src/components/Hero.astro")

      payload, code = json_cmd("scaffold", "--profile", "D")

      assert_equal 0, code
      assert_includes payload["changed_files"], "src/components/Hero.astro"
      assert File.exist?("src/components/Hero.astro")
      assert_match(/data-aiweb-id="component\.hero\.copy"/, File.read("src/components/Hero.astro"))
    end
  end

  def test_scaffold_cli_help_and_webbuilder_passthrough
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr
    assert_includes stdout, "scaffold --profile D [--force]"
    assert_includes stdout, "supabase-local-verify [--force]"

    in_tmp do |dir|
      target = File.join(dir, "passthrough-scaffold")
      _payload, start_code = json_cmd("start", "--path", target, "--profile", "D", "--idea", "content brand page", "--no-advance")
      assert_equal 0, start_code
      _brief_payload, brief_code = json_cmd("--path", target, "design-brief", "--force")
      assert_equal 0, brief_code
      File.write(File.join(target, ".ai-web", "DESIGN.md"), "# Custom Design System\n\nUse editorial calm, clear hierarchy, and source-backed proof only.\n")
      _design_payload, design_code = json_cmd("--path", target, "design", "--candidates", "3")
      assert_equal 0, design_code
      _select_payload, select_code = json_cmd("--path", target, "select-design", "candidate-02")
      assert_equal 0, select_code

      web_stdout, web_stderr, web_code = run_webbuilder("--path", target, "scaffold", "--profile", "D", "--json")
      web_payload = JSON.parse(web_stdout)
      assert_equal 0, web_code
      assert_equal "", web_stderr
      assert_equal "generated scaffold profile D", web_payload["action_taken"]
      assert File.exist?(File.join(target, "src", "pages", "index.astro"))
    end
  end

  def test_init_profile_s_records_local_supabase_stack_without_dot_env_template
    in_tmp do
      payload, code = json_cmd("init", "--profile", "S")

      assert_equal 0, code
      assert_equal "initialized profile S", payload["action_taken"]
      state = load_state
      assert_equal "S", state.dig("implementation", "stack_profile")
      assert_match(/Supabase/i, state.dig("implementation", "scaffold_target"))
      assert File.exist?(".ai-web/stack.md")
      assert File.exist?(".ai-web/deploy.md")
      assert_match(/Supabase/i, File.read(".ai-web/stack.md"))
      assert_match(/external deploy\/provider actions require explicit human approval/i, File.read(".ai-web/deploy.md"))
      refute_match(/supabase login|supabase projects create|supabase link/i, File.read(".ai-web/deploy.md"))
      assert_no_dot_env_files_created
    end
  end

  def test_scaffold_profile_s_creates_local_next_supabase_scaffold_without_external_actions
    in_tmp do
      prepare_profile_s_design_flow

      payload, code = json_cmd("scaffold", "--profile", "S")

      assert_equal 0, code
      assert_equal "generated scaffold profile S", payload["action_taken"]
      %w[
        package.json
        next.config.mjs
        tsconfig.json
        src/app/layout.tsx
        src/app/page.tsx
        src/app/globals.css
        src/lib/supabase/client.ts
        src/lib/supabase/server.ts
        supabase/migrations/0001_initial_schema.sql
        supabase/rls-draft.md
        supabase/storage.md
        supabase/env.example.template
        .ai-web/scaffold-profile-S.json
        .ai-web/qa/supabase-secret-qa.json
        .ai-web/qa/supabase-local-verify.json
      ].each do |path|
        assert File.exist?(path), "expected Profile S scaffold to create #{path}"
        assert_includes payload["changed_files"], path
      end
      assert_no_dot_env_files_created
      refute File.exist?(".ai-web/supabase-secret-qa.json"), "stale root secret QA artifact must not be created"

      package = JSON.parse(File.read("package.json"))
      assert_equal true, package["private"]
      assert_equal "next dev", package.dig("scripts", "dev")
      assert_equal "next build", package.dig("scripts", "build")
      assert_equal "next start", package.dig("scripts", "start")
      assert package.dig("dependencies", "next"), "Profile S package.json should include Next.js"
      assert package.dig("dependencies", "@supabase/supabase-js"), "Profile S package.json should include Supabase JS"
      assert package.dig("dependencies", "@supabase/ssr"), "Profile S package.json should include Supabase SSR"

      client = File.read("src/lib/supabase/client.ts")
      server = File.read("src/lib/supabase/server.ts")
      assert_match(/NEXT_PUBLIC_SUPABASE_URL/, client)
      assert_match(/NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY/, client)
      assert_match(/createBrowserClient|createClient/, client)
      assert_match(/createServerClient|cookies/, server)

      migration = File.read("supabase/migrations/0001_initial_schema.sql")
      assert_match(/enable row level security/i, migration)
      assert_match(/create policy/i, migration)
      assert_match(/draft|local/i, File.read("supabase/rls-draft.md"))
      assert_match(/storage/i, File.read("supabase/storage.md"))
      assert_match(/NEXT_PUBLIC_SUPABASE_URL/, File.read("supabase/env.example.template"))
      assert_match(/NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY/, File.read("supabase/env.example.template"))

      generated = profile_s_generated_text
      refute_match(/supabase\s+(login|link|projects\s+create|init|start|db\s+push)/i, generated)
      refute_match(/\b(vercel|netlify|cloudflare)\s+deploy\b/i, generated)
      refute_match(/\bcurl\s+https?:\/\//i, generated)
      refute_match(/SUPABASE_SERVICE_ROLE_KEY|sb_secret_[A-Za-z0-9_-]+|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}/, generated)

      metadata = JSON.parse(File.read(".ai-web/scaffold-profile-S.json"))
      assert_equal "S", metadata["profile"]
      assert_equal "Next.js", metadata["framework"]
      assert_equal "pnpm", metadata["package_manager"]
      assert_equal "pnpm dev", metadata["dev_command"]
      assert_equal "pnpm build", metadata["build_command"]
      assert_includes metadata["guardrails"], "no external Supabase project creation"
      assert_includes metadata["guardrails"], "no deploy/external hosting"
      assert_includes metadata["guardrails"], "no .env or .env.* files"

      secret_qa = JSON.parse(File.read(".ai-web/qa/supabase-secret-qa.json"))
      assert_equal "passed", secret_qa["status"]
      assert_equal false, secret_qa["read_dot_env"]
      assert_includes secret_qa["scanned_paths"], "supabase/env.example.template"
      refute secret_qa["scanned_paths"].any? { |path| File.basename(path).match?(/\A\.env(?:\.|\z)/) }

      local_verify = JSON.parse(File.read(".ai-web/qa/supabase-local-verify.json"))
      assert_equal "passed", local_verify["status"]
      assert_equal true, local_verify["local_only"]
      assert_equal false, local_verify["read_dot_env"]
      assert_equal false, local_verify["external_actions_performed"]
      assert_equal false, local_verify["provider_cli_invoked"]
      assert_includes local_verify["scanned_paths"], "supabase/migrations/0001_initial_schema.sql"
      assert_includes local_verify["scanned_paths"], "src/lib/supabase/server.ts"
      assert_equal "passed", local_verify.dig("checks", "migrations_rls", "status")
      assert_equal "passed", local_verify.dig("checks", "ssr_stubs", "status")

      state = load_state
      assert_equal true, state.dig("implementation", "scaffold_created")
      assert_equal "S", state.dig("implementation", "scaffold_profile")
      assert_equal "Next.js", state.dig("implementation", "scaffold_framework")
      assert_equal ".ai-web/scaffold-profile-S.json", state.dig("implementation", "scaffold_metadata_path")
      assert_equal ".ai-web/qa/supabase-local-verify.json", state.dig("qa", "supabase_local_verify")
    end
  end

  def test_scaffold_profile_s_preserves_existing_regular_files_and_does_not_create_env_example
    in_tmp do
      prepare_profile_s_design_flow
      json_cmd("scaffold", "--profile", "S")
      File.write("src/app/page.tsx", "// local user edit\n")

      payload, code = json_cmd("scaffold", "--profile", "S")

      assert_equal 1, code
      assert_match(/existing files.*src\/app\/page\.tsx/, payload.dig("error", "message"))
      assert_equal "// local user edit\n", File.read("src/app/page.tsx")
      assert_no_dot_env_files_created
    end
  end

  def test_supabase_local_verify_dry_run_and_real_run_are_local_only_without_env_reads
    in_tmp do
      prepare_profile_s_design_flow
      json_cmd("scaffold", "--profile", "S")
      env_body = "SECRET=profile-s-local-verify-do-not-read\n"
      File.write(".env", env_body)
      before_state = File.read(".ai-web/state.yaml")
      before_artifact = File.read(".ai-web/qa/supabase-local-verify.json")

      stdout, stderr, code = run_aiweb("supabase-local-verify", "--dry-run", "--json")
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal "passed", payload.dig("supabase_local_verify", "status")
      assert_equal true, payload.dig("supabase_local_verify", "dry_run")
      assert_equal false, payload.dig("supabase_local_verify", "read_dot_env")
      assert_equal false, payload.dig("supabase_local_verify", "external_actions_performed")
      assert_equal before_artifact, File.read(".ai-web/qa/supabase-local-verify.json"), "dry-run must not rewrite local verify artifact"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "dry-run must not mutate state"
      assert_equal env_body, File.read(".env"), "dry-run must not mutate .env"
      refute_includes stdout, "profile-s-local-verify-do-not-read"

      FileUtils.rm_f(".ai-web/qa/supabase-local-verify.json")
      real_payload, real_code = json_cmd("supabase-local-verify")
      assert_equal 0, real_code
      assert_equal "passed", real_payload.dig("supabase_local_verify", "status")
      assert_equal [".ai-web/qa/supabase-local-verify.json", ".ai-web/state.yaml"], real_payload["changed_files"]
      assert_equal false, real_payload.dig("supabase_local_verify", "read_dot_env")
      assert_equal false, real_payload.dig("supabase_local_verify", "external_actions_performed")
      assert File.exist?(".ai-web/qa/supabase-local-verify.json")
      assert_equal env_body, File.read(".env"), "real local verify must not mutate .env"
      refute_includes JSON.generate(real_payload), "profile-s-local-verify-do-not-read"

      web_stdout, web_stderr, web_code = run_webbuilder("supabase-local-verify", "--dry-run", "--json")
      web_payload = JSON.parse(web_stdout)
      assert_equal 0, web_code
      assert_equal "", web_stderr
      assert_equal "passed", web_payload.dig("supabase_local_verify", "status")
      assert_equal true, web_payload.dig("supabase_local_verify", "dry_run")
    end
  end

  def test_supabase_local_verify_fails_when_profile_s_file_is_missing
    in_tmp do
      prepare_profile_s_design_flow
      json_cmd("scaffold", "--profile", "S")
      FileUtils.rm_f("src/lib/supabase/server.ts")

      payload, code = json_cmd("supabase-local-verify")

      assert_equal 1, code
      assert_equal "failed", payload.dig("supabase_local_verify", "status")
      messages = payload.dig("supabase_local_verify", "findings").map { |finding| finding["message"] }.join("\n")
      assert_match(/required Profile S file is missing|createServerClient|cookies/, messages)
      assert_equal false, payload.dig("supabase_local_verify", "read_dot_env")
      assert_equal false, payload.dig("supabase_local_verify", "external_actions_performed")
    end
  end


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

  def write_fake_codex_tooling(root, prompt_path: nil, patch_path: nil, marker_path: nil, stdout_text: "fake codex stdout", stderr_text: "fake codex stderr", exit_status: 0)
    bin_dir = File.join(root, "fake-agent-bin")
    FileUtils.mkdir_p(bin_dir)
    script = File.join(bin_dir, "codex-fake.rb")
    File.write(
      script,
      <<~RUBY
        # frozen_string_literal: true

        require "fileutils"

        input = STDIN.read
        prompt_path = #{prompt_path.inspect}
        patch_path = #{patch_path.inspect}
        marker_path = #{marker_path.inspect}

        unless prompt_path.to_s.empty?
          FileUtils.mkdir_p(File.dirname(prompt_path))
          File.write(prompt_path, input)
        end

        if !patch_path.to_s.empty? && File.file?(patch_path)
          File.open(patch_path, "a") { |file| file.write("\\n<!-- patched by fake codex -->\\n") }
        end

        unless marker_path.to_s.empty?
          FileUtils.mkdir_p(File.dirname(marker_path))
          FileUtils.touch(marker_path)
        end

        puts #{stdout_text.inspect}
        warn #{stderr_text.inspect}
        exit #{exit_status.to_i}
      RUBY
    )
    if windows?
      File.write(File.join(bin_dir, "codex.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{script}\" %*\r\n")
    else
      wrapper = File.join(bin_dir, "codex")
      File.write(wrapper, "#!/bin/sh\nexec #{RbConfig.ruby.shellescape} #{script.shellescape} \"$@\"\n")
      FileUtils.chmod("+x", wrapper)
    end
    bin_dir
  end

  def write_fake_codex_env_guard_tooling(root)
    bin_dir = File.join(root, "fake-codex-env-guard-bin")
    FileUtils.mkdir_p(bin_dir)
    if windows?
      script = File.join(bin_dir, "codex-env-guard-fake.rb")
      File.write(
        script,
        <<~'RUBY'
          # frozen_string_literal: true
          STDIN.read
          if ENV.keys.any? { |key| %w[OPENAI_API_KEY ANTHROPIC_API_KEY FAKE_CODEX_SECRET].include?(key) }
            warn "secret environment leaked to codex"
            exit 81
          end
          path = File.join("src", "components", "Hero.astro")
          File.open(path, "a") { |file| file.write("\n<!-- patched by env guard codex -->\n") } if File.file?(path)
          puts "fake env guard codex stdout"
        RUBY
      )
      File.write(File.join(bin_dir, "codex.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{script}\" %*\r\n")
    else
      script = File.join(bin_dir, "codex")
      File.write(
        script,
        <<~'SH'
          #!/bin/sh
          cat >/dev/null
          if env | grep -E 'OPENAI_API_KEY|ANTHROPIC_API_KEY|FAKE_CODEX_SECRET' >/dev/null; then
            echo "secret environment leaked to codex" >&2
            exit 81
          fi
          if [ -f src/components/Hero.astro ]; then
            printf '\n<!-- patched by env guard codex -->\n' >> src/components/Hero.astro
          fi
          echo "fake env guard codex stdout"
        SH
      )
      FileUtils.chmod("+x", script)
    end
    bin_dir
  end

  def write_fake_engine_codex_tooling(root, patch_path: "src/components/Hero.astro", secret_path: nil, patch_text: "<!-- patched by fake engine codex -->", stdout_text: "fake engine codex stdout", exit_status: 0)
    bin_dir = File.join(root, "fake-engine-bin")
    FileUtils.mkdir_p(bin_dir)
    if windows?
      script = File.join(bin_dir, "codex-engine-fake.rb")
      File.write(
        script,
        <<~RUBY
          # frozen_string_literal: true
          STDIN.read
          path = #{patch_path.inspect}
          if path && !path.empty? && File.file?(path)
            File.open(path, "a") { |file| file.write("\\n" + #{patch_text.inspect} + "\\n") }
          end
          secret_path = #{secret_path.inspect}
          File.write(secret_path, "SECRET=engine-run-created-env\\n") if secret_path && !secret_path.empty?
          puts #{stdout_text.inspect}
          warn "fake engine codex stderr"
          exit #{exit_status.to_i}
        RUBY
      )
      File.write(File.join(bin_dir, "codex.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{script}\" %*\r\n")
    else
      script = File.join(bin_dir, "codex")
      File.write(
        script,
        <<~SH
          #!/bin/sh
          cat >/dev/null
          if [ -n #{patch_path.shellescape} ] && [ -f #{patch_path.shellescape} ]; then
            printf '\\n%s\\n' #{patch_text.shellescape} >> #{patch_path.shellescape}
          fi
          if [ -n #{secret_path.to_s.shellescape} ]; then
            printf 'SECRET=engine-run-created-env\\n' > #{secret_path.to_s.shellescape}
          fi
          echo #{stdout_text.shellescape}
          echo "fake engine codex stderr" >&2
          exit #{exit_status.to_i}
        SH
      )
      FileUtils.chmod("+x", script)
    end
    bin_dir
  end

  def write_fake_engine_repair_tooling(root)
    bin_dir = File.join(root, "fake-engine-repair-bin")
    FileUtils.mkdir_p(bin_dir)
    if windows?
      codex_script = File.join(bin_dir, "codex-repair-fake.rb")
      File.write(
        codex_script,
        <<~'RUBY'
          # frozen_string_literal: true
          STDIN.read
          marker = File.file?(File.join("_aiweb", "repair-observation.json")) ? "<!-- fixed after qa -->" : "<!-- needs repair -->"
          File.open(File.join("src", "components", "Hero.astro"), "a") { |file| file.write("\n#{marker}\n") }
          puts "fake repair codex stdout"
        RUBY
      )
      File.write(File.join(bin_dir, "codex.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{codex_script}\" %*\r\n")
      npm_script = File.join(bin_dir, "npm-repair-fake.rb")
      File.write(
        npm_script,
        <<~'RUBY'
          # frozen_string_literal: true
          unless ARGV == ["run", "build"]
            warn "unexpected npm command: #{ARGV.join(" ")}"
            exit 64
          end
          body = File.file?(File.join("src", "components", "Hero.astro")) ? File.read(File.join("src", "components", "Hero.astro")) : ""
          if body.include?("fixed after qa")
            puts "fake build passed"
            exit 0
          end
          warn "fake build failed"
          exit 7
        RUBY
      )
      File.write(File.join(bin_dir, "npm.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{npm_script}\" %*\r\n")
    else
      codex_script = File.join(bin_dir, "codex")
      File.write(
        codex_script,
        <<~'SH'
          #!/bin/sh
          cat >/dev/null
          if [ -f _aiweb/repair-observation.json ]; then
            printf '\n<!-- fixed after qa -->\n' >> src/components/Hero.astro
          else
            printf '\n<!-- needs repair -->\n' >> src/components/Hero.astro
          fi
          echo "fake repair codex stdout"
        SH
      )
      FileUtils.chmod("+x", codex_script)
      npm_script = File.join(bin_dir, "npm")
      File.write(
        npm_script,
        <<~'SH'
          #!/bin/sh
          if [ "$1 $2" != "run build" ]; then
            echo "unexpected npm command: $*" >&2
            exit 64
          fi
          if grep -q "fixed after qa" src/components/Hero.astro; then
            echo "fake build passed"
            exit 0
          fi
          echo "fake build failed" >&2
          exit 7
        SH
      )
      FileUtils.chmod("+x", npm_script)
    end
    bin_dir
  end

  def write_fake_engine_verification_guard_tooling(root)
    bin_dir = write_fake_engine_codex_tooling(root)
    if windows?
      npm_script = File.join(bin_dir, "npm-guard-fake.rb")
      File.write(
        npm_script,
        <<~'RUBY'
          # frozen_string_literal: true
          if ENV.keys.any? { |key| %w[OPENAI_API_KEY ANTHROPIC_API_KEY FAKE_ENGINE_SECRET].include?(key) }
            warn "secret environment leaked to verification"
            exit 81
          end
          unless ARGV == ["run", "build"]
            warn "unexpected npm command: #{ARGV.join(" ")}"
            exit 64
          end
          puts "fake clean verification"
        RUBY
      )
      File.write(File.join(bin_dir, "npm.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{npm_script}\" %*\r\n")
    else
      npm_script = File.join(bin_dir, "npm")
      File.write(
        npm_script,
        <<~'SH'
          #!/bin/sh
          if env | grep -E 'OPENAI_API_KEY|ANTHROPIC_API_KEY|FAKE_ENGINE_SECRET' >/dev/null; then
            echo "secret environment leaked to verification" >&2
            exit 81
          fi
          if [ "$1 $2" != "run build" ]; then
            echo "unexpected npm command: $*" >&2
            exit 64
          fi
          echo "fake clean verification"
        SH
      )
      FileUtils.chmod("+x", npm_script)
    end
    bin_dir
  end

  def write_fake_engine_openmanus_repair_tooling(root, agent_result_payload_after_repair: nil)
    bin_dir = write_fake_openmanus_tooling(root, repair_mode: true, agent_result_payload_after_repair: agent_result_payload_after_repair)
    if windows?
      npm_script = File.join(bin_dir, "npm-repair-fake.rb")
      File.write(
        npm_script,
        <<~'RUBY'
          # frozen_string_literal: true
          unless ARGV == ["run", "build"]
            warn "unexpected npm command: #{ARGV.join(" ")}"
            exit 64
          end
          body = File.file?(File.join("src", "components", "Hero.astro")) ? File.read(File.join("src", "components", "Hero.astro")) : ""
          if body.include?("fixed after qa")
            puts "fake build passed"
            exit 0
          end
          warn "fake build failed"
          exit 7
        RUBY
      )
      File.write(File.join(bin_dir, "npm.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{npm_script}\" %*\r\n")
    else
      npm_script = File.join(bin_dir, "npm")
      File.write(
        npm_script,
        <<~'SH'
          #!/bin/sh
          if [ "$1 $2" != "run build" ]; then
            echo "unexpected npm command: $*" >&2
            exit 64
          fi
          if grep -q "fixed after qa" src/components/Hero.astro; then
            echo "fake build passed"
            exit 0
          fi
          echo "fake build failed" >&2
          exit 7
        SH
      )
      FileUtils.chmod("+x", npm_script)
    end
    bin_dir
  end

  def write_fake_engine_openmanus_verification_guard_tooling(root)
    bin_dir = write_fake_openmanus_tooling(root)
    if windows?
      npm_script = File.join(bin_dir, "npm-guard-fake.rb")
      File.write(
        npm_script,
        <<~'RUBY'
          # frozen_string_literal: true
          if ENV.keys.any? { |key| %w[OPENAI_API_KEY ANTHROPIC_API_KEY FAKE_ENGINE_SECRET].include?(key) }
            warn "secret environment leaked to verification"
            exit 81
          end
          unless ARGV == ["run", "build"]
            warn "unexpected npm command: #{ARGV.join(" ")}"
            exit 64
          end
          puts "fake clean verification"
        RUBY
      )
      File.write(File.join(bin_dir, "npm.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{npm_script}\" %*\r\n")
    else
      npm_script = File.join(bin_dir, "npm")
      File.write(
        npm_script,
        <<~'SH'
          #!/bin/sh
          if env | grep -E 'OPENAI_API_KEY|ANTHROPIC_API_KEY|FAKE_ENGINE_SECRET' >/dev/null; then
            echo "secret environment leaked to verification" >&2
            exit 81
          fi
          if [ "$1 $2" != "run build" ]; then
            echo "unexpected npm command: $*" >&2
            exit 64
          fi
          echo "fake clean verification"
        SH
      )
      FileUtils.chmod("+x", npm_script)
    end
    bin_dir
  end

  def write_fake_engine_openmanus_preview_tooling(root, preview_exit_status: 0, **fake_options)
    bin_dir = write_fake_openmanus_tooling(root, **fake_options)
    if windows?
      npm_script = File.join(bin_dir, "npm-preview-fake.rb")
      File.write(
        npm_script,
        <<~RUBY
          # frozen_string_literal: true
          unless ARGV == ["run", "dev"]
            warn "unexpected npm command: \#{ARGV.join(" ")}"
            exit 64
          end
          if #{preview_exit_status.to_i} != 0
            warn "fake preview failed"
            exit #{preview_exit_status.to_i}
          end
          puts "Local: http://127.0.0.1:4321/"
          exit 0
        RUBY
      )
      File.write(File.join(bin_dir, "npm.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{npm_script}\" %*\r\n")
    else
      npm_script = File.join(bin_dir, "npm")
      File.write(
        npm_script,
        <<~SH
          #!/bin/sh
          if [ "$1 $2" != "run dev" ]; then
            echo "unexpected npm command: $*" >&2
            exit 64
          fi
          if [ #{preview_exit_status.to_i} -ne 0 ]; then
            echo "fake preview failed" >&2
            exit #{preview_exit_status.to_i}
          fi
          echo "Local: http://127.0.0.1:4321/"
          exit 0
        SH
      )
      FileUtils.chmod("+x", npm_script)
    end
    write_fake_engine_browser_observe_tooling(bin_dir)
    bin_dir
  end

  def write_fake_engine_browser_observe_tooling(bin_dir)
    script = File.join(bin_dir, "node-browser-observe-fake.rb")
    File.write(
      script,
      <<~'RUBY'
        # frozen_string_literal: true

        require "fileutils"
        require "json"
        require "zlib"

        def png_chunk(type, data)
          [data.bytesize].pack("N") + type + data + [Zlib.crc32(type + data)].pack("N")
        end

        def write_fake_png(path, width, height)
          width = width.to_i
          height = height.to_i
          row = "\x00".b + ("\xF4\xF4\xF4".b * width)
          raw = row * height
          png = "\x89PNG\r\n\x1A\n".b +
            png_chunk("IHDR", [width, height, 8, 2, 0, 0, 0].pack("NNCCCCC")) +
            png_chunk("IDAT", Zlib::Deflate.deflate(raw)) +
            png_chunk("IEND", "".b)
          File.binwrite(path, png)
        end

        unless ARGV[0].to_s.tr("\\", "/") == "_aiweb/browser-observe.js"
          warn "unexpected node command: #{ARGV.join(" ")}"
          exit 64
        end

        url, viewport, width, height, screenshot_path, evidence_path = ARGV[1, 6]
        FileUtils.mkdir_p(File.dirname(screenshot_path))
        FileUtils.mkdir_p(File.dirname(evidence_path))
        if ENV["BROWSER_OBSERVE_FAKE_STATUS"] == "failed" || File.file?(File.join(".ai-web", "fail-browser-observe"))
          File.write(evidence_path, JSON.pretty_generate(
            "schema_version" => 1,
            "status" => "failed",
            "viewport" => viewport,
            "width" => width.to_i,
            "height" => height.to_i,
            "url" => url,
            "blocking_issues" => ["fake browser observation failed"]
          ))
          warn "fake browser observe failure"
          exit 1
        end
        if ENV["BROWSER_OBSERVE_FAKE_INVALID_PNG"] == "1" || File.file?(File.join(".ai-web", "fake-browser-invalid-png"))
          File.write(screenshot_path, "fake browser screenshot for #{viewport} #{url}\n")
        else
          write_fake_png(screenshot_path, width, height)
        end
        console_errors = if ENV["BROWSER_OBSERVE_FAKE_CONSOLE_ERROR"] == "1" || File.file?(File.join(".ai-web", "fake-browser-console-error"))
          [{ "type" => "error", "text" => "fake console error", "location" => { "url" => url, "lineNumber" => 1, "columnNumber" => 1 } }]
        else
          []
        end
        network_errors = if ENV["BROWSER_OBSERVE_FAKE_NETWORK_ERROR"] == "1" || File.file?(File.join(".ai-web", "fake-browser-network-error"))
          [{ "url" => "#{url}missing.js", "method" => "GET", "resource_type" => "script", "status" => 500 }]
        else
          []
        end
        external_request_blocked = ENV["BROWSER_OBSERVE_FAKE_EXTERNAL_REQUEST_BLOCKED"] == "1" || File.file?(File.join(".ai-web", "fake-browser-external-request-blocked"))
        external_requests_blocked = external_request_blocked ? [
          { "url" => "https://example.test/asset.js", "method" => "GET", "resource_type" => "script", "is_navigation_request" => false, "failure" => "non_local_request_blocked" }
        ] : []
        network_errors.concat(external_requests_blocked)
        action_recovery_failed = ENV["BROWSER_OBSERVE_FAKE_ACTION_RECOVERY_FAIL"] == "1" || File.file?(File.join(".ai-web", "fake-browser-action-recovery-fail"))
        action_recovery_status = (action_recovery_failed || external_request_blocked) ? "failed" : "captured"
        action_recovery_blockers = []
        action_recovery_blockers << "fake action recovery failed" if action_recovery_failed
        action_recovery_blockers << "1 non-local browser request(s) were blocked" if external_request_blocked
        action_recovery = {
          "schema_version" => 1,
          "status" => action_recovery_status,
          "required" => true,
          "policy" => "localhost-only reversible UI actions; external navigation is blocked and recorded",
          "viewport" => viewport,
          "url" => url,
          "actionable_target_count" => 1,
          "actions" => [
            {
              "index" => 0,
              "status" => action_recovery_status,
              "selector" => "[data-aiweb-id=\"component.hero.copy\"]",
              "text_role" => "section",
              "actions" => [
                { "name" => "scroll_into_view", "status" => "passed" },
                { "name" => "hover", "status" => "passed" },
                { "name" => "focus", "status" => "passed" }
              ],
              "recovery" => [{ "name" => "escape", "status" => "passed" }]
            }
          ],
          "recovery_steps" => [{ "action" => "restore_preview_url", "status" => action_recovery_failed ? "failed" : "passed", "from" => url, "to" => url }],
          "external_requests_blocked" => external_requests_blocked,
          "unsafe_navigation_policy_enforced" => true,
          "unsafe_navigation_blocked" => external_request_blocked,
          "blocking_issues" => action_recovery_blockers
        }
        evidence = {
          "schema_version" => 1,
          "status" => "captured",
          "capture_mode" => "playwright_browser",
          "viewport" => viewport,
          "width" => width.to_i,
          "height" => height.to_i,
          "url" => url,
          "screenshot" => {
            "path" => screenshot_path,
            "capture_mode" => "playwright_browser"
          },
          "console_errors" => console_errors,
          "network_errors" => network_errors,
          "dom_snapshot" => {
            "schema_version" => 1,
            "status" => "captured",
            "capture_mode" => "playwright_browser",
            "route" => "/",
            "viewport" => viewport,
            "selectors" => [
              {
                "selector" => "[data-aiweb-id=\"component.hero.copy\"]",
                "data_aiweb_id" => "component.hero.copy",
                "text_role" => "section",
                "computed_styles" => { "font_size" => "16px", "line_height" => "24px" },
                "bounding_box" => { "x" => 0, "y" => 0, "width" => width.to_i, "height" => 120 }
              }
            ],
            "required_fields" => %w[route viewport selector data_aiweb_id text_role computed_styles bounding_box]
          },
          "a11y_report" => {
            "schema_version" => 1,
            "status" => "captured",
            "capture_mode" => "playwright_accessibility_tree",
            "required_checks" => %w[contrast keyboard_focus aria_labels landmarks touch_targets],
            "accessibility_tree_present" => true,
            "findings" => []
          },
          "computed_style_summary" => {
            "schema_version" => 1,
            "status" => "captured",
            "capture_mode" => "playwright_computed_style",
            "required_properties" => %w[font-family font-size font-weight line-height color background-color margin padding gap display grid flex overflow],
            "sampled_count" => 1
          },
          "interaction_states" => %w[default hover focus-visible active disabled loading empty error success].map do |state|
            {
              "state" => state,
              "status" => %w[disabled loading empty error success].include?(state) ? "not_applicable" : "captured",
              "evidence" => state == "default" ? [screenshot_path] : []
            }
          end,
          "keyboard_focus_traversal" => {
            "schema_version" => 1,
            "status" => "captured",
            "required" => true,
            "steps" => [{ "selector" => "[data-aiweb-id=\"component.hero.copy\"]", "text_role" => "section" }]
          },
          "action_recovery" => action_recovery,
          "blocking_issues" => []
        }
        File.write(evidence_path, JSON.pretty_generate(evidence))
        if ENV["BROWSER_OBSERVE_FAKE_EXIT_AFTER_EVIDENCE"] == "1" || File.file?(File.join(".ai-web", "fake-browser-exit-after-evidence"))
          warn "fake browser observe wrote evidence then failed"
          exit 1
        end
        warn "fake browser observe pass"
        exit 0
      RUBY
    )
    FileUtils.chmod("+x", script)
    if windows?
      File.write(File.join(bin_dir, "node.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{script}\" %*\r\n")
    else
      File.write(File.join(bin_dir, "node"), "#!/bin/sh\nexec #{RbConfig.ruby.shellescape} #{script.shellescape} \"$@\"\n")
      FileUtils.chmod("+x", File.join(bin_dir, "node"))
    end
  end

  def write_fake_openmanus_tooling(root, exit_status: 0, patch_workspace: true, mutate_root_path: nil, patch_path: File.join("src", "components", "Hero.astro"), patch_text: "<!-- patched by fake openmanus -->", stdout_text: "fake openmanus stdout", secret_path: nil, repair_mode: false, repair_first_text: "<!-- needs repair -->", repair_fixed_text: "<!-- fixed after qa -->", overwrite_workspace: false, include_podman: true, broker_blocked_action: nil, broker_args_text: nil, agent_result_payload: nil, agent_result_payload_after_repair: nil)
    bin_dir = File.join(root, "fake-openmanus-bin")
    FileUtils.mkdir_p(bin_dir)
    docker_script = File.join(bin_dir, "docker-openmanus-fake.rb")
    File.write(
      docker_script,
      <<~RUBY
        # frozen_string_literal: true
        require "fileutils"
        require "json"

        CONTAINER_MAP_PATH = File.join(File.dirname(__FILE__), "fake-runtime-containers.json")

        def option_value(argv, flag)
          index = argv.index(flag)
          return argv[index + 1].to_s if index && index + 1 < argv.length

          prefix = flag + "="
          argv.find { |value| value.start_with?(prefix) }.to_s.delete_prefix(prefix)
        end

        def option_values(argv, flag)
          values = []
          argv.each_with_index do |value, index|
            values << argv[index + 1].to_s if value == flag && index + 1 < argv.length
            values << value.delete_prefix(flag + "=") if value.start_with?(flag + "=")
          end
          values
        end

        def container_env(argv)
          option_values(argv, "-e").each_with_object({}) do |entry, memo|
            key, value = entry.split("=", 2)
            memo[key] = value.nil? ? ENV[key].to_s : value
          end
        end

        def workspace_path(host_workspace, container_path)
          text = container_path.to_s
          return text unless text.start_with?("/workspace/")

          File.join(host_workspace, text.delete_prefix("/workspace/"))
        end

        def read_container_map
          return {} unless File.file?(CONTAINER_MAP_PATH)

          JSON.parse(File.read(CONTAINER_MAP_PATH))
        rescue JSON::ParserError
          {}
        end

        def write_container_map(container_id, host_workspace)
          map = read_container_map
          map[container_id] = host_workspace
          File.write(CONTAINER_MAP_PATH, JSON.pretty_generate(map))
        end

        if ARGV[0] == "image" && ARGV[1] == "inspect"
          if ENV.keys.any? { |key| %w[OPENAI_API_KEY ANTHROPIC_API_KEY FAKE_OPENMANUS_SECRET].include?(key) }
            warn "secret environment leaked to docker image inspect"
            exit 82
          end
          if ENV["FAKE_OPENMANUS_IMAGE_MISSING"] == "1" || ARGV[2].to_s.include?("missing")
            warn "fake image missing"
            exit 1
          end
          if File.file?(File.join(Dir.pwd, ".ai-web", "empty-image-inspect"))
            exit 0
          end
          if File.file?(File.join(Dir.pwd, ".ai-web", "malformed-image-inspect"))
            puts "not-json"
            exit 0
          end
          image = ARGV[2].to_s
          image = "openmanus:latest" if image.empty?
          puts [{
            "Id" => "sha256:" + "a" * 64,
            "RepoDigests" => [image.sub(/:.*/, "") + "@sha256:" + "b" * 64],
            "Created" => "2026-05-14T00:00:00Z",
            "Architecture" => "amd64",
            "Os" => "linux"
          }].to_json
          exit 0
        end

        if ARGV[0] == "info"
          if ENV.keys.any? { |key| %w[OPENAI_API_KEY ANTHROPIC_API_KEY FAKE_OPENMANUS_SECRET].include?(key) }
            warn "secret environment leaked to docker info"
            exit 82
          end
          puts({
            "ServerVersion" => "fake-docker-26.0",
            "Driver" => "overlay2",
            "CgroupDriver" => "cgroupfs",
            "SecurityOptions" => ["name=seccomp,profile=default", "name=rootless"]
          }.to_json)
          exit 0
        end

        if ARGV[0] == "inspect"
          container_id = ARGV[1].to_s
          unsafe_inspect = ENV["FAKE_OPENMANUS_UNSAFE_INSPECT"] == "1" || File.file?(File.join(Dir.pwd, ".ai-web", "unsafe-runtime-inspect"))
          workspace_source = read_container_map[container_id].to_s
          workspace_source = "fake-wrong-workspace" if File.file?(File.join(Dir.pwd, ".ai-web", "unsafe-runtime-inspect-source"))
          workspace_source = "fake-workspace" if workspace_source.empty?
          puts [{
            "Id" => container_id.empty? ? "fake-runtime-container-missing" : container_id,
            "Name" => "/\#{container_id}",
            "Image" => "sha256:" + "a" * 64,
            "Config" => {
              "User" => option_value(ARGV, "--user").empty? ? "1000:1000" : option_value(ARGV, "--user")
            },
            "HostConfig" => {
              "NetworkMode" => unsafe_inspect ? "bridge" : "none",
              "ReadonlyRootfs" => true,
              "CapDrop" => ["ALL"],
              "SecurityOpt" => ["no-new-privileges"],
              "UsernsMode" => "",
              "PidsLimit" => 512,
              "Memory" => 2147483648,
              "NanoCpus" => 2000000000
            },
            "State" => {
              "Status" => "exited",
              "ExitCode" => 0,
              "OOMKilled" => false
            },
            "AppArmorProfile" => "docker-default",
            "ProcessLabel" => "system_u:system_r:container_t:s0:c1,c2",
            "Mounts" => [
              {
                "Type" => "bind",
                "Source" => workspace_source,
                "Destination" => "/workspace",
                "Mode" => "rw",
                "RW" => true
              }
            ]
          }].to_json
          exit 0
        end

        if ARGV[0] == "rm"
          exit 0
        end

        unless ARGV[0] == "run"
          warn "expected docker run"
          exit 64
        end
        if ENV.keys.any? { |key| %w[OPENAI_API_KEY ANTHROPIC_API_KEY FAKE_OPENMANUS_SECRET].include?(key) }
          warn "secret environment leaked to docker"
          exit 81
        end
        env = container_env(ARGV)
        unless env["AIWEB_NETWORK_ALLOWED"] == "0"
          warn "network guard missing"
          exit 82
        end
        unless env["AIWEB_MCP_ALLOWED"] == "0"
          warn "mcp guard missing"
          exit 83
        end
        unless env["AIWEB_ENV_ACCESS_ALLOWED"] == "0"
          warn "env guard missing"
          exit 84
        end
        unless option_value(ARGV, "--network") == "none"
          warn "network none missing"
          exit 85
        end
        mount = option_values(ARGV, "-v").find { |value| value.end_with?(":/workspace:rw") }.to_s
        host_workspace = mount.sub(%r{:/workspace:rw\\z}, "")
        if host_workspace.empty? || !Dir.exist?(host_workspace)
          warn "workspace mount missing"
          exit 86
        end
        cidfile = option_value(ARGV, "--cidfile")
        unless cidfile.empty?
          FileUtils.mkdir_p(File.dirname(cidfile))
          fake_container_id = "fake-runtime-container-\#{File.basename(host_workspace)}"
          File.write(cidfile, fake_container_id + "\n")
          write_container_map(fake_container_id, host_workspace)
        end

        STDIN.read
        configured_images = [ENV["AIWEB_OPENMANUS_IMAGE"].to_s, ENV["AIWEB_OPENHANDS_IMAGE"].to_s, ENV["AIWEB_LANGGRAPH_IMAGE"].to_s, ENV["AIWEB_OPENAI_AGENTS_IMAGE"].to_s, "openmanus:latest", "openhands:latest", "langgraph:latest", "openai-agents:latest"].reject(&:empty?)
        image_index = configured_images.filter_map { |image| ARGV.index(image) }.min
        container_command = image_index ? ARGV[(image_index + 1)..] : []
        tool_exit_status = nil
        Dir.chdir(host_workspace) do
          if env["AIWEB_ENGINE_RUN_TOOL"] == "sandbox_preflight_probe"
            if File.file?(File.join(".ai-web", "fail-sandbox-preflight-command"))
              warn "fake sandbox preflight command failed"
              tool_exit_status = 77
            elsif File.file?(File.join(".ai-web", "malformed-sandbox-preflight-probe"))
              puts "not-json"
              tool_exit_status = 0
            else
              probe_status = File.file?(File.join(".ai-web", "fail-sandbox-preflight-probe")) ? "failed" : "passed"
              puts({
                "schema_version" => 1,
                "status" => probe_status,
                "container_id" => probe_status == "passed" ? "fake-container-\#{File.basename(host_workspace)}" : nil,
                "effective_user" => {
                  "uid" => probe_status == "passed" ? 1000 : nil,
                  "gid" => 1000,
                  "name" => "aiweb"
                },
                "cwd" => "/workspace",
                "home" => env["HOME"],
                "env_guards" => {
                  "AIWEB_NETWORK_ALLOWED" => env["AIWEB_NETWORK_ALLOWED"],
                  "AIWEB_MCP_ALLOWED" => env["AIWEB_MCP_ALLOWED"],
                  "AIWEB_ENV_ACCESS_ALLOWED" => env["AIWEB_ENV_ACCESS_ALLOWED"],
                  "AIWEB_ENGINE_RUN_TOOL" => env["AIWEB_ENGINE_RUN_TOOL"]
                },
                "workspace_writable" => true,
                "root_filesystem_write_blocked" => true,
                "security_attestation" => {
                  "status" => probe_status,
                  "source" => "/proc/self/status",
                  "no_new_privs" => "1",
                  "no_new_privs_enabled" => true,
                  "seccomp" => "2",
                  "seccomp_filtering" => true,
                  "seccomp_filters" => "1",
                  "cap_eff" => "0000000000000000",
                  "cap_eff_zero" => true,
                  "cap_prm" => "0000000000000000",
                  "cap_bnd" => "0000000000000000"
                },
                "cgroup" => {
                  "source" => "/proc/self/cgroup",
                  "lines" => ["0::/fake-aiweb"]
                },
                "mountinfo_excerpt" => {
                  "source" => "/proc/self/mountinfo",
                  "lines" => ["1 0 0:1 / /workspace rw - overlay overlay rw"]
                },
                "egress_denial_probe" => {
                  "status" => probe_status,
                  "method" => "fake_inside_container_no_network_probe",
                  "target" => "93.184.216.34:80",
                  "observed" => probe_status == "passed" ? "connection_denied" : "unexpected_connect"
                }
              }.to_json)
              tool_exit_status = 0
            end
          elsif container_command.empty? || %w[openmanus openhands].include?(container_command.first.to_s) || container_command.join(" ").include?("langgraph-worker.py") || container_command.join(" ").include?("openai-agents-worker.py")
            puts #{stdout_text.inspect}
            warn "fake openmanus stderr"
            broker_blocked_action = #{broker_blocked_action.inspect}
            unless broker_blocked_action.to_s.empty?
              event_path = workspace_path(host_workspace, env["AIWEB_TOOL_BROKER_EVENTS_PATH"].to_s)
              FileUtils.mkdir_p(File.dirname(event_path)) unless event_path.empty?
              File.open(event_path, "a") do |file|
                file.puts({
                  "schema_version" => 1,
                  "type" => "tool.blocked",
                  "tool_name" => broker_blocked_action == "package_install" ? "npm" : broker_blocked_action,
                  "risk_class" => broker_blocked_action,
                  "reason" => "fake staged tool broker blocked " + broker_blocked_action,
                  "args_text" => #{broker_args_text.inspect} || (broker_blocked_action == "package_install" ? "install left-pad" : broker_blocked_action)
                }.to_json)
              end
              warn "AIWEB_TOOL_BROKER_BLOCKED " + broker_blocked_action
            end
            if #{patch_workspace ? "true" : "false"}
              path = #{patch_path.inspect}
              marker = if #{repair_mode ? "true" : "false"}
                         File.file?(File.join("_aiweb", "repair-observation.json")) ? #{repair_fixed_text.inspect} : #{repair_first_text.inspect}
                       else
                         #{patch_text.inspect}
                       end
              if File.file?(path)
                if #{overwrite_workspace ? "true" : "false"}
                  File.write(path, marker)
                else
                  File.open(path, "a") { |file| file.write("\\n" + marker + "\\n") }
                end
              end
            end
            secret_path = #{secret_path.inspect}
            File.write(secret_path, "SECRET=engine-run-created-env\\n") if secret_path && !secret_path.empty?
            result_env_path = env["AIWEB_OPENMANUS_RESULT_PATH"].to_s
            result_env_path = env["AIWEB_OPENHANDS_RESULT_PATH"].to_s if result_env_path.empty?
            result_env_path = env["AIWEB_LANGGRAPH_RESULT_PATH"].to_s if result_env_path.empty?
            result_env_path = env["AIWEB_OPENAI_AGENTS_RESULT_PATH"].to_s if result_env_path.empty?
            result_env_path = env["AIWEB_ENGINE_RUN_RESULT_PATH"].to_s if result_env_path.empty?
            result_path = workspace_path(host_workspace, result_env_path)
            FileUtils.mkdir_p(File.dirname(result_path)) unless result_path.empty?
            configured_result = #{agent_result_payload.nil? ? "nil" : JSON.generate(agent_result_payload).inspect}
            configured_result_after_repair = #{agent_result_payload_after_repair.nil? ? "nil" : JSON.generate(agent_result_payload_after_repair).inspect}
            if configured_result_after_repair && File.file?(File.join(host_workspace, "_aiweb", "repair-observation.json"))
              configured_result = configured_result_after_repair
            end
            File.write(result_path, configured_result || "{\\"schema_version\\":1,\\"status\\":\\"patched\\",\\"sandbox_mode\\":\\"docker\\"}\\n") unless result_path.empty?
          else
            system(*container_command)
            tool_exit_status = $?.exitstatus
          end
        end
        exit tool_exit_status if tool_exit_status
        root_mutation_path = #{mutate_root_path.inspect}
        if root_mutation_path && !root_mutation_path.empty?
          File.open(root_mutation_path, "a") { |file| file.write("\\n<!-- root mutation by fake openmanus -->\\n") }
        end
        exit #{exit_status.to_i}
      RUBY
    )
    if RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/i)
      File.write(File.join(bin_dir, "docker.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{docker_script}\" %*\r\n")
      File.write(File.join(bin_dir, "podman.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{docker_script}\" %*\r\n") if include_podman
    else
      File.write(File.join(bin_dir, "docker"), "#!/bin/sh\nexec #{RbConfig.ruby.shellescape} #{docker_script.shellescape} \"$@\"\n")
      FileUtils.chmod("+x", File.join(bin_dir, "docker"))
      if include_podman
        File.write(File.join(bin_dir, "podman"), "#!/bin/sh\nexec #{RbConfig.ruby.shellescape} #{docker_script.shellescape} \"$@\"\n")
        FileUtils.chmod("+x", File.join(bin_dir, "podman"))
      end
    end

    if RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/i)
      script = File.join(bin_dir, "openmanus-fake.rb")
      File.write(
        script,
        <<~RUBY
          # frozen_string_literal: true
          STDIN.read
          if ENV.keys.any? { |key| %w[OPENAI_API_KEY ANTHROPIC_API_KEY FAKE_OPENMANUS_SECRET].include?(key) }
            warn "secret environment leaked to openmanus"
            exit 81
          end
          unless ENV["AIWEB_NETWORK_ALLOWED"] == "0"
            warn "network guard missing"
            exit 82
          end
          unless ENV["AIWEB_MCP_ALLOWED"] == "0"
            warn "mcp guard missing"
            exit 83
          end
          unless ENV["AIWEB_ENV_ACCESS_ALLOWED"] == "0"
            warn "env guard missing"
            exit 84
          end
          puts #{stdout_text.inspect}
          warn "fake openmanus stderr"
          if #{patch_workspace ? "true" : "false"}
            path = #{patch_path.inspect}
            marker = if #{repair_mode ? "true" : "false"}
                       File.file?(File.join("_aiweb", "repair-observation.json")) ? #{repair_fixed_text.inspect} : #{repair_first_text.inspect}
                     else
                       #{patch_text.inspect}
                     end
            if File.file?(path)
              if #{overwrite_workspace ? "true" : "false"}
                File.write(path, marker)
              else
                File.open(path, "a") { |file| file.write("\\n" + marker + "\\n") }
              end
            end
          end
          secret_path = #{secret_path.inspect}
          File.write(secret_path, "SECRET=engine-run-created-env\\n") if secret_path && !secret_path.empty?
          root_mutation_path = #{mutate_root_path.inspect}
          if root_mutation_path && !root_mutation_path.empty?
            File.open(root_mutation_path, "a") { |file| file.write("\\n<!-- root mutation by fake openmanus -->\\n") }
          end
          result_path = ENV["AIWEB_OPENMANUS_RESULT_PATH"].to_s
          File.write(result_path, "{\\"schema_version\\":1,\\"status\\":\\"patched\\"}\\n") unless result_path.empty?
          exit #{exit_status.to_i}
        RUBY
      )
      File.write(File.join(bin_dir, "openmanus.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{script}\" %*\r\n")
      return bin_dir
    end

    workspace_patch =
      if patch_workspace
        shell_patch_text = repair_mode ? "" : patch_text.shellescape
        <<~SH
          if [ -f #{patch_path.shellescape} ]; then
            if [ #{repair_mode ? "1" : "0"} -eq 1 ] && [ -f _aiweb/repair-observation.json ]; then
              #{overwrite_workspace ? "printf '%s\\n' #{repair_fixed_text.shellescape} > #{patch_path.shellescape}" : "printf '\\n%s\\n' #{repair_fixed_text.shellescape} >> #{patch_path.shellescape}"}
            elif [ #{repair_mode ? "1" : "0"} -eq 1 ]; then
              #{overwrite_workspace ? "printf '%s\\n' #{repair_first_text.shellescape} > #{patch_path.shellescape}" : "printf '\\n%s\\n' #{repair_first_text.shellescape} >> #{patch_path.shellescape}"}
            else
              #{overwrite_workspace ? "printf '%s\\n' #{shell_patch_text} > #{patch_path.shellescape}" : "printf '\\n%s\\n' #{shell_patch_text} >> #{patch_path.shellescape}"}
            fi
          fi
        SH
      else
        ":"
      end
    root_mutation = mutate_root_path ? "printf '\\n<!-- root mutation by fake openmanus -->\\n' >> #{mutate_root_path.shellescape}" : ":"
    secret_write = secret_path.to_s.empty? ? ":" : "printf 'SECRET=engine-run-created-env\\n' > #{secret_path.to_s.shellescape}"
    write_fake_executable(
      bin_dir,
      "openmanus",
      <<~SH
        cat >/dev/null
        if env | grep -E 'OPENAI_API_KEY|ANTHROPIC_API_KEY|FAKE_OPENMANUS_SECRET' >/dev/null; then
          echo 'secret environment leaked to openmanus' >&2
          exit 81
        fi
        [ "$AIWEB_NETWORK_ALLOWED" = "0" ] || { echo 'network guard missing' >&2; exit 82; }
        [ "$AIWEB_MCP_ALLOWED" = "0" ] || { echo 'mcp guard missing' >&2; exit 83; }
        [ "$AIWEB_ENV_ACCESS_ALLOWED" = "0" ] || { echo 'env guard missing' >&2; exit 84; }
        echo #{stdout_text.shellescape}
        echo 'fake openmanus stderr' >&2
        #{workspace_patch}
        #{secret_write}
        #{root_mutation}
        if [ -n "$AIWEB_OPENMANUS_RESULT_PATH" ]; then
          printf '{"schema_version":1,"status":"patched"}\\n' > "$AIWEB_OPENMANUS_RESULT_PATH"
        fi
        exit #{exit_status.to_i}
      SH
    )
    bin_dir
  end

  def write_fake_verify_loop_tooling(root)
    FileUtils.mkdir_p(File.join(root, "node_modules", ".bin"))
    %w[playwright axe lighthouse].each do |name|
      write_fake_executable(File.join(root, "node_modules", ".bin"), name, "exit 0")
    end

    bin_dir = File.join(root, "fake-verify-loop-bin")
    FileUtils.mkdir_p(bin_dir)
    write_fake_executable(
      bin_dir,
      "pnpm",
      <<~'SH'
        case "$1" in
          build)
            mkdir -p dist
            printf '<h1>fake verify-loop build</h1>\n' > dist/index.html
            echo 'fake verify-loop build pass'
            exit "${BUILD_FAKE_EXIT_STATUS:-0}"
            ;;
          dev)
            echo 'fake verify-loop preview start'
            exit 0
            ;;
          exec)
            tool="$2"
            shift 2
            case "$tool" in
              playwright)
                subcommand="$1"
                if [ "$subcommand" = "test" ]; then
                  if [ "${PLAYWRIGHT_FAKE_STATUS:-passed}" = "failed" ]; then
                    echo '{"status":"failed","suites":[],"stats":{"unexpected":1}}'
                    echo 'fake verify-loop playwright failure' >&2
                    exit 1
                  fi
                  echo '{"status":"passed","suites":[],"stats":{"expected":1}}'
                  echo 'fake verify-loop playwright pass' >&2
                  exit 0
                fi
                if [ "$subcommand" = "screenshot" ]; then
                  wrote=0
                  for arg in "$@"; do
                    case "$arg" in
                      *.png)
                        mkdir -p "$(dirname "$arg")"
                        printf 'fake verify-loop screenshot for %s\n' "$arg" > "$arg"
                        wrote=1
                        ;;
                    esac
                  done
                  if [ "${QA_SCREENSHOT_FAKE_STATUS:-passed}" = "failed" ]; then
                    echo 'fake verify-loop screenshot failure' >&2
                    exit 1
                  fi
                  [ "$wrote" = 1 ] || { echo 'missing screenshot output' >&2; exit 64; }
                  echo 'fake verify-loop screenshot pass' >&2
                  exit 0
                fi
                ;;
              axe|lighthouse)
                status="${AIWEB_STATIC_QA_STATUS:-passed}"
                [ "$tool" = "axe" ] && status="${A11Y_FAKE_STATUS:-$status}"
                [ "$tool" = "lighthouse" ] && status="${LIGHTHOUSE_FAKE_STATUS:-$status}"
                for arg in "$@"; do
                  case "$arg" in
                    --output-path=*)
                      report="${arg#--output-path=}"
                      mkdir -p "$(dirname "$report")"
                      echo "{\"tool\":\"$tool\",\"status\":\"$status\"}" > "$report"
                      ;;
                  esac
                done
                if [ "$status" = "failed" ]; then
                  echo "{\"tool\":\"$tool\",\"status\":\"failed\"}"
                  echo "fake verify-loop $tool failure" >&2
                  exit 1
                fi
                echo "{\"tool\":\"$tool\",\"status\":\"passed\"}"
                echo "fake verify-loop $tool pass" >&2
                exit 0
                ;;
            esac
            ;;
        esac
        echo "unexpected fake verify-loop pnpm command: $*" >&2
        exit 64
      SH
    )
    codex_script = File.join(bin_dir, "codex-fake.rb")
    File.write(
      codex_script,
      <<~RUBY
        # frozen_string_literal: true

        require "fileutils"

        STDIN.read
        patch_path = #{File.join(root, "src/components/Hero.astro").inspect}
        marker_path = #{File.join(root, ".ai-web", "runs", "codex-runs.log").inspect}
        if File.file?(patch_path)
          File.open(patch_path, "a") { |file| file.write("\\n<!-- patched by fake verify-loop codex -->\\n") }
        end
        FileUtils.mkdir_p(File.dirname(marker_path))
        File.open(marker_path, "a") { |file| file.write("run\\n") }
        puts "fake verify-loop codex stdout"
        warn "fake verify-loop codex stderr"
      RUBY
    )
    if windows?
      File.write(File.join(bin_dir, "codex.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{codex_script}\" %*\r\n")
    else
      wrapper = File.join(bin_dir, "codex")
      File.write(wrapper, "#!/bin/sh\nexec #{RbConfig.ruby.shellescape} #{codex_script.shellescape} \"$@\"\n")
      FileUtils.chmod("+x", wrapper)
    end
    bin_dir
  end

  def assert_no_setup_side_effects(before_entries:, before_state:, env_path: ".env", env_size: nil, env_mtime: nil)
    assert_equal before_entries, project_entries
    assert_equal before_state, File.read(".ai-web/state.yaml")
    assert_equal env_size, File.size(env_path) if env_size
    assert_equal env_mtime, File.mtime(env_path) if env_mtime
    refute Dir.exist?("node_modules"), "setup preflight/dry-run must not create node_modules"
    refute Dir.exist?("dist"), "setup must not build"
    refute Dir.exist?(".ai-web/runs"), "setup preflight/dry-run must not write run artifacts"
  end

  def assert_setup_artifacts_do_not_leak_secret(setup_payload, secret)
    text = [setup_payload, setup_payload["setup"]].compact.map { |value| JSON.generate(value) }.join("
")
    refute_includes text, secret
    Dir.glob(".ai-web/runs/setup-*/**/*", File::FNM_DOTMATCH).select { |path| File.file?(path) }.each do |path|
      refute_match(%r{(^|/)\.env(\.|/|$)}, path)
      refute_includes File.read(path), secret, "#{path} must not contain .env secret content"
    end
  end

  def setup_payload_paths(payload)
    setup = payload.fetch("setup")
    [setup.fetch("stdout_log"), setup.fetch("stderr_log"), setup.fetch("metadata_path")]
  end

  def prepare_agent_run_fixture(task_markdown:, secret: nil)
    prepare_profile_d_scaffold_flow
    File.write(".ai-web/DESIGN.md", "# Agent Run Design System\n\nUse source-safe patching and recorded evidence.\n")
    component_map_payload, component_map_code = json_cmd("component-map")
    assert_equal 0, component_map_code
    assert_equal "ready", component_map_payload.dig("component_map", "status")

    FileUtils.mkdir_p(".ai-web/tasks")
    task_path = ".ai-web/tasks/agent-run-latest.md"
    File.write(task_path, task_markdown)

    state = load_state
    state["implementation"] ||= {}
    state["implementation"]["current_task"] = task_path
    state["implementation"]["latest_agent_run"] = nil
    state["implementation"]["last_diff"] = nil
    write_state(state)

    File.write(".env", "#{secret}\n") if secret
    task_path
  end

  def assert_no_agent_run_side_effects(before_entries:, before_state:, env_size: nil, env_mtime: nil)
    assert_equal before_entries, project_entries
    assert_equal before_state, File.read(".ai-web/state.yaml")
    assert_equal env_size, File.size(".env") if env_size
    assert_equal env_mtime, File.mtime(".env") if env_mtime
    refute Dir.exist?(".ai-web/runs"), "agent-run dry-run/blocking paths must not write run artifacts"
    refute Dir.exist?(".ai-web/diffs"), "agent-run dry-run/blocking paths must not write diff artifacts"
  end

  def assert_agent_run_artifacts_do_not_leak_secret(secret, *paths)
    text = paths.map { |path| File.exist?(path) ? File.read(path) : "" }.join("\n")
    refute_includes text, secret
  end

  def agent_run_safe_task_markdown
    <<~MD
      # Task Packet

      Task ID: agent-run-latest
      Phase: phase-7
      Created at: 2026-05-03T00:00:00Z

      ## Goal
      Improve the hero copy using a local source patch.

      ## Inputs
      - `.ai-web/state.yaml`
      - `.ai-web/DESIGN.md`
      - `.ai-web/component-map.json`
      - `src/components/Hero.astro`

      ## Constraints
      - Do not read `.env` or `.env.*`
      - Keep changes local and reversible

      ## Machine Constraints
      shell_allowed: false
      network_allowed: false
      env_access_allowed: false
      requires_selected_design: true
      allowed_source_paths:
      - src/components/Hero.astro

      ## Acceptance Criteria
      - Source patch evidence is recorded.
      - Logs, metadata, and diff evidence are written.
    MD
  end

  def test_engine_run_dry_run_returns_capability_envelope_without_writes
    in_tmp do
      json_cmd("init")
      File.write(".env", "SECRET=engine-run-dry-run-do-not-leak\n")
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      payload, code = json_cmd("engine-run", "--goal", "build a cafe landing page", "--dry-run")

      assert_equal 0, code
      assert_equal "planned engine run", payload["action_taken"]
      assert_equal "dry_run", payload.dig("engine_run", "status")
      assert_equal "agentic_local", payload.dig("engine_run", "mode")
      assert_equal "codex", payload.dig("engine_run", "agent")
      assert_includes payload.dig("engine_run", "capability", "allowed_tools"), "sandbox_shell"
      assert_includes payload.dig("engine_run", "capability", "forbidden"), "host_root_write"
      assert_equal %w[prepare act observe cancel resume finalize], payload.dig("engine_run", "capability", "worker_adapter", "api")
      assert_includes payload.dig("engine_run", "capability", "tool_broker", "event_flow"), "policy.decision"
      assert_equal true, payload.dig("engine_run", "capability", "authz_contract", "run_id_is_not_authority")
      assert_includes payload.dig("engine_run", "capability", "authz_contract", "saas_required_claims"), "tenant_id"
      assert_equal "redacted_at_source", payload.dig("engine_run", "capability", "retention_redaction_policy", "events", "redaction_status")
      assert_equal true, payload.dig("engine_run", "run_graph", "side_effects_must_use_tool_broker")
      assert_equal "sequential_durable_node_executor", payload.dig("engine_run", "run_graph", "executor_contract", "executor_type")
      graph_nodes = payload.dig("engine_run", "run_graph", "nodes")
      assert_equal graph_nodes.map { |node| node.fetch("node_id") }, payload.dig("engine_run", "run_graph", "executor_contract", "node_order")
      worker_node = graph_nodes.find { |node| node["node_id"] == "worker_act" }
      assert_equal "sandbox_tool_broker", worker_node.fetch("side_effect_boundary")
      assert_equal "engine_run.worker_act", worker_node.dig("executor", "executor_id")
      assert_equal "engine_run_execute_agentic_loop", worker_node.dig("executor", "handler")
      assert_equal true, worker_node.dig("executor", "tool_broker_required")
      assert_equal true, worker_node.dig("replay_policy", "requires_artifact_hash_validation")
      assert_includes payload.dig("engine_run", "tool_broker", "deny_by_default"), "package_install"
      surface_audit = payload.dig("engine_run", "tool_broker", "side_effect_surface_audit")
      assert_equal "aiweb.side_effect_surface_audit.v1", surface_audit.fetch("scanner")
      assert_equal "classified", surface_audit.fetch("coverage_status")
      assert_equal 0, surface_audit.fetch("unclassified_count")
      assert surface_audit.fetch("roots").any? { |entry| entry["source"] == "aiweb_runtime" }
      assert_equal "runtime_and_project_task_static_process_and_network_surface", surface_audit.fetch("scope")
      assert_includes surface_audit.fetch("scanned_globs"), "bin/**/*"
      assert_includes surface_audit.fetch("scanned_globs"), "scripts/**/*"
      assert_match(/not itself a runtime enforcement broker/, surface_audit.fetch("scanner_limitations").join("\n"))
      assert surface_audit.fetch("entries").any? { |entry| entry["classification"] == "brokered_engine_run_capture_command" }
      broker_enforcement = payload.dig("engine_run", "tool_broker", "runtime_broker_enforcement")
      assert_equal "partial_enforcement", broker_enforcement.fetch("status")
      assert_equal 0, broker_enforcement.fetch("executable_without_broker_count")
      assert_equal false, broker_enforcement.fetch("universal_broker_claim")
      assert_includes broker_enforcement.fetch("deny_by_default_surfaces"), "mcp_connectors"
      assert broker_enforcement.fetch("known_mcp_broker_drivers").any? { |driver| driver["server"] == "lazyweb" && driver["broker_id"] == "aiweb.lazyweb.side_effect_broker" }
      assert broker_enforcement.fetch("known_mcp_broker_drivers").any? { |driver| driver["server"] == "lazyweb" && driver["broker_id"] == "aiweb.implementation_mcp_broker" && driver["status"] == "implemented_for_approved_health_and_search_calls" }
      assert broker_enforcement.fetch("known_mcp_broker_drivers").any? { |driver| driver["server"] == "project_files" && driver["broker_id"] == "aiweb.implementation_mcp_broker" && driver["scope"] == "implementation_worker.mcp.project_files" && driver["status"] == "implemented_for_approved_project_file_metadata_list_excerpt_search" }
      mcp_surface = broker_enforcement.fetch("surfaces").find { |surface| surface["surface"] == "mcp_connectors" }
      assert_equal "partial_drivers_available_lazyweb_and_project_files", mcp_surface.fetch("status")
      assert_equal "aiweb.implementation_mcp_broker", mcp_surface.fetch("broker_id")
      assert_match(/project_files\.project_file_metadata\/project_file_list.*project_file_excerpt.*project_file_search/i, mcp_surface.fetch("policy"))
      assert_match(/all other implementation-worker MCP\/connectors remain denied/i, mcp_surface.fetch("policy"))
      assert broker_enforcement.fetch("surfaces").any? { |surface| surface["surface"] == "future_adapters" && surface["status"] == "fail_closed_until_broker_driver" }
      assert_match(%r{\A\.ai-web/runs/engine-run-.+/artifacts/project-index\.json\z}, payload.dig("planned_changes").find { |path| path.end_with?("project-index.json") })
      assert_match(%r{\A\.ai-web/runs/engine-run-.+/artifacts/graph-execution-plan\.json\z}, payload.dig("planned_changes").find { |path| path.end_with?("graph-execution-plan.json") })
      assert_match(%r{\A\.ai-web/runs/engine-run-.+/artifacts/sandbox-preflight\.json\z}, payload.dig("planned_changes").find { |path| path.end_with?("sandbox-preflight.json") })
      assert_match(/\A[0-9a-f]{64}\z/, payload.dig("engine_run", "approval_hash"))
      assert_match(%r{\A\.ai-web/runs/engine-run-.+/events\.jsonl\z}, payload.dig("engine_run", "events_path"))
      assert_match(%r{\A\.ai-web/runs/engine-run-.+/checkpoint\.json\z}, payload.dig("engine_run", "checkpoint_path"))
      assert_equal before_entries, project_entries, "engine-run --dry-run must not write run artifacts"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "engine-run --dry-run must not mutate state"
      refute_includes JSON.generate(payload), "engine-run-dry-run-do-not-leak"
    end
  end

  def test_engine_run_dry_run_includes_opendesign_contract_without_writes
    in_tmp do
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [
          {
            "data_aiweb_id" => "component.hero.copy",
            "source_path" => "src/components/Hero.astro",
            "editable" => true
          }
        ]
      ))
      before_entries = project_entries

      payload, code = json_cmd("engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--dry-run")

      assert_equal 0, code
      contract = payload.dig("engine_run", "opendesign_contract")
      assert_equal "ready", contract.fetch("status")
      assert_equal "candidate-02", contract.fetch("selected_candidate")
      assert_match(/\Asha256:[0-9a-f]{64}\z/, contract.fetch("contract_hash"))
      assert_equal contract.fetch("contract_hash"), payload.dig("engine_run", "capability", "opendesign_contract", "contract_hash")
      assert_equal ".ai-web/design-candidates/candidate-02.html", contract.fetch("selected_candidate_path")
      assert_includes contract.fetch("artifacts").keys, "design"
      assert_includes contract.fetch("artifacts").keys, "selected_design"
      assert_includes contract.fetch("artifacts").keys, "selected_candidate"
      assert_includes contract.fetch("artifacts").keys, "component_map"
      assert_includes contract.fetch("required_data_aiweb_ids"), "candidate.candidate-02.first-view"
      assert_includes contract.fetch("component_data_aiweb_ids"), "component.hero.copy"
      assert_equal before_entries, project_entries, "engine-run OpenDesign dry-run must not write artifacts"
    end
  end

  def test_engine_run_blocks_profile_d_ui_goal_when_selected_design_is_missing_without_writes
    in_tmp do |dir|
      json_cmd("init", "--profile", "D")
      bin_dir = write_fake_openmanus_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }
      before_entries = project_entries

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "build landing page UI", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_equal "missing", payload.dig("engine_run", "opendesign_contract", "status")
      assert_match(/selected design candidate/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      assert_equal before_entries, project_entries, "missing selected design must block before run artifacts"
    end
  end

  def test_engine_run_persists_opendesign_contract_and_keeps_hash_stable_between_dry_run_and_real_run
    in_tmp do |dir|
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write("package.json", JSON.pretty_generate("scripts" => { "dev" => "fake dev" }))
      bin_dir = write_fake_engine_openmanus_preview_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }
      dry_payload, dry_code = json_cmd("engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--dry-run")
      dry_contract_hash = dry_payload.dig("engine_run", "opendesign_contract", "contract_hash")

      assert_equal 0, dry_code
      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approval-hash", dry_payload.dig("engine_run", "approval_hash"), "--approved")

      assert_equal 0, code
      assert_equal "passed", payload.dig("engine_run", "status")
      assert_equal dry_contract_hash, payload.dig("engine_run", "opendesign_contract", "contract_hash")
      contract_path = File.join(payload.dig("engine_run", "run_dir"), "artifacts", "opendesign-contract.json")
      assert File.file?(contract_path)
      persisted = JSON.parse(File.read(contract_path))
      assert_equal dry_contract_hash, persisted.fetch("contract_hash")
      checkpoint = JSON.parse(File.read(payload.dig("engine_run", "checkpoint_path")))
      assert_equal dry_contract_hash, checkpoint.dig("opendesign_contract", "contract_hash")
      event_types = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line).fetch("type") }
      assert_includes event_types, "design.contract.loaded"
    end
  end

  def test_engine_run_openhands_experimental_container_adapter_invokes_headless_driver
    in_tmp do |dir|
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      source = "src/components/Hero.astro"
      File.write(source, "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [{ "data_aiweb_id" => "component.hero.copy", "source_path" => source, "editable" => true }]
      ))
      File.write("package.json", JSON.pretty_generate("scripts" => { "dev" => "fake dev" }))
      result_payload = {
        "schema_version" => 1,
        "adapter" => "openhands",
        "status" => "patched",
        "structured_events" => [{ "type" => "fake.openhands.completed" }],
        "artifact_refs" => ["_aiweb/openhands-task.md"],
        "changed_file_manifest" => [source],
        "proposed_tool_requests" => [],
        "risk_notes" => ["fake OpenHands smoke driver"],
        "blocking_issues" => []
      }
      bin_dir = write_fake_engine_openmanus_preview_tooling(dir, stdout_text: "fake openhands stdout", agent_result_payload: result_payload)
      env = {
        "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
        "AIWEB_OPENHANDS_IMAGE" => "openhands:latest"
      }
      dry_payload, dry_code = json_cmd("engine-run", "--goal", "patch hero", "--agent", "openhands", "--sandbox", "docker", "--dry-run")

      assert_equal 0, dry_code
      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openhands", "--sandbox", "docker", "--approval-hash", dry_payload.dig("engine_run", "approval_hash"), "--approved")

      assert_equal 0, code
      assert_equal "passed", payload.dig("engine_run", "status")
      assert_equal "openhands", payload.dig("engine_run", "agent")
      assert_includes File.read(payload.dig("engine_run", "events_path")), "openhands --headless --json --file /workspace/_aiweb/openhands-task.md"
      registry = payload.dig("engine_run", "worker_adapter_registry")
      assert_equal "openhands", registry.fetch("selected_adapter")
      assert_equal "experimental_container_worker", registry.fetch("selected_adapter_status")
      openhands = registry.fetch("adapters").find { |adapter| adapter["id"] == "openhands" }
      assert_equal true, openhands.fetch("executable")
      assert_equal "engine_run_openhands_command", openhands.fetch("command_driver")
      assert_equal "required_before_execution", openhands.fetch("sandbox_preflight")
      assert_equal "engine-run-openhands-result.schema.json", openhands.fetch("result_schema")
      assert_equal "experimental_ready", openhands.dig("driver_readiness", "state")
      assert_equal true, openhands.dig("driver_readiness", "executable_now")
      assert_equal "enforced", openhands.dig("broker_contract", "enforcement_status")
      assert_equal "passed", payload.dig("engine_run", "sandbox_preflight", "status")
      task_path = File.join(payload.dig("engine_run", "workspace_path"), "_aiweb", "openhands-task.md")
      assert File.file?(task_path), "OpenHands adapter must persist the headless task file inside the staged workspace"
      assert_includes File.read(task_path), "You are the agentic WebBuilderAgent sandbox worker"
      agent_result = JSON.parse(File.read(payload.dig("engine_run", "agent_result_path")))
      assert_equal "openhands", agent_result.fetch("adapter")
      assert_includes File.read(source), "patched by fake openmanus"
    end
  end

  def test_engine_run_openhands_blocks_without_sandbox_before_artifacts
    in_tmp do
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [{ "data_aiweb_id" => "component.hero.copy", "source_path" => "src/components/Hero.astro", "editable" => true }]
      ))
      before_entries = project_entries

      payload, code = json_cmd("engine-run", "--goal", "patch hero", "--agent", "openhands", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_match(/openhands requires --sandbox docker or --sandbox podman/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      assert_equal before_entries, project_entries, "OpenHands without sandbox must block before run artifacts"
    end
  end

  def test_engine_run_langgraph_experimental_container_adapter_invokes_stategraph_bridge
    in_tmp do |dir|
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      source = "src/components/Hero.astro"
      File.write(source, "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [{ "data_aiweb_id" => "component.hero.copy", "source_path" => source, "editable" => true }]
      ))
      File.write("package.json", JSON.pretty_generate("scripts" => { "dev" => "fake dev" }))
      result_payload = {
        "schema_version" => 1,
        "adapter" => "langgraph",
        "status" => "patched",
        "structured_events" => [{ "type" => "fake.langgraph.completed" }],
        "artifact_refs" => ["_aiweb/langgraph-worker.py", "_aiweb/langgraph-task.md"],
        "changed_file_manifest" => [source],
        "proposed_tool_requests" => [],
        "risk_notes" => ["fake LangGraph StateGraph smoke driver"],
        "blocking_issues" => [],
        "graph_trace" => {
          "api" => "langgraph.graph.StateGraph",
          "nodes" => %w[prepare act observe finalize],
          "edges" => [["START", "prepare"], ["prepare", "act"], ["act", "observe"], ["observe", "finalize"], ["finalize", "END"]]
        }
      }
      bin_dir = write_fake_engine_openmanus_preview_tooling(dir, stdout_text: "fake langgraph stdout", agent_result_payload: result_payload)
      env = {
        "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
        "AIWEB_LANGGRAPH_IMAGE" => "langgraph:latest"
      }
      dry_payload, dry_code = json_cmd("engine-run", "--goal", "patch hero", "--agent", "langgraph", "--sandbox", "docker", "--dry-run")

      assert_equal 0, dry_code
      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "langgraph", "--sandbox", "docker", "--approval-hash", dry_payload.dig("engine_run", "approval_hash"), "--approved")

      assert_equal 0, code
      assert_equal "passed", payload.dig("engine_run", "status")
      assert_equal "langgraph", payload.dig("engine_run", "agent")
      assert_includes File.read(payload.dig("engine_run", "events_path")), "langgraph-worker.py"
      registry = payload.dig("engine_run", "worker_adapter_registry")
      assert_equal "langgraph", registry.fetch("selected_adapter")
      assert_equal "experimental_container_worker", registry.fetch("selected_adapter_status")
      langgraph = registry.fetch("adapters").find { |adapter| adapter["id"] == "langgraph" }
      assert_equal true, langgraph.fetch("executable")
      assert_equal "engine_run_langgraph_command", langgraph.fetch("command_driver")
      assert_equal "required_before_execution", langgraph.fetch("sandbox_preflight")
      assert_equal "engine-run-langgraph-result.schema.json", langgraph.fetch("result_schema")
      assert_equal "experimental_ready", langgraph.dig("driver_readiness", "state")
      assert_equal true, langgraph.dig("driver_readiness", "executable_now")
      assert_equal "enforced", langgraph.dig("broker_contract", "enforcement_status")
      assert_equal "passed", payload.dig("engine_run", "sandbox_preflight", "status")
      workspace_aiweb = File.join(payload.dig("engine_run", "workspace_path"), "_aiweb")
      task_path = File.join(workspace_aiweb, "langgraph-task.md")
      worker_path = File.join(workspace_aiweb, "langgraph-worker.py")
      assert File.file?(task_path), "LangGraph adapter must persist the StateGraph task file inside the staged workspace"
      assert File.file?(worker_path), "LangGraph adapter must persist the StateGraph bridge inside the staged workspace"
      assert_includes File.read(worker_path), "StateGraph"
      agent_result = JSON.parse(File.read(payload.dig("engine_run", "agent_result_path")))
      assert_equal "langgraph", agent_result.fetch("adapter")
      assert_equal "langgraph.graph.StateGraph", agent_result.dig("graph_trace", "api")
      assert_includes File.read(source), "patched by fake openmanus"
    end
  end

  def test_engine_run_langgraph_blocks_without_sandbox_before_artifacts
    in_tmp do
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [{ "data_aiweb_id" => "component.hero.copy", "source_path" => "src/components/Hero.astro", "editable" => true }]
      ))
      before_entries = project_entries

      payload, code = json_cmd("engine-run", "--goal", "patch hero", "--agent", "langgraph", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_match(/langgraph requires --sandbox docker or --sandbox podman/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      assert_equal before_entries, project_entries, "LangGraph without sandbox must block before run artifacts"
    end
  end

  def test_engine_run_openai_agents_sdk_experimental_container_adapter_invokes_sdk_bridge
    in_tmp do |dir|
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      source = "src/components/Hero.astro"
      File.write(source, "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [{ "data_aiweb_id" => "component.hero.copy", "source_path" => source, "editable" => true }]
      ))
      File.write("package.json", JSON.pretty_generate("scripts" => { "dev" => "fake dev" }))
      result_payload = {
        "schema_version" => 1,
        "adapter" => "openai_agents_sdk",
        "status" => "patched",
        "structured_events" => [{ "type" => "fake.openai_agents_sdk.completed" }],
        "artifact_refs" => ["_aiweb/openai-agents-worker.py", "_aiweb/openai-agents-task.md"],
        "changed_file_manifest" => [source],
        "proposed_tool_requests" => [],
        "risk_notes" => ["fake OpenAI Agents SDK smoke driver"],
        "blocking_issues" => [],
        "sdk_trace" => {
          "api" => "agents.Agent/Runner",
          "model_call_attempted" => false,
          "model_call_allowed" => false
        }
      }
      bin_dir = write_fake_engine_openmanus_preview_tooling(dir, stdout_text: "fake openai agents stdout", agent_result_payload: result_payload)
      env = {
        "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
        "AIWEB_OPENAI_AGENTS_IMAGE" => "openai-agents:latest"
      }
      dry_payload, dry_code = json_cmd("engine-run", "--goal", "patch hero", "--agent", "openai_agents_sdk", "--sandbox", "docker", "--dry-run")

      assert_equal 0, dry_code
      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openai_agents_sdk", "--sandbox", "docker", "--approval-hash", dry_payload.dig("engine_run", "approval_hash"), "--approved")

      assert_equal 0, code
      assert_equal "passed", payload.dig("engine_run", "status")
      assert_equal "openai_agents_sdk", payload.dig("engine_run", "agent")
      assert_includes File.read(payload.dig("engine_run", "events_path")), "openai-agents-worker.py"
      registry = payload.dig("engine_run", "worker_adapter_registry")
      assert_equal "openai_agents_sdk", registry.fetch("selected_adapter")
      assert_equal "experimental_container_worker", registry.fetch("selected_adapter_status")
      openai_agents = registry.fetch("adapters").find { |adapter| adapter["id"] == "openai_agents_sdk" }
      assert_equal true, openai_agents.fetch("executable")
      assert_equal "engine_run_openai_agents_sdk_command", openai_agents.fetch("command_driver")
      assert_equal "required_before_execution", openai_agents.fetch("sandbox_preflight")
      assert_equal "engine-run-openai-agents-sdk-result.schema.json", openai_agents.fetch("result_schema")
      assert_equal "experimental_ready", openai_agents.dig("driver_readiness", "state")
      assert_equal true, openai_agents.dig("driver_readiness", "executable_now")
      assert_equal "enforced", openai_agents.dig("broker_contract", "enforcement_status")
      assert_equal "passed", payload.dig("engine_run", "sandbox_preflight", "status")
      workspace_aiweb = File.join(payload.dig("engine_run", "workspace_path"), "_aiweb")
      task_path = File.join(workspace_aiweb, "openai-agents-task.md")
      worker_path = File.join(workspace_aiweb, "openai-agents-worker.py")
      assert File.file?(task_path), "OpenAI Agents SDK adapter must persist the SDK task file inside the staged workspace"
      assert File.file?(worker_path), "OpenAI Agents SDK adapter must persist the SDK bridge inside the staged workspace"
      assert_includes File.read(worker_path), "from agents import Agent, Runner"
      agent_result = JSON.parse(File.read(payload.dig("engine_run", "agent_result_path")))
      assert_equal "openai_agents_sdk", agent_result.fetch("adapter")
      assert_equal "agents.Agent/Runner", agent_result.dig("sdk_trace", "api")
      assert_includes File.read(source), "patched by fake openmanus"
    end
  end

  def test_engine_run_openai_agents_sdk_blocks_without_sandbox_before_artifacts
    in_tmp do
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [{ "data_aiweb_id" => "component.hero.copy", "source_path" => "src/components/Hero.astro", "editable" => true }]
      ))
      before_entries = project_entries

      payload, code = json_cmd("engine-run", "--goal", "patch hero", "--agent", "openai_agents_sdk", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_match(/openai_agents_sdk requires --sandbox docker or --sandbox podman/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      assert_equal before_entries, project_entries, "OpenAI Agents SDK without sandbox must block before run artifacts"
    end
  end

  def test_engine_run_design_fidelity_blocks_copy_back_when_component_hook_is_removed
    in_tmp do |dir|
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      source = "src/components/Hero.astro"
      File.write(source, "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [{ "data_aiweb_id" => "component.hero.copy", "source_path" => source, "editable" => true }]
      ))
      bin_dir = write_fake_openmanus_tooling(dir, patch_text: "<section>Hook removed</section>\n", overwrite_workspace: true)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_equal "blocked", payload.dig("engine_run", "design_fidelity", "status")
      assert_operator payload.dig("engine_run", "design_fidelity", "selected_design_fidelity"), :<, 0.8
      assert_match(/data-aiweb-id.*component\.hero\.copy/i, payload.dig("engine_run", "design_fidelity", "blocking_issues").join("\n"))
      assert_equal "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n", File.read(source)
    end
  end

  def test_engine_run_design_fidelity_blocks_reference_brand_leakage
    in_tmp do |dir|
      prepare_profile_d_design_flow
      File.write(".ai-web/design-reference-brief.md", <<~MD)
        # Design Reference Brief

        Companies: Aesop, Stripe.
        Copy risk: pattern-only; do not reproduce exact layouts, trademarks, prices, or copy.
      MD
      FileUtils.mkdir_p("src/components")
      source = "src/components/Hero.astro"
      File.write(source, "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [{ "data_aiweb_id" => "component.hero.copy", "source_path" => source, "editable" => true }]
      ))
      bin_dir = write_fake_openmanus_tooling(dir, patch_text: "<section data-aiweb-id=\"component.hero.copy\">Aesop exact reference copy</section>\n", overwrite_workspace: true)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_match(/reference term|Aesop/i, payload.dig("engine_run", "design_fidelity", "blocking_issues").join("\n"))
      refute_match(/Aesop/, File.read(source))
    end
  end

  def test_engine_run_design_fidelity_blocks_selected_candidate_identity_drift
    in_tmp do |dir|
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/content")
      source = "src/content/site.json"
      File.write(source, JSON.pretty_generate("selected_candidate" => "candidate-02") + "\n")
      bin_dir = write_fake_openmanus_tooling(
        dir,
        patch_path: source,
        patch_text: JSON.pretty_generate("selected_candidate" => "candidate-03") + "\n",
        overwrite_workspace: true
      )
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch site content", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_match(/selected candidate/i, payload.dig("engine_run", "design_fidelity", "blocking_issues").join("\n"))
      assert_equal "candidate-02", JSON.parse(File.read(source)).fetch("selected_candidate")
    end
  end

  def test_engine_run_preview_runs_inside_sandbox_and_records_lifecycle_events
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      File.write("package.json", JSON.pretty_generate("scripts" => { "dev" => "fake dev" }))
      bin_dir = write_fake_engine_openmanus_preview_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      assert_equal 0, code
      assert_equal "ready", payload.dig("engine_run", "preview", "status")
      assert_match(/\Adocker run\b/, payload.dig("engine_run", "preview", "command"))
      assert_includes payload.dig("engine_run", "preview", "command"), "--network none"
      assert_equal "http://127.0.0.1:4321/", payload.dig("engine_run", "preview", "url")
      assert_includes %w[exited_after_ready persistent_ready], payload.dig("engine_run", "preview", "lifecycle")
      assert_match(%r{\A\.ai-web/runs/.+/logs/preview-stdout\.log\z}, payload.dig("engine_run", "preview", "stdout_path"))
      assert_equal false, payload.dig("engine_run", "preview", "teardown_required")
      event_types = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line).fetch("type") }
      assert_includes event_types, "preview.started"
      assert_includes event_types, "preview.ready"
      assert_includes event_types, "preview.stopped"
    end
  end

  def test_engine_run_preview_failure_records_evidence_without_copy_back
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      File.write("package.json", JSON.pretty_generate("scripts" => { "dev" => "fake dev" }))
      bin_dir = write_fake_engine_openmanus_preview_tooling(dir, preview_exit_status: 7)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "failed", payload.dig("engine_run", "status")
      assert_equal "failed", payload.dig("engine_run", "preview", "status")
      assert_match(/preview failed/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      refute_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
      event_types = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line).fetch("type") }
      assert_includes event_types, "preview.started"
      assert_includes event_types, "preview.failed"
      assert_includes event_types, "preview.stopped"
    end
  end

  def test_engine_run_captures_screenshot_manifest_from_sandbox_preview
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      File.write("package.json", JSON.pretty_generate("scripts" => { "dev" => "fake dev" }))
      bin_dir = write_fake_engine_openmanus_preview_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      assert_equal 0, code
      manifest_path = payload.dig("engine_run", "screenshot_evidence_path")
      assert_match(%r{\A\.ai-web/runs/.+/qa/screenshots\.json\z}, manifest_path)
      manifest = JSON.parse(File.read(manifest_path))
      assert_equal "captured", manifest.fetch("status")
      assert_equal %w[desktop tablet mobile], manifest.fetch("screenshots").map { |shot| shot.fetch("viewport") }
      manifest.fetch("screenshots").each do |shot|
        assert File.file?(shot.fetch("path")), "#{shot.fetch("path")} should exist"
        assert_operator File.size(shot.fetch("path")), :>, 0
        assert_equal "http://127.0.0.1:4321/", shot.fetch("url")
        assert_equal "playwright_browser", shot.fetch("capture_mode")
        refute_equal "sandbox_placeholder", shot.fetch("capture_mode")
        assert_equal "image/png", shot.fetch("mime_type")
        assert_equal true, shot.fetch("png_signature_valid")
        assert_operator shot.fetch("image_width"), :>, 1
        assert_operator shot.fetch("image_height"), :>, 1
        assert_equal "\x89PNG\r\n\x1A\n".b, File.binread(shot.fetch("path"), 8)
      end
      assert_equal "captured", manifest.dig("dom_snapshot", "status")
      assert_equal "captured", manifest.dig("a11y_report", "status")
      assert_equal "captured", manifest.dig("computed_style_summary", "status")
      assert_equal "captured", manifest.dig("keyboard_focus_traversal", "status")
      assert_equal "captured", manifest.dig("action_recovery", "status")
      assert manifest.dig("action_recovery", "viewports").all? { |entry| entry.fetch("unsafe_navigation_policy_enforced") == true }
      assert manifest.dig("action_recovery", "viewports").all? { |entry| entry.fetch("unsafe_navigation_blocked") == false }
      assert_operator manifest.dig("action_recovery", "action_sequences").length, :>, 0
      assert_operator manifest.dig("action_recovery", "recovery_attempts").length, :>, 0
      assert_equal [], manifest.dig("action_recovery", "external_requests_blocked")
      assert_equal "captured", manifest.dig("action_loop", "status")
      assert_equal "bounded_safe_local_observation_loop", manifest.dig("action_loop", "loop_type")
      assert_equal "deterministic_observation_not_open_ended", manifest.dig("action_loop", "autonomy_level")
      assert_equal "localhost-only", manifest.dig("action_loop", "policy", "network")
      assert_equal true, manifest.dig("action_loop", "policy", "reversible_only")
      assert_equal false, manifest.dig("action_loop", "policy", "form_submission_allowed")
      assert_operator manifest.dig("action_loop", "planned_steps").length, :>, 0
      assert_operator manifest.dig("action_loop", "executed_steps").length, :>, 0
      assert_operator manifest.dig("action_loop", "recovery_steps").length, :>, 0
      assert_operator manifest.dig("action_loop", "scenario_plan").length, :>, 0
      assert_operator manifest.dig("action_loop", "scenario_results").length, :>, 0
      assert_equal true, manifest.dig("action_loop", "multi_step_evidence", "multi_step_sequences_observed")
      assert_equal true, manifest.dig("action_loop", "multi_step_evidence", "all_scenarios_recovered")
      assert manifest.dig("action_loop", "scenario_results").all? { |entry| entry.fetch("status") == "captured" }
      assert manifest.dig("action_loop", "scenario_results").all? { |entry| entry.fetch("step_count") >= 2 }
      assert manifest.dig("action_loop", "scenario_results").all? { |entry| entry.fetch("recovery_step_count") >= 1 }
      assert manifest.dig("action_loop", "viewports").all? { |entry| entry.fetch("status") == "captured" }
      assert_equal "passed", manifest.dig("runtime_attestation", "status")
      assert_equal "openmanus", manifest.dig("runtime_attestation", "agent")
      assert_equal "docker", manifest.dig("runtime_attestation", "sandbox")
      assert_equal true, manifest.dig("runtime_attestation", "sandbox_required")
      assert_equal true, manifest.dig("runtime_attestation", "same_staged_workspace")
      assert_equal false, manifest.dig("runtime_attestation", "same_container_instance")
      assert_equal true, manifest.dig("runtime_attestation", "preview_tool_wrapped")
      assert_equal true, manifest.dig("runtime_attestation", "browser_tool_wrapped")
      assert_equal "_aiweb/tool-broker-bin", manifest.dig("runtime_attestation", "tool_broker_bin_path")
      assert_equal "localhost-only", manifest.dig("runtime_attestation", "network_policy")
      assert_equal [], manifest.fetch("console_errors")
      assert_equal [], manifest.fetch("network_errors")
      assert manifest.fetch("interaction_states").all? { |state| state.fetch("status") == "captured" }
      assert manifest.fetch("viewport_evidence").all? { |capture| capture.dig("dom_snapshot", "status") == "captured" }
      assert manifest.fetch("viewport_evidence").all? { |capture| capture.fetch("console_errors") == [] }
      assert manifest.fetch("viewport_evidence").all? { |capture| capture.fetch("network_errors") == [] }
      events = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line) }
      assert_nil events.first.fetch("previous_event_hash")
      assert_equal payload.dig("engine_run", "run_id"), events.first.fetch("run_id")
      assert_equal "aiweb.engine_run", events.first.fetch("actor")
      assert_match(/\Aspan-/, events.first.fetch("trace_span_id"))
      events.each_cons(2) do |previous, current|
        assert_equal previous.fetch("event_hash"), current.fetch("previous_event_hash")
        assert_match(/\Asha256:[a-f0-9]{64}\z/, current.fetch("event_hash"))
        assert_equal "redacted_at_source", current.fetch("redaction_status")
        assert_equal payload.dig("engine_run", "run_id"), current.fetch("run_id")
      end
      event_types = events.map { |event| event.fetch("type") }
      assert_includes event_types, "screenshot.capture.started"
      assert_includes event_types, "tool.started"
      assert_includes event_types, "tool.finished"
      assert_includes event_types, "screenshot.capture.finished"
      assert_includes event_types, "browser.observation.recorded"
      assert_includes event_types, "browser.action_recovery.recorded"
      assert_includes event_types, "browser.action_loop.recorded"
    end
  end

  def test_engine_run_browser_observer_script_enforces_localhost_request_policy
    in_tmp do |dir|
      json_cmd("init")
      workspace = File.join(dir, ".ai-web", "tmp", "browser-policy-workspace")

      Aiweb::Project.new(Dir.pwd).send(:engine_run_write_browser_observer_script, workspace)

      script = File.read(File.join(workspace, "_aiweb", "browser-observe.js"))
      assert_includes script, "page.route('**/*'"
      assert_includes script, "non_local_request_blocked"
      assert_includes script, "blockedExternalRequests"
      assert_includes script, "networkErrors.push(...uniqueBlockedExternalRequests)"
      assert_includes script, "unsafe_navigation_policy_enforced: true"
      assert_match(/unsafe_navigation_blocked:\s*false/, script)
      assert_includes script, "fill_text_probe"
      assert_includes script, "click_same_origin_anchor"
      assert_includes script, "click_toggle_button"
      assert_includes script, "restore_input_value"
    end
  end

  def test_engine_scheduler_records_project_local_tick_for_terminal_engine_run
    in_tmp do |dir|
      json_cmd("init")
      idle_payload, idle_code = json_cmd("engine-scheduler", "status")
      assert_equal 0, idle_code
      assert_equal "no_run", idle_payload.dig("engine_scheduler", "decision")
      blocked_tick_payload, blocked_tick_code = json_cmd("engine-scheduler", "tick")
      refute_equal 0, blocked_tick_code
      assert_equal "blocked", blocked_tick_payload.dig("engine_scheduler", "status")
      refute File.exist?(".ai-web/scheduler/ledger.jsonl")

      dry_daemon_payload, dry_daemon_code = json_cmd("engine-scheduler", "daemon", "--max-ticks", "1", "--dry-run")
      assert_equal 0, dry_daemon_code
      assert_equal "dry_run", dry_daemon_payload.dig("engine_scheduler", "status")
      refute File.exist?(".ai-web/scheduler/daemon.json")
      refute File.exist?(".ai-web/scheduler/worker-pool.json")

      dry_supervisor_payload, dry_supervisor_code = json_cmd("engine-scheduler", "supervisor", "--max-ticks", "0", "--workers", "2", "--dry-run")
      assert_equal 0, dry_supervisor_code
      assert_equal "dry_run", dry_supervisor_payload.dig("engine_scheduler", "status")
      assert_equal "aiweb.engine_scheduler.supervisor.v1", dry_supervisor_payload.dig("engine_scheduler", "supervisor_driver")
      refute File.exist?(".ai-web/scheduler/supervisor.json")

      supervisor_payload, supervisor_code = json_cmd("engine-scheduler", "supervisor", "--max-ticks", "0", "--interval-seconds", "5", "--workers", "2")
      assert_equal 0, supervisor_code, JSON.pretty_generate(supervisor_payload)
      assert_equal "recorded", supervisor_payload.dig("engine_scheduler", "status")
      assert_equal "supervisor_plan_recorded", supervisor_payload.dig("engine_scheduler", "decision")
      assert_equal false, supervisor_payload.dig("engine_scheduler", "install_performed")
      assert_equal "not_installed_by_aiweb", supervisor_payload.dig("engine_scheduler", "install_status")
      assert_equal ".ai-web/scheduler/supervisor.json", supervisor_payload.dig("engine_scheduler", "supervisor_artifact_path")
      assert File.file?(".ai-web/scheduler/supervisor.json")
      supervisor = JSON.parse(File.read(".ai-web/scheduler/supervisor.json"))
      assert_equal "aiweb.engine_scheduler.supervisor.v1", supervisor.fetch("supervisor_driver")
      assert_includes supervisor.dig("daemon_command", "argv"), "daemon"
      assert_equal true, supervisor.dig("daemon_command", "operator_must_set_working_directory_to_project_root")
      assert_equal false, supervisor.dig("production_readiness", "os_service_installed")
      assert_equal false, supervisor.dig("production_readiness", "distributed_worker_cluster")
      assert_equal "engine_run_resume_bridge", supervisor.dig("production_readiness", "node_body_executor")
      assert supervisor.fetch("service_unit_templates").fetch("systemd_user_service").join("\n").include?("Restart=on-failure")
      refute_match(Regexp.escape(dir), JSON.generate(supervisor), "supervisor artifact should avoid leaking absolute temp project paths")

      blocked_supervisor_payload, blocked_supervisor_code = json_cmd("engine-scheduler", "supervisor", "--execute")
      refute_equal 0, blocked_supervisor_code
      assert_equal "blocked", blocked_supervisor_payload.dig("engine_scheduler", "status")
      assert_match(/cannot install or execute OS service managers/i, blocked_supervisor_payload.dig("engine_scheduler", "blocking_issues").join(" "))

      invalid_workers_payload, invalid_workers_code = json_cmd("engine-scheduler", "daemon", "--workers", "0")
      refute_equal 0, invalid_workers_code
      assert_match(/--workers must be between 1 and 16/, JSON.generate(invalid_workers_payload))

      run_id = "engine-run-scheduler-test"
      run_dir = File.join(".ai-web", "runs", run_id)
      artifacts_dir = File.join(run_dir, "artifacts")
      FileUtils.mkdir_p(artifacts_dir)
      nodes = %w[preflight finalize].map.with_index(1) do |node_id, ordinal|
        {
          "node_id" => node_id,
          "ordinal" => ordinal,
          "state" => "passed",
          "attempt" => 1,
          "side_effect_boundary" => "none",
          "executor" => {
            "handler" => "handler_for_#{node_id}",
            "executor_id" => "engine_run.#{node_id}",
            "side_effect_boundary" => "none",
            "tool_broker_required" => false,
            "idempotent" => true
          },
          "input_artifact_refs" => [],
          "output_artifact_refs" => [],
          "replay_policy" => { "requires_artifact_hash_validation" => true },
          "idempotency_key" => "idem-#{node_id}",
          "checkpoint_cursor" => "#{run_id}:#{node_id}:1"
        }
      end
      run_graph = {
        "run_id" => run_id,
        "cursor" => { "node_id" => "finalize", "state" => "passed", "attempt" => 1 },
        "nodes" => nodes,
        "executor_contract" => {
          "executor_type" => "sequential_durable_node_executor",
          "node_order" => nodes.map { |node| node.fetch("node_id") },
          "checkpoint_policy" => "persist_before_and_after_side_effect_boundaries",
          "resume_strategy" => "validate_cursor_artifact_hashes_and_continue_at_next_idempotent_node",
          "side_effect_gate" => "tool_broker_required_for_non_none_boundaries"
        }
      }
      checkpoint = {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => "passed",
        "workspace_path" => ".ai-web/tmp/agentic/#{run_id}/workspace",
        "run_graph_cursor" => run_graph.fetch("cursor"),
        "run_graph" => run_graph,
        "artifact_hashes" => {}
      }
      metadata = {
        "schema_version" => 1,
        "run_id" => run_id,
        "kind" => "engine-run",
        "status" => "passed",
        "agent" => "openmanus",
        "mode" => "agentic_local",
        "sandbox" => "docker",
        "capability" => { "limits" => { "max_cycles" => 2 } },
        "workspace_path" => ".ai-web/tmp/agentic/#{run_id}/workspace",
        "metadata_path" => File.join(run_dir, "engine-run.json"),
        "checkpoint_path" => File.join(run_dir, "checkpoint.json"),
        "graph_execution_plan_path" => File.join(artifacts_dir, "graph-execution-plan.json"),
        "graph_scheduler_state_path" => File.join(artifacts_dir, "graph-scheduler-state.json"),
        "blocking_issues" => []
      }
      File.write(File.join(run_dir, "checkpoint.json"), JSON.pretty_generate(checkpoint) + "\n")
      File.write(File.join(run_dir, "engine-run.json"), JSON.pretty_generate(metadata) + "\n")
      File.write(File.join(run_dir, "lifecycle.json"), JSON.pretty_generate(metadata.merge("run_dir" => run_dir)) + "\n")

      status_payload, status_code = json_cmd("engine-scheduler", "status", "--run-id", run_id)
      assert_equal 0, status_code
      assert_equal "noop_terminal", status_payload.dig("engine_scheduler", "decision")
      assert_equal "finalize", status_payload.dig("engine_scheduler", "derived_start_node_id")
      assert_equal "engine_run_resume_bridge", status_payload.dig("engine_scheduler", "node_body_executor")

      tick_payload, tick_code = json_cmd("engine-scheduler", "tick", "--run-id", run_id)
      assert_equal 0, tick_code
      service_path = tick_payload.dig("engine_scheduler", "service_artifact_path")
      assert_equal File.join(run_dir, "artifacts", "scheduler-service.json").tr("\\", "/"), service_path
      assert File.file?(service_path)
      service = JSON.parse(File.read(service_path))
      assert_equal "aiweb.engine_scheduler.service.v1", service.fetch("service_driver")
      assert_equal "noop_terminal", service.fetch("decision")
      assert_includes service.fetch("limitations"), "node bodies still execute through the engine-run resume bridge"
      assert File.file?(".ai-web/scheduler/ledger.jsonl")
      ledger = File.readlines(".ai-web/scheduler/ledger.jsonl").map { |line| JSON.parse(line) }
      assert_equal run_id, ledger.last.fetch("selected_run_id")
      assert_equal "noop_terminal", ledger.last.fetch("decision")

      daemon_payload, daemon_code = json_cmd("engine-scheduler", "daemon", "--run-id", run_id, "--max-ticks", "2", "--workers", "2")
      assert_equal 0, daemon_code
      assert_equal "recorded", daemon_payload.dig("engine_scheduler", "status")
      assert_equal "aiweb.engine_scheduler.daemon.v1", daemon_payload.dig("engine_scheduler", "daemon_driver")
      assert_equal "project_local_durable_graph_scheduler_daemon", daemon_payload.dig("engine_scheduler", "service_type")
      assert_equal "terminal_or_no_runnable_work", daemon_payload.dig("engine_scheduler", "stop_reason")
      assert_equal 1, daemon_payload.dig("engine_scheduler", "tick_count")
      assert_equal ".ai-web/scheduler/daemon.json", daemon_payload.dig("engine_scheduler", "daemon_artifact_path")
      assert_equal ".ai-web/scheduler/worker-pool.json", daemon_payload.dig("engine_scheduler", "worker_pool_path")
      assert_equal ".ai-web/scheduler/daemon-heartbeat.json", daemon_payload.dig("engine_scheduler", "heartbeat_path")
      assert_equal ".ai-web/scheduler/leases.json", daemon_payload.dig("engine_scheduler", "leases_path")
      assert_equal ".ai-web/scheduler/queue-ledger.jsonl", daemon_payload.dig("engine_scheduler", "queue_ledger_path")
      assert File.file?(".ai-web/scheduler/daemon.json")
      assert File.file?(".ai-web/scheduler/worker-pool.json")
      assert File.file?(".ai-web/scheduler/daemon-heartbeat.json")
      assert File.file?(".ai-web/scheduler/leases.json")
      assert File.file?(".ai-web/scheduler/queue-ledger.jsonl")
      daemon = JSON.parse(File.read(".ai-web/scheduler/daemon.json"))
      worker_pool = JSON.parse(File.read(".ai-web/scheduler/worker-pool.json"))
      heartbeat = JSON.parse(File.read(".ai-web/scheduler/daemon-heartbeat.json"))
      leases = JSON.parse(File.read(".ai-web/scheduler/leases.json"))
      assert_equal "foreground_bounded_loop", daemon.fetch("mode")
      assert_equal "aiweb.engine_scheduler.worker_pool.v1", worker_pool.fetch("pool_driver")
      assert_equal 2, worker_pool.fetch("max_workers")
      assert_equal false, worker_pool.fetch("distributed")
      assert_equal true, worker_pool.fetch("concurrency_enforced")
      assert_equal 0, worker_pool.fetch("active_lease_count")
      assert_equal 2, worker_pool.fetch("worker_slots").length
      assert_equal "terminal_or_no_runnable_work", heartbeat.fetch("stop_reason")
      assert_equal 0, heartbeat.fetch("active_lease_count")
      assert_equal 0, leases.fetch("active_lease_count")
      assert_equal [], leases.fetch("duplicate_claims_blocked")
      queue_events = File.readlines(".ai-web/scheduler/queue-ledger.jsonl").map { |line| JSON.parse(line) }
      assert_equal "scheduler.tick", queue_events.last.fetch("event_type")
      ledger = File.readlines(".ai-web/scheduler/ledger.jsonl").map { |line| JSON.parse(line) }
      assert_equal run_id, ledger.last.fetch("selected_run_id")
      assert_equal "aiweb.engine_scheduler.daemon.v1", JSON.parse(File.read(service_path)).fetch("daemon_driver")

      dry_monitor_payload, dry_monitor_code = json_cmd("engine-scheduler", "monitor", "--dry-run")
      assert_equal 0, dry_monitor_code
      assert_equal "dry_run", dry_monitor_payload.dig("engine_scheduler", "status")
      refute File.exist?(".ai-web/scheduler/monitor.json")

      monitor_payload, monitor_code = json_cmd("engine-scheduler", "monitor")
      assert_equal 0, monitor_code, JSON.pretty_generate(monitor_payload)
      assert_equal "recorded", monitor_payload.dig("engine_scheduler", "status")
      assert_equal "healthy", monitor_payload.dig("engine_scheduler", "health_status")
      assert_equal "aiweb.engine_scheduler.monitor.v1", monitor_payload.dig("engine_scheduler", "monitor_driver")
      assert_equal ".ai-web/scheduler/monitor.json", monitor_payload.dig("engine_scheduler", "monitor_artifact_path")
      assert_equal ".ai-web/scheduler/monitor.json", monitor_payload.dig("changed_files", 0)
      assert File.file?(".ai-web/scheduler/monitor.json")
      monitor = JSON.parse(File.read(".ai-web/scheduler/monitor.json"))
      assert_equal "fresh", monitor.dig("checks", "heartbeat", "status")
      assert_equal "healthy", monitor.dig("checks", "leases", "status")
      assert_equal "healthy", monitor.dig("checks", "queue_ledger", "status")
      assert_equal "healthy", monitor.dig("checks", "worker_pool", "status")
      assert_equal "contract_only", monitor.dig("checks", "supervisor", "status")
      assert_equal false, monitor.dig("production_readiness", "os_service_health_observed")
      assert_equal false, monitor.dig("production_readiness", "distributed_worker_cluster")
      assert_match(/repo-local scheduler artifacts only/i, monitor.fetch("limitations").join(" "))

      resume_run_id = "engine-run-scheduler-resume"
      resume_run_dir = File.join(".ai-web", "runs", resume_run_id)
      resume_artifacts_dir = File.join(resume_run_dir, "artifacts")
      resume_workspace = File.join(".ai-web", "tmp", "agentic", resume_run_id, "workspace")
      FileUtils.mkdir_p(resume_artifacts_dir)
      FileUtils.mkdir_p(resume_workspace)
      resume_nodes = %w[preflight load_design_contract].map.with_index(1) do |node_id, ordinal|
        {
          "node_id" => node_id,
          "ordinal" => ordinal,
          "state" => node_id == "preflight" ? "passed" : "pending",
          "attempt" => 1,
          "side_effect_boundary" => "none",
          "executor" => {
            "handler" => "handler_for_#{node_id}",
            "executor_id" => "engine_run.#{node_id}",
            "side_effect_boundary" => "none",
            "tool_broker_required" => false,
            "idempotent" => true
          },
          "input_artifact_refs" => [],
          "output_artifact_refs" => [],
          "replay_policy" => { "requires_artifact_hash_validation" => true },
          "idempotency_key" => "idem-#{node_id}",
          "checkpoint_cursor" => "#{resume_run_id}:#{node_id}:1"
        }
      end
      resume_run_graph = {
        "run_id" => resume_run_id,
        "cursor" => { "node_id" => "preflight", "state" => "passed", "attempt" => 1 },
        "nodes" => resume_nodes,
        "executor_contract" => {
          "executor_type" => "sequential_durable_node_executor",
          "node_order" => resume_nodes.map { |node| node.fetch("node_id") },
          "checkpoint_policy" => "persist_before_and_after_side_effect_boundaries",
          "resume_strategy" => "validate_cursor_artifact_hashes_and_continue_at_next_idempotent_node",
          "side_effect_gate" => "tool_broker_required_for_non_none_boundaries"
        }
      }
      resume_artifact_refs = {
        graph_execution_plan_path: File.join(resume_artifacts_dir, "graph-execution-plan.json").tr("\\", "/"),
        graph_scheduler_state_path: File.join(resume_artifacts_dir, "graph-scheduler-state.json").tr("\\", "/"),
        checkpoint_path: File.join(resume_run_dir, "checkpoint.json").tr("\\", "/")
      }
      runtime = Aiweb::GraphSchedulerRuntime.new(run_graph: resume_run_graph, artifact_refs: resume_artifact_refs)
      graph_plan = runtime.execution_plan
      graph_state = runtime.initial_state(graph_plan)
      required_artifacts = {
        "staged-manifest.json" => { "schema_version" => 1, "files" => [] },
        "graph-execution-plan.json" => graph_plan,
        "graph-scheduler-state.json" => graph_state,
        "opendesign-contract.json" => { "schema_version" => 1 },
        "project-index.json" => { "schema_version" => 1 },
        "run-memory.json" => { "schema_version" => 1 },
        "authz-enforcement.json" => { "schema_version" => 1 },
        "worker-adapter-registry.json" => { "schema_version" => 1 },
        "sandbox-preflight.json" => { "schema_version" => 1, "status" => "passed" }
      }
      required_artifacts.each do |filename, payload|
        File.write(File.join(resume_artifacts_dir, filename), JSON.pretty_generate(payload) + "\n")
      end
      artifact_hashes = {
        "staged_manifest" => "staged-manifest.json",
        "graph_execution_plan" => "graph-execution-plan.json",
        "graph_scheduler_state" => "graph-scheduler-state.json",
        "opendesign_contract" => "opendesign-contract.json",
        "project_index" => "project-index.json",
        "run_memory" => "run-memory.json",
        "authz_enforcement" => "authz-enforcement.json",
        "worker_adapter_registry" => "worker-adapter-registry.json",
        "sandbox_preflight" => "sandbox-preflight.json"
      }.transform_values do |filename|
        path = File.join(resume_artifacts_dir, filename)
        {
          "path" => path.tr("\\", "/"),
          "sha256" => "sha256:#{Digest::SHA256.file(path).hexdigest}",
          "bytes" => File.size(path)
        }
      end
      resume_checkpoint = {
        "schema_version" => 1,
        "run_id" => resume_run_id,
        "status" => "running",
        "workspace_path" => resume_workspace.tr("\\", "/"),
        "run_graph_cursor" => resume_run_graph.fetch("cursor"),
        "run_graph" => resume_run_graph,
        "artifact_hashes" => artifact_hashes
      }
      resume_metadata = {
        "schema_version" => 1,
        "run_id" => resume_run_id,
        "kind" => "engine-run",
        "status" => "running",
        "agent" => "openmanus",
        "mode" => "agentic_local",
        "sandbox" => "docker",
        "capability" => { "limits" => { "max_cycles" => 2 } },
        "workspace_path" => resume_workspace.tr("\\", "/"),
        "metadata_path" => File.join(resume_run_dir, "engine-run.json").tr("\\", "/"),
        "checkpoint_path" => File.join(resume_run_dir, "checkpoint.json").tr("\\", "/"),
        "graph_execution_plan_path" => resume_artifact_refs.fetch(:graph_execution_plan_path),
        "graph_scheduler_state_path" => resume_artifact_refs.fetch(:graph_scheduler_state_path),
        "blocking_issues" => []
      }
      File.write(File.join(resume_run_dir, "checkpoint.json"), JSON.pretty_generate(resume_checkpoint) + "\n")
      File.write(File.join(resume_run_dir, "engine-run.json"), JSON.pretty_generate(resume_metadata) + "\n")
      File.write(File.join(resume_run_dir, "lifecycle.json"), JSON.pretty_generate(resume_metadata.merge("run_dir" => resume_run_dir)) + "\n")

      unapproved_execute_payload, unapproved_execute_code = json_cmd("engine-scheduler", "daemon", "--run-id", resume_run_id, "--execute")
      refute_equal 0, unapproved_execute_code
      assert_equal "blocked", unapproved_execute_payload.dig("engine_scheduler", "status")
      assert_match(/execute requires --approved/, unapproved_execute_payload.dig("engine_scheduler", "blocking_issues").join(" "))

      resume_daemon_payload, resume_daemon_code = json_cmd("engine-scheduler", "daemon", "--run-id", resume_run_id, "--max-ticks", "3", "--workers", "1")
      assert_equal 0, resume_daemon_code, JSON.pretty_generate(resume_daemon_payload)
      assert_equal "resume_ready_deferred", resume_daemon_payload.dig("engine_scheduler", "stop_reason")
      assert_equal 1, resume_daemon_payload.dig("engine_scheduler", "worker_pool", "active_lease_count")
      assert_equal true, resume_daemon_payload.dig("engine_scheduler", "worker_pool", "concurrency_enforced")
      assert_equal "claimed", resume_daemon_payload.dig("engine_scheduler", "worker_pool", "worker_slots", 0, "state")
      assert_equal "#{resume_run_id}:load_design_contract", resume_daemon_payload.dig("engine_scheduler", "leases", "leases", 0, "claim_key")
      duplicate_payload, duplicate_code = json_cmd("engine-scheduler", "daemon", "--run-id", resume_run_id, "--max-ticks", "1", "--workers", "1")
      refute_equal 0, duplicate_code
      assert_equal "blocked", duplicate_payload.dig("engine_scheduler", "status")
      assert_match(/duplicate active lease blocked/, duplicate_payload.dig("engine_scheduler", "blocking_issues").join(" "))

      stale_leases = JSON.parse(File.read(".ai-web/scheduler/leases.json"))
      old_time = (Time.now.utc - 600).iso8601
      stale_leases.fetch("leases").each do |lease|
        lease["claimed_at"] = old_time
        lease["expires_at"] = old_time
      end
      File.write(".ai-web/scheduler/leases.json", JSON.pretty_generate(stale_leases) + "\n")
      recovered_payload, recovered_code = json_cmd("engine-scheduler", "daemon", "--run-id", resume_run_id, "--max-ticks", "1", "--workers", "1")

      assert_equal 0, recovered_code, JSON.pretty_generate(recovered_payload)
      assert_equal "recorded", recovered_payload.dig("engine_scheduler", "status")
      assert_empty recovered_payload.dig("engine_scheduler", "leases", "duplicate_claims_blocked")
      assert_equal 300, recovered_payload.dig("engine_scheduler", "leases", "stale_lease_timeout_seconds")
      assert_equal "expired_or_ttl_elapsed_active_lease_may_be_reclaimed", recovered_payload.dig("engine_scheduler", "leases", "stale_lease_recovery_policy")
      assert_equal 1, recovered_payload.dig("engine_scheduler", "leases", "stale_leases_recovered").length
      assert_equal "#{resume_run_id}:load_design_contract", recovered_payload.dig("engine_scheduler", "leases", "stale_leases_recovered", 0, "claim_key")
      assert_equal "expired", recovered_payload.dig("engine_scheduler", "leases", "stale_leases_recovered", 0, "state")
      assert_equal 1, recovered_payload.dig("engine_scheduler", "worker_pool", "active_lease_count")
      assert_equal 300, recovered_payload.dig("engine_scheduler", "worker_pool", "lease_timeout_seconds")
      assert File.readlines(".ai-web/scheduler/queue-ledger.jsonl").map { |line| JSON.parse(line).fetch("event_type") }.include?("scheduler.lease.stale_recovered")
    end
  end

  def test_engine_scheduler_approved_execute_resumes_bridge_without_nested_state_lock
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir, patch_text: "<!-- scheduler tick failed patch -->", exit_status: 9)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      first_payload, first_code = json_cmd_with_env(env, "engine-run", "--goal", "scheduler tick resume", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "1", "--approved")
      refute_equal 0, first_code
      tick_parent_run_id = first_payload.dig("engine_run", "run_id")
      mark_engine_run_scheduler_resume_candidate!(tick_parent_run_id)

      write_fake_openmanus_tooling(dir, patch_text: "<!-- scheduler tick resumed patch -->")
      tick_payload, tick_code = json_cmd_with_env(env, "engine-scheduler", "tick", "--run-id", tick_parent_run_id, "--approved", "--execute")

      assert_equal 0, tick_code, JSON.pretty_generate(tick_payload)
      assert_equal "resume_ready", tick_payload.dig("engine_scheduler", "decision")
      assert_equal true, tick_payload.dig("engine_scheduler", "execution_attempted")
      assert_equal "passed", tick_payload.dig("engine_scheduler", "execution_status")
      refute_match(/state lock exists/, JSON.generate(tick_payload))
      tick_service = JSON.parse(File.read(tick_payload.dig("engine_scheduler", "service_artifact_path")))
      assert_equal "passed", tick_service.dig("execution_result_summary", "status")
      assert_equal tick_parent_run_id, tick_service.dig("execution_result_summary", "resume_from")
      body = File.read("src/components/Hero.astro")
      assert_match(/scheduler tick failed patch/, body)
      assert_match(/scheduler tick resumed patch/, body)

      write_fake_openmanus_tooling(dir, patch_text: "<!-- scheduler daemon failed patch -->", exit_status: 9)
      second_payload, second_code = json_cmd_with_env(env, "engine-run", "--goal", "scheduler daemon resume", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "1", "--approved")
      refute_equal 0, second_code
      daemon_parent_run_id = second_payload.dig("engine_run", "run_id")
      mark_engine_run_scheduler_resume_candidate!(daemon_parent_run_id)

      write_fake_openmanus_tooling(dir, patch_text: "<!-- scheduler daemon resumed patch -->")
      daemon_payload, daemon_code = json_cmd_with_env(env, "engine-scheduler", "daemon", "--run-id", daemon_parent_run_id, "--max-ticks", "1", "--workers", "1", "--approved", "--execute")

      assert_equal 0, daemon_code, JSON.pretty_generate(daemon_payload)
      assert_equal "resume_ready_executed", daemon_payload.dig("engine_scheduler", "stop_reason")
      assert_equal true, daemon_payload.dig("engine_scheduler", "execution_attempted")
      assert_equal "completed", daemon_payload.dig("engine_scheduler", "execution_status")
      assert_equal "passed", daemon_payload.dig("engine_scheduler", "execution_summary", "services", 0, "status")
      assert_equal 0, daemon_payload.dig("engine_scheduler", "leases", "active_lease_count")
      assert_equal "completed", daemon_payload.dig("engine_scheduler", "leases", "leases", 0, "state")
      assert_equal "available", daemon_payload.dig("engine_scheduler", "worker_pool", "worker_slots", 0, "state")
      refute_match(/state lock exists/, JSON.generate(daemon_payload))
      daemon = JSON.parse(File.read(".ai-web/scheduler/daemon.json"))
      assert_equal "resume_ready_executed", daemon.fetch("stop_reason")
      assert_equal "passed", daemon.dig("service_records", 0, "execution_result_summary", "status")
      assert File.readlines(".ai-web/scheduler/queue-ledger.jsonl").map { |line| JSON.parse(line).fetch("event_type") }.include?("scheduler.execution.finished")
      body = File.read("src/components/Hero.astro")
      assert_match(/scheduler daemon failed patch/, body)
      assert_match(/scheduler daemon resumed patch/, body)
    end
  end

  def test_mcp_broker_records_approved_lazyweb_implementation_call_and_blocks_unapproved_calls
    responses = lambda do |payload|
      case payload.fetch("method")
      when "initialize"
        { "jsonrpc" => "2.0", "id" => payload.fetch("id"), "result" => { "capabilities" => {} } }
      when "notifications/initialized"
        {}
      when "tools/call"
        assert_equal "lazyweb_search", payload.dig("params", "name")
        {
          "jsonrpc" => "2.0",
          "id" => payload.fetch("id"),
          "result" => {
            "content" => [{ "type" => "text", "text" => JSON.generate("results" => [
              { "company" => "Acme", "image_url" => "https://lazyweb.test/image.png?token=secret-token" }
            ]) }]
          }
        }
      else
        raise "unexpected MCP method #{payload.fetch("method")}"
      end
    end

    FakeMcpHttpServer.open(responses) do |endpoint, received|
      in_tmp do
        json_cmd("init")
        dry_payload, dry_code = json_cmd("mcp-broker", "call", "--server", "lazyweb", "--tool", "lazyweb_search", "--query", "pricing page", "--endpoint", "#{endpoint}?token=secret-token", "--dry-run")
        assert_equal 0, dry_code
        assert_equal "planned", dry_payload.dig("mcp_broker", "status")
        refute File.exist?(dry_payload.dig("mcp_broker", "metadata_path"))
        refute File.exist?(dry_payload.dig("mcp_broker", "side_effect_broker_path"))

        blocked_payload, blocked_code = json_cmd("mcp-broker", "call", "--server", "lazyweb", "--tool", "lazyweb_search", "--query", "pricing page", "--endpoint", endpoint)
        refute_equal 0, blocked_code
        assert_equal "blocked", blocked_payload.dig("mcp_broker", "status")
        assert_match(/requires --approved/, blocked_payload.fetch("blocking_issues").join(" "))
        blocked_events = File.readlines(blocked_payload.dig("mcp_broker", "side_effect_broker_path"), chomp: true).map { |line| JSON.parse(line) }
        assert_equal %w[tool.requested policy.decision tool.blocked], blocked_events.map { |event| event.fetch("event") }
        assert_equal "deny", blocked_events.find { |event| event.fetch("event") == "policy.decision" }.fetch("decision")

        env = { "LAZYWEB_MCP_TOKEN" => "secret-token" }
        payload, code = json_cmd_with_env(env, "mcp-broker", "call", "--server", "lazyweb", "--tool", "lazyweb_search", "--query", "pricing page", "--limit", "1", "--endpoint", "#{endpoint}?token=secret-token", "--approved")
        assert_equal 0, code
        assert_equal "passed", payload.dig("mcp_broker", "status")
        assert_equal "aiweb.implementation_mcp_broker", payload.dig("mcp_broker", "broker_driver")
        assert_equal "implementation_worker.mcp.lazyweb", payload.dig("mcp_broker", "scope")
        assert File.file?(payload.dig("mcp_broker", "metadata_path"))
        assert File.file?(payload.dig("mcp_broker", "side_effect_broker_path"))
        events = File.readlines(payload.dig("mcp_broker", "side_effect_broker_path"), chomp: true).map { |line| JSON.parse(line) }
        assert_equal %w[tool.requested policy.decision tool.started tool.finished], events.map { |event| event.fetch("event") }
        assert_equal "allow", events.find { |event| event.fetch("event") == "policy.decision" }.fetch("decision")
        assert_equal "Bearer secret-token", received.last.fetch("authorization")
        metadata = File.read(payload.dig("mcp_broker", "metadata_path"))
        broker_log = File.read(payload.dig("mcp_broker", "side_effect_broker_path"))
        refute_includes metadata, "secret-token"
        refute_includes broker_log, "secret-token"
        assert_includes metadata, "[REDACTED]"
      end
    end
  end

  def test_mcp_broker_blocks_unknown_connector_with_missing_driver_contract
    in_tmp do
      json_cmd("init")

      payload, code = json_cmd(
        "mcp-broker",
        "call",
        "--server",
        "github",
        "--tool",
        "issues_search",
        "--query",
        "bug report",
        "--approved"
      )

      refute_equal 0, code
      assert_equal "blocked", payload.dig("mcp_broker", "status")
      assert_equal "aiweb.implementation_mcp_broker", payload.dig("mcp_broker", "broker_driver")
      assert_equal "implementation_worker.mcp.denied", payload.dig("mcp_broker", "scope")
      assert_equal "github", payload.dig("mcp_broker", "server")
      assert_equal "issues_search", payload.dig("mcp_broker", "tool")
      assert_match(/only supports servers lazyweb, project_files/i, payload.fetch("blocking_issues").join("\n"))
      assert_match(/missing a broker driver/i, payload.fetch("blocking_issues").join("\n"))
      policy = payload.dig("mcp_broker", "connector_policy")
      assert_equal "aiweb.implementation_mcp_broker.connector_policy.v1", policy.fetch("policy")
      assert_equal false, policy.fetch("known_driver")
      assert_equal true, policy.fetch("fail_closed")
      assert_equal "missing_broker_driver_fail_closed", policy.fetch("driver_status")
      assert_equal true, policy.fetch("deny_by_default_for_unknown_connectors")
      %w[mcp_server tool_names allowed_args_schema credential_source delegated_identity network_destinations output_redaction per_call_audit side_effect_broker_path result_schema rollback_or_replay_policy].each do |field|
        assert_includes policy.fetch("missing_driver_required_fields"), field
      end
      assert File.file?(payload.dig("mcp_broker", "metadata_path"))
      assert File.file?(payload.dig("mcp_broker", "side_effect_broker_path"))
      metadata = JSON.parse(File.read(payload.dig("mcp_broker", "metadata_path")))
      assert_equal policy, metadata.fetch("connector_policy")
      events = File.readlines(payload.dig("mcp_broker", "side_effect_broker_path"), chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[tool.requested policy.decision tool.blocked], events.map { |event| event.fetch("event") }
      decision = events.find { |event| event.fetch("event") == "policy.decision" }
      assert_equal "deny", decision.fetch("decision")
      assert_equal "implementation_worker.mcp.denied", decision.fetch("scope")
      assert_equal "missing_broker_driver_fail_closed", decision.dig("connector_policy", "driver_status")
      assert_equal "deny", payload.dig("mcp_broker", "side_effect_broker", "policy", "decision")
    end
  end

  def test_mcp_broker_records_project_file_metadata_driver_without_content_or_network
    in_tmp do
      json_cmd("init")
      FileUtils.mkdir_p("src")
      File.write("src/app.js", "console.log('metadata only')\n")

      payload, code = json_cmd("mcp-broker", "call", "--server", "project_files", "--tool", "project_file_metadata", "--query", "src/app.js", "--approved")
      assert_equal 0, code, payload.inspect
      assert_equal "passed", payload.dig("mcp_broker", "status")
      assert_equal "implementation_worker.mcp.project_files", payload.dig("mcp_broker", "scope")
      assert_equal "project_files", payload.dig("mcp_broker", "server")
      assert_equal "project_file_metadata", payload.dig("mcp_broker", "tool")
      assert_equal [], payload.dig("mcp_broker", "network_destinations")
      assert_equal "none_local_metadata_only", payload.dig("mcp_broker", "credential_source")
      assert_equal "implemented_for_approved_project_file_metadata", payload.dig("mcp_broker", "connector_policy", "driver_status")
      assert_equal false, payload.dig("mcp_broker", "result", "content_included")
      assert_equal false, payload.dig("mcp_broker", "result", "network_used")
      assert_equal "src/app.js", payload.dig("mcp_broker", "result", "path")
      assert_match(/\Asha256:[a-f0-9]{64}\z/, payload.dig("mcp_broker", "result", "sha256"))
      metadata_text = File.read(payload.dig("mcp_broker", "metadata_path"))
      refute_includes metadata_text, "console.log('metadata only')"

      File.write(".env", "SECRET=should-not-read\n")
      blocked_payload, blocked_code = json_cmd("mcp-broker", "call", "--server", "project_files", "--tool", "project_file_metadata", "--query", ".env", "--approved")
      refute_equal 0, blocked_code
      assert_equal "blocked", blocked_payload.dig("mcp_broker", "status")
      assert_match(/must not reference \.env/i, blocked_payload.fetch("blocking_issues").join("\n"))
      refute_includes JSON.generate(blocked_payload), "should-not-read"
    end
  end

  def test_mcp_broker_records_project_file_list_driver_without_content_or_network
    in_tmp do
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      FileUtils.mkdir_p("node_modules/pkg")
      FileUtils.mkdir_p(".git")
      FileUtils.mkdir_p(".ai-web/runs/mcp-broker-secret")
      File.write("src/app.js", "console.log('listed but not leaked')\n")
      File.write("src/components/Hero.astro", "<section>Hero</section>\n")
      File.write("src/style.css", ".hero { color: red; }\n")
      File.write("src/.env.local", "SECRET=must-not-leak\n")

      payload, code = json_cmd("mcp-broker", "call", "--server", "project_files", "--tool", "project_file_list", "--query", "src", "--limit", "2", "--approved")
      assert_equal 0, code, payload.inspect
      assert_equal "passed", payload.dig("mcp_broker", "status")
      assert_equal "implementation_worker.mcp.project_files", payload.dig("mcp_broker", "scope")
      assert_equal "project_files", payload.dig("mcp_broker", "server")
      assert_equal "project_file_list", payload.dig("mcp_broker", "tool")
      assert_equal [], payload.dig("mcp_broker", "network_destinations")
      assert_equal "none_local_metadata_only", payload.dig("mcp_broker", "credential_source")
      assert_equal "implemented_for_approved_project_file_list", payload.dig("mcp_broker", "connector_policy", "driver_status")
      result = payload.dig("mcp_broker", "result")
      assert_equal false, result.fetch("content_included")
      assert_equal false, result.fetch("network_used")
      assert_equal "src", result.fetch("path")
      assert_equal 2, result.fetch("limit")
      assert_equal 2, result.fetch("entry_count")
      assert_equal true, result.fetch("truncated")
      assert_operator result.fetch("excluded_count"), :>=, 1
      assert_equal %w[src/app.js src/components], result.fetch("entries").map { |entry| entry.fetch("path") }
      assert result.fetch("entries").all? { |entry| entry.fetch("content_included") == false }
      metadata_text = File.read(payload.dig("mcp_broker", "metadata_path"))
      refute_includes metadata_text, "console.log('listed but not leaked')"
      refute_includes metadata_text, "SECRET=must-not-leak"
      events = File.readlines(payload.dig("mcp_broker", "side_effect_broker_path"), chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[tool.requested policy.decision tool.started tool.finished], events.map { |event| event.fetch("event") }
      assert_equal "allow", events.find { |event| event.fetch("event") == "policy.decision" }.fetch("decision")

      blocked_payload, blocked_code = json_cmd("mcp-broker", "call", "--server", "project_files", "--tool", "project_file_list", "--query", ".env", "--approved")
      refute_equal 0, blocked_code
      assert_equal "blocked", blocked_payload.dig("mcp_broker", "status")
      assert_match(/must not reference \.env/i, blocked_payload.fetch("blocking_issues").join("\n"))
      refute_includes JSON.generate(blocked_payload), "must-not-leak"

      traversal_payload, traversal_code = json_cmd("mcp-broker", "call", "--server", "project_files", "--tool", "project_file_list", "--query", "../outside", "--approved")
      refute_equal 0, traversal_code
      assert_equal "blocked", traversal_payload.dig("mcp_broker", "status")
      assert_match(/must not traverse outside project/i, traversal_payload.fetch("blocking_issues").join("\n"))

      runs_payload, runs_code = json_cmd("mcp-broker", "call", "--server", "project_files", "--tool", "project_file_list", "--query", ".ai-web/runs", "--approved")
      refute_equal 0, runs_code
      assert_equal "blocked", runs_payload.dig("mcp_broker", "status")
      assert_match(/generated run artifacts/i, runs_payload.fetch("blocking_issues").join("\n"))
    end
  end

  def test_mcp_broker_records_project_file_excerpt_driver_with_bounded_safe_content
    in_tmp do
      json_cmd("init")
      FileUtils.mkdir_p("src")
      File.binwrite("src/app.js", "line one\nline two\nline three\n")

      payload, code = json_cmd("mcp-broker", "call", "--server", "project_files", "--tool", "project_file_excerpt", "--query", "src/app.js", "--limit", "2", "--approved")
      assert_equal 0, code, payload.inspect
      assert_equal "passed", payload.dig("mcp_broker", "status")
      assert_equal "implementation_worker.mcp.project_files", payload.dig("mcp_broker", "scope")
      assert_equal "project_files", payload.dig("mcp_broker", "server")
      assert_equal "project_file_excerpt", payload.dig("mcp_broker", "tool")
      assert_equal [], payload.dig("mcp_broker", "network_destinations")
      assert_equal "none_local_safe_file_excerpt", payload.dig("mcp_broker", "credential_source")
      assert_equal "bounded_safe_excerpt_secret_scan_plus_side_effect_broker_redaction", payload.dig("mcp_broker", "output_redaction")
      assert_equal "implemented_for_approved_project_file_excerpt", payload.dig("mcp_broker", "connector_policy", "driver_status")
      result = payload.dig("mcp_broker", "result")
      assert_equal true, result.fetch("content_included")
      assert_equal false, result.fetch("network_used")
      assert_equal "src/app.js", result.fetch("path")
      assert_equal 2, result.fetch("max_lines")
      assert_equal 2, result.fetch("excerpt_line_count")
      assert_equal true, result.fetch("truncated")
      assert_equal "line one\nline two\n", result.fetch("excerpt")
      assert_match(/\Asha256:[a-f0-9]{64}\z/, result.fetch("sha256"))
      events = File.readlines(payload.dig("mcp_broker", "side_effect_broker_path"), chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[tool.requested policy.decision tool.started tool.finished], events.map { |event| event.fetch("event") }
      assert_equal "allow", events.find { |event| event.fetch("event") == "policy.decision" }.fetch("decision")

      File.write("src/note.txt", "SECRET=must-not-leak\n")
      blocked_payload, blocked_code = json_cmd("mcp-broker", "call", "--server", "project_files", "--tool", "project_file_excerpt", "--query", "src/note.txt", "--approved")
      refute_equal 0, blocked_code
      assert_equal "blocked", blocked_payload.dig("mcp_broker", "status")
      assert_match(/secret-like content/i, blocked_payload.fetch("blocking_issues").join("\n"))
      refute_includes JSON.generate(blocked_payload), "must-not-leak"

      File.binwrite("src/binary.bin", "safe\x00binary")
      binary_payload, binary_code = json_cmd("mcp-broker", "call", "--server", "project_files", "--tool", "project_file_excerpt", "--query", "src/binary.bin", "--approved")
      refute_equal 0, binary_code
      assert_equal "blocked", binary_payload.dig("mcp_broker", "status")
      assert_match(/binary files/i, binary_payload.fetch("blocking_issues").join("\n"))
    end
  end

  def test_mcp_broker_records_project_file_search_driver_with_bounded_safe_matches
    in_tmp do
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.binwrite("src/app.js", "alpha needle one\nno match\n")
      File.binwrite("src/components/Hero.astro", "<section>needle two</section>\n")
      File.write("src/components/secret.txt", "SECRET=must-not-leak needle\n")
      FileUtils.mkdir_p("node_modules/pkg")
      File.write("node_modules/pkg/index.js", "needle ignored\n")

      payload, code = json_cmd("mcp-broker", "call", "--server", "project_files", "--tool", "project_file_search", "--query", "src::needle", "--limit", "2", "--approved")
      assert_equal 0, code, payload.inspect
      assert_equal "passed", payload.dig("mcp_broker", "status")
      assert_equal "implementation_worker.mcp.project_files", payload.dig("mcp_broker", "scope")
      assert_equal "project_files", payload.dig("mcp_broker", "server")
      assert_equal "project_file_search", payload.dig("mcp_broker", "tool")
      assert_equal [], payload.dig("mcp_broker", "network_destinations")
      assert_equal "none_local_safe_file_search", payload.dig("mcp_broker", "credential_source")
      assert_equal "bounded_safe_search_secret_scan_plus_side_effect_broker_redaction", payload.dig("mcp_broker", "output_redaction")
      assert_equal "implemented_for_approved_project_file_search", payload.dig("mcp_broker", "connector_policy", "driver_status")
      result = payload.dig("mcp_broker", "result")
      assert_equal true, result.fetch("content_included")
      assert_equal false, result.fetch("network_used")
      assert_equal "src", result.fetch("path")
      assert_equal 2, result.fetch("limit")
      assert_equal 2, result.fetch("match_count")
      assert_match(/\Asha256:[a-f0-9]{64}\z/, result.fetch("pattern_sha256"))
      assert_equal ["src/app.js", "src/components/Hero.astro"], result.fetch("matches").map { |match| match.fetch("path") }
      assert result.fetch("matches").all? { |match| match.fetch("excerpt").include?("needle") }
      refute_includes JSON.generate(result), "must-not-leak"
      events = File.readlines(payload.dig("mcp_broker", "side_effect_broker_path"), chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[tool.requested policy.decision tool.started tool.finished], events.map { |event| event.fetch("event") }
      assert_equal "allow", events.find { |event| event.fetch("event") == "policy.decision" }.fetch("decision")

      unsafe_payload, unsafe_code = json_cmd("mcp-broker", "call", "--server", "project_files", "--tool", "project_file_search", "--query", "../outside::needle", "--approved")
      refute_equal 0, unsafe_code
      assert_equal "blocked", unsafe_payload.dig("mcp_broker", "status")
      assert_match(/must not traverse outside project/i, unsafe_payload.fetch("blocking_issues").join("\n"))

      secret_pattern_payload, secret_pattern_code = json_cmd("mcp-broker", "call", "--server", "project_files", "--tool", "project_file_search", "--query", "src::SECRET=must-not-leak", "--approved")
      refute_equal 0, secret_pattern_code
      assert_equal "blocked", secret_pattern_payload.dig("mcp_broker", "status")
      assert_match(/pattern must not be secret-like/i, secret_pattern_payload.fetch("blocking_issues").join("\n"))
      refute_includes JSON.generate(secret_pattern_payload), "must-not-leak"
    end
  end

  def test_engine_run_design_verdict_passes_with_screenshot_evidence_and_scores
    in_tmp do |dir|
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      source = "src/components/Hero.astro"
      File.write(source, "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [{ "data_aiweb_id" => "component.hero.copy", "source_path" => source, "editable" => true }]
      ))
      File.write("package.json", JSON.pretty_generate("scripts" => { "dev" => "fake dev" }))
      bin_dir = write_fake_engine_openmanus_preview_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      assert_equal 0, code
      assert_equal "passed", payload.dig("engine_run", "design_verdict", "status")
      assert_equal true, payload.dig("engine_run", "copy_back_policy", "design_gate_required")
      assert_equal "passed", payload.dig("engine_run", "copy_back_policy", "design_gate_status")
      assert_match(%r{\.ai-web/runs/.+/qa/design-verdict\.json}, payload.dig("engine_run", "copy_back_policy", "design_gate_artifact"))
      assert_equal "deterministic_local", payload.dig("engine_run", "design_verdict", "reviewer")
      assert_operator payload.dig("engine_run", "design_verdict", "scores", "selected_design_fidelity"), :>=, 0.8
      assert_equal "captured", payload.dig("engine_run", "design_verdict", "inputs", "browser_evidence_status")
      assert_equal "captured", payload.dig("engine_run", "design_verdict", "inputs", "dom_snapshot_status")
      assert_equal "captured", payload.dig("engine_run", "design_verdict", "inputs", "a11y_report_status")
      assert_equal "captured", payload.dig("engine_run", "design_verdict", "inputs", "computed_style_status")
      assert_equal "captured", payload.dig("engine_run", "design_verdict", "inputs", "keyboard_focus_status")
      assert_equal "captured", payload.dig("engine_run", "design_verdict", "inputs", "action_recovery_status")
      assert_equal "captured", payload.dig("engine_run", "design_verdict", "inputs", "action_loop_status")
      assert_equal 0, payload.dig("engine_run", "design_verdict", "inputs", "console_error_count")
      assert_equal 0, payload.dig("engine_run", "design_verdict", "inputs", "network_error_count")
      assert File.file?(payload.dig("engine_run", "design_verdict_path"))
      assert File.file?(payload.dig("engine_run", "design_fixture_path"))
      fixture = JSON.parse(File.read(payload.dig("engine_run", "design_fixture_path")))
      assert_equal "ready", fixture.fetch("status")
      assert_match(/\Adesign-fixture-[a-f0-9]{16}\z/, fixture.fetch("fixture_id"))
      assert_equal %w[desktop tablet mobile], fixture.fetch("viewport_expected_outcomes").map { |entry| entry.fetch("viewport") }
      assert_equal "passed", fixture.dig("stored_baseline_verdict", "status")
      assert_equal payload.dig("engine_run", "opendesign_contract", "selected_candidate_sha256"), fixture.dig("golden_reference", "sha256")
      assert_match(%r{\A\.ai-web/runs/.+/qa/eval-benchmark\.json\z}, payload.dig("engine_run", "eval_benchmark_path"))
      assert File.file?(payload.dig("engine_run", "eval_benchmark_path"))
      benchmark = JSON.parse(File.read(payload.dig("engine_run", "eval_benchmark_path")))
      assert_equal "passed", benchmark.fetch("status")
      assert_match(/\Aeval-benchmark-[a-f0-9]{16}\z/, benchmark.fetch("benchmark_id"))
      assert_equal fixture.fetch("fixture_id"), benchmark.fetch("fixture_id")
      assert_equal "seeded", benchmark.fetch("human_calibration_status")
      assert_equal "deterministic_design_fixture_seed", benchmark.dig("baseline_source", "type")
      assert_equal false, benchmark.dig("baseline_source", "human_calibrated")
      assert_equal "passed", benchmark.dig("regression_gate", "status")
      assert_equal true, benchmark.dig("regression_gate", "enforced")
      assert_equal "evidence_gate_only_no_human_baseline", benchmark.dig("regression_gate", "mode")
      assert_equal "passed", benchmark.dig("metrics", "task_success", "status")
      assert_equal "passed", benchmark.dig("metrics", "visual_fidelity", "status")
      assert_equal "passed", benchmark.dig("metrics", "interaction_pass", "status")
      assert_equal "passed", benchmark.dig("metrics", "action_recovery_pass", "status")
      assert_equal "passed", benchmark.dig("metrics", "browser_action_loop_pass", "status")
      assert_equal "passed", benchmark.dig("metrics", "a11y_pass", "status")
      assert_equal "skipped", benchmark.dig("metrics", "build_pass", "status")
      assert_equal "skipped", benchmark.dig("metrics", "test_pass", "status")
      assert_equal %w[desktop tablet mobile], benchmark.fetch("viewport_matrix").map { |entry| entry.fetch("viewport") }
      assert_equal true, payload.dig("engine_run", "copy_back_policy", "eval_benchmark_required")
      assert_equal "passed", payload.dig("engine_run", "copy_back_policy", "eval_benchmark_status")
      checkpoint = JSON.parse(File.read(payload.dig("engine_run", "checkpoint_path")))
      assert_equal payload.dig("engine_run", "eval_benchmark_path"), checkpoint.dig("artifact_hashes", "eval_benchmark", "path")
      event_types = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line).fetch("type") }
      assert_includes event_types, "design.review.started"
      assert_includes event_types, "design.review.finished"
      assert_includes event_types, "design.fixture.recorded"
      assert_includes event_types, "eval.benchmark.recorded"
    end
  end

  def test_engine_run_design_gate_blocks_copy_back_without_real_browser_evidence
    in_tmp do |dir|
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      source = "src/components/Hero.astro"
      File.write(source, "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [{ "data_aiweb_id" => "component.hero.copy", "source_path" => source, "editable" => true }]
      ))
      File.write(".ai-web/fail-browser-observe", "1\n")
      File.write("package.json", JSON.pretty_generate("scripts" => { "dev" => "fake dev" }))
      bin_dir = write_fake_engine_openmanus_preview_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "1", "--approved")

      refute_equal 0, code
      assert_equal "failed", payload.dig("engine_run", "status")
      assert_equal "failed", payload.dig("engine_run", "screenshot_evidence", "status")
      assert_equal "failed", payload.dig("engine_run", "design_verdict", "status")
      assert_match(/browser evidence|browser observation|DOM snapshot|accessibility/i, payload.dig("engine_run", "design_verdict", "blocking_issues").join("\n"))
      benchmark = JSON.parse(File.read(payload.dig("engine_run", "eval_benchmark_path")))
      assert_equal "failed", benchmark.fetch("status")
      assert_equal "failed", benchmark.dig("regression_gate", "status")
      assert_match(/captured browser evidence|accessibility evidence|interaction evidence/i, benchmark.fetch("blocking_issues").join("\n"))
      assert_equal "failed", benchmark.dig("metrics", "visual_fidelity", "status")
      refute_match(/patched by fake openmanus/, File.read(source))
      event_types = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line).fetch("type") }
      assert_includes event_types, "screenshot.capture.failed"
      assert_includes event_types, "design.review.failed"
      assert_includes event_types, "eval.benchmark.recorded"
    end
  end

  def test_engine_run_design_gate_blocks_copy_back_on_invalid_browser_png_evidence
    in_tmp do |dir|
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      source = "src/components/Hero.astro"
      File.write(source, "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [{ "data_aiweb_id" => "component.hero.copy", "source_path" => source, "editable" => true }]
      ))
      File.write(".ai-web/fake-browser-invalid-png", "1\n")
      File.write("package.json", JSON.pretty_generate("scripts" => { "dev" => "fake dev" }))
      bin_dir = write_fake_engine_openmanus_preview_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "1", "--approved")

      refute_equal 0, code
      assert_equal "failed", payload.dig("engine_run", "status")
      assert_equal "failed", payload.dig("engine_run", "screenshot_evidence", "status")
      assert_match(/not valid PNG evidence|png signature mismatch/i, payload.dig("engine_run", "screenshot_evidence", "blocking_issues").join("\n"))
      assert_equal "failed", payload.dig("engine_run", "design_verdict", "status")
      refute_match(/patched by fake openmanus/, File.read(source))
    end
  end

  def test_engine_run_design_gate_blocks_copy_back_on_browser_console_or_network_errors
    in_tmp do |dir|
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      source = "src/components/Hero.astro"
      File.write(source, "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [{ "data_aiweb_id" => "component.hero.copy", "source_path" => source, "editable" => true }]
      ))
      File.write(".ai-web/fake-browser-console-error", "1\n")
      File.write(".ai-web/fake-browser-network-error", "1\n")
      File.write("package.json", JSON.pretty_generate("scripts" => { "dev" => "fake dev" }))
      bin_dir = write_fake_engine_openmanus_preview_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "1", "--approved")

      refute_equal 0, code
      assert_equal "failed", payload.dig("engine_run", "status")
      assert_equal "failed", payload.dig("engine_run", "screenshot_evidence", "status")
      assert_operator payload.dig("engine_run", "screenshot_evidence", "console_errors").length, :>, 0
      assert_operator payload.dig("engine_run", "screenshot_evidence", "network_errors").length, :>, 0
      assert_equal "failed", payload.dig("engine_run", "design_verdict", "status")
      assert_match(/console-clean|network-clean/i, payload.dig("engine_run", "design_verdict", "blocking_issues").join("\n"))
      refute_match(/patched by fake openmanus/, File.read(source))
    end
  end

  def test_engine_run_design_gate_blocks_copy_back_on_browser_action_recovery_failure
    in_tmp do |dir|
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      source = "src/components/Hero.astro"
      File.write(source, "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [{ "data_aiweb_id" => "component.hero.copy", "source_path" => source, "editable" => true }]
      ))
      File.write(".ai-web/fake-browser-action-recovery-fail", "1\n")
      File.write("package.json", JSON.pretty_generate("scripts" => { "dev" => "fake dev" }))
      bin_dir = write_fake_engine_openmanus_preview_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "1", "--approved")

      refute_equal 0, code
      assert_equal "failed", payload.dig("engine_run", "status")
      assert_equal "failed", payload.dig("engine_run", "screenshot_evidence", "status")
      assert_equal "failed", payload.dig("engine_run", "screenshot_evidence", "action_recovery", "status")
      assert_equal "failed", payload.dig("engine_run", "screenshot_evidence", "action_loop", "status")
      assert_equal "failed", payload.dig("engine_run", "design_verdict", "status")
      assert_match(/action\/recovery|action-loop/i, payload.dig("engine_run", "design_verdict", "blocking_issues").join("\n"))
      assert_equal "failed", payload.dig("engine_run", "eval_benchmark", "metrics", "action_recovery_pass", "status")
      assert_equal "failed", payload.dig("engine_run", "eval_benchmark", "metrics", "browser_action_loop_pass", "status")
      refute_match(/patched by fake openmanus/, File.read(source))
    end
  end

  def test_engine_run_design_gate_blocks_copy_back_on_external_browser_request_attempt
    in_tmp do |dir|
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      source = "src/components/Hero.astro"
      File.write(source, "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [{ "data_aiweb_id" => "component.hero.copy", "source_path" => source, "editable" => true }]
      ))
      File.write(".ai-web/fake-browser-external-request-blocked", "1\n")
      File.write("package.json", JSON.pretty_generate("scripts" => { "dev" => "fake dev" }))
      bin_dir = write_fake_engine_openmanus_preview_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "1", "--approved")

      refute_equal 0, code
      assert_equal "failed", payload.dig("engine_run", "status")
      assert_equal "failed", payload.dig("engine_run", "screenshot_evidence", "status")
      assert_equal "failed", payload.dig("engine_run", "screenshot_evidence", "action_recovery", "status")
      assert_equal "failed", payload.dig("engine_run", "screenshot_evidence", "action_loop", "status")
      assert_equal true, payload.dig("engine_run", "screenshot_evidence", "action_recovery", "viewports").all? { |entry| entry.fetch("unsafe_navigation_blocked") == true }
      assert_operator payload.dig("engine_run", "screenshot_evidence", "action_recovery", "external_requests_blocked").length, :>, 0
      assert_match(/non-local browser request/i, payload.dig("engine_run", "screenshot_evidence", "action_recovery", "blocking_issues").join("\n"))
      assert_match(/network-clean|action\/recovery|action-loop/i, payload.dig("engine_run", "design_verdict", "blocking_issues").join("\n"))
      assert_equal "failed", payload.dig("engine_run", "eval_benchmark", "metrics", "action_recovery_pass", "status")
      assert_equal "failed", payload.dig("engine_run", "eval_benchmark", "metrics", "browser_action_loop_pass", "status")
      refute_match(/patched by fake openmanus/, File.read(source))
    end
  end

  def test_engine_run_preserves_structured_browser_policy_evidence_on_observer_exit_failure
    in_tmp do |dir|
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      source = "src/components/Hero.astro"
      File.write(source, "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [{ "data_aiweb_id" => "component.hero.copy", "source_path" => source, "editable" => true }]
      ))
      File.write(".ai-web/fake-browser-external-request-blocked", "1\n")
      File.write(".ai-web/fake-browser-exit-after-evidence", "1\n")
      File.write("package.json", JSON.pretty_generate("scripts" => { "dev" => "fake dev" }))
      bin_dir = write_fake_engine_openmanus_preview_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "1", "--approved")

      refute_equal 0, code
      evidence = payload.dig("engine_run", "screenshot_evidence")
      assert_equal "failed", evidence.fetch("status")
      assert_equal [], evidence.fetch("screenshots")
      assert_equal "failed", evidence.dig("action_recovery", "status")
      assert_equal "failed", evidence.dig("action_loop", "status")
      assert_match(/non-local browser request/i, evidence.dig("action_recovery", "blocking_issues").join("\n"))
      assert evidence.fetch("network_errors").any? { |entry| entry["failure"] == "non_local_request_blocked" }
      assert evidence.fetch("viewport_evidence").any? { |entry| entry.dig("action_recovery", "external_requests_blocked").to_a.any? }
      assert_match(/exit code 1|non-local browser request/i, evidence.fetch("blocking_issues").join("\n"))
    end
  end

  def test_engine_run_rejects_stale_approval_hash_after_opendesign_contract_changes
    in_tmp do |dir|
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      bin_dir = write_fake_openmanus_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }
      dry_payload, dry_code = json_cmd("engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--dry-run")
      before_entries = project_entries

      assert_equal 0, dry_code
      File.open(".ai-web/design-candidates/selected.md", "a") { |file| file.write("\nContract changed after approval.\n") }
      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approval-hash", dry_payload.dig("engine_run", "approval_hash"), "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_match(/approval hash does not match/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      assert_equal before_entries, project_entries, "stale approval must block before run artifacts"
    end
  end

  def test_engine_run_design_verdict_blocks_low_visual_quality
    in_tmp do |dir|
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      source = "src/components/Hero.astro"
      File.write(source, "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [{ "data_aiweb_id" => "component.hero.copy", "source_path" => source, "editable" => true }]
      ))
      File.write("package.json", JSON.pretty_generate("scripts" => { "dev" => "fake dev" }))
      bin_dir = write_fake_engine_openmanus_preview_tooling(dir)
      write_fake_openmanus_tooling(dir, patch_text: "<section data-aiweb-id=\"component.hero.copy\" class=\"bad-spacing bad-typography\">Weak</section>\n", overwrite_workspace: true)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "failed", payload.dig("engine_run", "status")
      assert_equal "failed", payload.dig("engine_run", "design_verdict", "status")
      assert_operator payload.dig("engine_run", "design_verdict", "scores", "spacing"), :<, 0.8
      assert_match(/spacing|typography/i, payload.dig("engine_run", "design_verdict", "blocking_issues").join("\n"))
      refute_match(/bad-spacing/, File.read(source))
      event_types = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line).fetch("type") }
      assert_includes event_types, "design.review.failed"
    end
  end

  def test_engine_run_design_repair_cycle_fixes_low_visual_quality
    in_tmp do |dir|
      prepare_profile_d_design_flow
      FileUtils.mkdir_p("src/components")
      source = "src/components/Hero.astro"
      File.write(source, "<section data-aiweb-id=\"component.hero.copy\">Before</section>\n")
      File.write(".ai-web/component-map.json", JSON.pretty_generate(
        "schema_version" => 1,
        "components" => [{ "data_aiweb_id" => "component.hero.copy", "source_path" => source, "editable" => true }]
      ))
      File.write("package.json", JSON.pretty_generate("scripts" => { "dev" => "fake dev" }))
      bin_dir = write_fake_engine_openmanus_preview_tooling(dir)
      write_fake_openmanus_tooling(
        dir,
        repair_mode: true,
        overwrite_workspace: true,
        repair_first_text: "<section data-aiweb-id=\"component.hero.copy\" class=\"bad-spacing bad-typography\">Weak</section>\n",
        repair_fixed_text: "<section data-aiweb-id=\"component.hero.copy\" class=\"polished-layout\">Fixed</section>\n"
      )
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "2", "--approved")

      assert_equal 0, code
      assert_equal "passed", payload.dig("engine_run", "status")
      assert_equal "passed", payload.dig("engine_run", "design_verdict", "status")
      assert_match(/polished-layout/, File.read(source))
      event_types = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line).fetch("type") }
      assert_includes event_types, "design.repair.planned"
      assert_includes event_types, "design.repair.started"
      assert_includes event_types, "design.repair.finished"
    end
  end

  def test_engine_run_blocks_unsandboxed_codex_agentic_local_without_launch_or_writes
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      File.write(".env", "SECRET=engine-run-approved-do-not-leak\n")
      marker = File.join(dir, "codex-was-run")
      bin_dir = write_fake_codex_tooling(dir, marker_path: marker, patch_path: File.join(dir, "src/components/Hero.astro"))
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }
      dry_payload, dry_code = json_cmd("engine-run", "--goal", "patch hero", "--dry-run")
      before_entries = project_entries

      assert_equal 0, dry_code
      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--approval-hash", dry_payload.dig("engine_run", "approval_hash"), "--approved")

      assert_equal 5, code
      assert_equal "engine run blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_equal "agentic_local", payload.dig("engine_run", "mode")
      assert_equal "codex", payload.dig("engine_run", "agent")
      assert_match(/unsandboxed codex|safe_patch|sandbox/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      assert_equal before_entries, project_entries, "blocked unsandboxed Codex must not create run artifacts"
      refute File.exist?(marker), "blocked unsandboxed Codex must not launch"
      assert_equal "<h1>Before</h1>\n", File.read("src/components/Hero.astro")
      assert_equal "SECRET=engine-run-approved-do-not-leak\n", File.read(".env")
      refute_includes JSON.generate(payload), "engine-run-approved-do-not-leak"
    end
  end

  def test_engine_run_blocks_secret_file_created_inside_staged_workspace
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      File.write(".env", "SECRET=engine-run-host-env-do-not-touch\n")
      bin_dir = write_fake_openmanus_tooling(dir, secret_path: ".env")
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "try unsafe env", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      assert_equal 5, code
      assert_equal "quarantined", payload.dig("engine_run", "status")
      assert_match(/unsafe changed path|\.env/i, payload.dig("engine_run", "copy_back_policy", "blocking_issues").join("\n"))
      assert_match(/\.env|secret|quarantine/i, payload.dig("engine_run", "quarantine", "blocking_issues").join("\n"))
      assert_equal "SECRET=engine-run-host-env-do-not-touch\n", File.read(".env")
      refute_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
      refute_includes JSON.generate(payload), "engine-run-host-env-do-not-touch"
    end
  end

  def test_engine_run_excludes_provider_credentials_and_browser_profiles_from_staged_workspace
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      {
        ".aws/credentials" => "aws_access_key_id = AKIA1111111111111111\n",
        ".npmrc" => "//registry.npmjs.org/:_authToken=npm_secret\n",
        ".vercel/auth.json" => "{\"token\":\"provider-secret\"}\n",
        ".netlify/config.json" => "{\"token\":\"provider-secret\"}\n",
        ".config/google-chrome/Default/Cookies" => "cookie-secret\n"
      }.each do |path, body|
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, body)
      end
      bin_dir = write_fake_openmanus_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      assert_equal 0, code
      manifest = JSON.parse(File.read(File.join(payload.dig("engine_run", "run_dir"), "artifacts", "staged-manifest.json")))
      staged = manifest.fetch("files").keys
      excluded = manifest.fetch("excluded")
      %w[
        .aws/credentials
        .npmrc
        .vercel
        .netlify
        .config/google-chrome
      ].each do |path|
        assert excluded.any? { |entry| entry == path || entry.start_with?("#{path}/") || path.start_with?("#{entry}/") }, "#{path} should be excluded from staged workspace"
      end
      refute_includes staged, ".aws/credentials"
      refute_includes staged, ".npmrc"
      refute staged.any? { |path| path.start_with?(".vercel/") }
      refute staged.any? { |path| path.start_with?(".netlify/") }
      refute staged.any? { |path| path.start_with?(".config/google-chrome/") }
      refute_includes JSON.generate(payload), "provider-secret"
      refute_includes JSON.generate(payload), "cookie-secret"
    end
  end

  def test_engine_run_openmanus_uses_aiweb_managed_sandbox_and_copies_back_safe_changes
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      File.write(".env", "SECRET=engine-run-openmanus-do-not-leak\n")
      bin_dir = write_fake_openmanus_tooling(dir)
      env = {
        "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
        "FAKE_OPENMANUS_SECRET" => "must-not-leak"
      }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      assert_equal 0, code
      assert_equal "passed", payload.dig("engine_run", "status")
      assert_equal "openmanus", payload.dig("engine_run", "agent")
      assert_equal "docker", payload.dig("engine_run", "sandbox")
      assert_includes payload.dig("engine_run", "copy_back_policy", "safe_changes"), "src/components/Hero.astro"
      assert_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
      assert_equal "SECRET=engine-run-openmanus-do-not-leak\n", File.read(".env")
      event_types = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line).fetch("type") }
      event_seq = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line).fetch("seq") }
      assert_equal (1..event_seq.length).to_a, event_seq
      assert_includes event_types, "sandbox.preflight.started"
      assert_includes event_types, "sandbox.preflight.finished"
      negative_checks = payload.dig("engine_run", "sandbox_preflight", "negative_checks")
      assert_equal "not_mounted", negative_checks.fetch("project_root")
      assert_equal "not_mounted", negative_checks.fetch(".env")
      assert_equal "not_mounted", negative_checks.fetch("host_home")
      assert_equal ["/workspace"], payload.dig("engine_run", "sandbox_preflight", "inside_mounts")
      assert_equal "openmanus@sha256:#{"b" * 64}", payload.dig("engine_run", "sandbox_preflight", "container_image_digest")
      assert_match(/\Afake-runtime-container-/, payload.dig("engine_run", "sandbox_preflight", "container_id"))
      assert_match(/\Afake-container-/, payload.dig("engine_run", "sandbox_preflight", "container_hostname"))
      assert_equal payload.dig("engine_run", "sandbox_preflight", "container_id"), payload.dig("engine_run", "sandbox_preflight", "inside_container_probe", "runtime_container_id")
      assert_equal "passed", payload.dig("engine_run", "sandbox_preflight", "runtime_container_inspect", "status")
      assert_equal payload.dig("engine_run", "sandbox_preflight", "container_id"), payload.dig("engine_run", "sandbox_preflight", "runtime_container_inspect", "container_id")
      assert_equal "none", payload.dig("engine_run", "sandbox_preflight", "runtime_container_inspect", "host_config", "network_mode")
      assert_equal true, payload.dig("engine_run", "sandbox_preflight", "runtime_container_inspect", "host_config", "readonly_rootfs")
      assert_equal ["ALL"], payload.dig("engine_run", "sandbox_preflight", "runtime_container_inspect", "host_config", "cap_drop")
      assert_includes payload.dig("engine_run", "sandbox_preflight", "runtime_container_inspect", "host_config", "security_opt"), "no-new-privileges"
      assert_equal 1000, payload.dig("engine_run", "sandbox_preflight", "effective_user", "uid")
      assert_equal "aiweb", payload.dig("engine_run", "sandbox_preflight", "effective_user", "name")
      assert_equal "passed", payload.dig("engine_run", "sandbox_preflight", "inside_container_probe", "status")
      assert_equal "1000:1000", payload.dig("engine_run", "sandbox_preflight", "sandbox_user")
      assert_equal true, payload.dig("engine_run", "sandbox_preflight", "inside_container_probe", "workspace_writable")
      assert_equal true, payload.dig("engine_run", "sandbox_preflight", "inside_container_probe", "root_filesystem_write_blocked")
      assert_equal "passed", payload.dig("engine_run", "sandbox_preflight", "security_attestation", "status")
      assert_equal true, payload.dig("engine_run", "sandbox_preflight", "security_attestation", "no_new_privs_enabled")
      assert_equal true, payload.dig("engine_run", "sandbox_preflight", "security_attestation", "seccomp_filtering")
      assert_equal true, payload.dig("engine_run", "sandbox_preflight", "security_attestation", "cap_eff_zero")
      assert_equal ["0::/fake-aiweb"], payload.dig("engine_run", "sandbox_preflight", "inside_container_probe", "cgroup", "lines")
      assert_equal "passed", payload.dig("engine_run", "sandbox_preflight", "egress_denial_probe", "status")
      assert_equal "fake_inside_container_no_network_probe", payload.dig("engine_run", "sandbox_preflight", "egress_denial_probe", "method")
      assert_equal "observed_rootless", payload.dig("engine_run", "sandbox_preflight", "rootless_mode")
      assert_equal "passed", payload.dig("engine_run", "sandbox_preflight", "runtime_info", "status")
      assert_includes payload.dig("engine_run", "sandbox_preflight", "runtime_info", "security_options"), "name=rootless"
      assert_includes payload.dig("engine_run", "sandbox_preflight", "preflight_warnings"), "container image reference is not digest-pinned"
      graph_nodes = payload.dig("engine_run", "run_graph", "nodes").to_h { |node| [node.fetch("node_id"), node] }
      assert_equal "passed", graph_nodes.fetch("preflight").fetch("state")
      assert_equal "passed", graph_nodes.fetch("worker_act").fetch("state")
      assert_equal "passed", graph_nodes.fetch("copy_back").fetch("state")
      assert_equal "passed", graph_nodes.fetch("finalize").fetch("state")
      assert_equal "finalize", payload.dig("engine_run", "run_graph", "cursor", "node_id")
      assert_match(%r{\A\.ai-web/runs/.+/artifacts/authz-enforcement\.json\z}, payload.dig("engine_run", "authz_enforcement_path"))
      authz_enforcement = JSON.parse(File.read(payload.dig("engine_run", "authz_enforcement_path")))
      assert_equal true, authz_enforcement.fetch("run_id_is_not_authority")
      assert_equal true, authz_enforcement.dig("local_backend_enforcement", "api_token_required_for_api_routes")
      assert_equal true, authz_enforcement.dig("local_backend_enforcement", "approval_token_required_for_approved_execution")
      assert_equal "blocked_until_tenant_project_user_claims_are_enforced", authz_enforcement.fetch("remote_exposure_status")
      assert_equal %w[tenant_id project_id user_id], authz_enforcement.fetch("saas_required_claims")
      assert_includes event_types, "authz.enforcement.recorded"
      assert_match(%r{\A\.ai-web/runs/.+/artifacts/worker-adapter-contract\.json\z}, payload.dig("engine_run", "worker_adapter_contract_path"))
      adapter_contract = JSON.parse(File.read(payload.dig("engine_run", "worker_adapter_contract_path")))
      assert_equal "openmanus", adapter_contract.fetch("adapter")
      assert_equal %w[prepare act observe cancel resume finalize], adapter_contract.fetch("api")
      assert_equal "_aiweb/worker-adapter-contract.json", adapter_contract.fetch("adapter_input_path")
      assert_match(%r{\A\.ai-web/runs/.+/artifacts/graph-execution-plan\.json\z}, adapter_contract.fetch("graph_execution_plan_ref"))
      assert_match(%r{\A\.ai-web/runs/.+/artifacts/graph-scheduler-state\.json\z}, adapter_contract.fetch("graph_scheduler_state_ref"))
      assert_match(%r{\A\.ai-web/runs/.+/artifacts/worker-adapter-registry\.json\z}, payload.dig("engine_run", "worker_adapter_registry_path"))
      adapter_registry = JSON.parse(File.read(payload.dig("engine_run", "worker_adapter_registry_path")))
      assert_equal "worker-adapter-v1", adapter_registry.fetch("protocol_version")
      assert_equal "openmanus", adapter_registry.fetch("selected_adapter")
      assert_equal "implemented_container_worker", adapter_registry.fetch("selected_adapter_status")
      assert_equal true, adapter_registry.fetch("selected_adapter_executable")
      assert_equal [], adapter_registry.fetch("selected_adapter_blocking_issues")
      adapter_entries = adapter_registry.fetch("adapters").to_h { |adapter| [adapter.fetch("id"), adapter] }
      assert_includes adapter_registry.fetch("adapters").map { |adapter| adapter.fetch("id") }, "openhands"
      assert_equal true, adapter_entries.fetch("openmanus").fetch("executable")
      assert_equal false, adapter_entries.fetch("openmanus").fetch("execution_blocked")
      assert_equal "aiweb.engine_run.tool_broker", adapter_entries.fetch("openmanus").dig("broker_contract", "broker_id")
      assert_equal "enforced", adapter_entries.fetch("openmanus").dig("broker_contract", "enforcement_status")
      assert_includes adapter_entries.fetch("openmanus").dig("broker_contract", "evidence_artifacts"), "_aiweb/tool-broker-events.jsonl"
      assert_equal "experimental_container_worker", adapter_entries.fetch("langgraph").fetch("status")
      assert_equal true, adapter_entries.fetch("langgraph").fetch("executable")
      assert_equal false, adapter_entries.fetch("langgraph").fetch("execution_blocked")
      assert_equal "engine_run_langgraph_command", adapter_entries.fetch("langgraph").fetch("command_driver")
      assert_equal "engine-run-langgraph-result.schema.json", adapter_entries.fetch("langgraph").fetch("result_schema")
      assert_equal "enforced", adapter_entries.fetch("langgraph").dig("broker_contract", "enforcement_status")
      assert_equal "experimental_ready", adapter_entries.fetch("langgraph").dig("driver_readiness", "state")
      assert_equal "experimental_container_worker", adapter_entries.fetch("openai_agents_sdk").fetch("status")
      assert_equal true, adapter_entries.fetch("openai_agents_sdk").fetch("executable")
      assert_equal false, adapter_entries.fetch("openai_agents_sdk").fetch("execution_blocked")
      assert_equal "engine_run_openai_agents_sdk_command", adapter_entries.fetch("openai_agents_sdk").fetch("command_driver")
      assert_equal "engine-run-openai-agents-sdk-result.schema.json", adapter_entries.fetch("openai_agents_sdk").fetch("result_schema")
      assert_equal "enforced", adapter_entries.fetch("openai_agents_sdk").dig("broker_contract", "enforcement_status")
      assert_equal "experimental_ready", adapter_entries.fetch("openai_agents_sdk").dig("driver_readiness", "state")
      assert_equal false, adapter_registry.dig("runtime_broker_enforcement", "universal_broker_claim")
      assert_equal 0, adapter_registry.dig("runtime_broker_enforcement", "executable_without_broker_count")
      assert adapter_registry.dig("runtime_broker_enforcement", "known_mcp_broker_drivers").any? { |driver| driver["server"] == "lazyweb" && driver["status"] == "implemented_for_design_research" }
      assert adapter_registry.dig("runtime_broker_enforcement", "known_mcp_broker_drivers").any? { |driver| driver["server"] == "lazyweb" && driver["broker_id"] == "aiweb.implementation_mcp_broker" }
      assert adapter_registry.dig("runtime_broker_enforcement", "known_mcp_broker_drivers").any? { |driver| driver["server"] == "project_files" && driver["scope"] == "implementation_worker.mcp.project_files" && driver["status"] == "implemented_for_approved_project_file_metadata_list_excerpt_search" }
      assert_includes adapter_registry.dig("runtime_broker_enforcement", "deny_by_default_surfaces"), "future_adapters"
      assert_match(%r{\A\.ai-web/runs/.+/artifacts/graph-execution-plan\.json\z}, payload.dig("engine_run", "graph_execution_plan_path"))
      graph_execution_plan = JSON.parse(File.read(payload.dig("engine_run", "graph_execution_plan_path")))
      assert_equal "sequential_durable_node_scheduler", graph_execution_plan.fetch("scheduler_type")
      assert_equal "aiweb.graph_scheduler.runtime.v1", graph_execution_plan.fetch("execution_driver")
      assert_equal "Aiweb::GraphSchedulerRuntime", graph_execution_plan.fetch("scheduler_runtime")
      assert_equal "graph_scheduler_runtime", graph_execution_plan.fetch("state_owner")
      assert_equal "run_graph.executor_contract", graph_execution_plan.fetch("executor_source")
      assert_equal payload.dig("engine_run", "run_graph", "executor_contract", "node_order"), graph_execution_plan.fetch("node_order")
      assert_equal "preflight", graph_execution_plan.fetch("start_node_id")
      assert_equal true, graph_execution_plan.dig("validation", "node_order_matches_graph")
      assert_equal true, graph_execution_plan.dig("validation", "all_side_effect_nodes_gated")
      assert_equal true, graph_execution_plan.dig("validation", "runtime_owns_retry_replay_cursor_checkpoint")
      assert graph_execution_plan.fetch("node_invocations").any? { |node| node["node_id"] == "worker_act" && node["handler"] == "engine_run_execute_agentic_loop" && node["tool_broker_required"] == true }
      assert_includes File.read(File.join(payload.dig("engine_run", "workspace_path"), "_aiweb", "graph-execution-plan.json")), "sequential_durable_node_scheduler"
      assert_match(%r{\A\.ai-web/runs/.+/artifacts/graph-scheduler-state\.json\z}, payload.dig("engine_run", "graph_scheduler_state_path"))
      graph_scheduler_state = JSON.parse(File.read(payload.dig("engine_run", "graph_scheduler_state_path")))
      assert_equal "sequential_durable_node_scheduler_state", graph_scheduler_state.fetch("scheduler_type")
      assert_equal "aiweb.graph_scheduler.runtime.v1", graph_scheduler_state.fetch("execution_driver")
      assert_equal "Aiweb::GraphSchedulerRuntime", graph_scheduler_state.fetch("scheduler_runtime")
      assert_equal "graph_scheduler_runtime", graph_scheduler_state.fetch("state_owner")
      assert_equal true, graph_scheduler_state.fetch("retry_replay_cursor_checkpoint_owned")
      assert_equal "delegates_node_body_to_registered_engine_handlers", graph_scheduler_state.fetch("node_execution_mode")
      assert_equal payload.dig("engine_run", "graph_execution_plan_path"), graph_scheduler_state.fetch("graph_execution_plan_ref")
      assert_equal "passed", graph_scheduler_state.fetch("status")
      assert_equal "finalize", graph_scheduler_state.dig("cursor", "node_id")
      assert graph_scheduler_state.fetch("transitions").any? { |transition| transition["node_id"] == "worker_act" && transition["state"] == "passed" }
      assert_includes File.read(File.join(payload.dig("engine_run", "workspace_path"), "_aiweb", "graph-scheduler-state.json")), "aiweb.graph_scheduler.runtime.v1"
      assert_match(%r{artifacts/graph-execution-plan\.json\z}, payload.dig("engine_run", "checkpoint", "artifact_hashes", "graph_execution_plan", "path"))
      assert_match(%r{artifacts/graph-scheduler-state\.json\z}, payload.dig("engine_run", "checkpoint", "artifact_hashes", "graph_scheduler_state", "path"))
      assert_includes File.read(File.join(payload.dig("engine_run", "workspace_path"), "_aiweb", "worker-adapter-registry.json")), "openai_agents_sdk"
      assert_includes File.read(File.join(payload.dig("engine_run", "workspace_path"), "_aiweb", "worker-adapter-contract.json")), "changed_file_manifest"
      project_index = JSON.parse(File.read(payload.dig("engine_run", "project_index_path")))
      assert_equal "ready", project_index.fetch("status")
      assert_equal false, project_index.dig("env_surface", "content_read")
      assert_includes project_index.dig("components", "items").map { |item| item.fetch("path") }, "src/components/Hero.astro"
      assert_includes File.read(File.join(payload.dig("engine_run", "workspace_path"), "_aiweb", "project-index.json")), "src/components/Hero.astro"
      assert_match(%r{\A\.ai-web/runs/.+/artifacts/run-memory\.json\z}, payload.dig("engine_run", "run_memory_path"))
      run_memory = JSON.parse(File.read(payload.dig("engine_run", "run_memory_path")))
      assert_equal "ready", run_memory.fetch("status")
      assert_equal "bounded_lexical_cards", run_memory.fetch("retrieval_strategy")
      assert_equal "not_configured", run_memory.fetch("rag_status")
      assert_operator run_memory.fetch("memory_records").length, :>, 0
      assert_equal run_memory.fetch("memory_records").length, run_memory.fetch("memory_record_count")
      assert_equal "_aiweb/run-memory.json", run_memory.dig("worker_handoff", "workspace_path")
      workspace_run_memory = File.read(File.join(payload.dig("engine_run", "workspace_path"), "_aiweb", "run-memory.json"))
      assert_includes workspace_run_memory, "bounded_lexical_cards"
      assert_includes workspace_run_memory, "src/components/Hero.astro"
      assert_includes event_types, "project.indexed"
      assert_includes event_types, "memory.index.recorded"
      assert_includes event_types, "worker.adapter.registry.recorded"
      assert_includes event_types, "graph.scheduler.planned"
      assert_includes event_types, "graph.scheduler.started"
      assert_includes event_types, "graph.node.finished"
      assert_includes event_types, "graph.scheduler.finished"
      job = JSON.parse(File.read(File.join(payload.dig("engine_run", "run_dir"), "job.json")))
      assert_equal "passed", job.fetch("status")
      checkpoint = JSON.parse(File.read(payload.dig("engine_run", "checkpoint_path")))
      assert checkpoint.dig("artifact_hashes", "staged_manifest", "sha256").match?(/\Asha256:[a-f0-9]{64}\z/)
      assert checkpoint.dig("artifact_hashes", "sandbox_preflight", "sha256").match?(/\Asha256:[a-f0-9]{64}\z/)
      assert_equal payload.dig("engine_run", "authz_enforcement_path"), checkpoint.dig("artifact_hashes", "authz_enforcement", "path")
      assert_equal payload.dig("engine_run", "worker_adapter_registry_path"), checkpoint.dig("artifact_hashes", "worker_adapter_registry", "path")
      assert_equal payload.dig("engine_run", "graph_scheduler_state_path"), checkpoint.dig("artifact_hashes", "graph_scheduler_state", "path")
      assert_equal payload.dig("engine_run", "run_memory_path"), checkpoint.dig("artifact_hashes", "run_memory", "path")
      assert_equal payload.dig("engine_run", "staged_manifest_path"), checkpoint.dig("artifact_hashes", "staged_manifest", "path")
      refute_includes JSON.generate(payload), "engine-run-openmanus-do-not-leak"
    end
  end

  def test_engine_run_openmanus_podman_records_runtime_inspect_cross_check
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "podman", "--approved")

      assert_equal 0, code
      assert_equal "passed", payload.dig("engine_run", "status")
      assert_equal "podman", payload.dig("engine_run", "sandbox")
      assert_match(/\Afake-runtime-container-/, payload.dig("engine_run", "sandbox_preflight", "container_id"))
      assert_equal "passed", payload.dig("engine_run", "sandbox_preflight", "runtime_container_inspect", "status")
      assert_equal "none", payload.dig("engine_run", "sandbox_preflight", "runtime_container_inspect", "host_config", "network_mode")
      assert_equal true, payload.dig("engine_run", "sandbox_preflight", "runtime_container_inspect", "host_config", "readonly_rootfs")
      assert_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_openmanus_blocks_when_runtime_inspect_contradicts_sandbox_policy
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      FileUtils.mkdir_p(".ai-web")
      File.write(".ai-web/unsafe-runtime-inspect", "1\n")
      bin_dir = write_fake_openmanus_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_equal "failed", payload.dig("engine_run", "sandbox_preflight", "status")
      assert_equal "failed", payload.dig("engine_run", "sandbox_preflight", "runtime_container_inspect", "status")
      assert_match(/runtime container inspect cross-check/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      assert_match(/network none/i, payload.dig("engine_run", "sandbox_preflight", "runtime_container_inspect", "blocking_issues").join("\n"))
      refute_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_openmanus_blocks_when_runtime_inspect_workspace_source_is_not_staged_workspace
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      FileUtils.mkdir_p(".ai-web")
      File.write(".ai-web/unsafe-runtime-inspect-source", "1\n")
      bin_dir = write_fake_openmanus_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_equal "failed", payload.dig("engine_run", "sandbox_preflight", "runtime_container_inspect", "status")
      assert_match(/staged workspace|workspace source/i, payload.dig("engine_run", "sandbox_preflight", "runtime_container_inspect", "blocking_issues").join("\n"))
      refute_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_openmanus_blocks_with_schema_valid_preflight_when_probe_command_fails
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      FileUtils.mkdir_p(".ai-web")
      File.write(".ai-web/fail-sandbox-preflight-command", "1\n")
      bin_dir = write_fake_openmanus_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      preflight = payload.dig("engine_run", "sandbox_preflight")
      assert_equal "failed", preflight.fetch("status")
      assert_equal "failed", preflight.dig("inside_container_probe", "status")
      assert_equal "self_attestation_probe_command_failed", preflight.dig("inside_container_probe", "reason")
      assert_equal "failed", preflight.dig("security_attestation", "status")
      assert_equal "failed", preflight.dig("egress_denial_probe", "status")
      assert_includes %w[passed failed], preflight.dig("runtime_container_inspect", "status")
      assert_match(/inside-container self-attestation|egress denial|security attestation/i, preflight.fetch("blocking_issues").join("\n"))
      refute_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_openmanus_blocks_with_schema_valid_preflight_when_probe_json_is_malformed
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      FileUtils.mkdir_p(".ai-web")
      File.write(".ai-web/malformed-sandbox-preflight-probe", "1\n")
      bin_dir = write_fake_openmanus_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      preflight = payload.dig("engine_run", "sandbox_preflight")
      assert_equal "failed", preflight.fetch("status")
      assert_equal "failed", preflight.dig("inside_container_probe", "status")
      assert_equal "self_attestation_probe_output_parse_failed", preflight.dig("inside_container_probe", "reason")
      assert_equal "failed", preflight.dig("security_attestation", "status")
      assert_equal "failed", preflight.dig("egress_denial_probe", "status")
      assert_equal "passed", preflight.dig("runtime_container_inspect", "status")
      assert_match(/inside-container self-attestation|egress denial|security attestation/i, preflight.fetch("blocking_issues").join("\n"))
      refute_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_openmanus_blocks_when_local_image_is_missing_without_writes
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir)
      env = {
          "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
          "AIWEB_OPENMANUS_IMAGE" => "missing-openmanus:latest"
        }
      before_entries = project_entries

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_match(/openmanus:latest|AIWEB_OPENMANUS_IMAGE|image/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      assert_equal before_entries, project_entries, "missing OpenManus image must block before run artifacts"
      assert_equal "<h1>Before</h1>\n", File.read("src/components/Hero.astro")
    end
  end

  def test_engine_run_openmanus_blocks_when_image_inspect_output_is_empty
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      FileUtils.mkdir_p(".ai-web")
      File.write(".ai-web/empty-image-inspect", "1\n")
      bin_dir = write_fake_openmanus_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }
      before_entries = project_entries

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_match(/validated local inspect evidence|image_inspect_empty_output|image/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      assert_equal before_entries, project_entries, "empty image inspect must block before run artifacts"
      refute_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_openmanus_blocks_when_image_inspect_output_is_malformed
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      FileUtils.mkdir_p(".ai-web")
      File.write(".ai-web/malformed-image-inspect", "1\n")
      bin_dir = write_fake_openmanus_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }
      before_entries = project_entries

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_match(/validated local inspect evidence|image_inspect_parse_failed|image/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      assert_equal before_entries, project_entries, "malformed image inspect must block before run artifacts"
      refute_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_openmanus_strict_sandbox_requires_digest_pinned_image
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      source = "src/components/Hero.astro"
      File.write(source, "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir)
      env = {
        "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
        "AIWEB_OPENMANUS_REQUIRE_DIGEST" => "1"
      }
      before_entries = project_entries

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_match(/digest-pinned|AIWEB_OPENMANUS_IMAGE/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      assert_equal before_entries, project_entries, "strict unpinned image policy must block before run artifacts"
      assert_equal "<h1>Before</h1>\n", File.read(source)
    end
  end

  def test_engine_run_openmanus_production_profile_requires_digest_pinned_image
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      source = "src/components/Hero.astro"
      File.write(source, "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir)
      env = {
        "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
        "AIWEB_ENV" => "production"
      }
      before_entries = project_entries

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_match(/digest-pinned|AIWEB_ENV/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      assert_equal before_entries, project_entries, "production profile digest policy must block before run artifacts"
      assert_equal "<h1>Before</h1>\n", File.read(source)
    end
  end

  def test_engine_run_openmanus_production_profile_allows_digest_pinned_image_and_records_policy_source
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir)
      pinned = "openmanus@sha256:#{"c" * 64}"
      env = {
        "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
        "AIWEB_ENV" => "production",
        "AIWEB_OPENMANUS_IMAGE" => pinned
      }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      assert_equal 0, code
      assert_equal "passed", payload.dig("engine_run", "status")
      assert_equal true, payload.dig("engine_run", "sandbox_preflight", "container_image_digest_required")
      assert_equal true, payload.dig("engine_run", "sandbox_preflight", "container_image_reference_pinned")
      assert_includes payload.dig("engine_run", "sandbox_preflight", "container_image_digest_policy_source"), "AIWEB_ENV"
      assert_equal "sha256:#{"c" * 64}", payload.dig("engine_run", "sandbox_preflight", "container_image_digest")
      assert_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_openmanus_required_runtime_matrix_records_docker_and_podman_evidence
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir)
      env = {
        "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
        "AIWEB_ENGINE_RUN_RUNTIME_MATRIX" => "docker,podman"
      }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      assert_equal 0, code
      matrix = payload.dig("engine_run", "sandbox_preflight", "runtime_matrix")
      assert_equal true, matrix.fetch("required")
      assert_equal "passed", matrix.fetch("status")
      assert_equal %w[docker podman], matrix.fetch("requested_runtimes")
      assert_includes matrix.fetch("policy_source"), "AIWEB_ENGINE_RUN_RUNTIME_MATRIX"
      entries = matrix.fetch("entries").to_h { |entry| [entry.fetch("runtime"), entry] }
      %w[docker podman].each do |runtime|
        assert_equal "passed", entries.fetch(runtime).fetch("status")
        assert_equal "passed", entries.fetch(runtime).dig("runtime_container_inspect", "status")
        assert_equal "passed", entries.fetch(runtime).dig("security_attestation", "status")
        assert_equal "passed", entries.fetch(runtime).dig("egress_denial_probe", "status")
      end
      assert_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_openmanus_required_runtime_matrix_blocks_when_podman_missing
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir, include_podman: false)
      env = {
        "PATH" => bin_dir,
        "AIWEB_ENGINE_RUN_RUNTIME_MATRIX" => "docker,podman"
      }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      matrix = payload.dig("engine_run", "sandbox_preflight", "runtime_matrix")
      assert_equal true, matrix.fetch("required")
      assert_equal "failed", matrix.fetch("status")
      assert_match(/podman runtime matrix.*executable is missing|runtime matrix verification/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      refute_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_openmanus_required_runtime_matrix_blocks_invalid_runtime_policy
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir)
      env = {
        "PATH" => bin_dir,
        "AIWEB_ENGINE_RUN_RUNTIME_MATRIX" => "docker,kubernetes"
      }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      matrix = payload.dig("engine_run", "sandbox_preflight", "runtime_matrix")
      assert_equal true, matrix.fetch("required")
      assert_equal "failed", matrix.fetch("status")
      assert_equal ["docker"], matrix.fetch("requested_runtimes")
      assert_equal ["kubernetes"], matrix.fetch("invalid_requested_runtimes")
      assert_match(/unsupported runtime matrix entry/i, matrix.fetch("blocking_issues").join("\n"))
      refute_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_waits_for_approval_when_agent_requests_package_install
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir, stdout_text: "need npm install lucide-react")
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero with icons", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      assert_equal 5, code
      assert_equal "waiting_approval", payload.dig("engine_run", "status")
      assert_match(/package install|network|deploy|provider CLI|git push/i, payload.dig("engine_run", "copy_back_policy", "approval_issues").join("\n"))
      approval_request = payload.dig("engine_run", "copy_back_policy", "approval_requests").find { |request| request.fetch("type") == "package_install" }
      assert_equal "supply_chain_and_network", approval_request.fetch("risk")
      assert_equal "approved_package_manager_install", approval_request.fetch("capability_unlocked")
      %w[package_manager exact_command registry_allowlist lifecycle_script_policy audit_sbom_output vulnerability_copy_back_gate].each do |field|
        assert_includes approval_request.fetch("requires"), field
      end
      event_types = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line).fetch("type") }
      assert_includes event_types, "tool.action.requested"
      assert_includes event_types, "tool.action.blocked"
      assert_includes event_types, "approval.requested"
      assert_includes event_types, "eval.benchmark.recorded"
      assert_includes event_types, "supply_chain.gate.recorded"
      gate = JSON.parse(File.read(payload.dig("engine_run", "supply_chain_gate_path")))
      assert_equal "waiting_approval", gate.fetch("status")
      assert_equal true, gate.fetch("required")
      assert_equal "npm", gate.fetch("package_manager")
      assert_equal "pending_approval", gate.dig("clean_cache_install", "status")
      assert_equal "_aiweb/package-cache", gate.dig("clean_cache_install", "isolated_cache_dir")
      assert_equal false, gate.dig("clean_cache_install", "default_install_lifecycle_execution")
      assert_equal false, gate.dig("clean_cache_install", "default_command_uses_ignore_scripts")
      assert_equal "pending_approval", gate.dig("dependency_diff", "status")
      assert_includes gate.dig("dependency_diff", "required_outputs"), "lockfile_diff"
      assert_equal "not_executed_pending_approval", gate.dig("sbom", "status")
      assert_equal "not_executed_pending_approval", gate.dig("audit", "status")
      assert_includes gate.dig("audit", "commands"), "npm audit --json"
      assert_equal "not_executed_pending_approval", gate.dig("execution_evidence", "status")
      lifecycle_gate = gate.fetch("lifecycle_sandbox_gate")
      assert_equal "aiweb.engine_run.lifecycle_sandbox_gate.v1", lifecycle_gate.fetch("policy")
      assert_equal "blocked_until_sandbox_and_egress_firewall", lifecycle_gate.fetch("status")
      assert_equal false, lifecycle_gate.fetch("lifecycle_scripts_present")
      assert_equal false, lifecycle_gate.fetch("default_install_lifecycle_execution")
      assert_equal false, lifecycle_gate.dig("egress_firewall", "external_network_allowed")
      assert_includes lifecycle_gate.dig("required_sandbox_evidence", "required_artifacts"), "egress-firewall-log.json"
      sbom = JSON.parse(File.read(gate.dig("sbom", "artifact_path")))
      audit = JSON.parse(File.read(gate.dig("audit", "artifact_path")))
      assert_equal "not_executed_pending_approval", sbom.fetch("status")
      assert_equal "sbom", sbom.fetch("artifact_kind")
      assert_equal "not_executed_pending_approval", audit.fetch("status")
      assert_equal "package_audit", audit.fetch("artifact_kind")
      assert_equal "pending_approval", gate.dig("vulnerability_copy_back_gate", "status")
      assert_includes gate.dig("vulnerability_copy_back_gate", "blocked_severities"), "critical"
      assert_equal "waiting_approval", payload.dig("engine_run", "copy_back_policy", "supply_chain_gate_status")
      benchmark = JSON.parse(File.read(payload.dig("engine_run", "eval_benchmark_path")))
      assert_equal "blocked", benchmark.fetch("status")
      assert_equal 1, benchmark.fetch("approval_count")
      assert_equal true, benchmark.fetch("unsafe_action_blocked")
      assert_equal "blocked", benchmark.dig("metrics", "approval_count", "status")
      assert_equal "blocked", benchmark.dig("metrics", "unsafe_action_blocked", "status")
      approval_event = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line) }.find { |event| event.fetch("type") == "approval.requested" }
      assert_equal "package_install", approval_event.dig("data", "approval_requests", 0, "type")
      refute_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_waits_for_approval_when_staged_tool_broker_blocks_package_install
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir, broker_blocked_action: "package_install")
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero with package", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      assert_equal 5, code
      assert_equal "waiting_approval", payload.dig("engine_run", "status")
      workspace = payload.dig("engine_run", "workspace_path")
      assert File.file?(File.join(workspace, "_aiweb", "tool-broker-bin", "npm"))
      assert_includes payload.dig("engine_run", "sandbox_preflight", "generated_argv"), "PATH=/workspace/_aiweb/tool-broker-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      actions = payload.dig("engine_run", "copy_back_policy", "requested_actions")
      package_action = actions.find { |action| action.fetch("type") == "package_install" }
      assert package_action, "tool broker package action should be surfaced as an approval request"
      assert_equal "tool_broker", package_action.fetch("source")
      assert_equal "npm", package_action.fetch("tool_name")
      assert_match(/tool broker blocked/i, payload.dig("engine_run", "copy_back_policy", "approval_issues").join("\n"))
      event_lines = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line) }
      blocked_event = event_lines.find { |event| event.fetch("type") == "tool.blocked" && event.dig("data", "risk_class") == "package_install" }
      assert blocked_event, "staged tool-broker block must be emitted as a tool.blocked event"
      assert_includes event_lines.map { |event| event.fetch("type") }, "eval.benchmark.recorded"
      assert_includes event_lines.map { |event| event.fetch("type") }, "supply_chain.gate.recorded"
      gate = JSON.parse(File.read(payload.dig("engine_run", "supply_chain_gate_path")))
      assert_equal "waiting_approval", gate.fetch("status")
      assert_equal true, gate.fetch("required")
      assert_equal "pending_approval", gate.dig("clean_cache_install", "status")
      assert_equal "pending_approval", gate.dig("dependency_diff", "status")
      assert_equal "not_executed_pending_approval", gate.dig("sbom", "status")
      assert_equal "not_executed_pending_approval", gate.dig("audit", "status")
      assert_equal "not_executed_pending_approval", gate.dig("execution_evidence", "status")
      assert File.file?(gate.dig("sbom", "artifact_path"))
      assert File.file?(gate.dig("audit", "artifact_path"))
      benchmark = JSON.parse(File.read(payload.dig("engine_run", "eval_benchmark_path")))
      assert_equal "blocked", benchmark.fetch("status")
      assert_equal true, benchmark.fetch("unsafe_action_blocked")
      assert_operator benchmark.dig("metrics", "unsafe_action_blocked", "requested_actions").length, :>=, 1
      refute_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_tool_broker_generated_source_blocks_install_mutators
    project = Aiweb::Project.new(Dir.pwd)
    source = project.send(:engine_run_tool_broker_shim_source, "npm", { "risk" => "package_install", "mode" => "package_manager", "reason" => "Package installation requires explicit approval" })

    assert_includes source, "add|install|i|ci|update|upgrade|up"
    assert_includes source, "AIWEB_TOOL_BROKER_BLOCKED"
  end

  def test_engine_run_detects_install_mutators_in_worker_output
    project = Aiweb::Project.new(Dir.pwd)
    actions = project.send(:engine_run_requested_tool_actions, "worker attempted npm ci and yarn up")

    assert actions.any? { |action| action.fetch("type") == "package_install" }
  end

  def test_engine_run_tool_broker_shims_block_flag_prefixed_install_mutators_and_git_push
    skip "generated tool-broker shims are POSIX container scripts" if windows?

    in_tmp do
      workspace = File.join(Dir.pwd, "workspace")
      FileUtils.mkdir_p(workspace)
      project = Aiweb::Project.new(Dir.pwd)
      broker = project.send(:engine_run_prepare_workspace_tool_broker, workspace)
      real_bin = File.join(Dir.pwd, "real-bin")
      FileUtils.mkdir_p(real_bin)
      real_log = File.join(workspace, "real-ran.log")
      %w[npm git].each do |name|
        File.write(File.join(real_bin, name), "#!/bin/sh\nprintf '#{name} %s\\n' \"$*\" >> #{real_log.shellescape}\nexit 0\n")
        FileUtils.chmod("+x", File.join(real_bin, name))
      end
      env = {
        "AIWEB_TOOL_BROKER_EVENTS_PATH" => broker.fetch(:events_path),
        "AIWEB_TOOL_BROKER_REAL_PATH" => real_bin
      }

      _stdout, stderr, status = Open3.capture3(env, File.join(broker.fetch(:bin_dir), "npm"), "--prefix", ".", "install", chdir: workspace)
      assert_equal 126, status.exitstatus
      assert_match(/AIWEB_TOOL_BROKER_BLOCKED package_install/, stderr)

      _stdout, stderr, status = Open3.capture3(env, File.join(broker.fetch(:bin_dir), "npm"), "--loglevel", "silly", "install", chdir: workspace)
      assert_equal 126, status.exitstatus
      assert_match(/AIWEB_TOOL_BROKER_BLOCKED package_install/, stderr)

      _stdout, stderr, status = Open3.capture3(env, File.join(broker.fetch(:bin_dir), "npm"), "ci", chdir: workspace)
      assert_equal 126, status.exitstatus
      assert_match(/AIWEB_TOOL_BROKER_BLOCKED package_install/, stderr)

      _stdout, stderr, status = Open3.capture3(env, File.join(broker.fetch(:bin_dir), "npm"), "update", chdir: workspace)
      assert_equal 126, status.exitstatus
      assert_match(/AIWEB_TOOL_BROKER_BLOCKED package_install/, stderr)

      _stdout, stderr, status = Open3.capture3(env, File.join(broker.fetch(:bin_dir), "git"), "-C", ".", "push", chdir: workspace)
      assert_equal 126, status.exitstatus
      assert_match(/AIWEB_TOOL_BROKER_BLOCKED git_push/, stderr)

      _stdout, stderr, status = Open3.capture3(env, File.join(broker.fetch(:bin_dir), "git"), "--work-tree", ".", "push", chdir: workspace)
      assert_equal 126, status.exitstatus
      assert_match(/AIWEB_TOOL_BROKER_BLOCKED git_push/, stderr)

      _stdout, stderr, status = Open3.capture3(env, File.join(broker.fetch(:bin_dir), "git"), "--git-dir", ".git", "push", chdir: workspace)
      assert_equal 126, status.exitstatus
      assert_match(/AIWEB_TOOL_BROKER_BLOCKED git_push/, stderr)

      _stdout, _stderr, status = Open3.capture3(env, File.join(broker.fetch(:bin_dir), "npm"), "run", "build", chdir: workspace)
      assert_equal 0, status.exitstatus
      assert_includes File.read(real_log), "npm run build"
      events = File.readlines(broker.fetch(:events_path), chomp: true).map { |line| JSON.parse(line) }
      assert events.any? { |event| event["tool_name"] == "npm" && event["risk_class"] == "package_install" }
      assert events.any? { |event| event["tool_name"] == "git" && event["risk_class"] == "git_push" }
      refute_includes File.read(real_log), "install"
      refute_includes File.read(real_log), "ci"
      refute_includes File.read(real_log), "update"
      refute_includes File.read(real_log), "push"
    end
  end

  def test_engine_run_redacts_tool_broker_event_payloads_before_streaming
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      secret_arg = "curl https://example.test/upload?token=AIWEB_TEST_API_KEY=fake-redaction-test-value"
      bin_dir = write_fake_openmanus_tooling(dir, broker_blocked_action: "external_network", broker_args_text: secret_arg)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero with network", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      assert_equal 5, code
      assert_equal "waiting_approval", payload.dig("engine_run", "status")
      serialized_payload = JSON.generate(payload)
      events_text = File.read(payload.dig("engine_run", "events_path"))
      refute_includes serialized_payload, "AIWEB_TEST_API_KEY=fake-redaction-test-value"
      refute_includes events_text, "AIWEB_TEST_API_KEY=fake-redaction-test-value"
      assert_includes events_text, "[redacted]"
      action = payload.dig("engine_run", "copy_back_policy", "requested_actions").find { |item| item["type"] == "external_network" }
      assert_equal "tool_broker", action.fetch("source")
      assert_includes action.fetch("args_text"), "[redacted]"
    end
  end

  def test_engine_run_surfaces_verification_tool_broker_blocks_in_policy_and_events
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      File.write("package.json", JSON.pretty_generate("scripts" => { "build" => "fake build" }))
      bin_dir = write_fake_openmanus_tooling(dir)
      if windows?
        npm_script = File.join(bin_dir, "npm-verification-broker-fake.rb")
        File.write(
          npm_script,
          <<~'RUBY'
            # frozen_string_literal: true
            require "fileutils"
            require "json"
            event_path = File.join("_aiweb", "tool-broker-events.jsonl")
            FileUtils.mkdir_p(File.dirname(event_path))
            File.open(event_path, "a") do |file|
              file.puts({ "schema_version" => 1, "type" => "tool.blocked", "tool_name" => "npm", "risk_class" => "package_install", "reason" => "verification package install blocked" }.to_json)
            end
            warn "AIWEB_TOOL_BROKER_BLOCKED package_install"
            exit 126
          RUBY
        )
        File.write(File.join(bin_dir, "npm.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{npm_script}\" %*\r\n")
      else
        npm_script = File.join(bin_dir, "npm")
        File.write(
          npm_script,
          <<~'SH'
            #!/bin/sh
            mkdir -p _aiweb
            printf '{"schema_version":1,"type":"tool.blocked","tool_name":"npm","risk_class":"package_install","reason":"verification package install blocked"}\n' >> _aiweb/tool-broker-events.jsonl
            echo "AIWEB_TOOL_BROKER_BLOCKED package_install" >&2
            exit 126
          SH
        )
        FileUtils.chmod("+x", npm_script)
      end
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "surface verification broker block", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      assert_equal 5, code
      assert_equal "waiting_approval", payload.dig("engine_run", "status")
      actions = payload.dig("engine_run", "copy_back_policy", "requested_actions")
      assert actions.any? { |action| action["source"] == "tool_broker" && action["type"] == "package_install" }
      assert_match(/tool broker blocked/i, payload.dig("engine_run", "copy_back_policy", "approval_issues").join("\n"))
      event_lines = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line) }
      assert event_lines.any? { |event| event.fetch("type") == "tool.blocked" && event.dig("data", "cycle") == "verification:build" }
      refute_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_blocks_when_worker_adapter_output_contains_host_absolute_path
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      result_payload = {
        "schema_version" => 1,
        "status" => "patched",
        "changed_file_manifest" => ["C:/Users/example/.env"],
        "risk_notes" => ["host path should be blocked"]
      }
      bin_dir = write_fake_openmanus_tooling(dir, agent_result_payload: result_payload)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_match(/worker adapter contract violation|host absolute path/i, payload.dig("engine_run", "copy_back_policy", "blocking_issues").join("\n"))
      assert_match(%r{artifacts/worker-adapter-contract\.json\z}, payload.dig("engine_run", "worker_adapter_contract_path"))
      assert_equal "<h1>Before</h1>\n", File.read("src/components/Hero.astro")
    end
  end

  def test_engine_run_waits_for_approval_when_agent_requests_mcp_connector
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir, stdout_text: "need MCP connector github app for repo context")
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero with repo context", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      assert_equal 5, code
      assert_equal "waiting_approval", payload.dig("engine_run", "status")
      assert_includes payload.dig("engine_run", "copy_back_policy", "requested_actions").map { |action| action.fetch("type") }, "mcp_connectors"
      assert_match(/MCP|connectors|allowlist/i, payload.dig("engine_run", "copy_back_policy", "requested_actions").map { |action| action.fetch("reason") }.join("\n"))
      assert_match(/MCP|connectors/i, payload.dig("engine_run", "copy_back_policy", "approval_issues").join("\n"))
      approval_request = payload.dig("engine_run", "copy_back_policy", "approval_requests").find { |request| request.fetch("type") == "mcp_connectors" }
      assert_equal "delegated_identity_and_connector_data_access", approval_request.fetch("risk")
      %w[mcp_server tool_names allowed_args_schema credential_source delegated_identity network_destinations output_redaction per_call_audit].each do |field|
        assert_includes approval_request.fetch("requires"), field
      end
      event_types = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line).fetch("type") }
      assert_includes event_types, "tool.action.requested"
      assert_includes event_types, "tool.action.blocked"
      assert_includes event_types, "approval.requested"
      refute_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_quarantines_secret_or_boundary_leakage_before_copy_back
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir, stdout_text: "secret environment leaked to docker")
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "quarantined", payload.dig("engine_run", "status")
      assert_equal false, payload.dig("engine_run", "quarantine", "copy_back_allowed")
      assert_match(/secret leakage|secret environment leaked/i, payload.dig("engine_run", "quarantine", "reasons").join("\n"))
      assert_match(%r{\A\.ai-web/runs/.+/artifacts/quarantine\.json\z}, payload.dig("engine_run", "quarantine_path"))
      assert File.file?(payload.dig("engine_run", "quarantine_path"))
      assert_equal "<h1>Before</h1>\n", File.read("src/components/Hero.astro")
      event_types = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line).fetch("type") }
      assert_includes event_types, "run.quarantined"
    end
  end

  def test_engine_run_repairs_after_sandbox_verification_failure
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      File.write("package.json", JSON.pretty_generate("scripts" => { "build" => "fake build" }))
      bin_dir = write_fake_engine_openmanus_repair_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "repair failing build", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "2", "--approved")

      assert_equal 0, code
      assert_equal "passed", payload.dig("engine_run", "status")
      assert_match(/needs repair/, File.read("src/components/Hero.astro"))
      assert_match(/fixed after qa/, File.read("src/components/Hero.astro"))
      assert_equal "passed", payload.dig("engine_run", "verification", "status")
      event_types = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line).fetch("type") }
      assert_includes event_types, "qa.failed"
      assert_includes event_types, "repair.planned"
    end
  end

  def test_engine_run_revalidates_worker_adapter_output_after_repair_cycle
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      File.write("package.json", JSON.pretty_generate("scripts" => { "build" => "fake build" }))
      invalid_repair_result = {
        "schema_version" => 1,
        "status" => "patched",
        "changed_file_manifest" => ["C:/Users/example/.env"],
        "risk_notes" => ["repair cycle host path should be blocked"]
      }
      bin_dir = write_fake_engine_openmanus_repair_tooling(dir, agent_result_payload_after_repair: invalid_repair_result)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "repair then emit invalid adapter result", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "2", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_match(/worker adapter contract violation|host absolute path/i, payload.dig("engine_run", "copy_back_policy", "blocking_issues").join("\n"))
      assert_equal "<h1>Before</h1>\n", File.read("src/components/Hero.astro"), "invalid repair-cycle adapter output must block copy-back"
    end
  end

  def test_engine_run_verification_uses_clean_environment
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      File.write("package.json", JSON.pretty_generate("scripts" => { "build" => "fake build" }))
      bin_dir = write_fake_engine_openmanus_verification_guard_tooling(dir)
      env = {
        "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
        "OPENAI_API_KEY" => "must-not-reach-verification",
        "FAKE_ENGINE_SECRET" => "must-not-reach-verification"
      }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "verify clean env", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      assert_equal 0, code
      assert_equal "passed", payload.dig("engine_run", "status")
      assert_equal "passed", payload.dig("engine_run", "verification", "status")
      verification_command = payload.dig("engine_run", "verification", "checks", 0, "command")
      assert_match(/\Adocker run\b/, verification_command)
      assert_includes verification_command, "--network none"
      refute_includes JSON.generate(payload), "must-not-reach-verification"
    end
  end

  def test_executable_version_uses_clean_environment
    in_tmp do |dir|
      bin_dir = File.join(dir, "fake-version-bin")
      FileUtils.mkdir_p(bin_dir)
      script = File.join(bin_dir, "pnpm-version-fake.rb")
      File.write(
        script,
        <<~'RUBY'
          # frozen_string_literal: true

          if ENV.keys.any? { |key| %w[OPENAI_API_KEY FAKE_VERSION_SECRET].include?(key) }
            warn "secret environment leaked to version command"
            exit 81
          end
          puts "9.9.9"
        RUBY
      )
      if windows?
        File.write(File.join(bin_dir, "pnpm.cmd"), "@echo off\r\n\"#{RbConfig.ruby}\" \"#{script}\" %*\r\n")
      else
        wrapper = File.join(bin_dir, "pnpm")
        File.write(wrapper, "#!/bin/sh\nexec #{RbConfig.ruby.shellescape} #{script.shellescape} \"$@\"\n")
        FileUtils.chmod("+x", wrapper)
      end

      old_path = ENV["PATH"]
      old_openai_key = ENV["OPENAI_API_KEY"]
      old_fake_secret = ENV["FAKE_VERSION_SECRET"]
      ENV["PATH"] = [bin_dir, old_path].compact.join(File::PATH_SEPARATOR)
      ENV["OPENAI_API_KEY"] = "must-not-reach-version"
      ENV["FAKE_VERSION_SECRET"] = "must-not-reach-version"

      assert_equal "9.9.9", Aiweb::Project.new(dir).send(:executable_version, "pnpm", "--version")
    ensure
      ENV["PATH"] = old_path
      old_openai_key.nil? ? ENV.delete("OPENAI_API_KEY") : ENV["OPENAI_API_KEY"] = old_openai_key
      old_fake_secret.nil? ? ENV.delete("FAKE_VERSION_SECRET") : ENV["FAKE_VERSION_SECRET"] = old_fake_secret
    end
  end

  def test_engine_run_resume_reuses_checkpoint_workspace_before_copy_back
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir, patch_text: "<!-- first failed patch -->", exit_status: 9)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      first_payload, first_code = json_cmd_with_env(env, "engine-run", "--goal", "resume hero patch", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "1", "--approved")

      refute_equal 0, first_code
      assert_equal "failed", first_payload.dig("engine_run", "status")
      refute_match(/first failed patch/, File.read("src/components/Hero.astro"))

      write_fake_openmanus_tooling(dir, patch_text: "<!-- resumed patch -->")
      payload, code = json_cmd_with_env(env, "engine-run", "--resume", first_payload.dig("engine_run", "run_id"), "--agent", "openmanus", "--sandbox", "docker", "--approved")

      assert_equal 0, code
      assert_equal "passed", payload.dig("engine_run", "status")
      body = File.read("src/components/Hero.astro")
      assert_match(/first failed patch/, body)
      assert_match(/resumed patch/, body)
      assert_equal first_payload.dig("engine_run", "run_id"), payload.dig("engine_run", "checkpoint", "resume_from")
      assert_equal "worker_act", payload.dig("engine_run", "graph_execution_plan", "start_node_id")
      assert_equal "worker_act", JSON.parse(File.read(payload.dig("engine_run", "graph_execution_plan_path"))).fetch("start_node_id")
      graph_scheduler_state = JSON.parse(File.read(payload.dig("engine_run", "graph_scheduler_state_path")))
      assert_equal first_payload.dig("engine_run", "run_id"), graph_scheduler_state.fetch("resume_from")
      assert_equal "worker_act", graph_scheduler_state.fetch("start_node_id")
      assert graph_scheduler_state.fetch("transitions").any? { |transition| transition["node_id"] == "worker_act" && transition["state"] == "passed" }
      event_types = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line).fetch("type") }
      assert_includes event_types, "run.resumed"
      assert_includes event_types, "graph.scheduler.planned"
      assert_includes event_types, "graph.scheduler.started"
      assert_includes event_types, "graph.scheduler.finished"
    end
  end

  def test_engine_run_resume_blocks_when_checkpoint_graph_cursor_is_tampered
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir, patch_text: "<!-- first failed patch -->", exit_status: 9)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      first_payload, first_code = json_cmd_with_env(env, "engine-run", "--goal", "resume hero patch", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "1", "--approved")

      refute_equal 0, first_code
      checkpoint_path = first_payload.dig("engine_run", "checkpoint_path")
      checkpoint = JSON.parse(File.read(checkpoint_path))
      checkpoint["run_graph_cursor"]["node_id"] = "not-a-real-node"
      File.write(checkpoint_path, JSON.pretty_generate(checkpoint) + "\n")

      write_fake_openmanus_tooling(dir, patch_text: "<!-- resumed patch -->")
      payload, code = json_cmd_with_env(env, "engine-run", "--resume", first_payload.dig("engine_run", "run_id"), "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_match(/graph cursor|unknown node/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      refute_match(/resumed patch/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_resume_blocks_when_checkpoint_graph_executor_contract_is_tampered
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir, patch_text: "<!-- first failed patch -->", exit_status: 9)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      first_payload, first_code = json_cmd_with_env(env, "engine-run", "--goal", "resume hero patch", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "1", "--approved")

      refute_equal 0, first_code
      checkpoint_path = first_payload.dig("engine_run", "checkpoint_path")
      checkpoint = JSON.parse(File.read(checkpoint_path))
      checkpoint["run_graph"]["executor_contract"]["node_order"] = checkpoint["run_graph"]["executor_contract"]["node_order"].reverse
      checkpoint["run_graph"]["nodes"].find { |node| node["node_id"] == "worker_act" }["executor"]["tool_broker_required"] = false
      File.write(checkpoint_path, JSON.pretty_generate(checkpoint) + "\n")

      write_fake_openmanus_tooling(dir, patch_text: "<!-- resumed patch -->")
      payload, code = json_cmd_with_env(env, "engine-run", "--resume", first_payload.dig("engine_run", "run_id"), "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      issues = payload.dig("engine_run", "blocking_issues").join("\n")
      assert_match(/executor node order|side effect is not gated by tool broker/i, issues)
      refute_match(/resumed patch/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_resume_waiting_approval_start_node_does_not_rerun_worker
    in_tmp do |dir|
      json_cmd("init")
      File.write("package.json", JSON.pretty_generate("scripts" => { "build" => "echo ok" }) + "\n")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      first_patch = JSON.pretty_generate("scripts" => { "build" => "echo patched" }) + "\n"
      bin_dir = write_fake_openmanus_tooling(dir, patch_path: "package.json", patch_text: first_patch, overwrite_workspace: true)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      first_payload, first_code = json_cmd_with_env(env, "engine-run", "--goal", "patch package", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, first_code
      assert_equal "waiting_approval", first_payload.dig("engine_run", "status")
      assert_equal "approval", first_payload.dig("engine_run", "run_graph", "cursor", "node_id")
      assert_includes File.read(File.join(first_payload.dig("engine_run", "workspace_path"), "package.json")), "echo patched"
      refute_includes File.read("package.json"), "echo patched"

      write_fake_openmanus_tooling(dir, patch_path: "package.json", patch_text: "SHOULD_NOT_RERUN_WORKER\n", overwrite_workspace: false)
      payload, code = json_cmd_with_env(env, "engine-run", "--resume", first_payload.dig("engine_run", "run_id"), "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_equal "approval", payload.dig("engine_run", "graph_execution_plan", "start_node_id")
      assert_match(/graph scheduler start node approval/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      refute_includes File.read(File.join(payload.dig("engine_run", "workspace_path"), "package.json")), "SHOULD_NOT_RERUN_WORKER"
      event_types = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line).fetch("type") }
      refute_includes event_types, "step.started"
      refute_includes event_types, "sandbox.preflight.started"
      refute_includes event_types, "sandbox.preflight.finished"
      assert_includes event_types, "graph.scheduler.finished"
    end
  end

  def test_engine_run_resume_blocks_when_checkpoint_cursor_is_rewound_from_hashed_scheduler_state
    in_tmp do |dir|
      json_cmd("init")
      File.write("package.json", JSON.pretty_generate("scripts" => { "build" => "echo ok" }) + "\n")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      first_patch = JSON.pretty_generate("scripts" => { "build" => "echo patched" }) + "\n"
      bin_dir = write_fake_openmanus_tooling(dir, patch_path: "package.json", patch_text: first_patch, overwrite_workspace: true)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      first_payload, first_code = json_cmd_with_env(env, "engine-run", "--goal", "patch package", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, first_code
      assert_equal "waiting_approval", first_payload.dig("engine_run", "status")
      checkpoint_path = first_payload.dig("engine_run", "checkpoint_path")
      checkpoint = JSON.parse(File.read(checkpoint_path))
      worker_node = checkpoint.fetch("run_graph").fetch("nodes").find { |node| node["node_id"] == "worker_act" }
      worker_node["state"] = "failed"
      worker_node["attempt"] = 1
      checkpoint["run_graph_cursor"] = {
        "node_id" => "worker_act",
        "state" => "failed",
        "attempt" => 1
      }
      File.write(checkpoint_path, JSON.pretty_generate(checkpoint) + "\n")

      write_fake_openmanus_tooling(dir, patch_path: "package.json", patch_text: "SHOULD_NOT_RERUN_WORKER\n", overwrite_workspace: false)
      payload, code = json_cmd_with_env(env, "engine-run", "--resume", first_payload.dig("engine_run", "run_id"), "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      issues = payload.dig("engine_run", "blocking_issues").join("\n")
      assert_match(/hashed graph scheduler state cursor|hashed graph scheduler state/i, issues)
      refute_includes File.read(File.join(first_payload.dig("engine_run", "workspace_path"), "package.json")), "SHOULD_NOT_RERUN_WORKER"
      assert_equal [], payload.dig("engine_run", "events")
    end
  end

  def test_engine_run_resume_blocks_when_checkpoint_artifact_hashes_are_removed
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir, patch_text: "<!-- first failed patch -->", exit_status: 9)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      first_payload, first_code = json_cmd_with_env(env, "engine-run", "--goal", "resume hero patch", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "1", "--approved")

      refute_equal 0, first_code
      checkpoint_path = first_payload.dig("engine_run", "checkpoint_path")
      checkpoint = JSON.parse(File.read(checkpoint_path))
      checkpoint.delete("artifact_hashes")
      File.write(checkpoint_path, JSON.pretty_generate(checkpoint) + "\n")

      write_fake_openmanus_tooling(dir, patch_text: "<!-- resumed patch -->")
      payload, code = json_cmd_with_env(env, "engine-run", "--resume", first_payload.dig("engine_run", "run_id"), "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_match(/missing artifact hashes|no artifact hashes/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      refute_match(/resumed patch/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_resume_blocks_when_required_checkpoint_artifact_hash_entry_is_removed
    %w[graph_execution_plan graph_scheduler_state staged_manifest].each do |missing_key|
      in_tmp do |dir|
        json_cmd("init")
        FileUtils.mkdir_p("src/components")
        File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
        bin_dir = write_fake_openmanus_tooling(dir, patch_text: "<!-- first failed patch -->", exit_status: 9)
        env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

        first_payload, first_code = json_cmd_with_env(env, "engine-run", "--goal", "resume hero patch", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "1", "--approved")

        refute_equal 0, first_code
        checkpoint_path = first_payload.dig("engine_run", "checkpoint_path")
        checkpoint = JSON.parse(File.read(checkpoint_path))
        assert checkpoint.dig("artifact_hashes", missing_key), "fixture must have #{missing_key} hash before tamper"
        checkpoint.fetch("artifact_hashes").delete(missing_key)
        File.write(checkpoint_path, JSON.pretty_generate(checkpoint) + "\n")

        write_fake_openmanus_tooling(dir, patch_text: "<!-- resumed patch -->")
        payload, code = json_cmd_with_env(env, "engine-run", "--resume", first_payload.dig("engine_run", "run_id"), "--agent", "openmanus", "--sandbox", "docker", "--approved")

        refute_equal 0, code, missing_key
        assert_equal "blocked", payload.dig("engine_run", "status"), missing_key
        assert_match(/missing required artifact hash.*#{Regexp.escape(missing_key)}/i, payload.dig("engine_run", "blocking_issues").join("\n"), missing_key)
        refute_match(/resumed patch/, File.read("src/components/Hero.astro"), missing_key)
      end
    end
  end

  def test_engine_run_resume_blocks_when_required_checkpoint_artifact_hash_path_is_tampered
    {
      "graph_execution_plan" => :alternate_run_artifact,
      "staged_manifest" => :absolute_path
    }.each do |hash_key, tamper_kind|
      in_tmp do |dir|
        json_cmd("init")
        FileUtils.mkdir_p("src/components")
        File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
        bin_dir = write_fake_openmanus_tooling(dir, patch_text: "<!-- first failed patch -->", exit_status: 9)
        env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

        first_payload, first_code = json_cmd_with_env(env, "engine-run", "--goal", "resume hero patch", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "1", "--approved")

        refute_equal 0, first_code
        checkpoint_path = first_payload.dig("engine_run", "checkpoint_path")
        checkpoint = JSON.parse(File.read(checkpoint_path))
        artifact = checkpoint.dig("artifact_hashes", hash_key)
        assert artifact, "fixture must have #{hash_key} hash before tamper"
        original_path = artifact.fetch("path")
        tampered_path =
          case tamper_kind
          when :alternate_run_artifact
            alternate = File.join(".ai-web", "runs", "engine-run-tampered", "artifacts", File.basename(original_path))
            FileUtils.mkdir_p(File.dirname(alternate))
            File.write(alternate, File.read(original_path))
            alternate
          when :absolute_path
            File.expand_path(original_path)
          else
            flunk "unknown tamper kind #{tamper_kind}"
          end
        artifact["path"] = tampered_path
        artifact["sha256"] = "sha256:#{Digest::SHA256.file(tampered_path).hexdigest}"
        artifact["bytes"] = File.size(tampered_path)
        File.write(checkpoint_path, JSON.pretty_generate(checkpoint) + "\n")

        write_fake_openmanus_tooling(dir, patch_text: "<!-- resumed patch -->")
        payload, code = json_cmd_with_env(env, "engine-run", "--resume", first_payload.dig("engine_run", "run_id"), "--agent", "openmanus", "--sandbox", "docker", "--approved")

        refute_equal 0, code, hash_key
        assert_equal "blocked", payload.dig("engine_run", "status"), hash_key
        assert_match(/artifact hash path is invalid.*#{Regexp.escape(hash_key)}/i, payload.dig("engine_run", "blocking_issues").join("\n"), hash_key)
        refute_match(/resumed patch/, File.read("src/components/Hero.astro"), hash_key)
      end
    end
  end

  def test_engine_run_resume_blocks_when_checkpoint_artifact_hash_unknown_key_is_injected
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      File.write(".env", "SECRET=must-not-be-hashed-by-resume\n")
      bin_dir = write_fake_openmanus_tooling(dir, patch_text: "<!-- first failed patch -->", exit_status: 9)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      first_payload, first_code = json_cmd_with_env(env, "engine-run", "--goal", "resume hero patch", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "1", "--approved")

      refute_equal 0, first_code
      checkpoint_path = first_payload.dig("engine_run", "checkpoint_path")
      checkpoint = JSON.parse(File.read(checkpoint_path))
      checkpoint.fetch("artifact_hashes")["injected_env"] = {
        "path" => ".env",
        "sha256" => "sha256:#{Digest::SHA256.file(".env").hexdigest}",
        "bytes" => File.size(".env")
      }
      File.write(checkpoint_path, JSON.pretty_generate(checkpoint) + "\n")

      write_fake_openmanus_tooling(dir, patch_text: "<!-- resumed patch -->")
      payload, code = json_cmd_with_env(env, "engine-run", "--resume", first_payload.dig("engine_run", "run_id"), "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_match(/unknown artifact hash.*injected_env/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      refute_match(/resumed patch/, File.read("src/components/Hero.astro"))
    end
  end

  def test_engine_run_resume_blocks_when_checkpoint_artifact_hash_bytes_are_missing
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<h1>Before</h1>\n")
      bin_dir = write_fake_openmanus_tooling(dir, patch_text: "<!-- first failed patch -->", exit_status: 9)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      first_payload, first_code = json_cmd_with_env(env, "engine-run", "--goal", "resume hero patch", "--agent", "openmanus", "--sandbox", "docker", "--max-cycles", "1", "--approved")

      refute_equal 0, first_code
      checkpoint_path = first_payload.dig("engine_run", "checkpoint_path")
      checkpoint = JSON.parse(File.read(checkpoint_path))
      checkpoint.fetch("artifact_hashes").fetch("graph_execution_plan").delete("bytes")
      File.write(checkpoint_path, JSON.pretty_generate(checkpoint) + "\n")

      write_fake_openmanus_tooling(dir, patch_text: "<!-- resumed patch -->")
      payload, code = json_cmd_with_env(env, "engine-run", "--resume", first_payload.dig("engine_run", "run_id"), "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_match(/artifact hash is incomplete.*graph_execution_plan/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      refute_match(/resumed patch/, File.read("src/components/Hero.astro"))
    end
  end

  def test_next_task_generates_schema_complete_machine_constrained_packet
    in_tmp do
      prepare_profile_d_scaffold_flow
      set_phase("phase-6")

      payload, code = json_cmd("next-task", "--type", "implementation")
      task_path = payload.fetch("changed_files").find { |path| path.match?(%r{\A\.ai-web/tasks/task-.+-implementation\.md\z}) }

      assert_equal 0, code
      assert task_path, "next-task must write a task packet path"
      assert_equal task_path, load_state.dig("implementation", "current_task")
      body = File.read(task_path)
      assert_includes body, "# Task Packet"
      assert_match(/Task ID: task-.+-implementation/, body)
      assert_includes body, "Phase: phase-6"
      assert_includes body, "## Goal"
      assert_includes body, "## Inputs"
      assert_includes body, "## Constraints"
      assert_includes body, "## Machine Constraints"
      assert_includes body, "## Acceptance Criteria"
      assert_includes body, "## Verification"
      assert_includes body, ".ai-web/state.yaml"
      assert_includes body, ".ai-web/DESIGN.md"
      assert_includes body, ".ai-web/design-candidates/candidate-02.html"
      assert_includes body, "Do not read `.env` or `.env.*`"
      assert_includes body, "Do not call external Lazyweb/design-research"
      assert_includes body, "Do not copy exact reference"
      assert_includes body, "shell_allowed: false"
      assert_includes body, "network_allowed: false"
      assert_includes body, "env_access_allowed: false"
      assert_includes body, "allowed_source_paths:"
      assert_includes body, "src/components/Hero.astro"
    end
  end


  def test_setup_install_without_approval_blocks_without_writes_or_env_access
    in_tmp do
      prepare_profile_d_scaffold_flow
      secret = "SECRET=pr20-no-approval-do-not-leak"
      File.write(".env", "#{secret}\n")
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")
      env_size = File.size(".env")
      env_mtime = File.mtime(".env")

      stdout, stderr, code = run_aiweb("setup", "--install", "--json")
      payload = JSON.parse(stdout)

      assert_equal 5, code
      assert_equal "", stderr
      assert_equal "setup install blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("setup", "status")
      assert_equal false, payload.dig("setup", "dry_run")
      assert_match(/approved|approval/i, [payload.dig("error", "message"), payload["blocking_issues"], payload.dig("setup", "blocking_issues")].flatten.compact.join("\n"))
      assert_no_setup_side_effects(before_entries: before_entries, before_state: before_state, env_size: env_size, env_mtime: env_mtime)
      refute_includes stdout, secret
    end
  end

  def test_setup_install_dry_run_plans_pnpm_install_without_writes_or_process_execution
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      secret = "SECRET=pr20-dry-run-do-not-leak"
      File.write(".env", "#{secret}\n")
      bin_dir = File.join(dir, "fake-setup-bin")
      FileUtils.mkdir_p(bin_dir)
      marker = File.join(dir, "pnpm-was-run")
      write_fake_executable(bin_dir, "pnpm", "touch #{marker.shellescape}; echo should-not-run >&2; exit 99")
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")
      env_size = File.size(".env")
      env_mtime = File.mtime(".env")

      stdout, stderr, code = run_aiweb_env({ "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }, "setup", "--install", "--dry-run", "--json")
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal true, payload["dry_run"]
      assert_equal "planned setup install", payload["action_taken"]
      assert_equal "dry_run", payload.dig("setup", "status")
      assert_equal true, payload.dig("setup", "dry_run")
      assert_equal "pnpm", payload.dig("setup", "package_manager")
      assert_match(/\Apnpm install --ignore-scripts --registry https:\/\/registry\.npmjs\.org\/ --store-dir \.ai-web\/runs\/setup-\d{8}T\d{12}Z-[0-9a-f]{8}\/package-cache\z/, payload.dig("setup", "command"))
      setup_payload_paths(payload).each do |path|
        assert_match(%r{\A\.ai-web/runs/setup-\d{8}T\d{12}Z-[0-9a-f]{8}/(stdout\.log|stderr\.log|setup\.json)\z}, path)
      end
      assert_match(%r{\A\.ai-web/runs/setup-\d{8}T\d{12}Z-[0-9a-f]{8}/side-effect-broker\.jsonl\z}, payload.dig("setup", "side_effect_broker_path"))
      assert_match(%r{\A\.ai-web/runs/setup-\d{8}T\d{12}Z-[0-9a-f]{8}/artifacts/supply-chain-gate\.json\z}, payload.dig("setup", "supply_chain_gate_path"))
      assert_match(%r{\A\.ai-web/runs/setup-\d{8}T\d{12}Z-[0-9a-f]{8}/artifacts/sbom\.json\z}, payload.dig("setup", "sbom_path"))
      assert_match(%r{\A\.ai-web/runs/setup-\d{8}T\d{12}Z-[0-9a-f]{8}/artifacts/sbom\.cyclonedx\.json\z}, payload.dig("setup", "cyclonedx_sbom_path"))
      assert_match(%r{\A\.ai-web/runs/setup-\d{8}T\d{12}Z-[0-9a-f]{8}/artifacts/sbom\.spdx\.json\z}, payload.dig("setup", "spdx_sbom_path"))
      assert_match(%r{\A\.ai-web/runs/setup-\d{8}T\d{12}Z-[0-9a-f]{8}/artifacts/package-audit\.json\z}, payload.dig("setup", "package_audit_path"))
      assert_equal "planned", payload.dig("setup", "supply_chain_gate", "status")
      assert_equal "CycloneDX 1.5 JSON", payload.dig("setup", "supply_chain_gate", "sbom", "accepted_formats", 0)
      assert_equal "SPDX 2.3 JSON", payload.dig("setup", "supply_chain_gate", "sbom", "accepted_formats", 1)
      assert_equal "planned", payload.dig("setup", "side_effect_broker", "status")
      assert_equal "plan-only", payload.dig("setup", "side_effect_broker", "policy", "decision")
      assert_equal false, payload.dig("setup", "side_effect_broker", "events_recorded")
      refute File.exist?(payload.dig("setup", "side_effect_broker_path")), "setup --dry-run must not write broker events"
      refute File.exist?(payload.dig("setup", "supply_chain_gate_path")), "setup --dry-run must not write supply-chain evidence"
      refute File.exist?(payload.dig("setup", "sbom_path")), "setup --dry-run must not write SBOM evidence"
      refute File.exist?(payload.dig("setup", "cyclonedx_sbom_path")), "setup --dry-run must not write CycloneDX SBOM evidence"
      refute File.exist?(payload.dig("setup", "spdx_sbom_path")), "setup --dry-run must not write SPDX SBOM evidence"
      refute File.exist?(payload.dig("setup", "package_audit_path")), "setup --dry-run must not write audit evidence"
      assert_no_setup_side_effects(before_entries: before_entries, before_state: before_state, env_size: env_size, env_mtime: env_mtime)
      refute File.exist?(marker), "setup --dry-run must not execute pnpm"
      refute_includes stdout, secret
    end
  end

  def test_setup_install_approved_records_broker_events_when_pnpm_is_missing
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      secret = "SECRET=pr20-approved-missing-pnpm-do-not-leak"
      File.write(".env", "#{secret}\n")
      empty_bin = File.join(dir, "empty-bin")
      FileUtils.mkdir_p(empty_bin)
      env_size = File.size(".env")
      env_mtime = File.mtime(".env")
      payload = nil

      with_env_values("PATH" => empty_bin) do
        payload = Aiweb::Project.new(Dir.pwd).setup(install: true, approved: true)
      end

      assert_equal "setup install blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("setup", "status")
      assert_equal true, payload.dig("setup", "approved")
      assert_nil payload.dig("setup", "exit_code")
      assert_match(/pnpm executable is missing/i, payload.fetch("blocking_issues").join("\n"))
      stdout_log, stderr_log, metadata_path = setup_payload_paths(payload)
      assert_equal "", File.read(stdout_log)
      assert_match(/pnpm executable is missing/i, File.read(stderr_log))
      assert File.file?(payload.dig("setup", "side_effect_broker_path")), "approved setup pre-launch block must still record broker events"
      broker_events = File.readlines(payload.dig("setup", "side_effect_broker_path"), chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[tool.requested policy.decision tool.blocked], broker_events.map { |event| event.fetch("event") }
      assert_equal "deny", broker_events.find { |event| event.fetch("event") == "policy.decision" }.fetch("decision")
      assert_equal "blocked", broker_events.last.fetch("status")
      assert_equal "blocked", payload.dig("setup", "side_effect_broker", "status")
      assert_equal true, payload.dig("setup", "side_effect_broker", "events_recorded")
      assert_equal broker_events.length, payload.dig("setup", "side_effect_broker", "event_count")
      assert_equal "deny", payload.dig("setup", "side_effect_broker", "policy", "decision")
      assert File.file?(payload.dig("setup", "supply_chain_gate_path"))
      assert_equal "blocked", payload.dig("setup", "supply_chain_gate", "status")
      assert_equal "not_executed", JSON.parse(File.read(payload.dig("setup", "sbom_path"))).fetch("status")
      assert_equal "not_executed", JSON.parse(File.read(payload.dig("setup", "cyclonedx_sbom_path"))).fetch("status")
      assert_equal "not_executed", JSON.parse(File.read(payload.dig("setup", "spdx_sbom_path"))).fetch("status")
      assert_equal "not_executed", JSON.parse(File.read(payload.dig("setup", "package_audit_path"))).fetch("status")
      assert_equal payload.fetch("setup"), JSON.parse(File.read(metadata_path))
      assert_equal env_size, File.size(".env")
      assert_equal env_mtime, File.mtime(".env")
      refute Dir.exist?("dist"), "blocked setup must not build"
      refute Dir.glob(".ai-web/runs/{build,preview,playwright-qa,a11y-qa,lighthouse-qa}-*").any?, "blocked setup must not run build/preview/QA"
      assert_setup_artifacts_do_not_leak_secret(payload, secret)
    end
  end

  def test_setup_install_approved_blocks_package_json_network_ref_before_pnpm_launch
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      package = JSON.parse(File.read("package.json"))
      package["dependencies"] ||= {}
      package["dependencies"]["evil-direct-git"] = "git+https://user:network-secret@github.com/evil/repo.git?token=network-secret"
      package["dependencies"]["evil-git-protocol"] = "git://github.com/acme/pkg.git"
      package["dependencies"]["evil-git-protocol-userinfo"] = "git://user:network-secret-git@github.com/acme/pkg.git"
      package["dependencies"]["evil-ssh-url-userinfo"] = "ssh://git:network-secret-ssh@github.com/acme/pkg.git"
      package["dependencies"]["evil-git-ssh-userinfo"] = "git+ssh://git:network-secret-git-ssh@github.com/acme/pkg.git"
      package["dependencies"]["evil-gitlab-shortcut"] = "gitlab:acme/pkg"
      package["dependencies"]["evil-bitbucket-shortcut"] = "bitbucket:acme/pkg"
      package["dependencies"]["evil-gist-shortcut"] = "gist:acme/pkg"
      package["dependencies"]["evil-github-bare"] = "acme/pkg"
      File.write("package.json", JSON.pretty_generate(package))
      marker = File.join(dir, "setup-env-probe.json")
      bin_dir = write_fake_pnpm_install_tooling(dir, env_probe_path: marker)

      payload = nil
      with_env_values("PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR)) do
        payload = Aiweb::Project.new(Dir.pwd).setup(install: true, approved: true)
      end

      assert_equal "setup install blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("setup", "status")
      assert_nil payload.dig("setup", "exit_code")
      assert_match(/pre-install setup network allowlist/i, payload.fetch("blocking_issues").join("\n"))
      refute File.exist?(marker), "network allowlist block must happen before launching pnpm"
      broker_events = File.readlines(payload.dig("setup", "side_effect_broker_path"), chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[tool.requested policy.decision tool.blocked], broker_events.map { |event| event.fetch("event") }
      assert_equal "deny", broker_events.find { |event| event.fetch("event") == "policy.decision" }.fetch("decision")
      gate = payload.dig("setup", "supply_chain_gate")
      assert_equal "blocked", gate.fetch("status")
      assert_equal "blocked", gate.dig("network_allowlist_enforcement", "status")
      violations = gate.dig("network_allowlist_enforcement", "before_violations")
      assert_includes violations.map { |violation| violation.fetch("host") }, "github.com"
      assert_includes violations.map { |violation| violation.fetch("host") }, "gitlab.com"
      assert_includes violations.map { |violation| violation.fetch("host") }, "bitbucket.org"
      assert_includes violations.map { |violation| violation.fetch("host") }, "gist.github.com"
      assert violations.any? { |violation| violation.fetch("path").match?(%r{package\.json/dependencies/evil-direct-git}) }
      assert violations.any? { |violation| violation.fetch("path").match?(%r{package\.json/dependencies/evil-github-bare}) }
      refute_includes JSON.generate(payload), "network-secret"
      refute_includes JSON.generate(payload), "network-secret-git"
      refute_includes JSON.generate(payload), "network-secret-ssh"
      refute_includes JSON.generate(payload), "network-secret-git-ssh"
      assert_equal "not_executed", JSON.parse(File.read(payload.dig("setup", "sbom_path"))).fetch("status")
    end
  end

  def test_setup_install_approved_blocks_post_install_lockfile_network_ref
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      malicious_lockfile = <<~YAML
        lockfileVersion: '9.0'
        importers:
          .:
            dependencies: {}
        packages:
          /evil-tarball@1.0.0:
            resolution:
              tarball: https://evil.example/evil-tarball-1.0.0.tgz
      YAML
      marker = File.join(dir, "setup-env-probe.json")
      bin_dir = write_fake_pnpm_install_tooling(dir, stdout: "fake install complete", stderr: "fake lifecycle warning", lockfile_after: malicious_lockfile, env_probe_path: marker)

      payload = nil
      with_env_values("PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR)) do
        payload = Aiweb::Project.new(Dir.pwd).setup(install: true, approved: true)
      end

      assert_equal "setup install blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("setup", "status")
      assert_equal 0, payload.dig("setup", "exit_code")
      assert File.exist?(marker), "post-install network allowlist regression should prove pnpm ran before the new lockfile was rejected"
      assert_match(/post-install setup network allowlist/i, payload.fetch("blocking_issues").join("\n"))
      gate = payload.dig("setup", "supply_chain_gate")
      assert_equal "blocked", gate.fetch("status")
      assert_equal "blocked", gate.dig("network_allowlist_enforcement", "status")
      assert_equal "evil.example", gate.dig("network_allowlist_enforcement", "after_violations", 0, "host")
      assert_match(%r{pnpm-lock\.yaml/packages//evil-tarball@1\.0\.0/resolution/tarball}, gate.dig("network_allowlist_enforcement", "after_violations", 0, "path"))
      assert_equal "blocked", gate.dig("execution_evidence", "status")
      refute Dir.exist?("dist"), "network-blocked setup must not build"
    end
  end

  def test_setup_install_approved_records_successful_fake_pnpm_artifacts_and_safe_state
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      secret = "SECRET=pr20-approved-do-not-leak"
      File.write(".env", "#{secret}\n")
      package = JSON.parse(File.read("package.json"))
      package["dependencies"] ||= {}
      package["dependencies"]["allowed-registry-tarball"] = "https://registry.npmjs.org/allowed/-/allowed-1.0.0.tgz?authToken=registry-secret&_authToken=registry-secret&npm_token=registry-secret"
      File.write("package.json", JSON.pretty_generate(package))
      bin_dir = write_fake_pnpm_install_tooling(dir, stdout: "fake install complete", stderr: "fake lifecycle warning")
      env_size = File.size(".env")
      env_mtime = File.mtime(".env")

      stdout, stderr, code = run_aiweb_env({ "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }, "setup", "--install", "--approved", "--json")
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal "ran setup install", payload["action_taken"]
      assert_equal "passed", payload.dig("setup", "status")
      assert_equal false, payload.dig("setup", "dry_run")
      assert_equal true, payload.dig("setup", "approved")
      assert_equal "pnpm", payload.dig("setup", "package_manager")
      assert_match(/\Apnpm install --ignore-scripts --registry https:\/\/registry\.npmjs\.org\/ --store-dir \.ai-web\/runs\/setup-\d{8}T\d{12}Z-[0-9a-f]{8}\/package-cache\z/, payload.dig("setup", "command"))
      assert_equal 0, payload.dig("setup", "exit_code")
      stdout_log, stderr_log, metadata_path = setup_payload_paths(payload)
      assert_equal "fake install complete\n", File.read(stdout_log)
      assert_equal "fake lifecycle warning\n", File.read(stderr_log)
      assert File.file?(payload.dig("setup", "side_effect_broker_path")), "approved setup install must record broker events"
      broker_events = File.readlines(payload.dig("setup", "side_effect_broker_path"), chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[tool.requested policy.decision tool.started tool.finished tool.requested policy.decision tool.started tool.finished tool.requested policy.decision tool.started tool.finished], broker_events.map { |event| event.fetch("event") }
      assert_equal payload.dig("setup", "side_effect_broker_events"), broker_events
      assert_equal "aiweb.setup.side_effect_broker", payload.dig("setup", "side_effect_broker", "broker")
      assert_equal "setup.package_install", payload.dig("setup", "side_effect_broker", "scope")
      assert_equal "passed", payload.dig("setup", "side_effect_broker", "status")
      assert_equal true, payload.dig("setup", "side_effect_broker", "events_recorded")
      assert_equal broker_events.length, payload.dig("setup", "side_effect_broker", "event_count")
      assert File.file?(payload.dig("setup", "supply_chain_gate_path"))
      assert File.file?(payload.dig("setup", "sbom_path"))
      assert File.file?(payload.dig("setup", "cyclonedx_sbom_path"))
      assert File.file?(payload.dig("setup", "spdx_sbom_path"))
      assert File.file?(payload.dig("setup", "package_audit_path"))
      assert_equal "passed", payload.dig("setup", "supply_chain_gate", "status")
      assert_equal "executed", payload.dig("setup", "supply_chain_gate", "execution_evidence", "status")
      assert_includes payload.dig("setup", "supply_chain_gate", "execution_evidence", "artifacts"), payload.dig("setup", "cyclonedx_sbom_path")
      assert_includes payload.dig("setup", "supply_chain_gate", "execution_evidence", "artifacts"), payload.dig("setup", "spdx_sbom_path")
      assert_equal ["https://registry.npmjs.org/"], payload.dig("setup", "supply_chain_gate", "clean_cache_install", "registry_allowlist")
      assert_equal ["registry.npmjs.org"], payload.dig("setup", "supply_chain_gate", "clean_cache_install", "network_allowlist")
      assert_equal "passed", payload.dig("setup", "supply_chain_gate", "network_allowlist_enforcement", "status")
      assert_equal [], payload.dig("setup", "supply_chain_gate", "network_allowlist_enforcement", "before_violations")
      assert_equal [], payload.dig("setup", "supply_chain_gate", "network_allowlist_enforcement", "after_violations")
      refute_includes JSON.generate(payload), "registry-secret"
      allowed_ref = payload.dig("setup", "supply_chain_gate", "network_allowlist_enforcement", "before_ref_count")
      assert_operator allowed_ref, :>=, 1
      assert_equal "disabled_by_default_with_ignore_scripts; future lifecycle-enabled installs require sandboxed elevated approval", payload.dig("setup", "supply_chain_gate", "clean_cache_install", "lifecycle_script_policy")
      assert_equal "generated", JSON.parse(File.read(payload.dig("setup", "sbom_path"))).fetch("status")
      cyclonedx = JSON.parse(File.read(payload.dig("setup", "cyclonedx_sbom_path")))
      assert_equal "CycloneDX", cyclonedx.fetch("bomFormat")
      assert_equal "1.5", cyclonedx.fetch("specVersion")
      assert_match(/\Aurn:uuid:/, cyclonedx.fetch("serialNumber"))
      assert_includes cyclonedx.fetch("components"), { "type" => "library", "name" => "fixture", "version" => "1.0.0" }
      assert_equal "generated", payload.dig("setup", "supply_chain_gate", "sbom", "standard_status")
      assert_equal "CycloneDX 1.5 JSON", payload.dig("setup", "supply_chain_gate", "sbom", "standard_format")
      assert_equal payload.dig("setup", "cyclonedx_sbom_path"), payload.dig("setup", "supply_chain_gate", "sbom", "standard_artifact_path")
      project = Aiweb::Project.new(Dir.pwd)
      assert_equal "failed", project.send(:setup_supply_chain_cyclonedx_status, "status" => "failed", "bomFormat" => "CycloneDX", "specVersion" => "1.4", "components" => [])
      assert_equal "failed", project.send(:setup_supply_chain_cyclonedx_status, "status" => "failed", "bomFormat" => "CycloneDX", "specVersion" => "1.5")
      spdx = JSON.parse(File.read(payload.dig("setup", "spdx_sbom_path")))
      assert_equal "SPDX-2.3", spdx.fetch("spdxVersion")
      assert_equal "CC0-1.0", spdx.fetch("dataLicense")
      assert_match(%r{\Ahttps://aiweb\.local/spdx/[0-9a-f-]+\z}, spdx.fetch("documentNamespace"))
      assert_includes spdx.fetch("packages"), {
        "name" => "fixture",
        "SPDXID" => "SPDXRef-Package-1",
        "versionInfo" => "1.0.0",
        "downloadLocation" => "NOASSERTION",
        "filesAnalyzed" => false,
        "licenseConcluded" => "NOASSERTION",
        "licenseDeclared" => "NOASSERTION",
        "copyrightText" => "NOASSERTION"
      }
      assert_equal "generated", payload.dig("setup", "supply_chain_gate", "sbom", "spdx_status")
      assert_equal "SPDX 2.3 JSON", payload.dig("setup", "supply_chain_gate", "sbom", "spdx_format")
      assert_equal payload.dig("setup", "spdx_sbom_path"), payload.dig("setup", "supply_chain_gate", "sbom", "spdx_artifact_path")
      assert_equal "failed", project.send(:setup_supply_chain_spdx_status, "status" => "failed", "spdxVersion" => "SPDX-2.2", "dataLicense" => "CC0-1.0", "packages" => [])
      assert_equal "failed", project.send(:setup_supply_chain_spdx_status, "status" => "failed", "spdxVersion" => "SPDX-2.3", "dataLicense" => "CC0-1.0")
      assert_equal "failed", project.send(:setup_supply_chain_spdx_status, "status" => "failed", "spdxVersion" => "SPDX-2.3", "dataLicense" => "CC0-1.0", "SPDXID" => "SPDXRef-DOCUMENT", "name" => "fixture", "documentNamespace" => "https://aiweb.local/spdx/fixture", "packages" => [])
      assert_equal "failed", project.send(:setup_supply_chain_spdx_status, "status" => "failed", "spdxVersion" => "SPDX-2.3", "dataLicense" => "CC0-1.0", "SPDXID" => "SPDXRef-DOCUMENT", "name" => "fixture", "creationInfo" => { "created" => "2026-01-01T00:00:00Z", "creators" => ["Tool: aiweb-test"] }, "packages" => [])
      audit = JSON.parse(File.read(payload.dig("setup", "package_audit_path")))
      assert_equal "passed", audit.fetch("status")
      assert_equal "passed", audit.fetch("vulnerability_gate")
      assert_equal payload.fetch("setup"), JSON.parse(File.read(metadata_path))
      state = load_state
      assert_equal metadata_path, state.dig("setup", "latest_run")
      assert_equal "pnpm", state.dig("setup", "package_manager")
      assert_includes [true, false], state.dig("setup", "node_modules_present")
      refute_nil state.dig("setup", "last_installed_at")
      assert_equal env_size, File.size(".env")
      assert_equal env_mtime, File.mtime(".env")
      refute Dir.exist?("dist"), "setup install must not build"
      refute Dir.glob(".ai-web/runs/{build,preview,playwright-qa,a11y-qa,lighthouse-qa}-*").any?, "setup install must not run build/preview/QA"
      assert_setup_artifacts_do_not_leak_secret(payload, secret)
    end
  end

  def test_setup_install_approved_records_lifecycle_sandbox_gate_without_running_scripts
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      package = JSON.parse(File.read("package.json"))
      package["scripts"] ||= {}
      package["scripts"]["postinstall"] = "node -e \"require('fs').writeFileSync('lifecycle-ran','bad')\""
      package["scripts"]["prepare"] = "node -e \"require('fs').readFileSync('.env')\""
      File.write("package.json", JSON.pretty_generate(package) + "\n")
      bin_dir = write_fake_pnpm_install_tooling(dir, stdout: "fake install complete", stderr: "fake lifecycle warning")

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "setup",
        "--install",
        "--approved",
        "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 0, code, stdout
      assert_equal "", stderr
      assert_equal "passed", payload.dig("setup", "status")
      assert_equal false, payload.dig("setup", "supply_chain_gate", "clean_cache_install", "default_install_lifecycle_execution")
      assert_equal true, payload.dig("setup", "supply_chain_gate", "clean_cache_install", "default_command_uses_ignore_scripts")
      gate = payload.dig("setup", "supply_chain_gate", "lifecycle_sandbox_gate")
      assert_equal "aiweb.setup.lifecycle_sandbox_gate.v1", gate.fetch("policy")
      assert_equal "blocked_until_sandbox_and_egress_firewall", gate.fetch("status")
      assert_equal true, gate.fetch("lifecycle_scripts_present")
      assert_equal false, gate.fetch("lifecycle_enabled_requested")
      assert_equal false, gate.fetch("lifecycle_enabled_execution_available")
      assert_equal false, gate.fetch("default_install_lifecycle_execution")
      assert_equal true, gate.fetch("default_command_uses_ignore_scripts")
      assert_equal "blocked_until_sandbox_and_egress_firewall", gate.fetch("lifecycle_enabled_install_status")
      assert_match(/default install disables/i, gate.fetch("lifecycle_enabled_block_reason"))
      assert_equal "fail_closed_until_lifecycle_sandbox_driver_and_egress_firewall_exist", gate.fetch("requested_command_policy")
      assert_equal false, gate.dig("egress_firewall", "external_network_allowed")
      assert_equal "not_installed", gate.dig("egress_firewall", "default_install_os_egress_firewall_status")
      assert_equal true, gate.dig("egress_firewall", "network_refs_static_allowlist_enforced")
      assert_equal true, gate.dig("egress_firewall", "lifecycle_enabled_egress_firewall_required")
      assert_equal "passed", gate.dig("default_install_sandbox_attestation", "status")
      assert_equal "host_package_manager_with_lifecycle_scripts_disabled", gate.dig("default_install_sandbox_attestation", "mode")
      assert_equal "not_claimed_for_default_install", gate.dig("default_install_sandbox_attestation", "filesystem_isolation")
      assert_equal false, gate.dig("default_install_sandbox_attestation", "lifecycle_scripts_executed")
      assert_equal false, gate.dig("default_install_sandbox_attestation", "dot_env_access_by_lifecycle_scripts")
      assert_equal true, gate.dig("default_install_sandbox_attestation", "child_env_policy", "unsetenv_others")
      assert_equal false, gate.dig("default_install_sandbox_attestation", "child_env_policy", "secret_values_recorded")
      assert_equal false, gate.dig("required_sandbox_evidence", "dot_env_reads_allowed")
      assert_equal false, gate.dig("required_sandbox_evidence", "workspace_escape_allowed")
      assert_includes gate.dig("required_sandbox_evidence", "required_artifacts"), "egress-firewall-log.json"
      scripts = gate.fetch("lifecycle_scripts")
      assert_equal %w[postinstall prepare], scripts.map { |entry| entry.fetch("script") }
      assert scripts.all? { |entry| entry.fetch("command_sha256").match?(/\A[a-f0-9]{64}\z/) }
      assert_includes scripts.last.fetch("command"), "[excluded unsafe environment-file reference]"
      assert_equal "postinstall", payload.dig("setup", "lifecycle_script_warnings", 0, "script")
      refute File.exist?("lifecycle-ran"), "setup install must not run package lifecycle scripts"
      assert_equal payload.fetch("setup"), JSON.parse(File.read(payload.dig("setup", "metadata_path")))
    end
  end

  def test_setup_install_allow_lifecycle_scripts_fails_closed_before_pnpm_launch
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      secret = "SECRET=pr20-lifecycle-enabled-do-not-leak"
      File.write(".env", "#{secret}\n")
      package = JSON.parse(File.read("package.json"))
      package["scripts"] ||= {}
      package["scripts"]["postinstall"] = "node -e \"require('fs').writeFileSync('lifecycle-ran','bad')\""
      package["scripts"]["prepare"] = "node -e \"require('fs').readFileSync('.env')\""
      File.write("package.json", JSON.pretty_generate(package) + "\n")
      marker = File.join(dir, "setup-env-probe.json")
      bin_dir = write_fake_pnpm_install_tooling(dir, stdout: "fake install should not run", stderr: "fake lifecycle warning", env_probe_path: marker)

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "setup",
        "--install",
        "--approved",
        "--allow-lifecycle-scripts",
        "--json"
      )
      payload = JSON.parse(stdout)

      refute_equal 0, code
      assert_equal "", stderr
      assert_equal "setup install blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("setup", "status")
      assert_equal true, payload.dig("setup", "approved")
      assert_equal true, payload.dig("setup", "lifecycle_enabled_requested")
      assert_nil payload.dig("setup", "exit_code")
      assert_match(/lifecycle-enabled install requested.*blocked/i, payload.fetch("blocking_issues").join("\n"))
      refute File.exist?(marker), "lifecycle-enabled fail-closed gate must happen before launching pnpm"
      refute File.exist?("lifecycle-ran"), "blocked lifecycle-enabled setup must not run lifecycle scripts"
      broker_events = File.readlines(payload.dig("setup", "side_effect_broker_path"), chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[tool.requested policy.decision tool.blocked], broker_events.map { |event| event.fetch("event") }
      assert_equal "deny", broker_events.find { |event| event.fetch("event") == "policy.decision" }.fetch("decision")
      assert_equal "blocked", payload.dig("setup", "side_effect_broker", "status")
      gate = payload.dig("setup", "supply_chain_gate", "lifecycle_sandbox_gate")
      assert_equal "blocked_until_sandbox_and_egress_firewall", gate.fetch("status")
      assert_equal true, gate.fetch("lifecycle_scripts_present")
      assert_equal true, gate.fetch("lifecycle_enabled_requested")
      assert_equal false, gate.fetch("lifecycle_enabled_execution_available")
      assert_equal "blocked_until_sandbox_and_egress_firewall", gate.fetch("lifecycle_enabled_install_status")
      assert_match(/explicitly requested.*fail-closed/i, gate.fetch("lifecycle_enabled_block_reason"))
      assert_equal "fail_closed_until_lifecycle_sandbox_driver_and_egress_firewall_exist", gate.fetch("requested_command_policy")
      assert_equal "blocked", payload.dig("setup", "supply_chain_gate", "execution_evidence", "status")
      assert_equal "not_executed", JSON.parse(File.read(payload.dig("setup", "sbom_path"))).fetch("status")
      assert_equal payload.fetch("setup"), JSON.parse(File.read(payload.dig("setup", "metadata_path")))
      assert_setup_artifacts_do_not_leak_secret(payload, secret)
    end
  end

  def test_setup_install_approved_records_dependency_semantic_diff
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      before_package = JSON.parse(File.read("package.json"))
      before_package["dependencies"] ||= {}
      before_package["devDependencies"] ||= {}
      before_package["dependencies"].merge!(
        "changed-package" => "^1.0.0",
        "kept-package" => "^1.0.0",
        "removed-package" => "^1.0.0"
      )
      before_package["devDependencies"]["removed-dev-package"] = "^0.1.0"
      after_package = JSON.parse(JSON.generate(before_package))
      after_package["dependencies"].delete("removed-package")
      after_package["dependencies"].merge!(
        "added-package" => "^1.0.0",
        "changed-package" => "^2.0.0"
      )
      after_package["devDependencies"].delete("removed-dev-package")
      after_package["devDependencies"]["added-dev-package"] = "^0.2.0"
      File.write("package.json", JSON.pretty_generate(before_package) + "\n")
      File.write("pnpm-lock.yaml", "lockfileVersion: '9.0'\n# before\n")
      bin_dir = write_fake_pnpm_install_tooling(
        dir,
        stdout: "fake install complete",
        stderr: "fake lifecycle warning",
        package_json_after: JSON.pretty_generate(after_package) + "\n",
        lockfile_after: "lockfileVersion: '9.0'\n# after\n"
      )

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "setup",
        "--install",
        "--approved",
        "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 0, code, stdout
      assert_equal "", stderr
      diff = payload.dig("setup", "supply_chain_gate", "dependency_diff")
      assert_equal "changed", diff.fetch("status")
      assert_equal "changed", diff.dig("semantic_dependency_diff", "status")
      assert_includes diff.fetch("package_file_diff").map { |item| item.fetch("path") }, "package.json"
      assert_includes diff.fetch("package_file_diff").map { |item| item.fetch("path") }, "pnpm-lock.yaml"
      semantic = diff.fetch("semantic_dependency_diff")
      assert_includes semantic.fetch("added"), { "section" => "dependencies", "name" => "added-package", "version" => "^1.0.0" }
      assert_includes semantic.fetch("added"), { "section" => "devDependencies", "name" => "added-dev-package", "version" => "^0.2.0" }
      assert_includes semantic.fetch("removed"), { "section" => "dependencies", "name" => "removed-package", "version" => "^1.0.0" }
      assert_includes semantic.fetch("removed"), { "section" => "devDependencies", "name" => "removed-dev-package", "version" => "^0.1.0" }
      assert_includes semantic.fetch("version_changes"), { "section" => "dependencies", "name" => "changed-package", "before" => "^1.0.0", "after" => "^2.0.0" }
      assert_equal 2, semantic.fetch("added_count")
      assert_equal 2, semantic.fetch("removed_count")
      assert_equal 1, semantic.fetch("version_change_count")
      assert_equal payload.fetch("setup"), JSON.parse(File.read(payload.dig("setup", "metadata_path")))
      refute Dir.exist?("dist"), "semantic-diff setup must not build"
    end
  end

  def test_setup_install_approved_records_pnpm_lockfile_semantic_diff
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      before_lockfile = <<~YAML
        lockfileVersion: '9.0'
        importers:
          .:
            dependencies:
              changed-lock:
                specifier: ^1.0.0
                version: 1.0.1
              kept-lock:
                specifier: ^1.0.0
                version: 1.0.0
              removed-lock:
                specifier: ^1.0.0
                version: 1.0.0
        packages:
          changed-lock@1.0.1:
            resolution: {integrity: sha512-before}
          kept-lock@1.0.0:
            resolution: {integrity: sha512-kept}
          removed-lock@1.0.0:
            resolution: {integrity: sha512-removed}
      YAML
      after_lockfile = <<~YAML
        lockfileVersion: '9.0'
        importers:
          .:
            dependencies:
              added-lock:
                specifier: ^3.0.0
                version: 3.0.0
              changed-lock:
                specifier: ^2.0.0
                version: 2.0.0
              kept-lock:
                specifier: ^1.0.0
                version: 1.0.0
        packages:
          added-lock@3.0.0:
            resolution: {integrity: sha512-added}
          changed-lock@2.0.0:
            resolution: {integrity: sha512-after}
          kept-lock@1.0.0:
            resolution: {integrity: sha512-kept}
      YAML
      File.write("pnpm-lock.yaml", before_lockfile)
      bin_dir = write_fake_pnpm_install_tooling(
        dir,
        stdout: "fake install complete",
        stderr: "fake lifecycle warning",
        lockfile_after: after_lockfile
      )

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "setup",
        "--install",
        "--approved",
        "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 0, code, stdout
      assert_equal "", stderr
      diff = payload.dig("setup", "supply_chain_gate", "dependency_diff")
      assert_includes diff.fetch("required_outputs"), "lockfile_semantic_diff"
      lockfile = diff.fetch("lockfile_semantic_diff")
      assert_equal "changed", lockfile.fetch("status")
      assert_equal "parsed", lockfile.fetch("before_status")
      assert_equal "parsed", lockfile.fetch("after_status")
      assert_includes lockfile.fetch("added_dependencies"), {
        "importer" => ".",
        "section" => "dependencies",
        "name" => "added-lock",
        "specifier" => "^3.0.0",
        "version" => "3.0.0"
      }
      assert_includes lockfile.fetch("removed_dependencies"), {
        "importer" => ".",
        "section" => "dependencies",
        "name" => "removed-lock",
        "specifier" => "^1.0.0",
        "version" => "1.0.0"
      }
      assert_includes lockfile.fetch("specifier_changes"), {
        "importer" => ".",
        "section" => "dependencies",
        "name" => "changed-lock",
        "before" => "^1.0.0",
        "after" => "^2.0.0"
      }
      assert_includes lockfile.fetch("version_changes"), {
        "importer" => ".",
        "section" => "dependencies",
        "name" => "changed-lock",
        "before" => "1.0.1",
        "after" => "2.0.0"
      }
      assert_includes lockfile.fetch("added_packages"), {
        "key" => "added-lock@3.0.0",
        "name" => "added-lock",
        "version" => "3.0.0"
      }
      assert_includes lockfile.fetch("removed_packages"), {
        "key" => "removed-lock@1.0.0",
        "name" => "removed-lock",
        "version" => "1.0.0"
      }
      assert_includes lockfile.fetch("package_version_changes"), {
        "name" => "changed-lock",
        "before_versions" => ["1.0.1"],
        "after_versions" => ["2.0.0"],
        "added_versions" => ["2.0.0"],
        "removed_versions" => ["1.0.1"]
      }
      assert_equal 1, lockfile.fetch("added_dependency_count")
      assert_equal 1, lockfile.fetch("removed_dependency_count")
      assert_equal 1, lockfile.fetch("specifier_change_count")
      assert_equal 1, lockfile.fetch("version_change_count")
      assert_equal 2, lockfile.fetch("added_package_count")
      assert_equal 2, lockfile.fetch("removed_package_count")
      assert_equal payload.fetch("setup"), JSON.parse(File.read(payload.dig("setup", "metadata_path")))
      refute Dir.exist?("dist"), "lockfile semantic-diff setup must not build"
    end
  end

  def test_setup_install_approved_strips_sensitive_environment_from_pnpm_processes
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      env_probe_path = File.join(dir, "setup-env-probe.json")
      bin_dir = write_fake_pnpm_install_tooling(dir, stdout: "fake install complete", stderr: "fake lifecycle warning", env_probe_path: env_probe_path)

      stdout, stderr, code = run_aiweb_env(
        {
          "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
          "SECRET" => "setup-secret-must-not-reach-pnpm",
          "NPM_TOKEN" => "npm-token-must-not-reach-pnpm"
        },
        "setup",
        "--install",
        "--approved",
        "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 0, code, stdout
      assert_equal "", stderr
      assert_equal "passed", payload.dig("setup", "status")
      probe = JSON.parse(File.read(env_probe_path))
      assert_nil probe["SECRET"]
      assert_nil probe["NPM_TOKEN"]
      assert_equal "1", probe["AIWEB_SETUP_APPROVED"]
      child_env_policy = payload.dig("setup", "supply_chain_gate", "lifecycle_sandbox_gate", "default_install_sandbox_attestation", "child_env_policy")
      assert_equal true, child_env_policy.fetch("unsetenv_others")
      assert_equal true, child_env_policy.fetch("aiweb_setup_approved")
      assert_includes child_env_policy.fetch("secret_parent_env_keys_stripped"), "SECRET"
      assert_includes child_env_policy.fetch("secret_parent_env_keys_stripped"), "NPM_TOKEN"
      assert_equal false, child_env_policy.fetch("secret_values_recorded")
      assert_setup_artifacts_do_not_leak_secret(payload, "setup-secret-must-not-reach-pnpm")
      assert_setup_artifacts_do_not_leak_secret(payload, "npm-token-must-not-reach-pnpm")
    end
  end

  def test_setup_install_approved_blocks_when_package_json_becomes_invalid
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      bin_dir = write_fake_pnpm_install_tooling(dir, stdout: "fake install complete", stderr: "fake lifecycle warning", package_json_after: "{ invalid json")

      stdout, stderr, code = run_aiweb_env({ "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }, "setup", "--install", "--approved", "--json")
      payload = JSON.parse(stdout)

      refute_equal 0, code
      assert_equal "", stderr
      assert_equal "setup install blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("setup", "status")
      assert_match(/post-install package\.json is invalid/i, payload.fetch("blocking_issues").join("\n"))
      assert_equal "invalid", payload.dig("setup", "supply_chain_gate", "dependency_diff", "semantic_after", "status")
      assert_equal "blocked", payload.dig("setup", "supply_chain_gate", "status")
      refute Dir.exist?("dist"), "invalid package manifest setup must not build"
    end
  end

  def test_setup_install_approved_blocks_when_package_json_manifest_is_emptied
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      bin_dir = write_fake_pnpm_install_tooling(dir, stdout: "fake install complete", stderr: "fake lifecycle warning", package_json_after: JSON.pretty_generate("name" => "emptied-manifest") + "\n")

      stdout, stderr, code = run_aiweb_env({ "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }, "setup", "--install", "--approved", "--json")
      payload = JSON.parse(stdout)

      refute_equal 0, code
      assert_equal "", stderr
      assert_equal "setup install blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("setup", "status")
      assert_match(/post-install package manifest failed runtime-plan validation/i, payload.fetch("blocking_issues").join("\n"))
      semantic = payload.dig("setup", "supply_chain_gate", "dependency_diff", "semantic_dependency_diff")
      assert_equal "changed", semantic.fetch("status")
      assert_operator semantic.fetch("removed_count"), :>, 0
      assert_equal "blocked", payload.dig("setup", "supply_chain_gate", "status")
      refute Dir.exist?("dist"), "emptied package manifest setup must not build"
    end
  end

  def test_setup_install_approved_blocks_when_pnpm_lockfile_becomes_invalid
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      bin_dir = write_fake_pnpm_install_tooling(
        dir,
        stdout: "fake install complete",
        stderr: "fake lifecycle warning",
        lockfile_after: "lockfileVersion: '9.0'\nimporters:\n  .: [\n"
      )

      stdout, stderr, code = run_aiweb_env({ "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }, "setup", "--install", "--approved", "--json")
      payload = JSON.parse(stdout)

      refute_equal 0, code
      assert_equal "", stderr
      assert_equal "setup install blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("setup", "status")
      assert_match(/post-install pnpm-lock\.yaml is invalid/i, payload.fetch("blocking_issues").join("\n"))
      assert_equal "invalid", payload.dig("setup", "supply_chain_gate", "dependency_diff", "lockfile_semantic_after", "status")
      assert_equal "blocked", payload.dig("setup", "supply_chain_gate", "status")
      refute Dir.exist?("dist"), "invalid lockfile setup must not build"
    end
  end

  def test_setup_install_approved_blocks_when_pnpm_lockfile_is_missing_after_install
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      FileUtils.rm_f("pnpm-lock.yaml")
      bin_dir = write_fake_pnpm_install_tooling(dir, stdout: "fake install complete", stderr: "fake lifecycle warning", lockfile_after: nil)

      stdout, stderr, code = run_aiweb_env({ "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }, "setup", "--install", "--approved", "--json")
      payload = JSON.parse(stdout)

      refute_equal 0, code
      assert_equal "", stderr
      assert_equal "setup install blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("setup", "status")
      assert_match(/post-install pnpm-lock\.yaml is missing/i, payload.fetch("blocking_issues").join("\n"))
      assert_equal "missing", payload.dig("setup", "supply_chain_gate", "dependency_diff", "lockfile_semantic_after", "status")
      assert_equal "blocked", payload.dig("setup", "supply_chain_gate", "status")
      refute Dir.exist?("dist"), "missing lockfile setup must not build"
    end
  end

  def test_setup_install_approved_repeated_runs_get_distinct_broker_paths_with_fixed_time
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      bin_dir = write_fake_pnpm_install_tooling(dir, stdout: "fake install complete", stderr: "fake lifecycle warning")
      fixed = Time.utc(2026, 1, 2, 3, 4, 5)
      suffixes = %w[aaaaaaaa bbbbbbbb]
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }
      first_payload = nil
      second_payload = nil

      with_env_values(env) do
        Time.stub(:now, fixed) do
          SecureRandom.stub(:hex, ->(_bytes) { suffixes.shift }) do
            project = Aiweb::Project.new(Dir.pwd)
            first_payload = project.setup(install: true, approved: true)
            second_payload = project.setup(install: true, approved: true)
          end
        end
      end

      first = first_payload.fetch("setup")
      second = second_payload.fetch("setup")
      refute_equal first.fetch("run_id"), second.fetch("run_id")
      refute_equal first.fetch("metadata_path"), second.fetch("metadata_path")
      refute_equal first.fetch("side_effect_broker_path"), second.fetch("side_effect_broker_path")
      assert File.file?(first.fetch("side_effect_broker_path"))
      assert File.file?(second.fetch("side_effect_broker_path"))
      assert_equal 12, File.readlines(first.fetch("side_effect_broker_path")).length
      assert_equal 12, File.readlines(second.fetch("side_effect_broker_path")).length
    end
  end

  def test_setup_install_approved_blocks_when_package_audit_reports_high_vulnerability
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      audit_json = JSON.generate(
        "metadata" => { "vulnerabilities" => { "critical" => 0, "high" => 1, "moderate" => 0, "low" => 0 } },
        "vulnerabilities" => {
          "bad-package" => { "name" => "bad-package", "severity" => "high", "id" => "GHSA-bad", "version" => "1.0.0" }
        }
      )
      bin_dir = write_fake_pnpm_install_tooling(dir, stdout: "fake install complete", stderr: "fake lifecycle warning", audit_json: audit_json, audit_exit_status: 1)

      stdout, stderr, code = run_aiweb_env({ "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }, "setup", "--install", "--approved", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "setup install blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("setup", "status")
      assert_match(/critical\/high vulnerabilities/i, payload.fetch("blocking_issues").join("\n"))
      audit = JSON.parse(File.read(payload.dig("setup", "package_audit_path")))
      assert_equal "blocked", audit.fetch("status")
      assert_equal "blocked", audit.fetch("vulnerability_gate")
      assert_equal 1, audit.dig("severity_counts", "high")
      assert_equal "blocked", payload.dig("setup", "supply_chain_gate", "vulnerability_copy_back_gate", "status")
      assert_equal "not_requested", payload.dig("setup", "supply_chain_gate", "vulnerability_copy_back_gate", "audit_exception", "status")
      assert File.file?(payload.dig("setup", "sbom_path"))
      refute Dir.exist?("dist"), "audit-blocked setup must not build"
      refute Dir.glob(".ai-web/runs/{build,preview,playwright-qa,a11y-qa,lighthouse-qa}-*").any?, "audit-blocked setup must not run build/preview/QA"
      refute Dir.exist?(".ai-web/deploy"), "audit-blocked setup must not create deploy provider artifacts"
    end
  end

  def test_setup_install_approved_allows_high_audit_with_valid_exception_and_rollback_plan
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      audit_json = JSON.generate(
        "metadata" => { "vulnerabilities" => { "critical" => 0, "high" => 1, "moderate" => 0, "low" => 0 } },
        "vulnerabilities" => {
          "bad-package" => { "name" => "bad-package", "severity" => "high", "id" => "GHSA-bad", "version" => "1.0.0" }
        }
      )
      FileUtils.mkdir_p(".ai-web/approvals")
      exception_path = ".ai-web/approvals/setup-audit-exception.json"
      File.write(
        exception_path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "approval_kind" => "setup_audit_exception",
          "approved" => true,
          "accepted_risk" => true,
          "approved_by" => "security-reviewer",
          "approved_at" => "2026-01-01T00:00:00Z",
          "expires_at" => (Time.now.utc + 86_400).iso8601,
          "reason" => "temporary fixture acceptance for patched transitive dependency",
          "applies_to" => {
            "package_manager" => "pnpm",
            "blocked_severities" => ["high"],
            "findings" => [
              {
                "package_name" => "bad-package",
                "severity" => "high",
                "advisory_id" => "GHSA-bad"
              }
            ]
          },
          "rollback_plan" => {
            "summary" => "remove the dependency update and restore the previous lockfile",
            "steps" => ["revert package.json and pnpm-lock.yaml", "rerun setup and audit gate"]
          }
        ) + "\n"
      )
      bin_dir = write_fake_pnpm_install_tooling(dir, stdout: "fake install complete", stderr: "fake lifecycle warning", audit_json: audit_json, audit_exit_status: 1)

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "setup",
        "--install",
        "--approved",
        "--audit-exception",
        exception_path,
        "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 0, code, stdout
      assert_equal "", stderr
      assert_equal "ran setup install", payload["action_taken"]
      assert_equal "passed", payload.dig("setup", "status")
      gate = payload.dig("setup", "supply_chain_gate")
      assert_equal "passed", gate.fetch("status")
      assert_equal "blocked", gate.dig("audit", "status")
      assert_equal [{ "package_name" => "bad-package", "severity" => "high", "advisory_id" => "GHSA-bad", "current_version" => "1.0.0" }], gate.dig("audit", "active_findings")
      assert_equal "accepted_risk", gate.dig("vulnerability_copy_back_gate", "status")
      exception = gate.dig("vulnerability_copy_back_gate", "audit_exception")
      assert_equal "accepted", exception.fetch("status")
      assert_equal exception_path, exception.fetch("path")
      assert_equal ["high"], exception.fetch("active_blocked_severities")
      assert_equal ["high"], exception.fetch("accepted_severities")
      assert_equal [{ "package_name" => "bad-package", "severity" => "high", "advisory_id" => "GHSA-bad" }], exception.fetch("accepted_findings")
      assert_equal "security-reviewer", exception.fetch("approved_by")
      assert_equal "remove the dependency update and restore the previous lockfile", exception.dig("rollback_plan", "summary")
      assert_equal ["revert package.json and pnpm-lock.yaml", "rerun setup and audit gate"], exception.dig("rollback_plan", "steps")
      assert_empty payload.fetch("blocking_issues")
      refute Dir.exist?("dist"), "audit-exception setup must not build"
    end
  end

  def test_setup_install_approved_blocks_high_audit_when_exception_lacks_rollback_plan
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      audit_json = JSON.generate(
        "metadata" => { "vulnerabilities" => { "critical" => 0, "high" => 1, "moderate" => 0, "low" => 0 } },
        "vulnerabilities" => {
          "bad-package" => { "name" => "bad-package", "severity" => "high", "id" => "GHSA-bad" }
        }
      )
      FileUtils.mkdir_p(".ai-web/approvals")
      exception_path = ".ai-web/approvals/setup-audit-exception.json"
      File.write(
        exception_path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "approval_kind" => "setup_audit_exception",
          "approved" => true,
          "accepted_risk" => true,
          "approved_by" => "security-reviewer",
          "approved_at" => "2026-01-01T00:00:00Z",
          "expires_at" => (Time.now.utc + 86_400).iso8601,
          "reason" => "temporary fixture acceptance",
          "applies_to" => {
            "package_manager" => "pnpm",
            "blocked_severities" => ["high"],
            "findings" => [
              {
                "package_name" => "bad-package",
                "severity" => "high",
                "advisory_id" => "GHSA-bad"
              }
            ]
          }
        ) + "\n"
      )
      bin_dir = write_fake_pnpm_install_tooling(dir, stdout: "fake install complete", stderr: "fake lifecycle warning", audit_json: audit_json, audit_exit_status: 1)

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "setup",
        "--install",
        "--approved",
        "--audit-exception",
        exception_path,
        "--json"
      )
      payload = JSON.parse(stdout)

      refute_equal 0, code
      assert_equal "", stderr
      assert_equal "setup install blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("setup", "status")
      assert_match(/rollback_plan/i, payload.fetch("blocking_issues").join("\n"))
      assert_equal "invalid", payload.dig("setup", "supply_chain_gate", "vulnerability_copy_back_gate", "audit_exception", "status")
      assert_equal "blocked", payload.dig("setup", "supply_chain_gate", "vulnerability_copy_back_gate", "status")
      refute Dir.exist?("dist"), "invalid audit-exception setup must not build"
    end
  end

  def test_setup_install_approved_blocks_nonzero_audit_error_json_without_findings
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      audit_json = JSON.generate("error" => { "code" => "EAUTH", "summary" => "registry auth failed" })
      bin_dir = write_fake_pnpm_install_tooling(dir, stdout: "fake install complete", stderr: "fake lifecycle warning", audit_json: audit_json, audit_exit_status: 1)

      stdout, stderr, code = run_aiweb_env({ "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }, "setup", "--install", "--approved", "--json")
      payload = JSON.parse(stdout)

      refute_equal 0, code
      assert_equal "", stderr
      assert_equal "setup install blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("setup", "status")
      assert_match(/package audit failed/i, payload.fetch("blocking_issues").join("\n"))
      audit = JSON.parse(File.read(payload.dig("setup", "package_audit_path")))
      assert_equal "failed", audit.fetch("status")
      assert_equal "failed", audit.fetch("vulnerability_gate")
      assert_equal 1, audit.fetch("exit_code")
      refute Dir.exist?("dist"), "audit error setup must not build"
    end
  end

  def test_setup_install_approved_blocks_exception_for_mismatched_audit_finding
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      audit_json = JSON.generate(
        "metadata" => { "vulnerabilities" => { "critical" => 0, "high" => 1, "moderate" => 0, "low" => 0 } },
        "vulnerabilities" => {
          "bad-package" => { "name" => "bad-package", "severity" => "high", "id" => "GHSA-bad", "version" => "1.0.0" }
        }
      )
      FileUtils.mkdir_p(".ai-web/approvals")
      exception_path = ".ai-web/approvals/setup-audit-exception.json"
      File.write(
        exception_path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "approval_kind" => "setup_audit_exception",
          "approved" => true,
          "accepted_risk" => true,
          "approved_by" => "security-reviewer",
          "approved_at" => "2026-01-01T00:00:00Z",
          "expires_at" => (Time.now.utc + 86_400).iso8601,
          "reason" => "temporary fixture acceptance for unrelated dependency",
          "applies_to" => {
            "package_manager" => "pnpm",
            "blocked_severities" => ["high"],
            "findings" => [
              {
                "package_name" => "other-package",
                "severity" => "high",
                "advisory_id" => "GHSA-other"
              }
            ]
          },
          "rollback_plan" => {
            "summary" => "remove the dependency update and restore the previous lockfile",
            "steps" => ["revert package.json and pnpm-lock.yaml"]
          }
        ) + "\n"
      )
      bin_dir = write_fake_pnpm_install_tooling(dir, stdout: "fake install complete", stderr: "fake lifecycle warning", audit_json: audit_json, audit_exit_status: 1)

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "setup",
        "--install",
        "--approved",
        "--audit-exception",
        exception_path,
        "--json"
      )
      payload = JSON.parse(stdout)

      refute_equal 0, code
      assert_equal "", stderr
      assert_equal "setup install blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("setup", "status")
      assert_match(/does not cover active findings/i, payload.fetch("blocking_issues").join("\n"))
      exception = payload.dig("setup", "supply_chain_gate", "vulnerability_copy_back_gate", "audit_exception")
      assert_equal "invalid", exception.fetch("status")
      assert_equal [{ "package_name" => "bad-package", "severity" => "high", "advisory_id" => "GHSA-bad", "current_version" => "1.0.0" }], exception.fetch("active_findings")
      refute Dir.exist?("dist"), "mismatched audit-exception setup must not build"
    end
  end

  def test_setup_install_approved_blocks_future_dated_audit_exception
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      audit_json = JSON.generate(
        "metadata" => { "vulnerabilities" => { "critical" => 0, "high" => 1, "moderate" => 0, "low" => 0 } },
        "vulnerabilities" => {
          "bad-package" => { "name" => "bad-package", "severity" => "high", "id" => "GHSA-bad" }
        }
      )
      FileUtils.mkdir_p(".ai-web/approvals")
      exception_path = ".ai-web/approvals/setup-audit-exception.json"
      File.write(
        exception_path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "approval_kind" => "setup_audit_exception",
          "approved" => true,
          "accepted_risk" => true,
          "approved_by" => "security-reviewer",
          "approved_at" => (Time.now.utc + 86_400).iso8601,
          "expires_at" => (Time.now.utc + 172_800).iso8601,
          "reason" => "future approval should not be active yet",
          "applies_to" => {
            "package_manager" => "pnpm",
            "blocked_severities" => ["high"],
            "findings" => [
              {
                "package_name" => "bad-package",
                "severity" => "high",
                "advisory_id" => "GHSA-bad"
              }
            ]
          },
          "rollback_plan" => {
            "summary" => "restore previous lockfile",
            "steps" => ["revert package changes"]
          }
        ) + "\n"
      )
      bin_dir = write_fake_pnpm_install_tooling(dir, stdout: "fake install complete", stderr: "fake lifecycle warning", audit_json: audit_json, audit_exit_status: 1)

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "setup",
        "--install",
        "--approved",
        "--audit-exception",
        exception_path,
        "--json"
      )
      payload = JSON.parse(stdout)

      refute_equal 0, code
      assert_equal "", stderr
      assert_match(/approved_at must not be in the future/i, payload.fetch("blocking_issues").join("\n"))
      assert_equal "invalid", payload.dig("setup", "supply_chain_gate", "vulnerability_copy_back_gate", "audit_exception", "status")
      refute Dir.exist?("dist"), "future-dated audit-exception setup must not build"
    end
  end

  def test_setup_install_approved_records_failed_fake_pnpm_artifact_without_build_preview_qa_or_deploy
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      secret = "SECRET=pr20-failed-do-not-leak"
      File.write(".env", "#{secret}\n")
      bin_dir = write_fake_pnpm_install_tooling(dir, exit_status: 42, stdout: "fake install stdout before failure", stderr: "fake install failed")
      env_size = File.size(".env")
      env_mtime = File.mtime(".env")

      stdout, stderr, code = run_aiweb_env({ "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }, "setup", "--install", "--approved", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "setup install failed", payload["action_taken"]
      assert_equal "failed", payload.dig("setup", "status")
      assert_equal 42, payload.dig("setup", "exit_code")
      assert_match(/failed|exit code 42/i, payload.fetch("blocking_issues").join("\n"))
      stdout_log, stderr_log, metadata_path = setup_payload_paths(payload)
      assert_equal "fake install stdout before failure\n", File.read(stdout_log)
      assert_equal "fake install failed\n", File.read(stderr_log)
      assert File.file?(payload.dig("setup", "side_effect_broker_path")), "failed approved setup install must still record broker events"
      broker_events = File.readlines(payload.dig("setup", "side_effect_broker_path"), chomp: true).map { |line| JSON.parse(line) }
      assert_equal %w[tool.requested policy.decision tool.started tool.finished], broker_events.map { |event| event.fetch("event") }
      assert_equal "failed", payload.dig("setup", "side_effect_broker", "status")
      assert_equal true, payload.dig("setup", "side_effect_broker", "events_recorded")
      assert_equal "failed", broker_events.last.fetch("status")
      assert_equal 42, broker_events.last.fetch("exit_code")
      assert_equal "blocked", payload.dig("setup", "supply_chain_gate", "status")
      assert_equal "not_executed", JSON.parse(File.read(payload.dig("setup", "sbom_path"))).fetch("status")
      assert_equal "not_executed", JSON.parse(File.read(payload.dig("setup", "package_audit_path"))).fetch("status")
      assert_equal payload.fetch("setup"), JSON.parse(File.read(metadata_path))
      assert_equal env_size, File.size(".env")
      assert_equal env_mtime, File.mtime(".env")
      refute Dir.exist?("dist"), "failed setup must not build"
      refute Dir.glob(".ai-web/runs/{build,preview,playwright-qa,a11y-qa,lighthouse-qa}-*").any?, "failed setup must not run build/preview/QA"
      refute Dir.exist?(".ai-web/deploy"), "setup install must not create deploy provider artifacts"
      assert_setup_artifacts_do_not_leak_secret(payload, secret)
    end
  end

  def test_setup_install_rejects_env_path_project_without_reading_or_printing_secret
    in_tmp do |dir|
      target = File.join(dir, ".env.local")
      Dir.mkdir(target)
      Dir.chdir(target) do
        secret = "SECRET=pr20-env-path-do-not-leak"
        File.write(".env", "#{secret}\n")

        stdout, stderr, code = run_aiweb("setup", "--install", "--dry-run", "--json")
        payload = JSON.parse(stdout)

        assert_equal 5, code
        assert_equal "", stderr
        assert_match(/not initialized|\.env|unsafe|refus/i, payload.dig("error", "message"))
        refute_includes stdout, secret
        refute Dir.exist?(".ai-web/runs"), "unsafe .env-like project paths must not create setup artifacts"
        refute Dir.exist?("node_modules"), "unsafe .env-like project paths must not install"
      end
    end
  end

  def test_setup_help_and_korean_webbuilder_passthrough_surface
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr
    assert_includes stdout, "setup --install --approved"
    assert_includes stdout, "--allow-lifecycle-scripts"
    assert_includes stdout, "setup --install --dry-run"

    in_tmp do |dir|
      target = File.join(dir, "passthrough-setup")
      Dir.mkdir(target)
      Dir.chdir(target) { prepare_profile_d_scaffold_flow }
      bin_dir = write_fake_pnpm_install_tooling(dir, stdout: "fake Korean wrapper install")

      web_stdout, web_stderr, web_code = run_korean_webbuilder_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "--path", target, "setup", "--install", "--approved", "--json"
      )
      web_payload = JSON.parse(web_stdout)

      assert_equal 0, web_code
      assert_equal "", web_stderr
      assert_equal "passed", web_payload.dig("setup", "status")
      assert_match(/\Apnpm install --ignore-scripts --registry https:\/\/registry\.npmjs\.org\/ --store-dir \.ai-web\/runs\/setup-\d{8}T\d{12}Z-[0-9a-f]{8}\/package-cache\z/, web_payload.dig("setup", "command"))
      assert_equal "fake Korean wrapper install\n", File.read(File.join(target, web_payload.dig("setup", "stdout_log")))
    end
  end

  def test_agent_run_dry_run_plans_source_patch_without_writes_or_process_execution
    in_tmp do |dir|
      task_markdown = <<~MD
        # Task Packet ??repair

        Task ID: agent-run-latest
        Phase: phase-7
        Created at: 2026-05-03T00:00:00Z

        ## Goal
        Improve the hero copy using a local source patch.

        ## Inputs
        - `.ai-web/state.yaml`
        - `.ai-web/DESIGN.md`
        - `.ai-web/component-map.json`
        - `src/components/Hero.astro`

        ## Constraints
        - Do not read `.env` or `.env.*`
        - Keep changes local and reversible

        ## Machine Constraints
        shell_allowed: false
        network_allowed: false
        env_access_allowed: false
        requires_selected_design: true
        allowed_source_paths:
        - src/components/Hero.astro

        ## Acceptance Criteria
        - Source patch evidence is recorded.
        - Logs and diff artifacts are written only on approved runs.
      MD
      prepare_agent_run_fixture(task_markdown: task_markdown)
      marker = File.join(dir, "codex-was-run")
      bin_dir = write_fake_codex_tooling(dir, marker_path: marker, patch_path: File.join(dir, "src/components/Hero.astro"))
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")
      before_source = File.read("src/components/Hero.astro")

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "agent-run", "--task", "latest", "--agent", "codex", "--dry-run", "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal true, payload["dry_run"]
      assert_equal true, payload.dig("agent_run", "dry_run")
      assert_match(/agent run/i, payload["action_taken"])
      assert_includes %w[planned dry_run], payload.dig("agent_run", "status")
      assert_equal "rerun aiweb agent-run --task latest --agent codex --approved to execute the local codex patch run", payload["next_action"]
      assert_no_agent_run_side_effects(before_entries: before_entries, before_state: before_state)
      assert_equal before_source, File.read("src/components/Hero.astro"), "agent-run --dry-run must not patch source"
      refute File.exist?(marker), "agent-run --dry-run must not execute codex"
      refute_includes stdout, "fake codex stdout"
      refute_includes stdout, "fake codex stderr"
    end
  end

  def test_agent_run_openmanus_dry_run_plans_contract_without_process_execution
    in_tmp do |dir|
      prepare_agent_run_fixture(task_markdown: agent_run_safe_task_markdown)
      bin_dir = write_fake_openmanus_tooling(dir)
      marker = File.join(dir, "openmanus-was-run")
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")
      before_source = File.read("src/components/Hero.astro")

      stdout, stderr, code = run_aiweb_env(
        {
          "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
          "FAKE_OPENMANUS_SECRET" => "must-not-reach-subprocess"
        },
        "agent-run", "--task", "latest", "--agent", "openmanus", "--dry-run", "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal true, payload["dry_run"]
      assert_equal "openmanus", payload.dig("agent_run", "agent")
      assert_equal "implementation-local-no-network", payload.dig("agent_run", "permission_profile")
      assert_equal "planned", payload.dig("agent_run", "status")
      assert_equal "rerun aiweb agent-run --task latest --agent openmanus --sandbox docker --approved to execute the local openmanus patch run in an aiweb-managed sandbox", payload["next_action"]
      assert_includes payload.fetch("planned_changes"), ".ai-web/runs/#{payload.dig("agent_run", "run_id")}/openmanus-context.json"
      assert_equal ["src/components/Hero.astro"], payload.dig("agent_run", "openmanus", "context", "allowed_source_paths")
      assert_equal "missing", payload.dig("agent_run", "openmanus", "context", "sandbox_mode")
      assert_equal true, payload.dig("agent_run", "openmanus", "context", "sandbox_required")
      assert_no_agent_run_side_effects(before_entries: before_entries, before_state: before_state)
      assert_equal before_source, File.read("src/components/Hero.astro"), "openmanus dry-run must not patch source"
      refute File.exist?(marker), "openmanus dry-run must not execute subprocess"
      refute_includes stdout, "must-not-reach-subprocess"
    end
  end

  def test_agent_run_diff_validator_rejects_unsafe_hunk_structure
    in_tmp do
      project = Aiweb::Project.new(Dir.pwd)
      diff = <<~PATCH
        diff --git a/src/components/Hero.astro b/.env
        old mode 100644
        new mode 100755
        --- a/src/components/Hero.astro
        +++ b/.env
        @@ malformed hunk
        +SECRET=leak
      PATCH

      blockers = project.send(:agent_run_validate_source_diff, diff, ["src/components/Hero.astro"])
      message = blockers.join("\n")
      assert_match(/outside allowed source paths|unsafe path/i, message)
      assert_match(/file mode changes/i, message)
      assert_match(/malformed hunk/i, message)
    end
  end

  def test_openmanus_sandbox_validation_rejects_unsafe_command_shape
    in_tmp do
      json_cmd("init")
      workspace = File.join(Dir.pwd, ".ai-web", "tmp", "openmanus", "validation")
      FileUtils.mkdir_p(workspace)
      unsafe = [
        "docker", "run", "--rm", "-i",
        "--network", "bridge",
        "--read-only",
        "--cap-drop", "ALL",
        "--security-opt", "no-new-privileges",
        "-v", "#{Dir.pwd}:/workspace:rw",
        "-w", "/workspace",
        "-e", "OPENAI_API_KEY",
        "openmanus:latest",
        "openmanus"
      ]

      blockers = Aiweb::Project.new(Dir.pwd).send(
        :sandbox_runtime_container_command_blockers,
        unsafe,
        sandbox: "docker",
        workspace_dir: workspace,
        required_env: { "AIWEB_NETWORK_ALLOWED" => "0" },
        label: "openmanus sandbox"
      )
      joined = blockers.join("\n")

      assert_match(/network.*none/i, joined)
      assert_match(/pids-limit/i, joined)
      assert_match(/memory/i, joined)
      assert_match(/cpus/i, joined)
      assert_match(/non-root numeric user/i, joined)
      assert_match(/staging workspace|project root|mount/i, joined)
      assert_match(/env passthrough|OPENAI_API_KEY/i, joined)
    end
  end

  def test_agent_run_source_patch_requires_selected_design_gate_before_planning
    in_tmp do |dir|
      json_cmd("init", "--profile", "D")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<section data-aiweb-id=\"hero\">Draft</section>\n")
      File.write(".ai-web/DESIGN.md", "# Agent Run Design System\n\nUse source-safe patching.\n")
      FileUtils.mkdir_p(".ai-web/tasks")
      task_path = ".ai-web/tasks/agent-run-latest.md"
      File.write(task_path, <<~MD)
        # Task Packet ??implementation

        ## Goal
        Patch the visible hero.

        ## Inputs
        - `.ai-web/DESIGN.md`
        - `src/components/Hero.astro`

        ## Constraints
        - Do not read `.env` or `.env.*`
        - Keep changes local and reversible

        ## Machine Constraints
        shell_allowed: false
        network_allowed: false
        env_access_allowed: false
        requires_selected_design: true
        allowed_source_paths:
        - src/components/Hero.astro
      MD
      state = load_state
      state["implementation"] ||= {}
      state["implementation"]["current_task"] = task_path
      write_state(state)

      marker = File.join(dir, "codex-was-run")
      bin_dir = write_fake_codex_tooling(dir, marker_path: marker)
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "agent-run", "--task", "latest", "--agent", "codex", "--dry-run", "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "blocked", payload.dig("agent_run", "status")
      assert_match(/selected design candidate/i, [payload["blocking_issues"], payload.dig("agent_run", "blocking_issues")].flatten.compact.join("\n"))
      assert_no_agent_run_side_effects(before_entries: before_entries, before_state: before_state)
      refute File.exist?(marker), "selected-design-gated dry-run must not execute codex"
    end
  end

  def test_agent_run_source_patch_blocks_when_selected_design_artifact_is_missing
    in_tmp do |dir|
      json_cmd("init", "--profile", "D")
      FileUtils.mkdir_p("src/components")
      File.write("src/components/Hero.astro", "<section data-aiweb-id=\"hero\">Draft</section>\n")
      File.write(".ai-web/DESIGN.md", "# Agent Run Design System\n\nUse source-safe patching.\n")
      FileUtils.mkdir_p(".ai-web/tasks")
      task_path = ".ai-web/tasks/agent-run-latest.md"
      File.write(task_path, <<~MD)
        # Task Packet ??implementation

        ## Goal
        Patch the visible hero.

        ## Inputs
        - `.ai-web/DESIGN.md`
        - `src/components/Hero.astro`

        ## Constraints
        - Do not read `.env` or `.env.*`
        - Keep changes local and reversible

        ## Machine Constraints
        shell_allowed: false
        network_allowed: false
        env_access_allowed: false
        requires_selected_design: true
        allowed_source_paths:
        - src/components/Hero.astro
      MD
      state = load_state
      state["implementation"] ||= {}
      state["implementation"]["current_task"] = task_path
      state["design_candidates"] ||= {}
      state["design_candidates"]["selected_candidate"] = "candidate-02"
      state["design_candidates"]["candidates"] = [{ "id" => "candidate-02", "path" => ".ai-web/design-candidates/candidate-02.html" }]
      write_state(state)

      marker = File.join(dir, "codex-was-run")
      bin_dir = write_fake_codex_tooling(dir, marker_path: marker)

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "agent-run", "--task", "latest", "--agent", "codex", "--dry-run", "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "blocked", payload.dig("agent_run", "status")
      assert_match(/selected design artifact/i, [payload["blocking_issues"], payload.dig("agent_run", "blocking_issues")].flatten.compact.join("\n"))
      refute File.exist?(marker), "missing selected design artifact must block before codex execution"
    end
  end

  def test_agent_run_dry_run_context_includes_selected_design_files
    in_tmp do |dir|
      task_markdown = <<~MD
        # Task Packet ??repair

        Task ID: agent-run-latest
        Phase: phase-7
        Created at: 2026-05-03T00:00:00Z

        ## Goal
        Improve the hero copy using a local source patch.

        ## Inputs
        - `.ai-web/state.yaml`
        - `.ai-web/DESIGN.md`
        - `.ai-web/component-map.json`
        - `src/components/Hero.astro`

        ## Constraints
        - Do not read `.env` or `.env.*`
        - Keep changes local and reversible

        ## Machine Constraints
        shell_allowed: false
        network_allowed: false
        env_access_allowed: false
        requires_selected_design: true
        allowed_source_paths:
        - src/components/Hero.astro
      MD
      prepare_agent_run_fixture(task_markdown: task_markdown)
      bin_dir = write_fake_codex_tooling(dir)

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "agent-run", "--task", "latest", "--agent", "codex", "--dry-run", "--json"
      )
      payload = JSON.parse(stdout)
      selected_files = payload.dig("agent_run", "context", "selected_design_files")

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal "candidate-02", payload.dig("agent_run", "context", "selected_candidate")
      assert_kind_of Array, selected_files
      assert selected_files.any? { |file| file["path"] == ".ai-web/design-candidates/selected.md" }
      assert selected_files.any? { |file| file["path"] == ".ai-web/design-candidates/candidate-02.html" }
    end
  end

  def test_agent_run_blocks_malformed_task_packet_schema
    in_tmp do
      prepare_profile_d_scaffold_flow
      json_cmd("component-map")
      FileUtils.mkdir_p(".ai-web/tasks")
      task_path = ".ai-web/tasks/agent-run-malformed.md"
      File.write(task_path, <<~MD)
        # Task Packet ??repair

        ## Goal
        Patch the hero.

        ## Inputs
        - `src/components/Hero.astro`
      MD
      state = load_state
      state["implementation"]["current_task"] = task_path
      write_state(state)

      stdout, stderr, code = run_aiweb("agent-run", "--task", "latest", "--agent", "codex", "--dry-run", "--json")
      payload = JSON.parse(stdout)

      assert_equal 5, code
      assert_equal "", stderr
      assert_equal "blocked", payload.dig("agent_run", "status")
      assert_match(/schema missing|machine constraint|DESIGN\.md|\.env/i, payload.dig("agent_run", "blocking_issues").join("\n"))
    end
  end

  def test_agent_run_without_approval_blocks_without_writes_or_process_execution
    in_tmp do |dir|
      task_markdown = <<~MD
        # Task Packet ??repair

        Task ID: agent-run-latest
        Phase: phase-7
        Created at: 2026-05-03T00:00:00Z

        ## Goal
        Improve the hero copy using a local source patch.

        ## Inputs
        - `.ai-web/state.yaml`
        - `.ai-web/DESIGN.md`
        - `.ai-web/component-map.json`
        - `src/components/Hero.astro`

        ## Constraints
        - Do not read `.env` or `.env.*`
        - Keep changes local and reversible

        ## Machine Constraints
        shell_allowed: false
        network_allowed: false
        env_access_allowed: false
        requires_selected_design: true
        allowed_source_paths:
        - src/components/Hero.astro
      MD
      prepare_agent_run_fixture(task_markdown: task_markdown)
      marker = File.join(dir, "codex-was-run")
      bin_dir = write_fake_codex_tooling(dir, marker_path: marker, patch_path: File.join(dir, "src/components/Hero.astro"))
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")
      before_source = File.read("src/components/Hero.astro")

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "agent-run", "--task", "latest", "--agent", "codex", "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 5, code
      assert_equal "", stderr
      assert_equal "blocked", payload.dig("agent_run", "status")
      assert_match(/approved|approval/i, [payload.dig("error", "message"), payload["blocking_issues"], payload.dig("agent_run", "blocking_issues")].flatten.compact.join("\n"))
      assert_no_agent_run_side_effects(before_entries: before_entries, before_state: before_state)
      assert_equal before_source, File.read("src/components/Hero.astro"), "blocked agent-run must not patch source"
      refute File.exist?(marker), "blocked agent-run must not execute codex"
      refute_includes stdout, "fake codex stdout"
      refute_includes stdout, "fake codex stderr"
    end
  end

  def test_agent_run_approved_fake_codex_success_records_logs_diff_and_safe_state
    in_tmp do |dir|
      secret = "SECRET=pr22-agent-run-do-not-leak"
      task_markdown = <<~MD
        # Task Packet ??repair

        Task ID: agent-run-latest
        Phase: phase-7
        Created at: 2026-05-03T00:00:00Z

        ## Goal
        Improve the hero copy using a local source patch.

        ## Inputs
        - `.ai-web/state.yaml`
        - `.ai-web/DESIGN.md`
        - `.ai-web/component-map.json`
        - `src/components/Hero.astro`

        ## Constraints
        - Do not read `.env` or `.env.*`
        - Keep changes local and reversible

        ## Machine Constraints
        shell_allowed: false
        network_allowed: false
        env_access_allowed: false
        requires_selected_design: true
        allowed_source_paths:
        - src/components/Hero.astro

        ## Acceptance Criteria
        - Source patch evidence is recorded.
        - Logs, metadata, and diff evidence are written.
      MD
      prepare_agent_run_fixture(task_markdown: task_markdown, secret: secret)
      bin_dir = write_fake_codex_tooling(
        dir,
        patch_path: File.join(dir, "src/components/Hero.astro"),
        stdout_text: "fake codex approved stdout",
        stderr_text: "fake codex approved stderr"
      )
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")
      before_source = File.read("src/components/Hero.astro")
      env_size = File.size(".env")
      env_mtime = File.mtime(".env")

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "agent-run", "--task", "latest", "--agent", "codex", "--approved", "--json"
      )
      payload = JSON.parse(stdout)
      run_dir = Dir.glob(".ai-web/runs/agent-run-*").sort.last
      diff_path = Dir.glob(".ai-web/diffs/agent-run-*.patch").sort.last
      state = load_state

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal false, payload.dig("agent_run", "dry_run")
      assert_equal "passed", payload.dig("agent_run", "status")
      assert_equal "ran agent patch", payload["action_taken"]
      assert run_dir, "approved agent-run must write a run directory"
      assert diff_path, "approved agent-run must write a diff patch"
      assert File.exist?(File.join(run_dir, "agent-run.json")), "approved agent-run must write metadata JSON"
      assert_equal "fake codex approved stdout\n", File.read(File.join(run_dir, "stdout.log"))
      assert_equal "fake codex approved stderr\n", File.read(File.join(run_dir, "stderr.log"))
      assert_match(/patched by fake codex/, File.read("src/components/Hero.astro"))
      refute_equal before_source, File.read("src/components/Hero.astro"), "approved agent-run must patch source"
      after_entries = project_entries
      assert_operator after_entries.size, :>, before_entries.size, "approved agent-run must write artifacts"
      assert after_entries.any? { |path| path.start_with?(".ai-web/runs/agent-run-") }, "approved agent-run must write run artifacts"
      assert after_entries.any? { |path| path.start_with?(".ai-web/diffs/agent-run-") }, "approved agent-run must write diff artifacts"
      assert_equal env_size, File.size(".env")
      assert_equal env_mtime, File.mtime(".env")
      refute_includes File.read(diff_path), secret
      assert_agent_run_artifacts_do_not_leak_secret(secret, File.join(run_dir, "agent-run.json"), File.join(run_dir, "stdout.log"), File.join(run_dir, "stderr.log"), diff_path)
      refute_nil state.dig("implementation", "latest_agent_run")
      assert_match(%r{\A\.ai-web/runs/agent-run-.+/agent-run\.json\z}, state.dig("implementation", "latest_agent_run"))
      refute_nil state.dig("implementation", "last_diff")
      assert_match(%r{\A\.ai-web/diffs/agent-run-.+\.patch\z}, state.dig("implementation", "last_diff"))
    end
  end

  def test_agent_run_codex_uses_clean_environment
    in_tmp do |dir|
      prepare_agent_run_fixture(task_markdown: agent_run_safe_task_markdown)
      bin_dir = write_fake_codex_env_guard_tooling(dir)
      env = {
        "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
        "OPENAI_API_KEY" => "must-not-reach-codex",
        "FAKE_CODEX_SECRET" => "must-not-reach-codex"
      }

      stdout, stderr, code = run_aiweb_env(env, "agent-run", "--task", "latest", "--agent", "codex", "--approved", "--json")
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal "passed", payload.dig("agent_run", "status")
      assert_match(/patched by env guard codex/, File.read("src/components/Hero.astro"))
      refute_includes stdout, "must-not-reach-codex"
    end
  end

  def test_agent_run_approved_fake_openmanus_uses_managed_container_sandbox_contract
    in_tmp do |dir|
      secret = "SECRET=pr-openmanus-do-not-leak"
      prepare_agent_run_fixture(task_markdown: agent_run_safe_task_markdown, secret: secret)
      bin_dir = write_fake_openmanus_tooling(dir)
      before_entries = project_entries
      before_source = File.read("src/components/Hero.astro")
      env_size = File.size(".env")
      env_mtime = File.mtime(".env")

      stdout, stderr, code = run_aiweb_env(
        {
          "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
          "OPENAI_API_KEY" => "must-not-reach-openmanus",
          "FAKE_OPENMANUS_SECRET" => "must-not-reach-openmanus"
        },
        "agent-run", "--task", "latest", "--agent", "openmanus", "--sandbox", "docker", "--approved", "--json"
      )
      payload = JSON.parse(stdout)
      run_dir = Dir.glob(".ai-web/runs/agent-run-*").sort.last
      diff_path = Dir.glob(".ai-web/diffs/agent-run-*.patch").sort.last
      state = load_state

      assert_equal 0, code, stdout
      assert_equal "", stderr
      assert_equal "openmanus", payload.dig("agent_run", "agent")
      assert_equal "passed", payload.dig("agent_run", "status")
      assert_equal "ran openmanus patch", payload["action_taken"]
      assert_equal "implementation-local-no-network", payload.dig("agent_run", "permission_profile")
      assert_equal "docker", payload.dig("agent_run", "openmanus", "context", "sandbox_mode")
      command = payload.dig("agent_run", "command")
      assert_match(/docker run/, command)
      assert_match(/--network none/, command)
      assert_match(/--read-only/, command)
      assert_match(/--cap-drop ALL/, command)
      assert_match(/--user 1000:1000/, command)
      assert_match(%r{:/workspace:rw}, command)
      assert_match(%r{PATH=/workspace/_aiweb/tool-broker-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin}, command)
      assert_equal ["src/components/Hero.astro"], payload.dig("agent_run", "changed_source_files")
      assert run_dir, "approved openmanus run must write a run directory"
      %w[openmanus-context.json openmanus-prompt.md openmanus-validator.json openmanus-result.json network.log browser-requests.log denied-access.log tool-broker-events.jsonl].each do |name|
        assert File.file?(File.join(run_dir, name)), "expected #{name} evidence"
      end
      assert_equal "_aiweb/tool-broker-bin", payload.dig("agent_run", "openmanus", "context", "tool_broker", "bin_path")
      assert_equal true, payload.dig("agent_run", "openmanus", "context", "tool_broker", "path_prepend_required")
      assert_equal ".ai-web/runs/#{File.basename(run_dir)}/tool-broker-events.jsonl", payload.dig("agent_run", "openmanus", "context", "tool_broker", "host_evidence_path")
      assert_equal ".ai-web/runs/#{File.basename(run_dir)}/tool-broker-events.jsonl", payload.dig("agent_run", "openmanus", "evidence", "tool_broker_log")
      workspace = payload.dig("agent_run", "openmanus", "context", "workspace_root")
      assert File.file?(File.join(workspace, "_aiweb", "tool-broker-bin", "npm"))
      assert_equal "fake openmanus stdout\n", File.read(File.join(run_dir, "stdout.log"))
      assert_equal "fake openmanus stderr\n", File.read(File.join(run_dir, "stderr.log"))
      assert_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
      refute_equal before_source, File.read("src/components/Hero.astro"), "approved openmanus run must patch source"
      assert_operator project_entries.size, :>, before_entries.size, "approved openmanus run must write evidence artifacts"
      assert_equal env_size, File.size(".env")
      assert_equal env_mtime, File.mtime(".env")
      refute_includes stdout, secret
      refute_includes stdout, "must-not-reach-openmanus"
      assert_agent_run_artifacts_do_not_leak_secret(secret, File.join(run_dir, "agent-run.json"), File.join(run_dir, "stdout.log"), File.join(run_dir, "stderr.log"), diff_path, File.join(run_dir, "openmanus-context.json"), File.join(run_dir, "openmanus-result.json"))
      result_payload = JSON.parse(File.read(File.join(run_dir, "openmanus-result.json")))
      assert_equal "openmanus", result_payload.fetch("agent")
      assert_equal "implementation-local-no-network", result_payload.fetch("permission_profile")
      assert_equal "docker", result_payload.fetch("openmanus_report").fetch("sandbox_mode") if result_payload.fetch("openmanus_report").key?("sandbox_mode")
      assert_equal ".ai-web/runs/#{File.basename(run_dir)}/openmanus-validator.json", result_payload.dig("evidence", "validator_result")
      assert_match(%r{\A\.ai-web/runs/agent-run-.+/agent-run\.json\z}, state.dig("implementation", "latest_agent_run"))
    end
  end

  def test_agent_run_openmanus_staged_tool_broker_blocks_package_install_before_copyback
    in_tmp do |dir|
      prepare_agent_run_fixture(task_markdown: agent_run_safe_task_markdown)
      bin_dir = write_fake_openmanus_tooling(dir, broker_blocked_action: "package_install")
      before_source = File.read("src/components/Hero.astro")

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "agent-run", "--task", "latest", "--agent", "openmanus", "--sandbox", "docker", "--approved", "--json"
      )
      payload = JSON.parse(stdout)
      run_dir = Dir.glob(".ai-web/runs/agent-run-*").sort.last
      workspace = Dir.glob(".ai-web/tmp/openmanus/agent-run-*").sort.last

      refute_equal 0, code
      assert_equal "", stderr
      assert_equal "failed", payload.dig("agent_run", "status")
      assert_equal before_source, File.read("src/components/Hero.astro"), "broker-blocked OpenManus changes must not copy back"
      assert File.file?(File.join(workspace, "_aiweb", "tool-broker-bin", "npm"))
      broker_log = File.read(File.join(run_dir, "tool-broker-events.jsonl"))
      denied_log = File.read(File.join(run_dir, "denied-access.log"))
      assert_includes broker_log, "package_install"
      assert_includes broker_log, "tool.blocked"
      assert_match(/tool broker blocked prohibited staged action/i, denied_log)
      assert_match(/package_install:npm/i, denied_log)
      refute_match(/patched by fake openmanus/, File.read("src/components/Hero.astro"))
    end
  end

  def test_agent_run_openmanus_approved_requires_aiweb_managed_sandbox
    in_tmp do |dir|
      prepare_agent_run_fixture(task_markdown: agent_run_safe_task_markdown)
      bin_dir = write_fake_openmanus_tooling(dir)
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")
      before_source = File.read("src/components/Hero.astro")

      stdout, stderr, code = run_aiweb_env(
        {
          "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
          "AIWEB_OPENMANUS_SANDBOX" => "external"
        },
        "agent-run", "--task", "latest", "--agent", "openmanus", "--approved", "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 5, code
      assert_equal "", stderr
      assert_equal "blocked", payload.dig("agent_run", "status")
      assert_match(/--sandbox docker|--sandbox podman|aiweb can construct/i, payload.dig("agent_run", "blocking_issues").join("\n"))
      assert_equal "missing", payload.dig("agent_run", "openmanus", "context", "sandbox_mode")
      assert_no_agent_run_side_effects(before_entries: before_entries, before_state: before_state)
      assert_equal before_source, File.read("src/components/Hero.astro"), "blocked openmanus run must not patch source"
    end
  end

  def test_agent_run_openmanus_approved_requires_prepared_local_image
    in_tmp do |dir|
      prepare_agent_run_fixture(task_markdown: agent_run_safe_task_markdown)
      bin_dir = write_fake_openmanus_tooling(dir)
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")
      before_source = File.read("src/components/Hero.astro")

      stdout, stderr, code = run_aiweb_env(
        {
          "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
          "AIWEB_OPENMANUS_IMAGE" => "missing-openmanus:latest"
        },
        "agent-run", "--task", "latest", "--agent", "openmanus", "--sandbox", "docker", "--approved", "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 5, code
      assert_equal "", stderr
      assert_equal "blocked", payload.dig("agent_run", "status")
      assert_match(/image is missing locally|openmanus:latest/i, payload.dig("agent_run", "blocking_issues").join("\n"))
      assert_no_agent_run_side_effects(before_entries: before_entries, before_state: before_state)
      assert_equal before_source, File.read("src/components/Hero.astro"), "blocked openmanus image preflight must not patch source"
    end
  end

  def test_engine_run_openmanus_blocks_when_sandbox_self_attestation_fails
    in_tmp do |dir|
      json_cmd("init")
      FileUtils.mkdir_p("src/components")
      source = "src/components/Hero.astro"
      File.write(source, "<h1>Before</h1>\n")
      FileUtils.mkdir_p(".ai-web")
      File.write(".ai-web/fail-sandbox-preflight-probe", "1\n")
      bin_dir = write_fake_openmanus_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      payload, code = json_cmd_with_env(env, "engine-run", "--goal", "patch hero", "--agent", "openmanus", "--sandbox", "docker", "--approved")

      refute_equal 0, code
      assert_equal "blocked", payload.dig("engine_run", "status")
      assert_equal "failed", payload.dig("engine_run", "sandbox_preflight", "status")
      assert_equal "failed", payload.dig("engine_run", "sandbox_preflight", "inside_container_probe", "status")
      assert_equal "failed", payload.dig("engine_run", "sandbox_preflight", "security_attestation", "status")
      assert_match(/self-attestation|egress|container id|effective user/i, payload.dig("engine_run", "blocking_issues").join("\n"))
      graph_nodes = payload.dig("engine_run", "run_graph", "nodes").to_h { |node| [node.fetch("node_id"), node] }
      assert_equal "failed", graph_nodes.fetch("preflight").fetch("state")
      assert_equal "preflight", payload.dig("engine_run", "run_graph", "cursor", "node_id")
      assert_match(%r{\A\.ai-web/runs/.+/artifacts/run-memory\.json\z}, payload.dig("engine_run", "run_memory_path"))
      assert_match(%r{\A\.ai-web/runs/.+/artifacts/authz-enforcement\.json\z}, payload.dig("engine_run", "authz_enforcement_path"))
      assert_match(%r{\A\.ai-web/runs/.+/artifacts/worker-adapter-registry\.json\z}, payload.dig("engine_run", "worker_adapter_registry_path"))
      assert_equal "ready", payload.dig("engine_run", "run_memory", "status")
      assert_equal true, payload.dig("engine_run", "authz_enforcement", "run_id_is_not_authority")
      assert_equal "worker-adapter-v1", payload.dig("engine_run", "worker_adapter_registry", "protocol_version")
      assert_equal payload.dig("engine_run", "run_memory_path"), payload.dig("engine_run", "checkpoint", "artifact_hashes", "run_memory", "path")
      assert_equal payload.dig("engine_run", "authz_enforcement_path"), payload.dig("engine_run", "checkpoint", "artifact_hashes", "authz_enforcement", "path")
      assert_equal payload.dig("engine_run", "worker_adapter_registry_path"), payload.dig("engine_run", "checkpoint", "artifact_hashes", "worker_adapter_registry", "path")
      refute_match(/patched by fake openmanus/, File.read(source))
      event_types = File.readlines(payload.dig("engine_run", "events_path")).map { |line| JSON.parse(line).fetch("type") }
      assert_includes event_types, "sandbox.preflight.started"
      assert_includes event_types, "sandbox.preflight.finished"
      refute_includes event_types, "step.started"
    end
  end

  def test_agent_run_openmanus_sandbox_validator_rejects_unsafe_container_shape
    in_tmp do |dir|
      project = Aiweb::Project.new(Dir.pwd)
      workspace_dir = File.join(dir, ".ai-web", "tmp", "openmanus", "agent-run-20260512T000000Z")
      unsafe = [
        "docker", "run", "--rm",
        "-v", "#{dir}:/workspace:rw",
        "openmanus:latest",
        "openmanus"
      ]

      blockers = project.send(:agent_run_openmanus_sandbox_command_blockers, unsafe, sandbox: "docker", workspace_dir: workspace_dir)
      message = blockers.join("\n")
      assert_match(/--network none/, message)
      assert_match(/read-only/, message)
      assert_match(/drop all capabilities/, message)
      assert_match(/staging workspace/, message)
    end
  end

  def test_agent_run_openmanus_rejects_root_mutations_outside_isolated_workspace
    in_tmp do |dir|
      prepare_agent_run_fixture(task_markdown: agent_run_safe_task_markdown)
      root_mutation_path = File.join(dir, "src/pages/index.astro")
      bin_dir = write_fake_openmanus_tooling(dir, mutate_root_path: root_mutation_path)
      before_hero = File.read("src/components/Hero.astro")

      stdout, stderr, code = run_aiweb_env(
        {
          "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
        },
        "agent-run", "--task", "latest", "--agent", "openmanus", "--sandbox", "docker", "--approved", "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "failed", payload.dig("agent_run", "status")
      assert_match(/outside the isolated workspace/i, payload.dig("agent_run", "blocking_issues").join("\n"))
      assert_includes payload.dig("agent_run", "blocking_issues").join("\n"), "src/pages/index.astro"
      assert_equal before_hero, File.read("src/components/Hero.astro"), "openmanus workspace patch must not be applied after root mutation"
      assert_match(/root mutation by fake openmanus/, File.read(root_mutation_path))
    end
  end

  def test_agent_run_targeted_visual_edit_uses_selected_source_only_and_blocks_full_page_regeneration
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      map_payload, map_code = json_cmd("component-map")
      assert_equal 0, map_code
      assert_includes component_map_ids(map_payload.fetch("component_map")), "component.hero.copy"
      edit_payload, edit_code = json_cmd("visual-edit", "--target", "component.hero.copy", "--prompt", "Refine only the mapped hero component copy")
      assert_equal 0, edit_code
      task_path = edit_payload.fetch("changed_files").find { |path| path.match?(%r{\A\.ai-web/tasks/visual-edit-.*\.md\z}) }
      state = load_state
      state["implementation"]["current_task"] = task_path
      write_state(state)

      prompt_path = File.join(dir, ".ai-web", "runs", "captured-codex-prompt.txt")
      bin_dir = write_fake_codex_tooling(dir, patch_path: File.join(dir, "src/components/Hero.astro"), prompt_path: prompt_path)
      FileUtils.mkdir_p(File.dirname(prompt_path))
      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "agent-run", "--task", "latest", "--agent", "codex", "--approved", "--json"
      )
      payload = JSON.parse(stdout)
      prompt = File.read(prompt_path)

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal "passed", payload.dig("agent_run", "status")
      assert_equal ["src/components/Hero.astro"], payload.dig("agent_run", "source_paths")
      assert_equal true, payload.dig("agent_run", "context", "targeted_edit")
      assert_equal ["src/components/Hero.astro"], payload.dig("agent_run", "context", "target_allowlist", "source_paths")
      assert_equal ["src/components/Hero.astro"], payload.dig("agent_run", "changed_source_files")
      assert_includes prompt, "Targeted visual edit allowlist"
      assert_includes prompt, "Do not regenerate the full page"
      assert_includes prompt, "Patch only the strict source_paths"
      assert_includes prompt, "## src/components/Hero.astro"
      refute_includes prompt, "## src/pages/index.astro"
    end
  end

  def test_agent_run_approved_fake_codex_failure_records_failure_and_logs
    in_tmp do |dir|
      task_markdown = <<~MD
        # Task Packet ??repair

        Task ID: agent-run-latest
        Phase: phase-7
        Created at: 2026-05-03T00:00:00Z

        ## Goal
        Improve the hero copy using a local source patch.

        ## Inputs
        - `.ai-web/state.yaml`
        - `.ai-web/DESIGN.md`
        - `.ai-web/component-map.json`
        - `src/components/Hero.astro`

        ## Constraints
        - Do not read `.env` or `.env.*`
        - Keep changes local and reversible

        ## Machine Constraints
        shell_allowed: false
        network_allowed: false
        env_access_allowed: false
        requires_selected_design: true
        allowed_source_paths:
        - src/components/Hero.astro
      MD
      prepare_agent_run_fixture(task_markdown: task_markdown)
      bin_dir = write_fake_codex_tooling(
        dir,
        stdout_text: "fake codex failure stdout",
        stderr_text: "fake codex failure stderr",
        exit_status: 23
      )

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "agent-run", "--task", "latest", "--agent", "codex", "--approved", "--json"
      )
      payload = JSON.parse(stdout)
      run_dir = Dir.glob(".ai-web/runs/agent-run-*").sort.last
      state = load_state

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "failed", payload.dig("agent_run", "status")
      assert_match(/codex exited with status 23/i, [payload.dig("error", "message"), payload["blocking_issues"], payload.dig("agent_run", "blocking_issues")].flatten.compact.join("\n"))
      assert run_dir, "failed agent-run must still write a run directory"
      assert_equal "fake codex failure stdout\n", File.read(File.join(run_dir, "stdout.log"))
      assert_equal "fake codex failure stderr\n", File.read(File.join(run_dir, "stderr.log"))
      refute_nil state.dig("implementation", "latest_agent_run")
    end
  end

  def test_agent_run_rejects_env_paths_without_leaking_secrets_or_writing
    in_tmp do
      prepare_profile_d_scaffold_flow
      json_cmd("component-map")
      secret = "SECRET=pr22-env-guard-do-not-leak"
      File.write(".env", "#{secret}\n")
      FileUtils.mkdir_p(".ai-web/tasks")
      malicious_task_path = ".ai-web/tasks/agent-run-malicious.md"
      File.write(
        malicious_task_path,
        <<~MD
          # Task Packet ??repair

          Task ID: agent-run-malicious
          Phase: phase-7
          Created at: 2026-05-03T00:00:00Z

          ## Goal
          Refuse unsafe paths.

          ## Inputs
          - `.ai-web/state.yaml`
          - `.env.local`
          - `src/components/Hero.astro`
        MD
      )
      state = load_state
      state["implementation"]["current_task"] = malicious_task_path
      write_state(state)
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")
      env_size = File.size(".env")
      env_mtime = File.mtime(".env")

      stdout, stderr, code = run_aiweb("agent-run", "--task", "latest", "--agent", "codex", "--approved", "--json")
      payload = JSON.parse(stdout)

      assert_equal 5, code
      assert_equal "", stderr
      assert_equal "blocked", payload.dig("agent_run", "status")
      assert_match(/\.env|unsafe|refus/i, [payload.dig("error", "message"), payload["blocking_issues"], payload.dig("agent_run", "blocking_issues")].flatten.compact.join("\n"))
      assert_no_agent_run_side_effects(before_entries: before_entries, before_state: before_state, env_size: env_size, env_mtime: env_mtime)
      refute_includes stdout, secret
    end
  end

  def test_agent_run_blocks_visual_edit_target_allowlist_with_unsafe_env_source
    in_tmp do
      prepare_profile_d_scaffold_flow
      json_cmd("component-map")
      secret = "SECRET=pr24-target-allowlist-do-not-leak"
      File.write(".env", "#{secret}\n")
      FileUtils.mkdir_p(".ai-web/tasks")
      task_path = ".ai-web/tasks/visual-edit-unsafe.md"
      File.write(
        task_path,
        <<~MD
          # Visual Edit Handoff

          ## Target Source Allowlist
          ```json
          {
            "type": "visual_edit_target_allowlist",
            "strict": true,
            "data_aiweb_ids": ["component.hero.copy"],
            "source_paths": [".env"],
            "full_page_regeneration_allowed": false
          }
          ```
        MD
      )
      state = load_state
      state["implementation"]["current_task"] = task_path
      write_state(state)
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")
      env_size = File.size(".env")
      env_mtime = File.mtime(".env")

      stdout, stderr, code = run_aiweb("agent-run", "--task", "latest", "--agent", "codex", "--approved", "--json")
      payload = JSON.parse(stdout)

      assert_equal 5, code
      assert_equal "", stderr
      assert_equal "blocked", payload.dig("agent_run", "status")
      assert_match(/allowlist|\.env|unsafe|source path/i, [payload.dig("error", "message"), payload["blocking_issues"], payload.dig("agent_run", "blocking_issues")].flatten.compact.join("\n"))
      assert_no_agent_run_side_effects(before_entries: before_entries, before_state: before_state, env_size: env_size, env_mtime: env_mtime)
      refute_includes stdout, secret
    end
  end

  def test_agent_run_rejects_secret_looking_paths_and_shell_requests_before_codex
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      json_cmd("component-map")
      FileUtils.mkdir_p(".ai-web/tasks")
      task_path = ".ai-web/tasks/agent-run-secret-shell.md"
      File.write(
        task_path,
        <<~MD
          # Task Packet ??repair

          Task ID: agent-run-secret-shell
          Phase: phase-7
          Created at: 2026-05-03T00:00:00Z

          ## Goal
          Patch the hero after reading config/credentials.yml and running `curl https://example.com`.

          ## Inputs
          - `.ai-web/state.yaml`
          - `.ai-web/DESIGN.md`
          - `.ai-web/component-map.json`
          - `src/components/Hero.astro`
          - `config/credentials.yml`

          ## Constraints
          - Do not read `.env` or `.env.*`
          - Keep changes local and reversible

          ## Machine Constraints
          shell_allowed: false
          network_allowed: false
          env_access_allowed: false
          requires_selected_design: true
          allowed_source_paths:
          - src/components/Hero.astro
        MD
      )
      state = load_state
      state["implementation"]["current_task"] = task_path
      write_state(state)
      marker = File.join(dir, "codex-was-run")
      bin_dir = write_fake_codex_tooling(dir, marker_path: marker)

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "agent-run", "--task", "latest", "--agent", "codex", "--approved", "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 5, code
      assert_equal "", stderr
      assert_equal "blocked", payload.dig("agent_run", "status")
      assert_match(/secret-looking|shell|network|command/i, payload.dig("agent_run", "blocking_issues").join("\n"))
      refute File.exist?(marker), "secret/shell policy blockers must stop before codex execution"
    end
  end

  def test_agent_run_approved_rejects_changes_outside_source_allowlist
    in_tmp do |dir|
      task_markdown = <<~MD
        # Task Packet ??repair

        Task ID: agent-run-latest
        Phase: phase-7
        Created at: 2026-05-03T00:00:00Z

        ## Goal
        Improve the hero copy using a local source patch.

        ## Inputs
        - `.ai-web/state.yaml`
        - `.ai-web/DESIGN.md`
        - `.ai-web/component-map.json`
        - `src/components/Hero.astro`

        ## Constraints
        - Do not read `.env` or `.env.*`
        - Keep changes local and reversible

        ## Machine Constraints
        shell_allowed: false
        network_allowed: false
        env_access_allowed: false
        requires_selected_design: true
        allowed_source_paths:
        - src/components/Hero.astro
      MD
      prepare_agent_run_fixture(task_markdown: task_markdown)
      marker = File.join(dir, "codex-was-run")
      bin_dir = write_fake_codex_tooling(
        dir,
        marker_path: marker,
        patch_path: File.join(dir, "src/components/Hero.astro"),
        stdout_text: "fake codex unauthorized stdout"
      )

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "agent-run", "--task", "latest", "--agent", "codex", "--approved", "--json"
      )
      payload = JSON.parse(stdout)
      run_dir = Dir.glob(".ai-web/runs/agent-run-*").sort.last

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "failed", payload.dig("agent_run", "status")
      assert_match(/outside allowed source paths/i, payload.dig("agent_run", "blocking_issues").join("\n"))
      assert_includes payload.dig("agent_run", "blocking_issues").join("\n"), "codex-was-run"
      assert File.exist?(marker), "fake codex marker proves the wrapper detected and rejected an out-of-allowlist mutation"
      assert run_dir, "rejected approved run still writes audit metadata"
      assert_equal "fake codex unauthorized stdout\n", File.read(File.join(run_dir, "stdout.log"))
    end
  end

  def test_agent_run_blocks_without_safe_target_or_task_artifact
    in_tmp do
      prepare_profile_d_scaffold_flow
      json_cmd("component-map")
      state = load_state
      state["implementation"]["current_task"] = nil
      write_state(state)
      FileUtils.rm_rf(".ai-web/tasks")
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb("agent-run", "--task", "latest", "--agent", "codex", "--approved", "--json")
      payload = JSON.parse(stdout)

      assert_equal 5, code
      assert_equal "", stderr
      assert_equal "blocked", payload.dig("agent_run", "status")
      assert_match(/task|target|latest|source/i, [payload.dig("error", "message"), payload["blocking_issues"], payload.dig("agent_run", "blocking_issues")].flatten.compact.join("\n"))
      assert_no_agent_run_side_effects(before_entries: before_entries, before_state: before_state)
    end
  end

  def test_agent_run_help_and_webbuilder_passthrough
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr
    assert_includes stdout, "agent-run --task latest --agent codex --approved"
    assert_includes stdout, "agent-run --task latest --agent codex --dry-run"
    assert_includes stdout, "agent-run --task latest --agent openmanus --sandbox docker --approved"
    assert_includes stdout, "agent-run --task latest --agent openmanus --dry-run"

    help_stdout, help_stderr, help_code = run_webbuilder("--help")
    assert_equal 0, help_code
    assert_equal "", help_stderr
    assert_match(/agent-run/, help_stdout)

    in_tmp do |dir|
      target = File.join(dir, "passthrough-agent-run")
      Dir.mkdir(target)
      Dir.chdir(target) { prepare_profile_d_scaffold_flow }
      json_cmd("--path", target, "component-map")
      FileUtils.mkdir_p(File.join(target, ".ai-web", "tasks"))
      File.write(
        File.join(target, ".ai-web", "tasks", "agent-run-latest.md"),
        <<~MD
          # Task Packet ??repair

          Task ID: agent-run-latest
          Phase: phase-7
          Created at: 2026-05-03T00:00:00Z

          ## Goal
          Improve the hero copy using a local source patch.

          ## Inputs
          - `.ai-web/state.yaml`
          - `.ai-web/DESIGN.md`
          - `.ai-web/component-map.json`
          - `src/components/Hero.astro`

          ## Constraints
          - Do not read `.env` or `.env.*`
          - Keep changes local and reversible

          ## Machine Constraints
          shell_allowed: false
          network_allowed: false
          env_access_allowed: false
          requires_selected_design: true
          allowed_source_paths:
          - src/components/Hero.astro
        MD
      )
      state_path = File.join(target, ".ai-web", "state.yaml")
      state = YAML.load_file(state_path)
      state["implementation"]["current_task"] = ".ai-web/tasks/agent-run-latest.md"
      File.write(state_path, YAML.dump(state))

      bin_dir = write_fake_codex_tooling(dir)
      web_stdout, web_stderr, web_code = run_webbuilder_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "--path", target, "agent-run", "--task", "latest", "--agent", "codex", "--dry-run", "--json"
      )
      web_payload = JSON.parse(web_stdout)
      assert_equal 0, web_code
      assert_equal "", web_stderr
      assert_equal true, web_payload["dry_run"]
      assert_equal "planned agent run", web_payload["action_taken"]
      assert Dir.glob(File.join(target, ".ai-web", "runs", "agent-run-*")).empty?, "webbuilder agent-run --dry-run must not write run artifacts"
      assert Dir.glob(File.join(target, ".ai-web", "diffs", "agent-run-*.patch")).empty?, "webbuilder agent-run --dry-run must not write diff artifacts"
      refute File.exist?(File.join(target, ".ai-web", "runs", "agent-run-was-run"))
    end
  end

  def test_verify_loop_dry_run_plans_closed_loop_without_writes_or_process_execution
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      secret = "SECRET=pr23-verify-loop-dry-run-do-not-leak"
      File.write(".env", "#{secret}\n")
      bin_dir = File.join(dir, "fake-verify-loop-bin")
      FileUtils.mkdir_p(bin_dir)
      marker = File.join(dir, "verify-loop-tool-was-run")
      write_fake_executable(bin_dir, "pnpm", "touch #{marker.shellescape}; echo should-not-run >&2; exit 99")
      write_fake_executable(bin_dir, "codex", "touch #{marker.shellescape}; echo should-not-run >&2; exit 99")
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "verify-loop", "--max-cycles", "3", "--dry-run", "--json"
      )
      payload = JSON.parse(stdout)
      loop = payload.fetch("verify_loop")
      steps = loop.fetch("steps").map { |step| step.fetch("command") || step.fetch("name") }

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal true, payload["dry_run"]
      assert_equal true, loop["dry_run"]
      assert_includes %w[planned dry_run], loop["status"]
      assert_equal 3, loop["max_cycles"]
      %w[build preview qa-playwright qa-screenshot visual-critique visual-polish agent-run].each do |expected_step|
        assert steps.any? { |step| step.to_s.include?(expected_step) }, "verify-loop dry run should plan #{expected_step}"
      end
      assert_match(%r{\A\.ai-web/runs/verify-loop-\d{8}T\d{6}Z/verify-loop\.json\z}, loop["metadata_path"])
      assert_equal before_entries, project_entries, "verify-loop --dry-run must not write artifacts, generated output, or task packets"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "verify-loop --dry-run must not mutate state"
      assert_equal "#{secret}\n", File.read(".env"), "verify-loop --dry-run must not mutate .env"
      refute File.exist?(marker), "verify-loop --dry-run must not execute pnpm or codex"
      refute Dir.exist?("dist"), "verify-loop --dry-run must not build"
      refute_includes stdout, secret
    end
  end

  def test_verify_loop_dry_run_accepts_openmanus_implementation_agent
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      bin_dir = write_fake_openmanus_tooling(dir)
      marker = File.join(dir, "verify-loop-tool-was-run")
      write_fake_executable(bin_dir, "pnpm", "touch #{marker.shellescape}; echo should-not-run >&2; exit 99")
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "verify-loop", "--max-cycles", "2", "--agent", "openmanus", "--dry-run", "--json"
      )
      payload = JSON.parse(stdout)
      loop = payload.fetch("verify_loop")

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal "openmanus", loop["agent"]
      assert_equal true, loop["dry_run"]
      assert_includes payload["next_action"], "--agent openmanus --sandbox docker --approved"
      assert_equal before_entries, project_entries, "openmanus verify-loop dry-run must not write artifacts"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "openmanus verify-loop dry-run must not mutate state"
      refute File.exist?(marker), "openmanus verify-loop dry-run must not execute pnpm or openmanus"
    end
  end

  def test_verify_loop_rejects_excessive_max_cycles_without_writes_or_processes
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      bin_dir = File.join(dir, "fake-verify-loop-bin")
      FileUtils.mkdir_p(bin_dir)
      marker = File.join(dir, "verify-loop-tool-was-run")
      write_fake_executable(bin_dir, "pnpm", "touch #{marker.shellescape}; exit 99")
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "verify-loop", "--max-cycles", "30000", "--dry-run", "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_match(/max-cycles.*1.*10/i, payload.dig("error", "message"))
      assert_equal before_entries, project_entries, "excessive verify-loop cycle count must not write artifacts"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "excessive verify-loop cycle count must not mutate state"
      refute File.exist?(marker), "excessive verify-loop cycle count must not execute tools"
    end
  end

  def test_verify_loop_requires_approval_for_real_closed_loop_before_writes_or_processes
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      secret = "SECRET=pr23-no-approval-do-not-leak"
      File.write(".env", "#{secret}\n")
      FileUtils.mkdir_p("node_modules")
      bin_dir = File.join(dir, "fake-verify-loop-bin")
      FileUtils.mkdir_p(bin_dir)
      marker = File.join(dir, "verify-loop-tool-was-run")
      write_fake_executable(bin_dir, "pnpm", "touch #{marker.shellescape}; echo should-not-run >&2; exit 99")
      write_fake_executable(bin_dir, "codex", "touch #{marker.shellescape}; echo should-not-run >&2; exit 99")
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "verify-loop", "--max-cycles", "3", "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 5, code
      assert_equal "", stderr
      assert_equal "blocked", payload.dig("verify_loop", "status")
      assert_equal false, payload.dig("verify_loop", "dry_run")
      assert_match(/approved|approval/i, [payload.dig("error", "message"), payload["blocking_issues"], payload.dig("verify_loop", "blocking_issues")].flatten.compact.join("\n"))
      assert_equal before_entries, project_entries, "unapproved verify-loop must not write build, preview, QA, critique, task, or agent-run artifacts"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "unapproved verify-loop must not mutate state"
      assert_equal "#{secret}\n", File.read(".env"), "unapproved verify-loop must not mutate .env"
      refute File.exist?(marker), "unapproved verify-loop must not execute pnpm or codex"
      refute Dir.exist?("dist"), "unapproved verify-loop must not build"
      refute_includes stdout, secret
    end
  end

  def test_verify_loop_help_and_webbuilder_dry_run_passthrough
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr
    assert_includes stdout, "verify-loop --max-cycles 3"
    assert_includes stdout, "--max-cycles is capped at 10"
    assert_includes stdout, "run-status"
    assert_includes stdout, "run-cancel"
    assert_includes stdout, "run-resume"
    assert_includes stdout, "run-timeline"
    assert_includes stdout, "observability-summary"
    assert_match(/verify-loop: runs the local build -> preview -> QA -> critique -> task -> agent-run loop/i, stdout)

    help_stdout, help_stderr, help_code = run_webbuilder("--help")
    assert_equal 0, help_code
    assert_equal "", help_stderr
    assert_match(/verify-loop/, help_stdout)

    in_tmp do |dir|
      target = File.join(dir, "passthrough-verify-loop")
      Dir.mkdir(target)
      Dir.chdir(target) do
        prepare_profile_d_scaffold_flow
        File.write(".env", "SECRET=pr23-webbuilder-do-not-leak\n")
      end

      web_stdout, web_stderr, web_code = run_webbuilder("--path", target, "verify-loop", "--max-cycles", "2", "--dry-run", "--json")
      web_payload = JSON.parse(web_stdout)

      assert_equal 0, web_code
      assert_equal "", web_stderr
      assert_equal true, web_payload["dry_run"]
      assert_equal 2, web_payload.dig("verify_loop", "max_cycles")
      assert_includes %w[planned dry_run], web_payload.dig("verify_loop", "status")
      assert_empty Dir.glob(File.join(target, ".ai-web", "runs", "verify-loop-*")), "webbuilder verify-loop --dry-run must not write run artifacts"
      refute Dir.exist?(File.join(target, "dist")), "webbuilder verify-loop --dry-run must not build"
      refute_includes web_stdout, "pr23-webbuilder-do-not-leak"
    end
  end

  def test_run_status_is_read_only_when_no_active_run
    in_tmp do
      prepare_profile_d_scaffold_flow
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb("run-status", "--json")
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      lifecycle = payload.fetch("run_lifecycle")
      assert_equal "idle", lifecycle.fetch("status")
      assert_nil lifecycle.fetch("active_run")
      assert_equal [], payload.fetch("changed_files")
      assert_equal before_entries, project_entries, "run-status must not write lifecycle artifacts"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "run-status must not mutate state"
    end
  end

  def test_run_timeline_is_read_only_and_redacts_sensitive_metadata
    in_tmp do
      prepare_profile_d_scaffold_flow
      run_dir = File.join(".ai-web", "runs", "verify-loop-redacted")
      FileUtils.mkdir_p(run_dir)
      File.write(
        File.join(run_dir, "verify-loop.json"),
        JSON.pretty_generate(
          "schema_version" => 1,
          "run_id" => "verify-loop-redacted",
          "status" => "blocked",
          "api_token" => "SECRET-TOKEN-SHOULD-NOT-APPEAR",
          "env_path" => ".env.local",
          "blocking_issues" => ["sample blocker"]
        ) + "\n"
      )
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb("run-timeline", "--limit", "5", "--json")
      payload = JSON.parse(stdout)
      timeline = payload.fetch("run_timeline")

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal "ready", timeline.fetch("status")
      assert_equal 5, timeline.fetch("limit")
      assert_equal 1, timeline.fetch("runs").length
      assert_equal "blocked", timeline.dig("runs", 0, "status")
      assert_includes timeline.dig("runs", 0, "blocking_issues"), "sample blocker"
      refute_includes stdout, "SECRET-TOKEN-SHOULD-NOT-APPEAR"
      refute_includes stdout, ".env.local"
      assert_equal before_entries, project_entries, "run-timeline must not write artifacts"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "run-timeline must not mutate state"

      web_stdout, web_stderr, web_code = run_webbuilder("--path", Dir.pwd, "timeline", "--limit", "1", "--json")
      web_payload = JSON.parse(web_stdout)
      assert_equal 0, web_code
      assert_equal "", web_stderr
      assert_equal 1, web_payload.dig("run_timeline", "limit")
      assert_equal 1, web_payload.dig("run_timeline", "runs").length
    end
  end

  def test_observability_summary_rolls_up_latest_runs_without_writes
    in_tmp do
      prepare_profile_d_scaffold_flow
      verify_dir = File.join(".ai-web", "runs", "verify-loop-observe")
      deploy_dir = File.join(".ai-web", "runs", "deploy-observe-vercel")
      FileUtils.mkdir_p(verify_dir)
      FileUtils.mkdir_p(deploy_dir)
      verify_path = File.join(verify_dir, "verify-loop.json")
      deploy_path = File.join(deploy_dir, "deploy.json")
      File.write(
        verify_path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "run_id" => "verify-loop-observe",
          "status" => "passed",
          "cycle_count" => 1,
          "metadata_path" => verify_path,
          "blocking_issues" => []
        ) + "\n"
      )
      File.write(
        deploy_path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "run_id" => "deploy-observe-vercel",
          "status" => "failed",
          "target" => "vercel",
          "metadata_path" => deploy_path,
          "blocking_issues" => ["fake deploy failed"]
        ) + "\n"
      )
      state = load_state
      state["implementation"]["latest_verify_loop"] = verify_path
      state["implementation"]["verify_loop_status"] = "passed"
      state["implementation"]["verify_loop_cycle_count"] = 1
      state["deploy"] ||= {}
      state["deploy"]["latest_deploy"] = deploy_path
      state["deploy"]["latest_deploy_status"] = "failed"
      write_state(state)
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb("observability-summary", "--limit", "10", "--json")
      payload = JSON.parse(stdout)
      summary = payload.fetch("observability_summary")

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal "ready", summary.fetch("status")
      assert_equal 2, summary.fetch("recent_run_count")
      assert_equal 1, summary.dig("recent_status_counts", "passed")
      assert_equal 1, summary.dig("recent_status_counts", "failed")
      assert_equal "passed", summary.dig("latest_verify_loop", "status")
      assert_equal "failed", summary.dig("latest_deploy", "status")
      assert_includes summary.fetch("recent_blockers"), "fake deploy failed"
      assert_equal before_entries, project_entries, "observability-summary must not write artifacts"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "observability-summary must not mutate state"

      alias_stdout, alias_stderr, alias_code = run_aiweb("summary", "--limit", "1", "--json")
      alias_payload = JSON.parse(alias_stdout)
      assert_equal 0, alias_code
      assert_equal "", alias_stderr
      assert_equal 1, alias_payload.dig("observability_summary", "limit")
      assert_equal 1, alias_payload.dig("observability_summary", "recent_run_count")
    end
  end

  def test_run_cancel_and_resume_record_local_lifecycle_descriptors_without_process_execution
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      run_id = "verify-loop-20260506T000000Z"
      run_dir = File.join(".ai-web", "runs", run_id)
      FileUtils.mkdir_p(run_dir)
      verify_metadata_path = File.join(run_dir, "verify-loop.json")
      File.write(
        verify_metadata_path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "run_id" => run_id,
          "status" => "cancelled",
          "approved" => true,
          "dry_run" => false,
          "max_cycles" => 3,
          "cycle_count" => 1,
          "metadata_path" => verify_metadata_path,
          "blocking_issues" => ["verify-loop cancellation requested"]
        ) + "\n"
      )
      active_lock = {
        "schema_version" => 1,
        "run_id" => run_id,
        "kind" => "verify-loop",
        "status" => "running",
        "pid" => Process.pid,
        "started_at" => Time.now.utc.iso8601,
        "run_dir" => run_dir,
        "metadata_path" => verify_metadata_path,
        "command" => ["aiweb", "verify-loop", "--max-cycles", "3", "--approved"]
      }
      File.write(File.join(".ai-web", "runs", "active-run.json"), JSON.pretty_generate(active_lock) + "\n")
      marker = File.join(dir, "unexpected-process")
      bin_dir = File.join(dir, "fake-run-lifecycle-bin")
      FileUtils.mkdir_p(bin_dir)
      write_fake_executable(bin_dir, "codex", "touch #{marker.shellescape}; exit 99")
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      cancel_stdout, cancel_stderr, cancel_code = run_aiweb_env(env, "run-cancel", "--run-id", "active", "--json")
      cancel_payload = JSON.parse(cancel_stdout)

      assert_equal 0, cancel_code
      assert_equal "", cancel_stderr
      assert_equal "cancel_requested", cancel_payload.dig("run_lifecycle", "status")
      cancel_path = File.join(run_dir, "cancel-request.json")
      lifecycle_path = File.join(run_dir, "lifecycle.json")
      assert File.file?(cancel_path)
      assert File.file?(lifecycle_path)
      assert_equal "cancel_requested", JSON.parse(File.read(File.join(".ai-web", "runs", "active-run.json"))).fetch("status")
      refute File.exist?(marker), "run-cancel must not launch local agent/provider commands"

      dry_stdout, dry_stderr, dry_code = run_aiweb_env(env, "run-resume", "--run-id", run_id, "--dry-run", "--json")
      dry_payload = JSON.parse(dry_stdout)
      assert_equal 0, dry_code
      assert_equal "", dry_stderr
      assert_equal "resume_planned", dry_payload.dig("run_lifecycle", "status")
      assert_equal ["aiweb", "verify-loop", "--max-cycles", "3", "--approved"], dry_payload.dig("run_lifecycle", "resume_plan", "command")
      refute File.exist?(File.join(run_dir, "resume-plan.json")), "run-resume --dry-run must not write"

      resume_stdout, resume_stderr, resume_code = run_aiweb_env(env, "run-resume", "--run-id", run_id, "--json")
      resume_payload = JSON.parse(resume_stdout)
      assert_equal 0, resume_code
      assert_equal "", resume_stderr
      assert_equal "resume_planned", resume_payload.dig("run_lifecycle", "status")
      assert File.file?(File.join(run_dir, "resume-plan.json"))
      assert_includes resume_payload.dig("run_lifecycle", "resume_plan", "next_command"), "aiweb verify-loop --max-cycles 3 --approved"
      refute File.exist?(marker), "run-resume records a descriptor only"
    end
  end

  def test_active_run_lock_blocks_real_verify_loop_without_running_tools
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      bin_dir = write_fake_verify_loop_tooling(dir)
      marker = File.join(dir, "verify-loop-tool-was-run")
      write_fake_executable(bin_dir, "pnpm", "touch #{marker.shellescape}; exit 99")
      active_lock = {
        "schema_version" => 1,
        "run_id" => "verify-loop-active",
        "kind" => "verify-loop",
        "status" => "running",
        "pid" => Process.pid,
        "started_at" => Time.now.utc.iso8601,
        "run_dir" => ".ai-web/runs/verify-loop-active",
        "metadata_path" => ".ai-web/runs/verify-loop-active/verify-loop.json"
      }
      FileUtils.mkdir_p(File.join(".ai-web", "runs"))
      File.write(File.join(".ai-web", "runs", "active-run.json"), JSON.pretty_generate(active_lock) + "\n")
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "verify-loop", "--max-cycles", "1", "--approved", "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_match(/active run exists/i, payload.dig("error", "message"))
      assert_equal before_entries, project_entries, "active-run lock blocker must not write new verify-loop artifacts"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "active-run lock blocker must not mutate state"
      refute File.exist?(marker), "active-run lock blocker must not execute verify-loop tools"
    end
  end

  def test_verify_loop_fake_success_records_cycle_evidence_and_safe_state
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      File.write(".env", "SECRET=pr23-success-do-not-leak\n")
      bin_dir = write_fake_verify_loop_tooling(dir)
      env = {
        "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR)
      }

      stdout, stderr, code = run_aiweb_env(env, "verify-loop", "--max-cycles", "3", "--approved", "--json")
      payload = JSON.parse(stdout)
      loop = payload.fetch("verify_loop")

      assert_equal 0, code, stdout
      assert_equal "", stderr
      assert_equal "passed", loop["status"]
      assert_equal 1, loop["cycle_count"]
      assert_equal "verify loop passed", payload["action_taken"]
      lifecycle_path = File.join(loop.fetch("run_dir"), "lifecycle.json")
      assert File.file?(lifecycle_path), "verify-loop should record lifecycle evidence"
      assert_equal "passed", JSON.parse(File.read(lifecycle_path)).fetch("status")
      refute File.exist?(File.join(".ai-web", "runs", "active-run.json")), "verify-loop should clear active-run lock after completion"
      provenance = loop.fetch("provenance")
      assert_equal 1, provenance.fetch("schema_version")
      assert_equal "dist", provenance.dig("output", "directory")
      assert_equal true, provenance.dig("output", "exists")
      refute_nil provenance.dig("output", "sha256")
      refute_nil provenance.dig("workspace", "source", "sha256")
      refute_nil provenance.dig("workspace", "package", "sha256")
      assert_includes provenance.fetch("tool_versions"), "ruby"
      assert File.file?(loop.fetch("metadata_path"))
      assert_equal loop, JSON.parse(File.read(loop.fetch("metadata_path")))
      %w[build preview qa-playwright qa-a11y qa-lighthouse qa-screenshot visual-critique].each do |step|
        assert File.file?(File.join(loop.fetch("run_dir"), "cycle-1", "#{step}.json")), "expected verify-loop evidence for #{step}"
      end
      state = load_state
      assert_equal loop.fetch("metadata_path"), state.dig("implementation", "latest_verify_loop")
      assert_equal "passed", state.dig("implementation", "verify_loop_status")
      assert_equal 1, state.dig("implementation", "verify_loop_cycle_count")
      assert_equal "SECRET=pr23-success-do-not-leak\n", File.read(".env")
      refute_includes stdout, "pr23-success-do-not-leak"
      refute Dir.exist?(".ai-web/runs/deploy-*"), "verify-loop must not deploy"
    end
  end

  def test_verify_loop_fake_qa_failure_creates_repair_task_and_runs_agent_once
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      File.write(".env", "SECRET=pr23-repair-do-not-leak\n")
      bin_dir = write_fake_verify_loop_tooling(dir)
      marker = File.join(dir, ".ai-web", "runs", "codex-runs.log")
      FileUtils.mkdir_p(File.dirname(marker))
      env = {
        "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
        "PLAYWRIGHT_FAKE_STATUS" => "failed"
      }

      stdout, stderr, code = run_aiweb_env(env, "verify-loop", "--max-cycles", "1", "--approved", "--json")
      payload = JSON.parse(stdout)
      loop = payload.fetch("verify_loop")

      assert_equal 3, code, stdout
      assert_equal "", stderr
      assert_equal "max_cycles", loop["status"]
      assert_equal 1, loop["cycle_count"]
      cycle_steps = loop.fetch("cycles").first.fetch("steps").map { |step| step.fetch("name") }
      assert_includes cycle_steps, "repair"
      assert_includes cycle_steps, "agent-run"
      assert_equal 1, File.readlines(marker).length, "fake codex should run exactly once for one failed cycle"
      assert_match(/patched by fake verify-loop codex/, File.read("src/components/Hero.astro"))
      assert Dir.glob(".ai-web/tasks/fix-*.md").any?, "verify-loop QA failure should create a repair task"
      assert Dir.glob(".ai-web/runs/agent-run-*").any?, "verify-loop should record the approved agent-run evidence"
      assert_equal "SECRET=pr23-repair-do-not-leak\n", File.read(".env")
      refute_includes stdout, "pr23-repair-do-not-leak"
    end
  end

  def test_verify_loop_max_cycle_cap_stops_deterministically_after_repair_agent_run
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      bin_dir = write_fake_verify_loop_tooling(dir)
      marker = File.join(dir, ".ai-web", "runs", "codex-runs.log")
      FileUtils.mkdir_p(File.dirname(marker))
      env = {
        "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
        "PLAYWRIGHT_FAKE_STATUS" => "failed"
      }

      stdout, stderr, code = run_aiweb_env(env, "verify-loop", "--max-cycles", "1", "--approved", "--json")
      payload = JSON.parse(stdout)

      assert_equal 3, code, stdout
      assert_equal "", stderr
      assert_equal "max_cycles", payload.dig("verify_loop", "status")
      assert_equal 1, payload.dig("verify_loop", "cycle_count")
      assert_match(/max cycles/i, payload.dig("verify_loop", "latest_blocker"))
      assert_equal 1, File.readlines(marker).length
    end
  end

  def test_runtime_plan_blocks_uninitialized_and_unscaffolded_without_writes
    in_tmp do
      payload, code = json_cmd("runtime-plan")
      assert_equal 1, code
      assert_equal "blocked", payload.dig("runtime_plan", "readiness")
      assert_match(/not initialized/, payload["blocking_issues"].join("\n"))
      refute File.exist?(".ai-web"), "runtime-plan must not initialize or write state"

      json_cmd("init", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      before_state = File.read(".ai-web/state.yaml")
      unscaffolded_payload, unscaffolded_code = json_cmd("runtime-plan")

      assert_equal 1, unscaffolded_code
      assert_equal "blocked", unscaffolded_payload.dig("runtime_plan", "readiness")
      assert_equal false, unscaffolded_payload.dig("runtime_plan", "scaffold", "scaffold_created")
      assert_includes unscaffolded_payload.dig("runtime_plan", "missing_required_scaffold_files"), "package.json"
      assert_match(/Scaffold has not been created/, unscaffolded_payload["blocking_issues"].join("\n"))
      assert_equal before_state, File.read(".ai-web/state.yaml"), "runtime-plan must not persist refreshed state"
      assert_equal env_body, File.read(".env"), "runtime-plan must not modify .env"
    end
  end

  def test_runtime_plan_ready_after_profile_d_scaffold
    in_tmp do
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")

      payload, code = json_cmd("runtime-plan")

      assert_equal 0, code
      assert_equal "reported runtime plan", payload["action_taken"]
      assert_equal "ready", payload.dig("runtime_plan", "readiness")
      assert_empty payload.dig("runtime_plan", "blockers")
      assert_equal true, payload.dig("runtime_plan", "scaffold", "scaffold_created")
      assert_equal "D", payload.dig("runtime_plan", "scaffold", "profile")
      assert_equal "Astro", payload.dig("runtime_plan", "scaffold", "framework")
      assert_equal "pnpm", payload.dig("runtime_plan", "scaffold", "package_manager")
      assert_equal "pnpm dev", payload.dig("runtime_plan", "scaffold", "dev_command")
      assert_equal "pnpm build", payload.dig("runtime_plan", "scaffold", "build_command")
      assert_equal "candidate-02", payload.dig("runtime_plan", "design", "selected_candidate")
      assert_equal true, payload.dig("runtime_plan", "design", "design_md_present")
      assert_empty payload.dig("runtime_plan", "missing_required_scaffold_files")
      assert_equal true, payload.dig("runtime_plan", "package_json", "scripts", "dev", "matches")
      assert_equal true, payload.dig("runtime_plan", "package_json", "dependencies", "astro", "present")
    end
  end

  def test_runtime_plan_blocks_selected_design_drift_between_state_metadata_and_generated_content
    in_tmp do
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")

      state = load_state
      state["design_candidates"]["selected_candidate"] = "candidate-01"
      write_state(state)

      payload, code = json_cmd("runtime-plan")

      assert_equal 1, code
      assert_equal "blocked", payload.dig("runtime_plan", "readiness")
      joined = payload["blocking_issues"].join("\n")
      assert_match(/state design_candidates\.selected_candidate \("candidate-01"\) does not match scaffold metadata selected_candidate \("candidate-02"\)/, joined)
      assert_match(/generated scaffold content src\/content\/site\.json selected_candidate \("candidate-02"\) does not match selected design \("candidate-01"\)/, joined)
      assert_equal "candidate-01", payload.dig("runtime_plan", "design", "state_selected_candidate")
      assert_equal "candidate-02", payload.dig("runtime_plan", "design", "metadata_selected_candidate")
      assert_equal "candidate-02", payload.dig("runtime_plan", "design", "generated_reference", "selected_candidate")
    end
  end

  def test_runtime_plan_blocks_generated_scaffold_selected_design_drift
    in_tmp do
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      site = JSON.parse(File.read("src/content/site.json"))
      site["selected_candidate"] = "candidate-03"
      site["selected_candidate_path"] = ".ai-web/design-candidates/candidate-03.html"
      File.write("src/content/site.json", JSON.pretty_generate(site))

      payload, code = json_cmd("runtime-plan")

      assert_equal 1, code
      assert_equal "blocked", payload.dig("runtime_plan", "readiness")
      joined = payload["blocking_issues"].join("\n")
      assert_match(/generated scaffold content src\/content\/site\.json selected_candidate \("candidate-03"\) does not match selected design \("candidate-02"\)/, joined)
      assert_match(/generated scaffold content src\/content\/site\.json selected_candidate \("candidate-03"\) does not match scaffold metadata selected_candidate \("candidate-02"\)/, joined)
    end
  end

  def test_runtime_plan_blocks_unsafe_scaffold_metadata_paths_without_reading_them
    unsafe_paths = {
      "absolute" => File.join(Dir.tmpdir, "aiweb-unsafe-scaffold-profile-D.json"),
      "traversal" => "../outside-scaffold-profile-D.json",
      "env_like" => ".ai-web/.env.local",
      "env_segmented" => ".env/foo.json",
      "nested_env_segmented" => "nested/.env.local/foo.json"
    }

    unsafe_paths.each do |label, unsafe_path|
      in_tmp do
        prepare_profile_d_design_flow
        json_cmd("scaffold", "--profile", "D")
        state = load_state
        state["implementation"]["scaffold_metadata_path"] = unsafe_path
        write_state(state)

        payload, code = json_cmd("runtime-plan")

        assert_equal 1, code, label
        assert_equal "blocked", payload.dig("runtime_plan", "readiness"), label
        assert_equal false, payload.dig("runtime_plan", "scaffold", "metadata_path_safe"), label
        assert_equal false, payload.dig("runtime_plan", "metadata", "path_safe"), label
        assert_equal false, payload.dig("runtime_plan", "metadata", "present"), "unsafe metadata path must not be read even when the expected metadata file exists (#{label})"
        assert_match(/Unsafe scaffold metadata path/, payload["blocking_issues"].join("\n"), label)
      end
    end
  end

  def test_scaffold_status_alias_reports_missing_files_blocked_read_only
    in_tmp do
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      FileUtils.rm_f("src/components/Hero.astro")
      before_state = File.read(".ai-web/state.yaml")

      payload, code = json_cmd("scaffold-status")

      assert_equal 1, code
      assert_equal "blocked", payload.dig("runtime_plan", "readiness")
      assert_includes payload.dig("runtime_plan", "missing_required_scaffold_files"), "src/components/Hero.astro"
      assert_match(/Required scaffold file src\/components\/Hero\.astro is missing/, payload["blocking_issues"].join("\n"))
      assert_equal before_state, File.read(".ai-web/state.yaml")
      refute File.exist?("src/components/Hero.astro"), "scaffold-status must not repair missing files"
    end
  end

  def test_runtime_plan_blocks_malformed_or_incomplete_package_json
    in_tmp do
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")

      File.write("package.json", "{ broken json")
      malformed_payload, malformed_code = json_cmd("runtime-plan")
      assert_equal 1, malformed_code
      assert_equal "blocked", malformed_payload.dig("runtime_plan", "readiness")
      assert_equal false, malformed_payload.dig("runtime_plan", "package_json", "valid_json")
      assert_match(/package\.json is malformed/, malformed_payload["blocking_issues"].join("\n"))

      File.write("package.json", JSON.pretty_generate("scripts" => { "dev" => "vite dev" }, "dependencies" => { "astro" => "latest" }))
      incomplete_payload, incomplete_code = json_cmd("runtime-plan")
      assert_equal 1, incomplete_code
      joined = incomplete_payload["blocking_issues"].join("\n")
      assert_match(/script "dev" should be "astro dev"/, joined)
      assert_match(/script "build" should be "astro build"/, joined)
      assert_match(/dependency "@astrojs\/mdx" is missing/, joined)
    end
  end

  def test_runtime_plan_help_and_webbuilder_passthrough
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr
    assert_includes stdout, "runtime-plan (alias: scaffold-status)"

    help_stdout, help_stderr, help_code = run_webbuilder("--help")
    assert_equal 0, help_code
    assert_equal "", help_stderr
    assert_match(/./m, help_stdout)

    in_tmp do |dir|
      target = File.join(dir, "passthrough-runtime-plan")
      _payload, start_code = json_cmd("start", "--path", target, "--profile", "D", "--idea", "content brand page", "--no-advance")
      assert_equal 0, start_code
      _brief_payload, brief_code = json_cmd("--path", target, "design-brief", "--force")
      assert_equal 0, brief_code
      File.write(File.join(target, ".ai-web", "DESIGN.md"), "# Custom Design System\n\nUse editorial calm, clear hierarchy, and source-backed proof only.\n")
      _design_payload, design_code = json_cmd("--path", target, "design", "--candidates", "3")
      assert_equal 0, design_code
      _select_payload, select_code = json_cmd("--path", target, "select-design", "candidate-02")
      assert_equal 0, select_code
      _scaffold_payload, scaffold_code = json_cmd("--path", target, "scaffold", "--profile", "D")
      assert_equal 0, scaffold_code

      web_stdout, web_stderr, web_code = run_webbuilder("--path", target, "scaffold-status", "--json")
      web_payload = JSON.parse(web_stdout)
      assert_equal 0, web_code
      assert_equal "", web_stderr
      assert_equal "ready", web_payload.dig("runtime_plan", "readiness")
    end
  end

  def test_workbench_dry_run_plans_ui_contract_without_writes_or_state_mutation
    in_tmp do
      prepare_profile_d_design_flow
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      before_state = File.read(".ai-web/state.yaml")
      before_entries = Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." || path == ".." || path.end_with?("/.") }.sort

      stdout, stderr, code = run_aiweb("workbench", "--dry-run", "--json")
      payload = JSON.parse(stdout)
      after_entries = Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." || path == ".." || path.end_with?("/.") }.sort

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal true, payload["dry_run"]
      assert_equal "planned", payload.dig("workbench", "status")
      assert_equal true, payload.dig("workbench", "dry_run")
      paths = payload.dig("workbench", "paths")
      assert_equal ".ai-web/workbench/index.html", paths["html"] || paths["index_html"]
      assert_equal ".ai-web/workbench/workbench.json", paths["manifest"] || paths["manifest_json"]
      assert_equal before_entries, after_entries, "workbench --dry-run must not write UI artifacts"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "workbench --dry-run must not mutate state"
      assert_equal env_body, File.read(".env"), "workbench --dry-run must not mutate .env"

      expected_panels = %w[
        chat
        plan_artifacts
        design_candidates
        selected_design
        preview
        file_tree
        qa_results
        visual_critique
        run_timeline
        verify_loop_status
      ]
      panels = payload.dig("workbench", "panels")
      panel_ids = panels.is_a?(Hash) ? panels.keys : panels.map { |panel| panel.fetch("id") }
      assert_equal expected_panels, panel_ids

      controls = payload.dig("workbench", "controls")
      expected_controls = [
        "aiweb run",
        "aiweb design",
        "aiweb build",
        "aiweb preview",
        "aiweb qa-playwright",
        "aiweb visual-critique",
        "aiweb repair",
        "aiweb visual-polish",
        "aiweb verify-loop --max-cycles 3"
      ]
      assert_equal expected_controls, controls.map { |control| control.fetch("command") }
      controls.each do |control|
        assert_includes ["cli", "cli_descriptor"], control["kind"] || control["mode"]
        assert_includes [true, false], control["mutates_state"] if control.key?("mutates_state")
        assert_includes [true, false], control["launches_process"] if control.key?("launches_process")
        assert_includes [true, false], control["requires_approval"] if control.key?("requires_approval")
        refute_match(/state\.yaml/, control.fetch("command"), "workbench controls must be declarative CLI commands, not direct state writes")
      end
      design_control = controls.find { |control| control.fetch("command") == "aiweb design" }
      preview_control = controls.find { |control| control.fetch("command") == "aiweb preview" }
      verify_control = controls.find { |control| control.fetch("command") == "aiweb verify-loop --max-cycles 3" }
      assert_equal true, design_control["mutates_state"]
      assert_equal true, preview_control["launches_process"]
      assert_equal true, verify_control["requires_approval"]
      refute_includes stdout, "do-not-touch"
    end
  end

  def test_workbench_export_writes_only_workbench_artifacts_and_not_state
    in_tmp do
      prepare_profile_d_design_flow
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      before_state = File.read(".ai-web/state.yaml")
      before_entries = Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." || path == ".." || path.end_with?("/.") }.sort

      stdout, stderr, code = run_aiweb("workbench", "--export", "--json")
      payload = JSON.parse(stdout)
      after_entries = Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." || path == ".." || path.end_with?("/.") }.sort

      assert_equal 0, code
      assert_equal "", stderr
      assert_includes %w[exported ready], payload.dig("workbench", "status")
      assert_equal false, payload.dig("workbench", "dry_run")
      assert_equal before_state, File.read(".ai-web/state.yaml"), "workbench export must not mutate state"
      assert_equal env_body, File.read(".env"), "workbench export must not mutate .env"

      added_entries = after_entries - before_entries
      assert_equal [".ai-web/workbench", ".ai-web/workbench/index.html", ".ai-web/workbench/workbench.json"], added_entries
      assert_equal [".ai-web/workbench/index.html", ".ai-web/workbench/workbench.json"], payload["changed_files"]

      html = File.read(".ai-web/workbench/index.html")
      manifest = JSON.parse(File.read(".ai-web/workbench/workbench.json"))
      assert_equal payload["workbench"], manifest
      assert_match(/Workbench/i, html)
      assert_match(/plan_artifacts/, html)
      refute_includes stdout, "do-not-touch"
      refute_includes html, "do-not-touch"
      refute_includes JSON.generate(manifest), "do-not-touch"
    end
  end

  def test_workbench_file_tree_excludes_env_and_generated_bulk_directories
    in_tmp do
      prepare_profile_d_design_flow
      File.write(".env", "SECRET=do-not-touch\n")
      File.write(".env.local", "LOCAL_SECRET=do-not-touch\n")
      FileUtils.mkdir_p("node_modules/package")
      FileUtils.mkdir_p(".git")
      FileUtils.mkdir_p("dist")
      File.write("node_modules/package/index.js", "module.exports = true\n")
      File.write(".git/config", "[core]\n")
      File.write("dist/index.html", "<p>generated</p>\n")

      stdout, stderr, code = run_aiweb("workbench", "--export", "--json")
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      manifest_text = File.read(".ai-web/workbench/workbench.json")
      html = File.read(".ai-web/workbench/index.html")
      assert_equal "file_tree", payload.dig("workbench", "panels").find { |panel| panel["id"] == "file_tree" }.fetch("id")
      refute_match(%r{(^|[/"])\.env(\.local)?($|["])}, stdout)
      refute_match(%r{(^|[/"])\.env(\.local)?($|["])}, manifest_text)
      refute_match(%r{(^|[/"])\.env(\.local)?($|["])}, html)
      refute_includes stdout, "do-not-touch"
      refute_includes manifest_text, "do-not-touch"
      refute_includes html, "do-not-touch"
      refute_match(%r{node_modules/}, manifest_text)
      refute_match(%r{\.git/}, manifest_text)
      refute_match(%r{dist/}, manifest_text)
    end
  end

  def test_workbench_blocks_uninitialized_without_creating_workspace
    in_tmp do
      File.write(".env", "SECRET=do-not-touch\n")

      stdout, stderr, code = run_aiweb("workbench", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      message = [payload.dig("error", "message"), payload["blocking_issues"], payload.dig("workbench", "blocking_issues")].flatten.compact.join("\n")
      assert_match(/not initialized|initialize/i, message)
      refute Dir.exist?(".ai-web"), "uninitialized workbench must not create .ai-web"
      refute_includes stdout, "do-not-touch"
    end
  end

  def test_workbench_serve_dry_run_plans_localhost_server_without_writes_or_process
    in_tmp do
      prepare_profile_d_design_flow
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      before_state = File.read(".ai-web/state.yaml")
      before_entries = project_entries

      stdout, stderr, code = run_aiweb("workbench", "--serve", "--host", "localhost", "--port", "17345", "--dry-run", "--json")
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal "planned", payload.dig("workbench", "status")
      assert_equal true, payload.dig("workbench", "dry_run")
      assert_equal "localhost", payload.dig("workbench", "serve", "host")
      assert_equal 17_345, payload.dig("workbench", "serve", "port")
      assert_equal "http://localhost:17345/", payload.dig("workbench", "serve", "url")
      assert_match(%r{\A\.ai-web/runs/workbench-serve-.+/workbench-serve\.json\z}, payload.dig("workbench", "serve", "metadata_path"))
      assert_equal before_entries, project_entries, "workbench --serve --dry-run must not write UI or run artifacts"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "workbench --serve --dry-run must not mutate state"
      assert_equal env_body, File.read(".env"), "workbench --serve --dry-run must not mutate .env"
      refute_includes stdout, "do-not-touch"
    end
  end

  def test_workbench_serve_without_approval_blocks_without_writes_or_process
    in_tmp do
      prepare_profile_d_design_flow
      before_state = File.read(".ai-web/state.yaml")
      before_entries = project_entries

      stdout, stderr, code = run_aiweb("workbench", "--serve", "--json")
      payload = JSON.parse(stdout)

      assert_equal 5, code
      assert_equal "", stderr
      assert_equal "blocked", payload.dig("workbench", "status")
      assert_match(/approved/i, [payload.dig("error", "message"), payload["blocking_issues"], payload.dig("workbench", "blocking_issues")].flatten.compact.join("\n"))
      assert_equal before_entries, project_entries, "unapproved workbench serve must not write artifacts"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "unapproved workbench serve must not mutate state"
    end
  end

  def test_workbench_serve_blocks_non_localhost_host
    in_tmp do
      prepare_profile_d_design_flow
      before_entries = project_entries

      stdout, stderr, code = run_aiweb("workbench", "--serve", "--approved", "--host", "0.0.0.0", "--json")
      payload = JSON.parse(stdout)

      assert_equal 5, code
      assert_equal "", stderr
      assert_equal "blocked", payload.dig("workbench", "status")
      assert_match(/localhost|127\.0\.0\.1/i, [payload.dig("error", "message"), payload["blocking_issues"], payload.dig("workbench", "blocking_issues")].flatten.compact.join("\n"))
      assert_equal before_entries, project_entries, "non-localhost serve must not write artifacts"
    end
  end

  def test_workbench_serve_approved_records_metadata_and_runs_local_server
    in_tmp do
      prepare_profile_d_design_flow
      before_state = File.read(".ai-web/state.yaml")
      port = 17_350 + (Process.pid % 500)
      pid = nil

      stdout, stderr, code = run_aiweb("workbench", "--serve", "--approved", "--port", port.to_s, "--json")
      payload = JSON.parse(stdout)
      pid = payload.dig("workbench", "serve", "pid").to_i

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal "running", payload.dig("workbench", "status")
      assert_equal "127.0.0.1", payload.dig("workbench", "serve", "host")
      assert_equal port, payload.dig("workbench", "serve", "port")
      assert_equal true, payload.dig("workbench", "serve", "approved")
      assert_operator pid, :>, 0
      Process.kill(0, pid)
      metadata_path = payload.dig("workbench", "serve", "metadata_path")
      assert File.exist?(".ai-web/workbench/index.html")
      assert File.exist?(".ai-web/workbench/workbench.json")
      assert File.exist?(metadata_path)
      metadata = JSON.parse(File.read(metadata_path))
      assert_equal "running", metadata.fetch("status")
      assert_equal port, metadata.fetch("port")
      assert_equal true, metadata.fetch("local_only")
      assert_equal before_state, File.read(".ai-web/state.yaml"), "workbench serve must not mutate state"
    ensure
      if pid && pid.positive?
        begin
          Process.kill(RbConfig::CONFIG["host_os"].match?(/mswin|mingw|cygwin/i) ? "KILL" : "TERM", pid)
        rescue Errno::ESRCH, Errno::EINVAL
        end
      end
    end
  end

  def project_entries
    Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." || path == ".." || path.end_with?("/.") }.sort
  end

  def prepare_profile_d_scaffold_flow
    prepare_profile_d_design_flow
    json_cmd("scaffold", "--profile", "D")
  end

  def component_map_ids(component_map)
    Array(component_map["components"]).map { |component| component.fetch("data_aiweb_id") }
  end

  def test_github_sync_dry_run_plans_local_artifact_without_writes_or_external_actions
    in_tmp do
      prepare_profile_d_scaffold_flow
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb("github-sync", "--dry-run", "--json")
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      sync = payload.fetch("github_sync")
      assert_equal ".ai-web/github-sync.json", sync.fetch("planned_config_path")
      assert_equal false, sync.fetch("external_push_performed")
      assert_equal false, sync.fetch("external_deploy_performed")
      assert_equal true, sync.fetch("requires_approval")
      assert_equal [".ai-web/github-sync.json"], payload.fetch("planned_changes")
      assert_equal false, payload.fetch("external_push_performed")
      assert_equal false, payload.fetch("external_deploy_performed")
      assert_equal before_entries, project_entries, "github-sync --dry-run must not write files"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "github-sync --dry-run must not mutate state"
      assert_equal env_body, File.read(".env"), "github-sync --dry-run must not mutate .env"
      refute_includes stdout, "do-not-touch"
      refute Dir.exist?("dist"), "github-sync --dry-run must not build"
    end
  end

  def test_github_sync_real_run_writes_only_local_artifact_without_push
    in_tmp do
      prepare_profile_d_scaffold_flow
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      before_state = File.read(".ai-web/state.yaml")
      before_entries = project_entries

      stdout, stderr, code = run_aiweb("github-sync", "--json")
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      sync = payload.fetch("github_sync")
      assert_equal ".ai-web/github-sync.json", sync.fetch("planned_config_path")
      assert_equal false, sync.fetch("external_push_performed")
      assert_equal false, sync.fetch("external_deploy_performed")
      assert_equal true, sync.fetch("requires_approval")
      artifact_path = ".ai-web/github-sync.json"
      assert File.file?(artifact_path), "github-sync must write local artifact"
      artifact = JSON.parse(File.read(artifact_path))
      assert_equal false, artifact.fetch("external_push_performed")
      assert_equal false, artifact.fetch("external_deploy_performed")
      added_entries = project_entries - before_entries
      assert_includes added_entries, artifact_path
      assert added_entries.all? { |path| path.start_with?(".ai-web/") }, "github-sync must only write local .ai-web artifacts/state"
      refute_equal before_state, File.read(".ai-web/state.yaml"), "github-sync must update state safely"
      state = load_state
      assert_equal ".ai-web/github-sync.json", state.dig("artifacts", "github_sync", "path")
      assert_equal ".ai-web/github-sync.json", state.dig("deploy", "github_sync_plan")
      assert_equal env_body, File.read(".env"), "github-sync must not mutate .env"
      refute_includes stdout, "do-not-touch"
      refute Dir.exist?("dist"), "github-sync must not build"
    end
  end

  def test_deploy_plan_dry_run_and_real_run_are_local_only_and_stateful
    in_tmp do
      prepare_profile_d_scaffold_flow
      set_phase("phase-11")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      dry_stdout, dry_stderr, dry_code = run_aiweb("deploy-plan", "--dry-run", "--json")
      dry_payload = JSON.parse(dry_stdout)

      assert_equal 0, dry_code
      assert_equal "", dry_stderr
      dry_plan = dry_payload.fetch("deploy_plan")
      assert_equal ".ai-web/deploy-plan.json", dry_plan.fetch("planned_config_path")
      assert_equal({ "cloudflare-pages" => ".ai-web/deploy/cloudflare-pages.json", "vercel" => ".ai-web/deploy/vercel.json" }, dry_plan.fetch("provider_config_paths"))
      assert_equal false, dry_plan.fetch("external_deploy_performed")
      assert_equal true, dry_plan.fetch("requires_approval")
      assert_equal [".ai-web/deploy-plan.json", ".ai-web/deploy/cloudflare-pages.json", ".ai-web/deploy/vercel.json"], dry_payload.fetch("planned_changes")
      assert_equal before_entries, project_entries, "deploy-plan --dry-run must not write files"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "deploy-plan --dry-run must not mutate state"

      real_stdout, real_stderr, real_code = run_aiweb("deploy-plan", "--json")
      real_payload = JSON.parse(real_stdout)

      assert_equal 0, real_code
      assert_equal "", real_stderr
      real_plan = real_payload.fetch("deploy_plan")
      assert_equal ".ai-web/deploy-plan.json", real_plan.fetch("planned_config_path")
      assert_equal false, real_plan.fetch("external_deploy_performed")
      assert_equal true, real_plan.fetch("requires_approval")
      [".ai-web/deploy-plan.json", ".ai-web/deploy/cloudflare-pages.json", ".ai-web/deploy/vercel.json"].each do |artifact_path|
        assert File.file?(artifact_path), "deploy-plan must write #{artifact_path}"
      end
      state = load_state
      assert_equal ".ai-web/deploy-plan.json", state.dig("artifacts", "deploy_plan", "path")
      assert_equal ".ai-web/deploy-plan.json", state.dig("deploy", "deploy_plan")
      assert_equal({ "cloudflare-pages" => ".ai-web/deploy/cloudflare-pages.json", "vercel" => ".ai-web/deploy/vercel.json" }, state.dig("deploy", "provider_config_paths"))
      added_entries = project_entries - before_entries
      assert added_entries.all? { |path| path.start_with?(".ai-web/") }, "deploy-plan must only write local .ai-web artifacts/state"
      assert_equal env_body, File.read(".env"), "deploy-plan must not mutate .env"
      refute_includes dry_stdout + real_stdout, "do-not-touch"
      refute Dir.exist?("dist"), "deploy-plan must not build"
    end
  end

  def test_deploy_target_dry_runs_are_local_only_for_supported_providers
    ["cloudflare-pages", "vercel"].each do |target|
      in_tmp do
        prepare_profile_d_scaffold_flow
        set_phase("phase-11")
        env_body = "SECRET=do-not-touch\n"
        File.write(".env", env_body)
        before_entries = project_entries
        before_state = File.read(".ai-web/state.yaml")

        stdout, stderr, code = run_aiweb("deploy", "--target", target, "--dry-run", "--json")
        payload = JSON.parse(stdout)

        assert_equal 0, code, target
        assert_equal "", stderr, target
        deploy = payload.fetch("deploy")
        assert_equal target, deploy.fetch("target")
        assert_equal true, deploy.fetch("dry_run")
        assert_equal "planned", deploy.fetch("status")
        assert_equal false, deploy.fetch("external_push_performed")
        assert_equal false, deploy.fetch("external_deploy_performed")
        assert_equal true, deploy.fetch("requires_approval")
        assert_equal false, deploy.fetch("writes_performed")
        assert_equal false, deploy.fetch("provider_cli_invoked")
        assert_equal false, deploy.fetch("network_calls_performed")
        assert_equal "planned", deploy.dig("side_effect_broker", "status")
        assert_equal "plan-only", deploy.dig("side_effect_broker", "policy", "decision")
        assert_equal false, deploy.dig("side_effect_broker", "events_recorded")
        refute File.exist?(deploy.fetch("side_effect_broker_path")), "deploy --dry-run must not write broker events (#{target})"
        assert_includes deploy.fetch("planned_changes"), ".ai-web/deploy-plan.json"
        assert_includes deploy.fetch("planned_changes"), ".ai-web/deploy/#{target}.json"
        assert_includes deploy.fetch("planned_changes"), deploy.fetch("side_effect_broker_path")
        assert_equal before_entries, project_entries, "deploy --dry-run must not write files (#{target})"
        assert_equal before_state, File.read(".ai-web/state.yaml"), "deploy --dry-run must not mutate state (#{target})"
        assert_equal env_body, File.read(".env"), "deploy --dry-run must not mutate .env (#{target})"
        refute_includes stdout, "do-not-touch", target
        refute Dir.exist?("dist"), "deploy --dry-run must not build (#{target})"
      end
    end
  end

  def test_deploy_blocks_unsafe_real_external_actions_and_invalid_targets
    in_tmp do
      prepare_profile_d_scaffold_flow
      set_phase("phase-11")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb("deploy", "--target", "vercel", "--json")
      payload = JSON.parse(stdout)

      assert_equal 5, code
      assert_equal "", stderr
      message = [payload.dig("error", "message"), payload["blocking_issues"], payload.dig("deploy", "blocking_issues")].flatten.compact.join("\n")
      assert_match(/external|unsafe|dry-run|approval|blocked/i, message)
      assert_equal "blocked", payload.dig("deploy", "side_effect_broker", "status")
      assert_equal "deny", payload.dig("deploy", "side_effect_broker", "policy", "decision")
      refute File.exist?(payload.dig("deploy", "side_effect_broker_path")), "blocked deploy must not write broker events"
      assert_equal before_entries, project_entries, "blocked deploy must not write files"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "blocked deploy must not mutate state"
      assert_equal env_body, File.read(".env"), "blocked deploy must not mutate .env"
      refute_includes stdout, "do-not-touch"
      refute Dir.exist?("dist"), "blocked deploy must not build"

      invalid_stdout, invalid_stderr, invalid_code = run_aiweb("deploy", "--target", "ftp", "--dry-run", "--json")
      invalid_payload = JSON.parse(invalid_stdout)

      assert_equal 1, invalid_code
      assert_equal "", invalid_stderr
      assert_match(/target|cloudflare-pages|vercel|invalid/i, invalid_payload.dig("error", "message"))
      assert_equal before_entries, project_entries, "invalid target must not write files"
    end
  end

  def test_deploy_approved_blocks_without_passing_verify_loop_evidence
    in_tmp do
      prepare_profile_d_scaffold_flow
      set_phase("phase-11")
      FileUtils.mkdir_p("dist")
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb("deploy", "--target", "cloudflare-pages", "--approved", "--json")
      payload = JSON.parse(stdout)

      assert_equal 5, code
      assert_equal "", stderr
      deploy = payload.fetch("deploy")
      assert_equal "blocked", deploy.fetch("status")
      message = [payload["blocking_issues"], deploy.fetch("blocking_issues")].flatten.compact.join("\n")
      assert_match(/verify-loop/i, message)
      assert_match(/provider CLI|wrangler/i, message)
      assert_equal false, deploy.fetch("provider_cli_invoked")
      assert_equal false, deploy.fetch("external_deploy_performed")
      assert_equal "blocked", deploy.dig("side_effect_broker", "status")
      assert_equal "deny", deploy.dig("side_effect_broker", "policy", "decision")
      refute File.exist?(deploy.fetch("side_effect_broker_path")), "approved deploy with missing gates must not write broker events"
      assert_equal before_entries, project_entries, "approved deploy with missing gates must not write files"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "approved deploy with missing gates must not mutate state"
    end
  end

  def test_deploy_approved_blocks_unsafe_verify_loop_evidence_path_without_reading_env
    in_tmp do
      prepare_profile_d_scaffold_flow
      set_phase("phase-11")
      state = load_state
      state["implementation"]["latest_verify_loop"] = ".env.deploy"
      write_state(state)
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb("deploy", "--target", "vercel", "--approved", "--json")
      payload = JSON.parse(stdout)

      assert_equal 5, code
      assert_equal "", stderr
      deploy = payload.fetch("deploy")
      assert_equal "blocked", deploy.fetch("status")
      assert_equal "blocked", deploy.dig("verify_loop_gate", "status")
      assert_includes deploy.dig("verify_loop_gate", "blocking_issues").join("\n"), "unsafe"
      assert_equal false, deploy.fetch("provider_cli_invoked")
      assert_equal false, deploy.fetch("external_deploy_performed")
      assert_equal "blocked", deploy.dig("side_effect_broker", "status")
      assert_equal "deny", deploy.dig("side_effect_broker", "policy", "decision")
      refute File.exist?(deploy.fetch("side_effect_broker_path")), "unsafe verify-loop evidence path must not write broker events"
      assert_equal before_entries, project_entries, "unsafe verify-loop evidence path must not write files"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "unsafe verify-loop evidence path must not mutate state"
    end
  end

  def test_deploy_approved_fake_provider_command_records_evidence_and_state
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      set_phase("phase-11")
      FileUtils.mkdir_p("dist")
      File.write("dist/index.html", "<h1>Deploy fixture</h1>\n")
      verify_dir = ".ai-web/runs/verify-loop-test"
      FileUtils.mkdir_p(verify_dir)
      verify_metadata_path = File.join(verify_dir, "verify-loop.json")
      File.write(
        verify_metadata_path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "status" => "passed",
          "approved" => true,
          "dry_run" => false,
          "cycle_count" => 1,
          "provenance" => deploy_provenance_fixture
        ) + "\n"
      )
      state = load_state
      state["implementation"]["latest_verify_loop"] = verify_metadata_path
      state["implementation"]["verify_loop_status"] = "passed"
      write_state(state)

      bin_dir = File.join(dir, "fake-deploy-bin")
      FileUtils.mkdir_p(bin_dir)
      marker = File.join(dir, "fake-vercel-ran")
      write_fake_executable(
        bin_dir,
        "vercel",
        <<~SH
          echo fake vercel deploy "$@"
          touch #{marker.shellescape}
          exit 0
        SH
      )
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      stdout, stderr, code = run_aiweb_env(env, "deploy", "--target", "vercel", "--approved", "--json")
      payload = JSON.parse(stdout)

      assert_equal 0, code, stdout
      assert_equal "", stderr
      deploy = payload.fetch("deploy")
      assert_equal "passed", deploy.fetch("status")
      assert_equal "vercel", deploy.fetch("target")
      assert_equal true, deploy.fetch("approved")
      assert_equal false, deploy.fetch("dry_run")
      assert_equal "passed", deploy.dig("verify_loop_gate", "status")
      assert_equal "ready", deploy.dig("provider_readiness", "status")
      assert_equal "vercel", deploy.fetch("command").first
      assert_equal true, deploy.fetch("provider_executed")
      assert_equal true, deploy.fetch("provider_cli_invoked")
      assert_equal true, deploy.fetch("writes_performed")
      assert File.file?(marker), "fake provider command should run only from test-controlled PATH"
      assert File.file?(deploy.fetch("metadata_path")), "deploy metadata must be recorded"
      assert File.file?(deploy.fetch("stdout_log")), "deploy stdout log must be recorded"
      assert File.file?(deploy.fetch("stderr_log")), "deploy stderr log must be recorded"
      assert File.file?(deploy.fetch("side_effect_broker_path")), "deploy side-effect broker log must be recorded"
      broker_events = File.readlines(deploy.fetch("side_effect_broker_path"), chomp: true).map { |line| JSON.parse(line) }
      assert_equal deploy.fetch("side_effect_broker_events"), broker_events
      assert_equal %w[tool.requested policy.decision tool.started tool.finished], broker_events.map { |event| event.fetch("event") }
      assert_equal "aiweb.deploy.side_effect_broker", deploy.dig("side_effect_broker", "broker")
      assert_equal "deploy.provider_cli", deploy.dig("side_effect_broker", "scope")
      assert_equal "passed", deploy.dig("side_effect_broker", "status")
      assert_equal true, deploy.dig("side_effect_broker", "events_recorded")
      assert_equal broker_events.length, deploy.dig("side_effect_broker", "event_count")
      assert_equal "allow", broker_events.find { |event| event.fetch("event") == "policy.decision" }.fetch("decision")
      broker_json = JSON.generate(broker_events)
      refute_includes broker_json, ".env"
      refute_includes broker_json, "do-not-touch"
      assert_includes File.read(deploy.fetch("stdout_log")), "fake vercel deploy"
      artifact = JSON.parse(File.read(deploy.fetch("metadata_path")))
      assert_equal deploy, artifact
      state = load_state
      assert_equal deploy.fetch("metadata_path"), state.dig("deploy", "latest_deploy")
      assert_equal "vercel", state.dig("deploy", "latest_deploy_target")
      assert_equal "passed", state.dig("deploy", "latest_deploy_status")
      refute_includes stdout, ".env"
      refute_includes File.read(deploy.fetch("stdout_log")), ".env"
      refute_includes File.read(deploy.fetch("stderr_log")), ".env"
    end
  end

  def test_deploy_approved_provider_output_is_redacted_before_logs
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      set_phase("phase-11")
      FileUtils.mkdir_p("dist")
      File.write("dist/index.html", "<h1>Deploy fixture</h1>\n")
      verify_dir = ".ai-web/runs/verify-loop-test"
      FileUtils.mkdir_p(verify_dir)
      verify_metadata_path = File.join(verify_dir, "verify-loop.json")
      File.write(
        verify_metadata_path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "status" => "passed",
          "approved" => true,
          "dry_run" => false,
          "cycle_count" => 1,
          "provenance" => deploy_provenance_fixture
        ) + "\n"
      )
      state = load_state
      state["implementation"]["latest_verify_loop"] = verify_metadata_path
      state["implementation"]["verify_loop_status"] = "passed"
      write_state(state)

      bin_dir = File.join(dir, "fake-deploy-bin")
      FileUtils.mkdir_p(bin_dir)
      marker = File.join(dir, "fake-vercel-ran")
      write_fake_provider_cli(
        bin_dir,
        name: "vercel",
        marker: marker,
        stdout_lines: [
          "SECRET=do-not-touch",
          "SECRET=do not touch",
          "KEY=plain-key-secret",
          "KEY=\"quoted key secret\"",
          "PRIVATE_KEY=-----BEGIN PRIVATE KEY-----",
          "PRIVATE_KEY=-----BEGIN PRIVATE KEY-----\nMIISECRETKEYBODY\n-----END PRIVATE KEY-----",
          "Deploy wrote .env.production",
          "Authorization: Bearer bearer-secret-token",
          "preview=https://example.test?access_token=secret-token"
        ],
        stderr_lines: [
          "VERCEL_TOKEN=stderr-token",
          "VERCEL_TOKEN: colon-stderr-token",
          "token: colon-secret-token",
          "credential=.env.local"
        ]
      )
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      stdout, stderr, code = run_aiweb_env(env, "deploy", "--target", "vercel", "--approved", "--json")
      payload = JSON.parse(stdout)

      assert_equal 0, code, stdout
      assert_equal "", stderr
      deploy = payload.fetch("deploy")
      assert File.file?(marker), "fake provider command should run"
      stdout_log = File.read(deploy.fetch("stdout_log"))
      stderr_log = File.read(deploy.fetch("stderr_log"))
      combined_logs = "#{stdout_log}\n#{stderr_log}"
      assert_includes stdout_log, "fake vercel deploy"
      assert_includes combined_logs, "[redacted]"
      assert_includes combined_logs, "[excluded unsafe environment-file reference]"
      refute_includes combined_logs, "do-not-touch"
      refute_includes combined_logs, "do not touch"
      refute_includes combined_logs, "plain-key-secret"
      refute_includes combined_logs, "quoted key secret"
      refute_includes combined_logs, "PRIVATE KEY"
      refute_includes combined_logs, "MIISECRETKEYBODY"
      refute_includes combined_logs, "stderr-token"
      refute_includes combined_logs, "colon-stderr-token"
      refute_includes combined_logs, "colon-secret-token"
      refute_includes combined_logs, "bearer-secret-token"
      refute_includes combined_logs, "secret-token"
      refute_includes combined_logs, ".env"
      refute_includes stdout, "do-not-touch"
      refute_includes stdout, "do not touch"
      refute_includes stdout, "plain-key-secret"
      refute_includes stdout, "quoted key secret"
      refute_includes stdout, "PRIVATE KEY"
      refute_includes stdout, "MIISECRETKEYBODY"
      refute_includes stdout, "stderr-token"
      refute_includes stdout, "colon-stderr-token"
      refute_includes stdout, "colon-secret-token"
      refute_includes stdout, "bearer-secret-token"
      refute_includes stdout, "secret-token"
    end
  end

  def test_side_effect_broker_redacts_sensitive_command_flags_and_keeps_helper_internal
    in_tmp do |dir|
      project = Aiweb::Project.new(Dir.pwd)

      refute project.respond_to?(:append_side_effect_broker_event), "broker event append must not be a public Project API"
      redacted = project.send(
        :redact_side_effect_command,
        [
          "vercel",
          "deploy",
          "--auth=auth-secret",
          "--credential",
          "credential-secret",
          "--private-key=private-key-secret",
          "--client-secret",
          "client-secret-value",
          "--authorization",
          "authorization-secret"
        ]
      )
      assert_equal(
        [
          "vercel",
          "deploy",
          "[REDACTED]",
          "--credential",
          "[REDACTED]",
          "[REDACTED]",
          "--client-secret",
          "[REDACTED]",
          "--authorization",
          "[REDACTED]"
        ],
        redacted
      )

      assert_raises(Aiweb::UserError) do
        project.send(:append_side_effect_broker_event, File.join(dir, "outside.jsonl"), [], "tool.requested", {})
      end
      refute File.exist?(File.join(dir, "outside.jsonl"))
    end
  end

  def test_deploy_approved_failed_provider_records_network_attempt
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      set_phase("phase-11")
      FileUtils.mkdir_p("dist")
      File.write("dist/index.html", "<h1>Deploy fixture</h1>\n")
      verify_dir = ".ai-web/runs/verify-loop-test"
      FileUtils.mkdir_p(verify_dir)
      verify_metadata_path = File.join(verify_dir, "verify-loop.json")
      File.write(
        verify_metadata_path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "status" => "passed",
          "approved" => true,
          "dry_run" => false,
          "cycle_count" => 1,
          "provenance" => deploy_provenance_fixture
        ) + "\n"
      )
      state = load_state
      state["implementation"]["latest_verify_loop"] = verify_metadata_path
      state["implementation"]["verify_loop_status"] = "passed"
      write_state(state)

      bin_dir = File.join(dir, "fake-deploy-bin")
      FileUtils.mkdir_p(bin_dir)
      marker = File.join(dir, "fake-vercel-ran")
      write_fake_provider_cli(
        bin_dir,
        name: "vercel",
        marker: marker,
        stdout_lines: ["provider attempted deploy"],
        stderr_lines: ["provider failed after attempting network"],
        exit_code: 42
      )
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      stdout, stderr, code = run_aiweb_env(env, "deploy", "--target", "vercel", "--approved", "--json")
      payload = JSON.parse(stdout)

      refute_equal 0, code, stdout
      assert_equal "", stderr
      deploy = payload.fetch("deploy")
      assert_equal "failed", deploy.fetch("status")
      assert_equal 42, deploy.fetch("exit_code")
      assert_equal true, deploy.fetch("provider_executed")
      assert_equal true, deploy.fetch("provider_cli_invoked")
      assert_equal false, deploy.fetch("external_deploy_performed")
      assert_equal true, deploy.fetch("network_calls_performed")
      assert_equal "attempted_unknown_result", deploy.fetch("network_call_status")
      assert File.file?(marker), "fake provider command should have run"
      broker_events = File.readlines(deploy.fetch("side_effect_broker_path"), chomp: true).map { |line| JSON.parse(line) }
      finished = broker_events.find { |event| event.fetch("event") == "tool.finished" }
      assert_equal "failed", finished.fetch("status")
      assert_equal 42, finished.fetch("exit_code")
    end
  end

  def test_deploy_approved_repeated_runs_get_distinct_broker_paths_with_fixed_time
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      set_phase("phase-11")
      FileUtils.mkdir_p("dist")
      File.write("dist/index.html", "<h1>Deploy fixture</h1>\n")
      verify_dir = ".ai-web/runs/verify-loop-test"
      FileUtils.mkdir_p(verify_dir)
      verify_metadata_path = File.join(verify_dir, "verify-loop.json")
      File.write(
        verify_metadata_path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "status" => "passed",
          "approved" => true,
          "dry_run" => false,
          "cycle_count" => 1,
          "provenance" => deploy_provenance_fixture
        ) + "\n"
      )
      state = load_state
      state["implementation"]["latest_verify_loop"] = verify_metadata_path
      state["implementation"]["verify_loop_status"] = "passed"
      write_state(state)

      bin_dir = File.join(dir, "fake-deploy-bin")
      FileUtils.mkdir_p(bin_dir)
      marker = File.join(dir, "fake-vercel-ran")
      write_fake_executable(
        bin_dir,
        "vercel",
        <<~SH
          echo fake vercel deploy "$@"
          touch #{marker.shellescape}
          exit 0
        SH
      )
      fixed = Time.utc(2026, 1, 2, 3, 4, 5)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }
      first_payload = nil
      second_payload = nil

      with_env_values(env) do
        Time.stub(:now, fixed) do
          project = Aiweb::Project.new(Dir.pwd)
          first_payload = project.deploy(target: "vercel", approved: true)
          second_payload = project.deploy(target: "vercel", approved: true)
        end
      end

      first = first_payload.fetch("deploy")
      second = second_payload.fetch("deploy")
      refute_equal first.fetch("run_id"), second.fetch("run_id")
      refute_equal first.fetch("run_dir"), second.fetch("run_dir")
      refute_equal first.fetch("side_effect_broker_path"), second.fetch("side_effect_broker_path")
      assert File.file?(first.fetch("side_effect_broker_path"))
      assert File.file?(second.fetch("side_effect_broker_path"))
      assert_equal 4, File.readlines(first.fetch("side_effect_broker_path")).length
      assert_equal 4, File.readlines(second.fetch("side_effect_broker_path")).length
    end
  end

  def test_deploy_approved_blocks_stale_verify_loop_provenance_without_provider_execution
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      set_phase("phase-11")
      FileUtils.mkdir_p("dist")
      File.write("dist/index.html", "<h1>Deploy fixture</h1>\n")
      verify_dir = ".ai-web/runs/verify-loop-test"
      FileUtils.mkdir_p(verify_dir)
      verify_metadata_path = File.join(verify_dir, "verify-loop.json")
      File.write(
        verify_metadata_path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "status" => "passed",
          "approved" => true,
          "dry_run" => false,
          "cycle_count" => 1,
          "provenance" => deploy_provenance_fixture
        ) + "\n"
      )
      state = load_state
      state["implementation"]["latest_verify_loop"] = verify_metadata_path
      state["implementation"]["verify_loop_status"] = "passed"
      write_state(state)
      File.write("dist/index.html", "<h1>Mutated after verify-loop</h1>\n")

      bin_dir = File.join(dir, "fake-deploy-bin")
      FileUtils.mkdir_p(bin_dir)
      marker = File.join(dir, "fake-vercel-ran")
      write_fake_executable(bin_dir, "vercel", "touch #{marker.shellescape}; exit 0")
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "deploy", "--target", "vercel", "--approved", "--json"
      )
      payload = JSON.parse(stdout)
      deploy = payload.fetch("deploy")
      blockers = deploy.fetch("blocking_issues").join("\n")

      assert_equal 5, code
      assert_equal "", stderr
      assert_equal "blocked", deploy.fetch("status")
      assert_equal "blocked", deploy.dig("verify_loop_gate", "status")
      assert_match(/provenance mismatch.*output\.sha256/i, blockers)
      assert_equal false, deploy.fetch("provider_cli_invoked")
      assert_equal false, deploy.fetch("external_deploy_performed")
      assert_equal false, deploy.fetch("writes_performed")
      refute File.exist?(marker), "stale verify-loop provenance must block provider command execution"
      assert_equal before_entries, project_entries, "stale verify-loop provenance blocker must not write deploy artifacts"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "stale verify-loop provenance blocker must not mutate state"
      refute_includes stdout, ".env"
    end
  end

  def test_deploy_approved_blocks_legacy_verify_loop_evidence_without_provenance
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      set_phase("phase-11")
      FileUtils.mkdir_p("dist")
      File.write("dist/index.html", "<h1>Deploy fixture</h1>\n")
      verify_dir = ".ai-web/runs/verify-loop-legacy"
      FileUtils.mkdir_p(verify_dir)
      verify_metadata_path = File.join(verify_dir, "verify-loop.json")
      File.write(
        verify_metadata_path,
        JSON.pretty_generate(
          "schema_version" => 1,
          "status" => "passed",
          "approved" => true,
          "dry_run" => false,
          "cycle_count" => 1
        ) + "\n"
      )
      state = load_state
      state["implementation"]["latest_verify_loop"] = verify_metadata_path
      state["implementation"]["verify_loop_status"] = "passed"
      write_state(state)

      bin_dir = File.join(dir, "fake-deploy-bin")
      FileUtils.mkdir_p(bin_dir)
      marker = File.join(dir, "fake-vercel-ran")
      write_fake_executable(bin_dir, "vercel", "touch #{marker.shellescape}; exit 0")
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "deploy", "--target", "vercel", "--approved", "--json"
      )
      payload = JSON.parse(stdout)
      deploy = payload.fetch("deploy")

      assert_equal 5, code
      assert_equal "", stderr
      assert_equal "blocked", deploy.fetch("status")
      assert_equal "blocked", deploy.dig("verify_loop_gate", "status")
      assert_match(/missing deployment provenance/i, deploy.fetch("blocking_issues").join("\n"))
      assert_equal false, deploy.fetch("provider_cli_invoked")
      refute File.exist?(marker), "legacy verify-loop metadata must not unlock provider command execution"
      assert_equal before_entries, project_entries, "legacy verify-loop provenance blocker must not write deploy artifacts"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "legacy verify-loop provenance blocker must not mutate state"
      refute_includes stdout, ".env"
    end
  end

  def test_github_deploy_help_and_webbuilder_passthrough_surface
    aiweb_stdout, aiweb_stderr, aiweb_code = run_aiweb("help")
    assert_equal 0, aiweb_code
    assert_equal "", aiweb_stderr
    ["github-sync", "deploy-plan", "deploy --target", "cloudflare-pages", "vercel", "--approved"].each do |snippet|
      assert_includes aiweb_stdout, snippet
    end
    assert_includes aiweb_stdout, "deploy provenance"

    web_stdout, web_stderr, web_code = run_webbuilder("help")
    assert_equal 0, web_code
    assert_equal "", web_stderr
    ["github-sync", "deploy-plan", "deploy", "cloudflare-pages", "vercel", "--approved"].each do |snippet|
      assert_includes web_stdout, snippet
    end
  end

  def test_component_map_dry_run_discovers_profile_d_regions_without_writes
    in_tmp do
      prepare_profile_d_scaffold_flow
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      before_state = File.read(".ai-web/state.yaml")
      before_entries = project_entries

      stdout, stderr, code = run_aiweb("component-map", "--dry-run", "--json")
      payload = JSON.parse(stdout)
      after_entries = project_entries

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal true, payload["dry_run"]
      assert_includes %w[planned discovered ready], payload.dig("component_map", "status")
      assert_equal ".ai-web/component-map.json", payload.dig("component_map", "artifact_path") || payload.dig("component_map", "planned_path")
      assert_includes component_map_ids(payload.fetch("component_map")), "page.home"
      assert_includes component_map_ids(payload.fetch("component_map")), "component.hero.copy"
      assert_equal before_entries, after_entries, "component-map --dry-run must not write artifacts"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "component-map --dry-run must not mutate state"
      assert_equal env_body, File.read(".env"), "component-map --dry-run must not mutate .env"
      refute_includes stdout, "do-not-touch"
    end
  end

  def test_component_map_writes_only_local_artifact_from_profile_d_scaffold_ids
    in_tmp do
      prepare_profile_d_scaffold_flow
      before_state = File.read(".ai-web/state.yaml")
      before_entries = project_entries

      payload, code = json_cmd("component-map")
      after_entries = project_entries

      assert_equal 0, code
      assert_equal "created component map", payload["action_taken"]
      assert_equal "ready", payload.dig("component_map", "status")
      assert_equal [".ai-web/component-map.json"], payload["changed_files"]
      assert File.exist?(".ai-web/component-map.json")
      added_entries = after_entries - before_entries
      assert_equal [".ai-web/component-map.json"], added_entries
      assert_equal before_state, File.read(".ai-web/state.yaml"), "component-map must not mutate state"

      artifact = JSON.parse(File.read(".ai-web/component-map.json"))
      assert_equal payload.fetch("component_map"), artifact
      ids = component_map_ids(artifact)
      assert_includes ids, "page.home"
      assert_includes ids, "component.hero.copy"
      hero_mapping = artifact.fetch("components").find { |component| component["data_aiweb_id"] == "component.hero.copy" }
      assert_equal "src/components/Hero.astro", hero_mapping.fetch("source_path")
      assert hero_mapping.key?("kind"), "component mappings should classify source regions"
      assert hero_mapping.key?("route"), "component mappings should retain route context"
      assert_equal true, hero_mapping.fetch("editable")
      refute_includes JSON.generate(artifact), "do-not-touch"
    end
  end

  def test_component_map_blocks_missing_scaffold_without_creating_artifact
    in_tmp do
      json_cmd("init", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      before_state = File.read(".ai-web/state.yaml")
      before_entries = project_entries

      stdout, stderr, code = run_aiweb("component-map", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "blocked", payload.dig("component_map", "status")
      assert_match(/scaffold|src\/pages\/index\.astro|data-aiweb-id/i, [payload.dig("error", "message"), payload["blocking_issues"], payload.dig("component_map", "blocking_issues")].flatten.compact.join("\n"))
      refute File.exist?(".ai-web/component-map.json")
      assert_equal before_entries, project_entries, "blocked component-map must not write artifacts"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "blocked component-map must not mutate state"
      assert_equal env_body, File.read(".env"), "blocked component-map must not mutate .env"
      refute_includes stdout, "do-not-touch"
    end
  end

  def test_visual_edit_dry_run_validates_target_without_writes
    in_tmp do
      prepare_profile_d_scaffold_flow
      json_cmd("component-map")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      before_state = File.read(".ai-web/state.yaml")
      before_entries = project_entries
      before_source = File.read("src/components/Hero.astro")

      stdout, stderr, code = run_aiweb("visual-edit", "--target", "component.hero.copy", "--prompt", "edit", "--dry-run", "--json")
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal true, payload["dry_run"]
      assert_equal "planned", payload.dig("visual_edit", "status")
      assert_equal "component.hero.copy", payload.dig("visual_edit", "target", "data_aiweb_id")
      assert_equal "src/components/Hero.astro", payload.dig("visual_edit", "target", "source_path")
      assert_match(%r{\.ai-web/tasks/visual-edit-}, payload.dig("visual_edit", "planned_task_path"))
      assert_match(%r{\.ai-web/visual/visual-edit-}, payload.dig("visual_edit", "planned_record_path"))
      assert_equal before_entries, project_entries, "visual-edit --dry-run must not write task artifacts"
      assert_equal before_source, File.read("src/components/Hero.astro"), "visual-edit --dry-run must not edit source"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "visual-edit --dry-run must not mutate state"
      assert_equal env_body, File.read(".env"), "visual-edit --dry-run must not mutate .env"
      refute_includes stdout, "do-not-touch"

      missing_stdout, missing_stderr, missing_code = run_aiweb("visual-edit", "--target", "missing.region", "--prompt", "edit", "--dry-run", "--json")
      missing_payload = JSON.parse(missing_stdout)
      assert_equal 1, missing_code
      assert_equal "", missing_stderr
      assert_equal "blocked", missing_payload.dig("visual_edit", "status")
      assert_match(/missing\.region|target/i, [missing_payload.dig("error", "message"), missing_payload["blocking_issues"], missing_payload.dig("visual_edit", "blocking_issues")].flatten.compact.join("\n"))
      assert_equal before_entries, project_entries, "blocked visual-edit --dry-run must not write artifacts"
      refute_includes missing_stdout, "do-not-touch"
    end
  end

  def test_visual_edit_creates_handoff_artifacts_without_source_or_state_mutation
    in_tmp do
      prepare_profile_d_scaffold_flow
      json_cmd("component-map")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      before_state = File.read(".ai-web/state.yaml")
      before_index = File.read("src/pages/index.astro")
      before_hero = File.read("src/components/Hero.astro")
      before_entries = project_entries

      payload, code = json_cmd("visual-edit", "--target", "component.hero.copy", "--prompt", "edit")
      after_entries = project_entries

      assert_equal 0, code
      assert_equal "created visual edit handoff", payload["action_taken"]
      assert_equal "created", payload.dig("visual_edit", "status")
      changed_files = payload.fetch("changed_files")
      assert_equal 2, changed_files.length
      task_path = changed_files.find { |path| path.match?(%r{\A\.ai-web/tasks/visual-edit-.*\.md\z}) }
      record_path = changed_files.find { |path| path.match?(%r{\A\.ai-web/visual/visual-edit-.*\.json\z}) }
      assert task_path, "visual-edit should write a markdown task handoff"
      assert record_path, "visual-edit should write a JSON audit record"
      assert File.exist?(task_path)
      assert File.exist?(record_path)
      added_entries = after_entries - before_entries
      assert_includes added_entries, task_path
      assert_includes added_entries, record_path
      assert_equal [], added_entries - [".ai-web/tasks", task_path, ".ai-web/visual", record_path]
      assert_equal before_index, File.read("src/pages/index.astro"), "visual-edit must not patch page source"
      assert_equal before_hero, File.read("src/components/Hero.astro"), "visual-edit must not patch component source"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "visual-edit must not mutate state"
      assert_equal env_body, File.read(".env"), "visual-edit must not mutate .env"

      record = JSON.parse(File.read(record_path))
      assert_equal "component.hero.copy", record.dig("target", "data_aiweb_id")
      assert_equal "src/components/Hero.astro", record.dig("target", "source_path")
      assert_equal true, record.dig("target_allowlist", "strict")
      assert_equal "visual_edit_target_allowlist", record.dig("target_allowlist", "type")
      assert_equal ["component.hero.copy"], record.dig("target_allowlist", "data_aiweb_ids")
      assert_equal ["src/components/Hero.astro"], record.dig("target_allowlist", "source_paths")
      assert_equal false, record.dig("target_allowlist", "full_page_regeneration_allowed")
      assert_equal "src/components/Hero.astro", record.dig("target_allowlist", "selected_component", "source_path")
      assert_match(/selected region|source auto-patch|no source/i, JSON.generate(record.fetch("guardrails")))
      task_markdown = File.read(task_path)
      assert_includes task_markdown, "Target Source Allowlist"
      assert_includes task_markdown, "visual_edit_target_allowlist"
      assert_includes task_markdown, "Do not regenerate the full page"
      assert_includes task_markdown, "src/components/Hero.astro"
      refute_includes task_markdown, "do-not-touch"
      refute_includes JSON.generate(record), "do-not-touch"
    end
  end

  def test_visual_edit_blocks_ambiguous_target_component_map_without_writes
    in_tmp do
      prepare_profile_d_scaffold_flow
      _map_payload, map_code = json_cmd("component-map")
      assert_equal 0, map_code
      map = JSON.parse(File.read(".ai-web/component-map.json"))
      duplicate = map.fetch("components").find { |component| component["data_aiweb_id"] == "component.hero.copy" }.dup
      duplicate["line"] = duplicate.fetch("line").to_i + 1
      map.fetch("components") << duplicate
      File.write(".ai-web/component-map.json", JSON.pretty_generate(map))
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb("visual-edit", "--target", "component.hero.copy", "--prompt", "edit", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "blocked", payload.dig("visual_edit", "status")
      assert_match(/ambiguous|component\.hero\.copy/i, [payload.dig("error", "message"), payload["blocking_issues"], payload.dig("visual_edit", "blocking_issues")].flatten.compact.join("\n"))
      assert_equal before_entries, project_entries, "ambiguous visual-edit must not write task or record artifacts"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "ambiguous visual-edit must not mutate state"
    end
  end

  def test_visual_edit_blocks_unsafe_target_source_path_without_leaking_or_writing
    in_tmp do
      prepare_profile_d_scaffold_flow
      json_cmd("component-map")
      secret = "SECRET=pr24-visual-target-do-not-leak"
      File.write(".env", "#{secret}\n")
      map = JSON.parse(File.read(".ai-web/component-map.json"))
      target = map.fetch("components").find { |component| component["data_aiweb_id"] == "component.hero.copy" }
      target["source_path"] = ".env"
      File.write(".ai-web/component-map.json", JSON.pretty_generate(map))
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")
      env_size = File.size(".env")
      env_mtime = File.mtime(".env")

      stdout, stderr, code = run_aiweb("visual-edit", "--target", "component.hero.copy", "--prompt", "edit", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "blocked", payload.dig("visual_edit", "status")
      assert_match(/unsafe|\.env|source path/i, [payload.dig("error", "message"), payload["blocking_issues"], payload.dig("visual_edit", "blocking_issues")].flatten.compact.join("\n"))
      assert_equal before_entries, project_entries, "unsafe source visual-edit must not write artifacts"
      assert_equal before_state, File.read(".ai-web/state.yaml"), "unsafe source visual-edit must not mutate state"
      assert_equal env_size, File.size(".env")
      assert_equal env_mtime, File.mtime(".env")
      refute_includes stdout, secret
    end
  end

  def test_visual_edit_rejects_env_map_paths_without_leaking_or_writing
    in_tmp do
      prepare_profile_d_scaffold_flow
      json_cmd("component-map")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      File.write(".env.local", "LOCAL_SECRET=do-not-touch-too\n")
      before_state = File.read(".ai-web/state.yaml")
      before_entries = project_entries

      [".env", ".env/map.json", "nested/.env.local/map.json"].each do |forbidden_path|
        stdout, stderr, code = run_aiweb("visual-edit", "--target", "component.hero.copy", "--prompt", "edit", "--from-map", forbidden_path, "--json")
        payload = JSON.parse(stdout)

        assert_equal 1, code, forbidden_path
        assert_equal "", stderr, forbidden_path
        assert_equal "blocked", payload.dig("visual_edit", "status"), forbidden_path
        assert_match(/unsafe|\.env|map path/i, [payload.dig("error", "message"), payload["blocking_issues"], payload.dig("visual_edit", "blocking_issues")].flatten.compact.join("\n"), forbidden_path)
        assert_equal before_entries, project_entries, "unsafe .env map path must not create visual-edit artifacts (#{forbidden_path})"
        assert_equal before_state, File.read(".ai-web/state.yaml"), "unsafe .env map path must not mutate state (#{forbidden_path})"
        assert_equal env_body, File.read(".env"), "unsafe .env map path must not mutate .env (#{forbidden_path})"
        refute_includes stdout, "do-not-touch", forbidden_path
        refute_includes stdout, "do-not-touch-too", forbidden_path
      end
    end
  end

  def test_component_map_and_visual_edit_help_and_webbuilder_passthrough
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr
    assert_includes stdout, "component-map [--force]"
    assert_includes stdout, "visual-edit --target DATA_AIWEB_ID --prompt TEXT"

    help_stdout, help_stderr, help_code = run_webbuilder("--help")
    assert_equal 0, help_code
    assert_equal "", help_stderr
    assert_match(/component-map/, help_stdout)
    assert_match(/visual-edit/, help_stdout)

    in_tmp do |dir|
      target = File.join(dir, "passthrough-visual-edit")
      Dir.mkdir(target)
      Dir.chdir(target) { prepare_profile_d_scaffold_flow }

      map_stdout, map_stderr, map_code = run_webbuilder("--path", target, "component-map", "--dry-run", "--json")
      map_payload = JSON.parse(map_stdout)
      assert_equal 0, map_code
      assert_equal "", map_stderr
      assert_includes %w[planned discovered ready], map_payload.dig("component_map", "status")
      refute File.exist?(File.join(target, ".ai-web", "component-map.json")), "webbuilder component-map --dry-run must not write artifact"

      _created_map, created_map_code = json_cmd("--path", target, "component-map")
      assert_equal 0, created_map_code
      before_task_artifacts = Dir.glob(File.join(target, ".ai-web", "tasks", "visual-edit-*"))
      before_visual_artifacts = Dir.glob(File.join(target, ".ai-web", "visual", "visual-edit-*"))
      edit_stdout, edit_stderr, edit_code = run_webbuilder("--path", target, "visual-edit", "--target", "component.hero.copy", "--prompt", "edit", "--dry-run", "--json")
      edit_payload = JSON.parse(edit_stdout)
      assert_equal 0, edit_code
      assert_equal "", edit_stderr
      assert_equal "planned", edit_payload.dig("visual_edit", "status")
      assert_equal before_task_artifacts, Dir.glob(File.join(target, ".ai-web", "tasks", "visual-edit-*")), "webbuilder visual-edit --dry-run must not write task artifacts"
      assert_equal before_visual_artifacts, Dir.glob(File.join(target, ".ai-web", "visual", "visual-edit-*")), "webbuilder visual-edit --dry-run must not write record artifacts"
    end
  end

  def test_workbench_help_and_webbuilder_passthrough
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr
    assert_includes stdout, "workbench [--export] [--serve] [--approved]"
    assert_includes stdout, "workbench --serve --dry-run"
    assert_match(/workbench: .*local .*UI|workbench: .*local UI manifest/i, stdout)

    help_stdout, help_stderr, help_code = run_webbuilder("--help")
    assert_equal 0, help_code
    assert_equal "", help_stderr
    assert_match(/workbench/, help_stdout)
    assert_match(/workbench --serve --dry-run/, help_stdout)

    in_tmp do |dir|
      target = File.join(dir, "passthrough-workbench")
      Dir.mkdir(target)
      Dir.chdir(target) do
        prepare_profile_d_design_flow
        File.write(".env", "SECRET=do-not-touch\n")
      end

      web_stdout, web_stderr, web_code = run_webbuilder("--path", target, "workbench", "--dry-run", "--json")
      web_payload = JSON.parse(web_stdout)
      assert_equal 0, web_code
      assert_equal "", web_stderr
      assert_equal "planned", web_payload.dig("workbench", "status")
      assert_equal true, web_payload.dig("workbench", "dry_run")
      refute Dir.exist?(File.join(target, ".ai-web", "workbench")), "webbuilder workbench --dry-run must not write artifacts"
      refute_includes web_stdout, "do-not-touch"

      serve_stdout, serve_stderr, serve_code = run_webbuilder("--path", target, "workbench", "--serve", "--dry-run", "--json")
      serve_payload = JSON.parse(serve_stdout)
      assert_equal 0, serve_code
      assert_equal "", serve_stderr
      assert_equal "planned", serve_payload.dig("workbench", "status")
      assert_equal "127.0.0.1", serve_payload.dig("workbench", "serve", "host")
      refute Dir.exist?(File.join(target, ".ai-web", "workbench")), "webbuilder workbench --serve --dry-run must not write artifacts"
      refute_includes serve_stdout, "do-not-touch"
    end
  end


  def test_preview_blocks_uninitialized_and_unready_without_touching_env_or_runs
    in_tmp do
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)

      stdout, stderr, code = run_aiweb("preview", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "error", payload["status"]
      assert_match(/not initialized|initialize/i, payload.dig("error", "message"))
      assert_match(/not initialized|initialize/i, payload["blocking_issues"].join("\n"))
      refute Dir.exist?(".ai-web/runs"), "uninitialized preview must not create run artifacts"
      assert_equal env_body, File.read(".env"), "uninitialized preview must not mutate .env"

      json_cmd("init", "--profile", "D")
      before_state = File.read(".ai-web/state.yaml")
      stdout, stderr, code = run_aiweb("preview", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "scaffold preview blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("preview", "status")
      assert_match(/Scaffold has not been created|runtime-plan/i, payload["blocking_issues"].join("\n"))
      assert_equal before_state, File.read(".ai-web/state.yaml"), "blocked preview preflight must not persist state changes"
      assert_equal env_body, File.read(".env"), "blocked preview must not mutate .env"
      refute Dir.exist?(".ai-web/runs"), "blocked preview preflight must not create run artifacts"
      refute Dir.exist?("node_modules"), "preview must not install dependencies"
      refute Dir.exist?("dist"), "blocked preview must not run Astro"
    end
  end

  def test_preview_dry_run_on_ready_scaffold_plans_without_files_or_process
    in_tmp do
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      before_entries = Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." || path == ".." }.sort

      stdout, stderr, code = run_aiweb("preview", "--dry-run", "--json")
      payload = JSON.parse(stdout)
      after_entries = Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." || path == ".." }.sort

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal true, payload["dry_run"]
      assert_equal "planned scaffold preview", payload["action_taken"]
      assert_equal "dry_run", payload.dig("preview", "status")
      assert_equal true, payload.dig("preview", "dry_run")
      assert_equal "pnpm dev --host 127.0.0.1", payload.dig("preview", "command")
      assert_match(%r{http://(localhost|127\.0\.0\.1):4321/?}, payload.dig("preview", "preview_url"))
      assert_nil payload.dig("preview", "pid"), "dry-run preview must not record a live process"
      assert_match(%r{\A\.ai-web/runs/preview-\d{8}T\d{6}Z/stdout\.log\z}, payload.dig("preview", "stdout_log"))
      assert_match(%r{\A\.ai-web/runs/preview-\d{8}T\d{6}Z/stderr\.log\z}, payload.dig("preview", "stderr_log"))
      assert_match(%r{\A\.ai-web/runs/preview-\d{8}T\d{6}Z/preview\.json\z}, payload.dig("preview", "metadata_path"))
      assert payload["changed_files"].any? { |path| path.match?(%r{\A\.ai-web/runs/preview-\d{8}T\d{6}Z\z}) }
      assert_equal before_entries, after_entries, "preview --dry-run must not write run artifacts or generated output"
      assert_equal env_body, File.read(".env"), "preview --dry-run must not mutate .env"
      refute Dir.exist?("node_modules"), "preview --dry-run must not install dependencies"
      refute Dir.exist?("dist"), "preview --dry-run must not run Astro"
    end
  end

  def test_preview_ready_scaffold_blocks_deterministically_when_pnpm_is_missing
    in_tmp do
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      empty_path = File.join(Dir.pwd, "empty-path")
      FileUtils.mkdir_p(empty_path)

      stdout, stderr, code = run_aiweb_env({ "PATH" => [empty_path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }, "preview", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "scaffold preview blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("preview", "status")
      assert_nil payload.dig("preview", "pid")
      assert_nil payload.dig("preview", "exit_code")
      assert_match(/pnpm executable is missing/, payload["blocking_issues"].join("\n"))
      assert File.file?(payload.dig("preview", "metadata_path"))
      assert_equal env_body, File.read(".env"), "missing-pnpm preview must not mutate .env"
      refute Dir.exist?("node_modules"), "missing-pnpm preview must not install dependencies"
      refute Dir.exist?("dist"), "missing-pnpm preview must not create dist"
    end
  end

  def test_preview_ready_scaffold_blocks_deterministically_when_node_modules_is_missing
    in_tmp do
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      bin_dir = File.join(Dir.pwd, "fake-bin")
      FileUtils.mkdir_p(bin_dir)
      write_fake_executable(bin_dir, "pnpm", "echo should-not-run >&2; exit 99")

      stdout, stderr, code = run_aiweb_env({ "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }, "preview", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "scaffold preview blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("preview", "status")
      assert_nil payload.dig("preview", "pid")
      assert_nil payload.dig("preview", "exit_code")
      assert_match(/node_modules is missing/, payload["blocking_issues"].join("\n"))
      assert_equal payload.dig("preview", "blocking_issues").join("\n") + "\n", File.read(payload.dig("preview", "stderr_log"))
      assert_equal env_body, File.read(".env"), "missing-node_modules preview must not mutate .env"
      refute Dir.exist?("dist"), "missing-node_modules preview must not create dist"
    end
  end

  def test_preview_records_running_fake_dev_server_duplicate_and_stop
    in_tmp do |dir|
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      FileUtils.mkdir_p("node_modules")
      bin_dir = File.join(dir, "fake-bin")
      FileUtils.mkdir_p(bin_dir)
      write_fake_executable(
        bin_dir,
        "pnpm",
        "[ \"$1\" = dev ] || exit 64\necho fake astro dev stdout\necho fake astro dev stderr >&2\ntrap 'exit 0' TERM INT\nwhile :; do sleep 1; done"
      )
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }
      pid = nil

      begin
        stdout, stderr, code = run_webbuilder_env(env, "--path", Dir.pwd, "preview", "--json")
        payload = JSON.parse(stdout)

        assert_equal 0, code
        assert_equal "", stderr
        assert_equal "started scaffold preview", payload["action_taken"]
        assert_equal "running", payload.dig("preview", "status")
        assert_equal "pnpm dev --host 127.0.0.1", payload.dig("preview", "command")
        assert_match(%r{http://(localhost|127\.0\.0\.1):4321/?}, payload.dig("preview", "preview_url"))
        pid = payload.dig("preview", "pid")
        assert_kind_of Integer, pid
        assert_operator pid, :>, 0
        assert_empty payload["blocking_issues"]
        assert File.file?(payload.dig("preview", "stdout_log"))
        assert File.file?(payload.dig("preview", "stderr_log"))
        assert File.file?(payload.dig("preview", "metadata_path"))
        assert_equal payload["preview"], JSON.parse(File.read(payload.dig("preview", "metadata_path")))
        Process.kill(0, pid)
        assert_equal env_body, File.read(".env"), "successful preview must not mutate .env"
        refute Dir.exist?("dist"), "preview must not run a build"

        duplicate_stdout, duplicate_stderr, duplicate_code = run_aiweb_env(env, "preview", "--json")
        duplicate_payload = JSON.parse(duplicate_stdout)
        assert_equal 0, duplicate_code
        assert_equal "", duplicate_stderr
        assert_equal "scaffold preview already running", duplicate_payload["action_taken"]
        assert_equal "already_running", duplicate_payload.dig("preview", "status")
        assert_equal pid, duplicate_payload.dig("preview", "pid")
        assert_equal payload.dig("preview", "metadata_path"), duplicate_payload.dig("preview", "metadata_path")

        stop_stdout, stop_stderr, stop_code = run_aiweb_env(env, "preview", "--stop", "--json")
        stop_payload = JSON.parse(stop_stdout)
        assert_equal 0, stop_code
        assert_equal "", stop_stderr
        assert_equal "stopped scaffold preview", stop_payload["action_taken"]
        assert_equal "stopped", stop_payload.dig("preview", "status")
        assert_equal pid, stop_payload.dig("preview", "stopped_pid")
        assert File.file?(stop_payload.dig("preview", "metadata_path"))
        assert_equal stop_payload["preview"], JSON.parse(File.read(stop_payload.dig("preview", "metadata_path")))
        assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
        refute_windows_process_command_includes(File.join(bin_dir, "pnpm-fake.rb"))
        pid = nil
      ensure
        if pid
          begin
            Process.kill(windows? ? "KILL" : "TERM", pid)
          rescue Errno::ESRCH
            nil
          end
        end
      end
    end
  end

  def test_build_uninitialized_project_fails_without_initializing_aiweb_or_touching_env
    in_tmp do
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)

      stdout, stderr, code = run_aiweb("build", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "error", payload["status"]
      assert_match(/not initialized/, payload.dig("error", "message"))
      refute Dir.exist?(".ai-web"), "uninitialized build must not initialize .ai-web"
      assert_equal env_body, File.read(".env"), "uninitialized build must not mutate .env"
      refute Dir.exist?("node_modules"), "uninitialized build must not install dependencies"
      refute Dir.exist?("dist"), "uninitialized build must not run Astro"
    end
  end

  def test_build_blocks_when_runtime_plan_is_not_ready_without_touching_env_or_runs
    in_tmp do
      json_cmd("init", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb("build", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "scaffold build blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("build", "status")
      assert_equal "pnpm build", payload.dig("build", "command")
      assert_equal false, payload.dig("build", "dry_run")
      assert_match(/Scaffold has not been created/, payload["blocking_issues"].join("\n"))
      assert_empty payload["changed_files"]
      assert_equal before_state, File.read(".ai-web/state.yaml")
      assert_equal env_body, File.read(".env"), "build must not mutate .env"
      refute Dir.exist?(".ai-web/runs"), "blocked runtime-plan preflight must not create run artifacts"
      refute Dir.exist?("node_modules"), "build must not install dependencies"
      refute Dir.exist?("dist"), "blocked build must not run Astro"
    end
  end

  def test_build_dry_run_on_ready_scaffold_plans_without_writes_install_or_build
    in_tmp do
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      before_entries = Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." || path == ".." }.sort

      stdout, stderr, code = run_aiweb("build", "--dry-run", "--json")
      payload = JSON.parse(stdout)
      after_entries = Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." || path == ".." }.sort

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal true, payload["dry_run"]
      assert_equal "planned scaffold build", payload["action_taken"]
      assert_equal "dry_run", payload.dig("build", "status")
      assert_equal true, payload.dig("build", "dry_run")
      assert_equal "pnpm build", payload.dig("build", "command")
      assert_match(%r{\A\.ai-web/runs/build-\d{8}T\d{6}Z/stdout\.log\z}, payload.dig("build", "stdout_log"))
      assert_match(%r{\A\.ai-web/runs/build-\d{8}T\d{6}Z/stderr\.log\z}, payload.dig("build", "stderr_log"))
      assert_match(%r{\A\.ai-web/runs/build-\d{8}T\d{6}Z/build\.json\z}, payload.dig("build", "metadata_path"))
      assert payload["changed_files"].any? { |path| path.match?(%r{\A\.ai-web/runs/build-\d{8}T\d{6}Z\z}) }
      assert_equal before_entries, after_entries, "build --dry-run must not write run artifacts or generated output"
      assert_equal env_body, File.read(".env"), "build --dry-run must not mutate .env"
      refute Dir.exist?("node_modules"), "build --dry-run must not install dependencies"
      refute Dir.exist?("dist"), "build --dry-run must not run Astro"
    end
  end

  def test_build_ready_scaffold_records_blocked_run_artifacts_for_missing_local_tooling
    in_tmp do
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)

      stdout, stderr, code = run_aiweb("build", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "scaffold build blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("build", "status")
      assert_equal false, payload.dig("build", "dry_run")
      assert_equal "pnpm build", payload.dig("build", "command")
      assert_nil payload.dig("build", "exit_code"), "blocked preconditions should not execute the build command"
      assert_match(/pnpm executable is missing|node_modules is missing/, payload["blocking_issues"].join("\n"))
      assert_match(%r{\A\.ai-web/runs/build-\d{8}T\d{6}Z/stdout\.log\z}, payload.dig("build", "stdout_log"))
      assert_match(%r{\A\.ai-web/runs/build-\d{8}T\d{6}Z/stderr\.log\z}, payload.dig("build", "stderr_log"))
      assert_match(%r{\A\.ai-web/runs/build-\d{8}T\d{6}Z/build\.json\z}, payload.dig("build", "metadata_path"))
      assert File.file?(payload.dig("build", "stdout_log"))
      assert File.file?(payload.dig("build", "stderr_log"))
      assert File.file?(payload.dig("build", "metadata_path"))
      metadata = JSON.parse(File.read(payload.dig("build", "metadata_path")))
      assert_equal payload["build"], metadata
      assert_equal payload.dig("build", "blocking_issues").join("\n") + "\n", File.read(payload.dig("build", "stderr_log"))
      assert_equal env_body, File.read(".env"), "build must not mutate .env"
      refute Dir.exist?("node_modules"), "build must not install dependencies"
      refute Dir.exist?("dist"), "blocked local tooling must not create build output"
    end
  end

  def test_build_ready_scaffold_blocks_deterministically_when_pnpm_is_missing
    in_tmp do
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      empty_path = File.join(Dir.pwd, "empty-path")
      FileUtils.mkdir_p(empty_path)

      stdout, stderr, code = run_aiweb_env({ "PATH" => [empty_path, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }, "build", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "scaffold build blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("build", "status")
      assert_nil payload.dig("build", "exit_code")
      assert_match(/pnpm executable is missing/, payload["blocking_issues"].join("\n"))
      assert File.file?(payload.dig("build", "metadata_path"))
      assert_equal env_body, File.read(".env"), "missing-pnpm build must not mutate .env"
      refute Dir.exist?("node_modules"), "missing-pnpm build must not install dependencies"
      refute Dir.exist?("dist"), "missing-pnpm build must not create dist"
    end
  end

  def test_build_ready_scaffold_blocks_deterministically_when_node_modules_is_missing
    in_tmp do
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      bin_dir = File.join(Dir.pwd, "fake-bin")
      FileUtils.mkdir_p(bin_dir)
      write_fake_executable(bin_dir, "pnpm", "echo should-not-run >&2; exit 99")

      stdout, stderr, code = run_aiweb_env({ "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }, "build", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "scaffold build blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("build", "status")
      assert_nil payload.dig("build", "exit_code")
      assert_match(/node_modules is missing/, payload["blocking_issues"].join("\n"))
      assert_equal payload.dig("build", "blocking_issues").join("\n") + "\n", File.read(payload.dig("build", "stderr_log"))
      assert_equal env_body, File.read(".env"), "missing-node_modules build must not mutate .env"
      refute Dir.exist?("dist"), "missing-node_modules build must not create dist"
    end
  end

  def test_build_ready_scaffold_records_successful_fake_pnpm_build_artifacts
    in_tmp do
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      FileUtils.mkdir_p("node_modules")
      bin_dir = File.join(Dir.pwd, "fake-bin")
      FileUtils.mkdir_p(bin_dir)
      write_fake_executable(
        bin_dir,
        "pnpm",
        "[ \"$1\" = build ] || exit 64\necho fake astro build stdout\necho fake astro build stderr >&2\nmkdir -p dist\nprintf built > dist/index.html"
      )

      stdout, stderr, code = run_aiweb_env({ "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }, "build", "--json")
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal "ran scaffold build", payload["action_taken"]
      assert_equal "passed", payload.dig("build", "status")
      assert_equal 0, payload.dig("build", "exit_code")
      assert_equal "dist", payload.dig("build", "build_output_path")
      assert_empty payload["blocking_issues"]
      assert_equal "fake astro build stdout\n", File.read(payload.dig("build", "stdout_log"))
      assert_equal "fake astro build stderr\n", File.read(payload.dig("build", "stderr_log"))
      metadata = JSON.parse(File.read(payload.dig("build", "metadata_path")))
      assert_equal payload["build"], metadata
      assert_equal "built", File.read("dist/index.html")
      assert_equal env_body, File.read(".env"), "successful build must not mutate .env"
    end
  end


  def test_qa_playwright_uninitialized_and_unready_are_safe
    in_tmp do
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)

      stdout, stderr, code = run_aiweb("qa-playwright", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "error", payload["status"]
      assert_match(/not initialized|initialize/i, payload.dig("error", "message"))
      refute Dir.exist?(".ai-web/runs"), "uninitialized qa-playwright must not create run artifacts"
      assert_equal env_body, File.read(".env"), "uninitialized qa-playwright must not mutate .env"

      json_cmd("init", "--profile", "D")
      before_state = File.read(".ai-web/state.yaml")
      stdout, stderr, code = run_aiweb("qa-playwright", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "playwright QA blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("playwright_qa", "status")
      assert_equal false, payload.dig("playwright_qa", "dry_run")
      assert_match(/Scaffold has not been created|runtime-plan/i, payload["blocking_issues"].join("\n"))
      assert_empty payload["changed_files"]
      assert_equal before_state, File.read(".ai-web/state.yaml"), "runtime-plan block must not persist state changes"
      assert_equal env_body, File.read(".env"), "blocked qa-playwright must not mutate .env"
      refute Dir.exist?(".ai-web/runs"), "runtime-plan block must not create run artifacts"
      refute Dir.exist?("node_modules"), "qa-playwright must not install dependencies"
      refute Dir.exist?("dist"), "qa-playwright must not run build output"
    end
  end

  def test_qa_playwright_dry_run_on_ready_scaffold_plans_without_writes
    in_tmp do
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      before_entries = Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." || path == ".." }.sort

      stdout, stderr, code = run_aiweb("qa-playwright", "--url", "http://127.0.0.1:4321", "--task-id", "dry-smoke", "--dry-run", "--json")
      payload = JSON.parse(stdout)
      after_entries = Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." || path == ".." }.sort

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal true, payload["dry_run"]
      assert_equal "planned Playwright QA", payload["action_taken"]
      assert_equal "dry_run", payload.dig("playwright_qa", "status")
      assert_equal true, payload.dig("playwright_qa", "dry_run")
      assert_equal "http://127.0.0.1:4321", payload.dig("playwright_qa", "url")
      assert_equal "dry-smoke", payload.dig("playwright_qa", "task_id")
      assert_match(/pnpm exec playwright test .* --reporter=json/, payload.dig("playwright_qa", "command"))
      assert_match(%r{\A\.ai-web/runs/playwright-qa-\d{8}T\d{6}Z/smoke\.spec\.(js|mjs)\z}, payload.dig("playwright_qa", "spec_path"))
      assert_match(%r{\A\.ai-web/runs/playwright-qa-\d{8}T\d{6}Z/stdout\.log\z}, payload.dig("playwright_qa", "stdout_log"))
      assert_match(%r{\A\.ai-web/runs/playwright-qa-\d{8}T\d{6}Z/stderr\.log\z}, payload.dig("playwright_qa", "stderr_log"))
      assert_match(%r{\A\.ai-web/runs/playwright-qa-\d{8}T\d{6}Z/playwright-qa\.json\z}, payload.dig("playwright_qa", "metadata_path"))
      assert_nil payload.dig("playwright_qa", "exit_code"), "dry-run must not execute Playwright"
      assert payload["changed_files"].any? { |path| path.match?(%r{\A\.ai-web/runs/playwright-qa-\d{8}T\d{6}Z\z}) }
      assert_equal before_entries, after_entries, "qa-playwright --dry-run must not write run artifacts or generated specs"
      assert_equal env_body, File.read(".env"), "qa-playwright --dry-run must not mutate .env"
      refute Dir.exist?("node_modules"), "qa-playwright --dry-run must not install dependencies"
      refute Dir.exist?("dist"), "qa-playwright --dry-run must not run a build"
    end
  end

  def test_qa_playwright_missing_local_playwright_blocks_with_artifacts
    in_tmp do
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      FileUtils.mkdir_p("node_modules")
      bin_dir = File.join(Dir.pwd, "fake-bin")
      FileUtils.mkdir_p(bin_dir)
      write_fake_executable(bin_dir, "pnpm", "echo should-not-run >&2; exit 99")

      stdout, stderr, code = run_aiweb_env({ "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }, "qa-playwright", "--url", "http://127.0.0.1:4321", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "playwright QA blocked", payload["action_taken"]
      assert_equal "blocked", payload.dig("playwright_qa", "status")
      assert_nil payload.dig("playwright_qa", "exit_code"), "missing local Playwright must not execute pnpm"
      assert_match(/Playwright executable is missing|node_modules\/\.bin\/playwright/, payload["blocking_issues"].join("\n"))
      assert_match(%r{\A\.ai-web/runs/playwright-qa-\d{8}T\d{6}Z/stdout\.log\z}, payload.dig("playwright_qa", "stdout_log"))
      assert_match(%r{\A\.ai-web/runs/playwright-qa-\d{8}T\d{6}Z/stderr\.log\z}, payload.dig("playwright_qa", "stderr_log"))
      assert_match(%r{\A\.ai-web/runs/playwright-qa-\d{8}T\d{6}Z/playwright-qa\.json\z}, payload.dig("playwright_qa", "metadata_path"))
      assert_match(%r{\A\.ai-web/qa/results/qa-\d{8}T\d{6}Z-.*\.json\z}, payload.dig("playwright_qa", "result_path"))
      assert File.file?(payload.dig("playwright_qa", "stdout_log"))
      assert File.file?(payload.dig("playwright_qa", "stderr_log"))
      assert File.file?(payload.dig("playwright_qa", "metadata_path"))
      result = JSON.parse(File.read(payload.dig("playwright_qa", "result_path")))
      assert_equal "blocked", result["status"]
      assert_equal "http://127.0.0.1:4321", result.dig("environment", "url")
      assert_equal payload.dig("playwright_qa", "blocking_issues").join("\n") + "\n", File.read(payload.dig("playwright_qa", "stderr_log"))
      assert_equal env_body, File.read(".env"), "missing-local-playwright QA must not mutate .env"
      refute Dir.exist?("dist"), "qa-playwright must not build or deploy"
    end
  end

  def test_qa_playwright_records_fake_pass_and_fail_results
    in_tmp do |dir|
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      bin_dir = write_fake_playwright_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      stdout, stderr, code = run_aiweb_env(env, "qa-playwright", "--url", "http://127.0.0.1:4321", "--task-id", "smoke-pass", "--json")
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal "ran Playwright QA", payload["action_taken"]
      assert_equal "passed", payload.dig("playwright_qa", "status")
      assert_equal 0, payload.dig("playwright_qa", "exit_code")
      assert_match(/pnpm exec playwright test .* --reporter=json/, payload.dig("playwright_qa", "command"))
      assert_match(%r{\A\.ai-web/runs/playwright-qa-\d{8}T\d{6}Z/smoke\.spec\.(js|mjs)\z}, payload.dig("playwright_qa", "spec_path"))
      assert File.file?(payload.dig("playwright_qa", "spec_path"))
      assert File.file?(payload.dig("playwright_qa", "metadata_path"))
      assert File.file?(payload.dig("playwright_qa", "result_path"))
      pass_result = JSON.parse(File.read(payload.dig("playwright_qa", "result_path")))
      assert_equal "passed", pass_result["status"]
      assert_equal "smoke-pass", pass_result["task_id"]
      assert_equal "http://127.0.0.1:4321", pass_result.dig("environment", "url")
      assert_equal "fake playwright pass\n", File.read(payload.dig("playwright_qa", "stderr_log"))
      assert_equal env_body, File.read(".env"), "successful qa-playwright must not mutate .env"
      refute Dir.exist?("dist"), "qa-playwright must not run build output"

      fail_env = env.merge("PLAYWRIGHT_FAKE_STATUS" => "failed")
      fail_stdout, fail_stderr, fail_code = run_aiweb_env(fail_env, "qa-playwright", "--url", "http://127.0.0.1:4321", "--task-id", "smoke-fail", "--json")
      fail_payload = JSON.parse(fail_stdout)

      assert_equal 1, fail_code
      assert_equal "", fail_stderr
      assert_equal "ran Playwright QA", fail_payload["action_taken"]
      assert_equal "failed", fail_payload.dig("playwright_qa", "status")
      assert_equal 1, fail_payload.dig("playwright_qa", "exit_code")
      fail_result = JSON.parse(File.read(fail_payload.dig("playwright_qa", "result_path")))
      assert_equal "failed", fail_result["status"]
      assert_equal "smoke-fail", fail_result["task_id"]
      assert_match(/fake playwright failure/, File.read(fail_payload.dig("playwright_qa", "stderr_log")))
      assert_equal env_body, File.read(".env"), "failed qa-playwright must not mutate .env"
      refute Dir.exist?("dist"), "failed qa-playwright must not build or deploy"
    end
  end

  PR12_QA_COMMANDS = [
    ["qa-a11y", "a11y_qa", "axe", "A11Y_FAKE_STATUS"],
    ["qa-lighthouse", "lighthouse_qa", "lighthouse", "LIGHTHOUSE_FAKE_STATUS"]
  ].freeze

  VISUAL_CRITIQUE_SCORE_KEYS = %w[
    first_impression
    hierarchy
    typography
    layout_rhythm
    spacing
    color
    originality
    mobile_polish
    brand_fit
    intent_fit
    content_credibility
    interaction_clarity
  ].freeze

  def write_visual_critique_fixture(path, scores:)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(
      path,
      JSON.pretty_generate(
        "viewport" => { "width" => 1440, "height" => 900, "name" => "desktop" },
        "scores" => scores,
        "observations" => ["fixture observation"]
      )
    )
    path
  end

  def assert_visual_critique_scores(payload)
    scores = payload.dig("visual_critique", "scores")
    assert_kind_of Hash, scores
    VISUAL_CRITIQUE_SCORE_KEYS.each do |key|
      assert_includes scores, key
      assert_kind_of Numeric, scores[key], "#{key} score must be numeric"
      assert_operator scores[key], :>=, 0
      assert_operator scores[key], :<=, 100
    end
  end

  def screenshot_entry_for(payload, viewport)
    screenshots = payload.fetch("screenshots")
    case screenshots
    when Hash
      screenshots.fetch(viewport)
    when Array
      screenshots.find { |entry| entry["viewport"] == viewport || entry["name"] == viewport } || flunk("missing #{viewport} screenshot entry")
    else
      flunk("unexpected screenshots shape: #{screenshots.class}")
    end
  end

  def screenshot_path_for(payload, viewport)
    screenshot_entry_for(payload, viewport).fetch("path")
  end

  def screenshot_paths_by_viewport(payload)
    %w[mobile tablet desktop].to_h { |viewport| [viewport, screenshot_path_for(payload, viewport)] }
  end

  def record_visual_critique_fixture!(task_id:, scores:)
    FileUtils.mkdir_p("evidence")
    screenshot_path = File.join("evidence", "#{task_id}.png")
    File.binwrite(screenshot_path, "fake screenshot bytes")
    metadata_path = write_visual_critique_fixture(
      File.join("evidence", "#{task_id}-metadata.json"),
      scores: scores
    )

    json_cmd(
      "visual-critique",
      "--screenshot", screenshot_path,
      "--metadata", metadata_path,
      "--task-id", task_id
    )
  end

  def test_visual_critique_dry_run_plans_from_explicit_local_evidence_without_writes
    in_tmp do
      json_cmd("init", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      FileUtils.mkdir_p("evidence")
      screenshot_path = File.join("evidence", "homepage.png")
      File.binwrite(screenshot_path, "fake screenshot bytes")
      metadata_path = write_visual_critique_fixture(
        File.join("evidence", "visual-metadata.json"),
        scores: VISUAL_CRITIQUE_SCORE_KEYS.to_h { |key| [key, 88] }
      )
      before_entries = Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." || path == ".." }.sort

      stdout, stderr, code = run_aiweb(
        "visual-critique",
        "--screenshot", screenshot_path,
        "--metadata", metadata_path,
        "--task-id", "hero-dry",
        "--dry-run",
        "--json"
      )
      payload = JSON.parse(stdout)
      after_entries = Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." || path == ".." }.sort

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal true, payload["dry_run"]
      assert_equal "planned visual critique", payload["action_taken"]
      assert_equal "dry_run", payload.dig("visual_critique", "status")
      assert_equal true, payload.dig("visual_critique", "dry_run")
      assert_equal "hero-dry", payload.dig("visual_critique", "task_id")
      assert_equal screenshot_path, payload.dig("visual_critique", "screenshot_path")
      assert_equal metadata_path, payload.dig("visual_critique", "metadata_path")
      assert_match(%r{\A\.ai-web/visual/visual-critique-\d{8}T\d{6}Z-hero-dry\.json\z}, payload.dig("visual_critique", "artifact_path"))
      assert_equal "pass", payload.dig("visual_critique", "approval")
      assert_visual_critique_scores(payload)
      assert_kind_of Array, payload.dig("visual_critique", "issues")
      assert_kind_of Array, payload.dig("visual_critique", "patch_plan")
      assert_equal before_entries, after_entries, "visual-critique --dry-run must not write artifacts or state"
      assert_equal env_body, File.read(".env"), "visual-critique --dry-run must not mutate .env"
    end
  end

  def test_visual_critique_records_artifact_and_latest_state_for_passing_fixture
    in_tmp do
      json_cmd("init", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      FileUtils.mkdir_p("evidence")
      screenshot_path = File.join("evidence", "homepage.png")
      File.binwrite(screenshot_path, "fake screenshot bytes")
      metadata_path = write_visual_critique_fixture(
        File.join("evidence", "visual-metadata.json"),
        scores: VISUAL_CRITIQUE_SCORE_KEYS.to_h { |key| [key, 91] }
      )

      stdout, stderr, code = run_aiweb(
        "visual-critique",
        "--screenshot", screenshot_path,
        "--metadata", metadata_path,
        "--task-id", "hero-pass",
        "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 0, code
      assert_equal "", stderr
      assert_equal "recorded visual critique", payload["action_taken"]
      assert_equal "passed", payload.dig("visual_critique", "status")
      assert_equal false, payload.dig("visual_critique", "dry_run")
      assert_equal "hero-pass", payload.dig("visual_critique", "task_id")
      assert_equal "pass", payload.dig("visual_critique", "approval")
      assert_visual_critique_scores(payload)
      artifact_path = payload.dig("visual_critique", "artifact_path")
      assert_match(%r{\A\.ai-web/visual/visual-critique-\d{8}T\d{6}Z-hero-pass\.json\z}, artifact_path)
      assert File.file?(artifact_path)
      artifact = JSON.parse(File.read(artifact_path))
      assert_equal payload["visual_critique"], artifact
      assert_equal artifact_path, load_state.dig("qa", "latest_visual_critique")
      assert_equal env_body, File.read(".env"), "visual-critique must not mutate .env"
      refute Dir.exist?("dist"), "visual-critique must not build or deploy"
      refute Dir.exist?(".ai-web/runs"), "visual-critique must not launch browser or runtime QA"
    end
  end

  def test_visual_critique_low_scores_return_non_success_without_source_repair
    in_tmp do
      json_cmd("init", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      FileUtils.mkdir_p("evidence")
      screenshot_path = File.join("evidence", "homepage.png")
      File.binwrite(screenshot_path, "fake screenshot bytes")
      metadata_path = write_visual_critique_fixture(
        File.join("evidence", "visual-metadata.json"),
        scores: VISUAL_CRITIQUE_SCORE_KEYS.to_h { |key| [key, 24] }
      )

      stdout, stderr, code = run_aiweb(
        "visual-critique",
        "--screenshot", screenshot_path,
        "--metadata", metadata_path,
        "--task-id", "hero-redesign",
        "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "recorded visual critique", payload["action_taken"]
      assert_equal "failed", payload.dig("visual_critique", "status")
      assert_equal "redesign", payload.dig("visual_critique", "approval")
      assert_visual_critique_scores(payload)
      assert File.file?(payload.dig("visual_critique", "artifact_path"))
      assert_equal payload.dig("visual_critique", "artifact_path"), load_state.dig("qa", "latest_visual_critique")
      assert payload.dig("visual_critique", "patch_plan").any?, "low-score critique should describe a manual patch plan"
      assert_equal env_body, File.read(".env"), "low-score visual critique must not mutate .env"
      refute Dir.exist?(".ai-web/repair"), "visual-critique must not create repair records"
      refute Dir.exist?("dist"), "visual-critique must not build or deploy"
    end
  end

  def test_visual_critique_phase_0_average_threshold_requires_repair
    in_tmp do
      json_cmd("init", "--profile", "D")
      FileUtils.mkdir_p("evidence")
      screenshot_path = File.join("evidence", "homepage.png")
      File.binwrite(screenshot_path, "fake screenshot bytes")
      metadata_path = write_visual_critique_fixture(
        File.join("evidence", "visual-metadata.json"),
        scores: VISUAL_CRITIQUE_SCORE_KEYS.to_h { |key| [key, 77] }
      )

      stdout, stderr, code = run_aiweb(
        "visual-critique",
        "--screenshot", screenshot_path,
        "--metadata", metadata_path,
        "--task-id", "hero-average-gate",
        "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "repair", payload.dig("visual_critique", "approval")
      assert_match(/average visual score/i, payload.dig("visual_critique", "issues").join("\n"))
      assert payload.dig("visual_critique", "patch_plan").any?, "average-gate repair should include a patch plan"
    end
  end

  def test_visual_critique_rejects_env_paths_without_reading_or_echoing_secret
    in_tmp do
      json_cmd("init", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      File.write(".env.local", "LOCAL_SECRET=do-not-touch\n")
      FileUtils.mkdir_p("evidence")
      safe_screenshot = File.join("evidence", "homepage.png")
      File.binwrite(safe_screenshot, "fake screenshot bytes")
      safe_metadata = write_visual_critique_fixture(
        File.join("evidence", "visual-metadata.json"),
        scores: VISUAL_CRITIQUE_SCORE_KEYS.to_h { |key| [key, 90] }
      )

      [
        ["--screenshot", ".env"],
        ["--metadata", ".env.local"],
        ["--screenshot", ".env/homepage.png"],
        ["--metadata", "nested/.env.local/visual-metadata.json"]
      ].each do |option, forbidden_path|
        args = ["visual-critique", "--screenshot", safe_screenshot, "--metadata", safe_metadata]
        index = args.index(option)
        args[index + 1] = forbidden_path if index
        stdout, stderr, code = run_aiweb(*args, "--json")
        payload = JSON.parse(stdout)

        assert_equal 1, code
        assert_equal "", stderr
        assert_equal "error", payload["status"]
        assert_match(/\.env/, payload.dig("error", "message"))
        refute_includes stdout, "do-not-touch"
        refute Dir.exist?(".ai-web/visual"), "rejected .env evidence path must not create visual artifacts"
        assert_equal env_body, File.read(".env"), "rejected visual-critique path must not mutate .env"
      end
    end
  end

  def test_visual_critique_help_and_webbuilder_passthrough
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr
    assert_includes stdout, "visual-critique"
    assert_match(/visual-critique: records safe local visual critique/i, stdout)

    help_stdout, help_stderr, help_code = run_webbuilder("--help")
    assert_equal 0, help_code
    assert_equal "", help_stderr
    assert_match(/visual-critique/, help_stdout)

    in_tmp do |dir|
      target = File.join(dir, "passthrough-visual-critique")
      Dir.mkdir(target)
      Dir.chdir(target) do
        json_cmd("init", "--profile", "D")
        FileUtils.mkdir_p("evidence")
        File.binwrite(File.join("evidence", "homepage.png"), "fake screenshot bytes")
      end

      web_stdout, web_stderr, web_code = run_webbuilder(
        "--path", target,
        "visual-critique",
        "--screenshot", File.join(target, "evidence", "homepage.png"),
        "--task-id", "web-dry",
        "--dry-run",
        "--json"
      )
      web_payload = JSON.parse(web_stdout)
      assert_equal 0, web_code
      assert_equal "", web_stderr
      assert_equal "planned visual critique", web_payload["action_taken"]
      assert_equal "dry_run", web_payload.dig("visual_critique", "status")
      assert_equal "web-dry", web_payload.dig("visual_critique", "task_id")
      refute Dir.exist?(File.join(target, ".ai-web", "visual")), "webbuilder visual-critique --dry-run must not write artifacts"
    end
  end

  def test_visual_polish_dry_run_from_latest_failed_critique_plans_without_writes
    in_tmp do
      json_cmd("init", "--profile", "D")
      set_phase("phase-10")
      FileUtils.mkdir_p("src")
      File.write("src/app.js", "console.log('before polish');\n")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      _critique_payload, critique_code = record_visual_critique_fixture!(
        task_id: "hero-polish-dry",
        scores: VISUAL_CRITIQUE_SCORE_KEYS.to_h { |key| [key, 32] }
      )
      assert_equal 1, critique_code

      before_state = File.read(".ai-web/state.yaml")
      before_source = File.read("src/app.js")
      before_polish_records = Dir.glob(".ai-web/visual/polish-*.json").sort
      before_snapshots = Dir.glob(".ai-web/snapshots/*").sort
      before_tasks = Dir.glob(".ai-web/tasks/*").sort

      payload, code = json_cmd("visual-polish", "--repair", "--from-critique", "latest", "--dry-run")

      assert_equal 0, code
      assert_equal true, payload["dry_run"]
      polish_loop = payload.fetch("visual_polish")
      assert_equal true, polish_loop["dry_run"]
      assert_includes %w[planned ready], polish_loop["status"]
      assert_match(%r{\.ai-web/visual/visual-critique-}, polish_loop.fetch("source_critique"))
      assert_match(%r{\.ai-web/snapshots/}, polish_loop.fetch("planned_snapshot_path"))
      assert_match(%r{\.ai-web/visual/polish-}, polish_loop.fetch("planned_polish_record_path"))
      assert_match(%r{\.ai-web/tasks/}, polish_loop.fetch("planned_polish_task_path"))
      assert_equal before_state, File.read(".ai-web/state.yaml")
      assert_equal before_source, File.read("src/app.js")
      assert_equal env_body, File.read(".env"), "visual-polish --dry-run must not mutate .env"
      assert_equal before_polish_records, Dir.glob(".ai-web/visual/polish-*.json").sort
      assert_equal before_snapshots, Dir.glob(".ai-web/snapshots/*").sort
      assert_equal before_tasks, Dir.glob(".ai-web/tasks/*").sort
      refute Dir.exist?("dist"), "visual-polish --dry-run must not build or deploy"
      refute Dir.exist?(".ai-web/runs"), "visual-polish --dry-run must not launch browser or QA"
    end
  end

  def test_visual_polish_from_failed_critique_creates_record_snapshot_task_and_state_without_source_patch
    in_tmp do
      json_cmd("init", "--profile", "D")
      set_phase("phase-10")
      FileUtils.mkdir_p("src")
      File.write("src/app.js", "console.log('before polish');\n")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      _critique_payload, critique_code = record_visual_critique_fixture!(
        task_id: "hero-polish",
        scores: VISUAL_CRITIQUE_SCORE_KEYS.to_h { |key| [key, 28] }
      )
      assert_equal 1, critique_code

      before_source = File.read("src/app.js")
      payload, code = json_cmd("visual-polish", "--repair", "--from-critique", "latest")

      assert_equal 0, code
      polish_loop = payload.fetch("visual_polish")
      assert_equal "created", polish_loop["status"]
      assert_match(%r{\.ai-web/visual/visual-critique-}, polish_loop.fetch("source_critique"))
      assert_match(%r{\.ai-web/snapshots/}, polish_loop.fetch("pre_polish_snapshot"))
      assert_match(%r{\.ai-web/visual/polish-}, polish_loop.fetch("polish_record"))
      assert_match(%r{\.ai-web/tasks/}, polish_loop.fetch("polish_task"))
      assert_includes payload["changed_files"], polish_loop["polish_record"]
      assert File.exist?(polish_loop["polish_record"])
      assert File.exist?(File.join(polish_loop["pre_polish_snapshot"], "manifest.json"))
      assert File.exist?(polish_loop["polish_task"])
      assert_equal before_source, File.read("src/app.js"), "visual-polish must not patch source files"
      assert_equal env_body, File.read(".env"), "visual-polish must not mutate .env"

      state = load_state
      assert_equal polish_loop["polish_record"], state.dig("visual", "latest_polish")
      assert_equal polish_loop["polish_task"], state.dig("implementation", "current_task")
      polish_record = JSON.parse(File.read(polish_loop["polish_record"]))
      assert_equal polish_loop["source_critique"], polish_record["source_critique"]
      assert_equal polish_loop["polish_task"], polish_record["polish_task"]
      assert_equal true, polish_record.fetch("guardrails").any? { |guardrail| guardrail =~ /no source auto-patch/i }
      assert_equal true, polish_record.fetch("guardrails").any? { |guardrail| guardrail =~ /no exact reference/i }
      assert_kind_of Hash, polish_record.fetch("design_contract")
      task_body = File.read(polish_loop["polish_task"])
      assert_includes task_body, "# Task Packet"
      assert_includes task_body, ".ai-web/DESIGN.md"
      assert_includes task_body, "shell_allowed: false"
      assert_includes task_body, "network_allowed: false"
      assert_includes task_body, "env_access_allowed: false"
      assert_match(/Do not copy exact reference/i, task_body)
      refute Dir.exist?("dist"), "visual-polish must not build or deploy"
      refute Dir.exist?(".ai-web/runs"), "visual-polish must not launch browser or QA"
    end
  end

  def test_visual_polish_rejects_malformed_critique_without_writes
    in_tmp do
      json_cmd("init", "--profile", "D")
      set_phase("phase-10")
      FileUtils.mkdir_p(".ai-web/visual")
      malformed_path = ".ai-web/visual/visual-critique-bad.json"
      File.write(malformed_path, JSON.pretty_generate("schema_version" => 1, "type" => "visual_critique"))
      before_state = File.read(".ai-web/state.yaml")

      stdout, stderr, code = run_aiweb("visual-polish", "--repair", "--from-critique", malformed_path, "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "error", payload["status"]
      assert_match(/malformed|id is required|evidence/i, payload.dig("error", "message"))
      assert_equal before_state, File.read(".ai-web/state.yaml")
      assert_empty Dir.glob(".ai-web/visual/polish-*.json")
      assert_empty Dir.glob(".ai-web/snapshots/*")
      assert_empty Dir.glob(".ai-web/tasks/*")
    end
  end

  def test_visual_polish_blocks_for_missing_or_passing_latest_critique_without_writes
    in_tmp do
      json_cmd("init", "--profile", "D")
      set_phase("phase-10")

      missing_payload, missing_code = json_cmd("visual-polish", "--repair", "--from-critique", "latest")
      assert_includes [1, 2, 3], missing_code
      assert_equal "blocked", missing_payload.fetch("visual_polish").fetch("status")
      assert_empty Dir.glob(".ai-web/visual/polish-*.json")
      assert_empty Dir.glob(".ai-web/snapshots/*")

      _critique_payload, critique_code = record_visual_critique_fixture!(
        task_id: "hero-pass-polish",
        scores: VISUAL_CRITIQUE_SCORE_KEYS.to_h { |key| [key, 93] }
      )
      assert_equal 0, critique_code
      before_state = File.read(".ai-web/state.yaml")
      passing_payload, passing_code = json_cmd("visual-polish", "--repair", "--from-critique", "latest")

      assert_includes [1, 2, 3], passing_code
      assert_equal "blocked", passing_payload.fetch("visual_polish").fetch("status")
      assert_match(/pass|passed|no visual|no failed|no repair/i, passing_payload["blocking_issues"].join("\n"))
      assert_equal before_state, File.read(".ai-web/state.yaml")
      assert_empty Dir.glob(".ai-web/visual/polish-*.json")
      assert_empty Dir.glob(".ai-web/snapshots/*")
    end
  end

  def test_visual_polish_cycle_cap_blocks_before_new_snapshot_record_or_task
    in_tmp do
      json_cmd("init", "--profile", "D")
      set_phase("phase-10")
      _critique_payload, critique_code = record_visual_critique_fixture!(
        task_id: "hero-cap-polish",
        scores: VISUAL_CRITIQUE_SCORE_KEYS.to_h { |key| [key, 35] }
      )
      assert_equal 1, critique_code
      first_payload, first_code = json_cmd("visual-polish", "--repair", "--from-critique", "latest", "--max-cycles", "1")
      assert_equal 0, first_code

      before_state = File.read(".ai-web/state.yaml")
      before_records = Dir.glob(".ai-web/visual/polish-*.json").sort
      before_snapshots = Dir.glob(".ai-web/snapshots/*").sort
      before_tasks = Dir.glob(".ai-web/tasks/*").sort
      blocked_payload, blocked_code = json_cmd("visual-polish", "--repair", "--from-critique", "latest", "--max-cycles", "1")

      assert_includes [1, 2, 3], blocked_code
      assert_equal "blocked", blocked_payload.fetch("visual_polish").fetch("status")
      assert_match(/cycle|cap|max/i, blocked_payload["blocking_issues"].join("\n"))
      assert_equal before_state, File.read(".ai-web/state.yaml")
      assert_equal before_records, Dir.glob(".ai-web/visual/polish-*.json").sort
      assert_equal before_snapshots, Dir.glob(".ai-web/snapshots/*").sort
      assert_equal before_tasks, Dir.glob(".ai-web/tasks/*").sort
      assert_equal "created", first_payload.fetch("visual_polish").fetch("status")
    end
  end

  def test_visual_polish_rejects_env_path_without_reading_or_printing_secret
    in_tmp do
      json_cmd("init", "--profile", "D")
      set_phase("phase-10")
      env_body = "SECRET=do-not-print\n"
      File.write(".env", env_body)
      File.write(".env.local", "LOCAL_SECRET=do-not-print\n")

      [".env", ".env.local", ".env/visual-critique.json", "nested/.env.local/visual-critique.json"].each do |forbidden_path|
        stdout, stderr, code = run_aiweb("visual-polish", "--repair", "--from-critique", forbidden_path, "--json")
        payload = JSON.parse(stdout)

        assert_equal 1, code
        assert_equal "", stderr
        assert_equal "error", payload["status"]
        assert_match(/\.env|unsafe|refus/i, payload.dig("error", "message"))
        refute_includes stdout, "do-not-print"
        assert_equal env_body, File.read(".env")
        assert_empty Dir.glob(".ai-web/visual/polish-*.json")
        assert_empty Dir.glob(".ai-web/snapshots/*")
      end
    end
  end

  def test_visual_polish_help_and_webbuilder_passthrough
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr
    assert_includes stdout, "visual-polish"
    assert_match(/visual-polish --repair: records safe local visual polish repair loop/i, stdout)

    help_stdout, help_stderr, help_code = run_webbuilder("--help")
    assert_equal 0, help_code
    assert_equal "", help_stderr
    assert_match(/visual-polish/, help_stdout)

    in_tmp do |dir|
      target = File.join(dir, "passthrough-visual-polish")
      Dir.mkdir(target)
      Dir.chdir(target) do
        json_cmd("init", "--profile", "D")
        set_phase("phase-10")
        _critique_payload, critique_code = record_visual_critique_fixture!(
          task_id: "web-polish",
          scores: VISUAL_CRITIQUE_SCORE_KEYS.to_h { |key| [key, 30] }
        )
        assert_equal 1, critique_code
      end

      web_stdout, web_stderr, web_code = run_webbuilder(
        "--path", target,
        "visual-polish",
        "--repair",
        "--from-critique", "latest",
        "--dry-run",
        "--json"
      )
      web_payload = JSON.parse(web_stdout)
      assert_equal 0, web_code
      assert_equal "", web_stderr
      assert_includes %w[planned ready], web_payload.fetch("visual_polish").fetch("status")
      assert_equal true, web_payload.fetch("visual_polish").fetch("dry_run")
      assert_empty Dir.glob(File.join(target, ".ai-web", "visual", "polish-*.json")), "webbuilder visual-polish --dry-run must not write polish records"
    end
  end

  def test_pr12_qa_commands_uninitialized_and_unready_are_safe
    PR12_QA_COMMANDS.each do |command, payload_key, _tool_label, _status_env|
      in_tmp do
        env_body = "SECRET=do-not-touch\n"
        File.write(".env", env_body)

        stdout, stderr, code = run_aiweb(command, "--url", "http://127.0.0.1:4321", "--json")
        payload = JSON.parse(stdout)

        assert_equal 1, code, command
        assert_equal "", stderr
        assert_equal "error", payload["status"]
        assert_match(/not initialized|initialize/i, payload.dig("error", "message"))
        refute Dir.exist?(".ai-web/runs"), "uninitialized #{command} must not create run artifacts"
        assert_equal env_body, File.read(".env"), "uninitialized #{command} must not mutate .env"

        json_cmd("init", "--profile", "D")
        before_state = File.read(".ai-web/state.yaml")
        stdout, stderr, code = run_aiweb(command, "--url", "http://127.0.0.1:4321", "--json")
        payload = JSON.parse(stdout)

        assert_equal 1, code, command
        assert_equal "", stderr
        assert_equal "blocked", payload.dig(payload_key, "status"), "#{command} must report under #{payload_key}"
        assert_equal false, payload.dig(payload_key, "dry_run")
        assert_match(/Scaffold has not been created|runtime-plan/i, payload["blocking_issues"].join("\n"))
        assert_empty payload["changed_files"]
        assert_equal before_state, File.read(".ai-web/state.yaml"), "runtime-plan block must not persist state changes"
        assert_equal env_body, File.read(".env"), "blocked #{command} must not mutate .env"
        refute Dir.exist?(".ai-web/runs"), "runtime-plan block must not create run artifacts"
        refute Dir.exist?("node_modules"), "#{command} must not install dependencies"
        refute Dir.exist?("dist"), "#{command} must not run build output"
      end
    end
  end

  def test_pr12_qa_commands_dry_run_on_ready_scaffold_plans_without_writes
    PR12_QA_COMMANDS.each do |command, payload_key, _tool_label, _status_env|
      in_tmp do
        prepare_profile_d_design_flow
        json_cmd("scaffold", "--profile", "D")
        env_body = "SECRET=do-not-touch\n"
        File.write(".env", env_body)
        before_entries = Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." || path == ".." }.sort

        stdout, stderr, code = run_aiweb(command, "--url", "http://127.0.0.1:4321", "--task-id", "dry-smoke", "--dry-run", "--json")
        payload = JSON.parse(stdout)
        after_entries = Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." || path == ".." }.sort

        assert_equal 0, code, command
        assert_equal "", stderr
        assert_equal true, payload["dry_run"]
        assert_equal "dry_run", payload.dig(payload_key, "status"), "#{command} must report under #{payload_key}"
        assert_equal true, payload.dig(payload_key, "dry_run")
        assert_equal "http://127.0.0.1:4321", payload.dig(payload_key, "url")
        assert_equal "dry-smoke", payload.dig(payload_key, "task_id")
        assert_match(/pnpm exec .*(--reporter=json|--output=json)/, payload.dig(payload_key, "command"))
        assert_match(%r{\A\.ai-web/runs/#{command.delete_prefix("qa-")}-qa-\d{8}T\d{6}Z/stdout\.log\z}, payload.dig(payload_key, "stdout_log"))
        assert_match(%r{\A\.ai-web/runs/#{command.delete_prefix("qa-")}-qa-\d{8}T\d{6}Z/stderr\.log\z}, payload.dig(payload_key, "stderr_log"))
        assert_nil payload.dig(payload_key, "exit_code"), "dry-run must not execute #{command}"
        assert_equal before_entries, after_entries, "#{command} --dry-run must not write run artifacts"
        assert_equal env_body, File.read(".env"), "#{command} --dry-run must not mutate .env"
        refute Dir.exist?("node_modules"), "#{command} --dry-run must not install dependencies"
        refute Dir.exist?("dist"), "#{command} --dry-run must not run a build"
      end
    end
  end

  def test_pr12_qa_commands_missing_local_tools_block_with_payload_keys
    PR12_QA_COMMANDS.each do |command, payload_key, tool_label, _status_env|
      in_tmp do
        prepare_profile_d_design_flow
        json_cmd("scaffold", "--profile", "D")
        env_body = "SECRET=do-not-touch\n"
        File.write(".env", env_body)
        FileUtils.mkdir_p("node_modules")
        bin_dir = File.join(Dir.pwd, "fake-bin")
        FileUtils.mkdir_p(bin_dir)
        write_fake_executable(bin_dir, "pnpm", "echo should-not-run >&2; exit 99")

        stdout, stderr, code = run_aiweb_env({ "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }, command, "--url", "http://127.0.0.1:4321", "--json")
        payload = JSON.parse(stdout)

        assert_equal 1, code, command
        assert_equal "", stderr
        assert_equal "blocked", payload.dig(payload_key, "status"), "#{command} must report under #{payload_key}"
        assert_nil payload.dig(payload_key, "exit_code"), "missing local #{tool_label} must not execute pnpm"
        assert_match(/#{tool_label}|node_modules\/\.bin/i, payload["blocking_issues"].join("\n"))
        assert_match(%r{\A\.ai-web/runs/#{command.delete_prefix("qa-")}-qa-\d{8}T\d{6}Z/stdout\.log\z}, payload.dig(payload_key, "stdout_log"))
        assert_match(%r{\A\.ai-web/runs/#{command.delete_prefix("qa-")}-qa-\d{8}T\d{6}Z/stderr\.log\z}, payload.dig(payload_key, "stderr_log"))
        assert File.file?(payload.dig(payload_key, "stdout_log"))
        assert File.file?(payload.dig(payload_key, "stderr_log"))
        assert_equal payload.dig(payload_key, "blocking_issues").join("\n") + "\n", File.read(payload.dig(payload_key, "stderr_log"))
        assert_equal env_body, File.read(".env"), "missing-local-tool #{command} must not mutate .env"
        refute Dir.exist?("dist"), "#{command} must not build or deploy"
      end
    end
  end

  def test_pr12_qa_commands_record_fake_pass_and_fail_results
    PR12_QA_COMMANDS.each do |command, payload_key, tool_label, status_env|
      in_tmp do |dir|
        prepare_profile_d_design_flow
        json_cmd("scaffold", "--profile", "D")
        env_body = "SECRET=do-not-touch\n"
        File.write(".env", env_body)
        bin_dir = write_fake_pr12_qa_tooling(dir)
        env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

        stdout, stderr, code = run_aiweb_env(env, command, "--url", "http://127.0.0.1:4321", "--task-id", "smoke-pass", "--json")
        payload = JSON.parse(stdout)

        assert_equal 0, code, command
        assert_equal "", stderr
        assert_equal "passed", payload.dig(payload_key, "status"), "#{command} must report under #{payload_key}"
        assert_equal 0, payload.dig(payload_key, "exit_code")
        assert_match(/pnpm exec #{tool_label}/, payload.dig(payload_key, "command"))
        assert File.file?(payload.dig(payload_key, "metadata_path"))
        assert File.file?(payload.dig(payload_key, "result_path"))
        pass_result = JSON.parse(File.read(payload.dig(payload_key, "result_path")))
        assert_equal "passed", pass_result["status"]
        assert_equal "smoke-pass", pass_result["task_id"]
        assert_equal "http://127.0.0.1:4321", pass_result.dig("environment", "url")
        assert_match(/fake .* pass/, File.read(payload.dig(payload_key, "stderr_log")))
        assert_equal env_body, File.read(".env"), "successful #{command} must not mutate .env"
        refute Dir.exist?("dist"), "successful #{command} must not run build output"

        fail_env = env.merge(status_env => "failed")
        fail_stdout, fail_stderr, fail_code = run_aiweb_env(fail_env, command, "--url", "http://127.0.0.1:4321", "--task-id", "smoke-fail", "--json")
        fail_payload = JSON.parse(fail_stdout)

        assert_equal 1, fail_code, command
        assert_equal "", fail_stderr
        assert_equal "failed", fail_payload.dig(payload_key, "status"), "#{command} must report failures under #{payload_key}"
        assert_equal 1, fail_payload.dig(payload_key, "exit_code")
        fail_result = JSON.parse(File.read(fail_payload.dig(payload_key, "result_path")))
        assert_equal "failed", fail_result["status"]
        assert_equal "smoke-fail", fail_result["task_id"]
        assert_match(/fake .* failure/, File.read(fail_payload.dig(payload_key, "stderr_log")))
        assert_equal env_body, File.read(".env"), "failed #{command} must not mutate .env"
        refute Dir.exist?("dist"), "failed #{command} must not build or deploy"
      end
    end
  end

  def test_qa_playwright_help_and_webbuilder_passthrough
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr
    assert_includes stdout, "qa-playwright"
    assert_match(/qa-playwright: runs safe local Playwright QA/i, stdout)

    help_stdout, help_stderr, help_code = run_webbuilder("--help")
    assert_equal 0, help_code
    assert_equal "", help_stderr
    assert_match(/qa-playwright/, help_stdout)

    in_tmp do |dir|
      target = File.join(dir, "passthrough-playwright")
      Dir.mkdir(target)
      Dir.chdir(target) do
        prepare_profile_d_design_flow
        json_cmd("scaffold", "--profile", "D")
        File.write(".env", "SECRET=do-not-touch\n")
      end

      web_stdout, web_stderr, web_code = run_webbuilder("--path", target, "qa-playwright", "--url", "http://127.0.0.1:4321", "--task-id", "web-dry", "--dry-run", "--json")
      web_payload = JSON.parse(web_stdout)
      assert_equal 0, web_code
      assert_equal "", web_stderr
      assert_equal "planned Playwright QA", web_payload["action_taken"]
      assert_equal "dry_run", web_payload.dig("playwright_qa", "status")
      assert_equal "web-dry", web_payload.dig("playwright_qa", "task_id")
      assert_equal "SECRET=do-not-touch\n", File.read(File.join(target, ".env"))
      refute Dir.exist?(File.join(target, ".ai-web", "runs")), "webbuilder qa-playwright --dry-run must not write run artifacts"
    end
  end

  def test_qa_a11y_and_lighthouse_dry_run_help_and_webbuilder_passthrough
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr
    assert_includes stdout, "qa-a11y"
    assert_includes stdout, "qa-lighthouse"

    help_stdout, help_stderr, help_code = run_webbuilder("--help")
    assert_equal 0, help_code
    assert_equal "", help_stderr
    assert_match(/qa-a11y/, help_stdout)
    assert_match(/qa-lighthouse/, help_stdout)

    in_tmp do |dir|
      target = File.join(dir, "passthrough-static-qa")
      Dir.mkdir(target)
      Dir.chdir(target) do
        prepare_profile_d_design_flow
        json_cmd("scaffold", "--profile", "D")
        File.write(".env", "SECRET=do-not-touch\n")
      end

      a11y_stdout, a11y_stderr, a11y_code = run_webbuilder("--path", target, "qa-a11y", "--url", "http://127.0.0.1:4321", "--task-id", "web-a11y", "--dry-run", "--json")
      a11y_payload = JSON.parse(a11y_stdout)
      assert_equal 0, a11y_code
      assert_equal "", a11y_stderr
      assert_equal "planned axe accessibility QA", a11y_payload["action_taken"]
      assert_equal "dry_run", a11y_payload.dig("a11y_qa", "status")
      assert_equal "web-a11y", a11y_payload.dig("a11y_qa", "task_id")
      assert_match(/pnpm exec axe http:\/\/127\.0\.0\.1:4321 --reporter=json/, a11y_payload.dig("a11y_qa", "command"))

      lighthouse_stdout, lighthouse_stderr, lighthouse_code = run_webbuilder("--path", target, "qa-lighthouse", "--url", "http://127.0.0.1:4321", "--task-id", "web-lighthouse", "--dry-run", "--json")
      lighthouse_payload = JSON.parse(lighthouse_stdout)
      assert_equal 0, lighthouse_code
      assert_equal "", lighthouse_stderr
      assert_equal "planned Lighthouse QA", lighthouse_payload["action_taken"]
      assert_equal "dry_run", lighthouse_payload.dig("lighthouse_qa", "status")
      assert_equal "web-lighthouse", lighthouse_payload.dig("lighthouse_qa", "task_id")
      assert_match(/pnpm exec lighthouse http:\/\/127\.0\.0\.1:4321 --output=json/, lighthouse_payload.dig("lighthouse_qa", "command"))

      assert_equal "SECRET=do-not-touch\n", File.read(File.join(target, ".env"))
      refute Dir.exist?(File.join(target, ".ai-web", "runs")), "static QA --dry-run must not write run artifacts"
    end
  end

  def test_qa_a11y_and_lighthouse_record_fake_pass_results
    in_tmp do |dir|
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      env_body = "SECRET=do-not-touch\n"
      File.write(".env", env_body)
      bin_dir = write_fake_static_qa_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      a11y_stdout, a11y_stderr, a11y_code = run_aiweb_env(env, "qa-a11y", "--url", "http://127.0.0.1:4321", "--task-id", "a11y-pass", "--json")
      a11y_payload = JSON.parse(a11y_stdout)
      assert_equal 0, a11y_code
      assert_equal "", a11y_stderr
      assert_equal "ran axe accessibility QA", a11y_payload["action_taken"]
      assert_equal "passed", a11y_payload.dig("a11y_qa", "status")
      assert_equal 0, a11y_payload.dig("a11y_qa", "exit_code")
      assert File.file?(a11y_payload.dig("a11y_qa", "result_path"))
      a11y_result = JSON.parse(File.read(a11y_payload.dig("a11y_qa", "result_path")))
      assert_equal "passed", a11y_result["status"]
      assert_equal "accessibility", a11y_result.dig("checks", 0, "category")
      assert_equal "axe", a11y_result.dig("environment", "browser")

      lighthouse_stdout, lighthouse_stderr, lighthouse_code = run_aiweb_env(env, "qa-lighthouse", "--url", "http://127.0.0.1:4321", "--task-id", "lighthouse-pass", "--json")
      lighthouse_payload = JSON.parse(lighthouse_stdout)
      assert_equal 0, lighthouse_code
      assert_equal "", lighthouse_stderr
      assert_equal "ran Lighthouse QA", lighthouse_payload["action_taken"]
      assert_equal "passed", lighthouse_payload.dig("lighthouse_qa", "status")
      assert_equal 0, lighthouse_payload.dig("lighthouse_qa", "exit_code")
      assert File.file?(lighthouse_payload.dig("lighthouse_qa", "result_path"))
      lighthouse_result = JSON.parse(File.read(lighthouse_payload.dig("lighthouse_qa", "result_path")))
      assert_equal "passed", lighthouse_result["status"]
      assert_equal "performance", lighthouse_result.dig("checks", 0, "category")
      assert_equal "lighthouse", lighthouse_result.dig("environment", "browser")

      assert_equal env_body, File.read(".env"), "static QA commands must not mutate .env"
      refute Dir.exist?("dist"), "static QA commands must not build or deploy"
    end
  end


  def test_qa_screenshot_dry_run_plans_local_viewport_artifacts_without_writes
    ["http://127.0.0.1:4321", "http://localhost:4321"].each do |url|
      in_tmp do
        prepare_profile_d_design_flow
        json_cmd("scaffold", "--profile", "D")
        env_body = "SECRET=do-not-touch
"
        File.write(".env", env_body)
        before_entries = Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." || path == ".." }.sort

        stdout, stderr, code = run_aiweb("qa-screenshot", "--url", url, "--task-id", "home-shot", "--dry-run", "--json")
        payload = JSON.parse(stdout)
        after_entries = Dir.glob("**/*", File::FNM_DOTMATCH).reject { |path| path == "." || path == ".." }.sort

        assert_equal 0, code, stdout
        assert_equal "", stderr
        assert_equal true, payload["dry_run"]
        screenshot_qa = payload.fetch("qa_screenshot")
        assert_equal "dry_run", screenshot_qa["status"]
        assert_equal true, screenshot_qa["dry_run"]
        assert_equal url, screenshot_qa["url"]
        assert_equal "home-shot", screenshot_qa["task_id"]
        assert_equal ".ai-web/qa/screenshots/metadata.json", payload.dig("screenshot_metadata", "metadata_path")
        assert_equal ".ai-web/qa/screenshots/mobile-home.png", screenshot_path_for(screenshot_qa, "mobile")
        assert_equal ".ai-web/qa/screenshots/tablet-home.png", screenshot_path_for(screenshot_qa, "tablet")
        assert_equal ".ai-web/qa/screenshots/desktop-home.png", screenshot_path_for(screenshot_qa, "desktop")
        assert_nil screenshot_qa["exit_code"], "dry-run must not execute Playwright"
        assert_equal before_entries, after_entries, "qa-screenshot --dry-run must not write screenshots, metadata, runs, or results"
        assert_equal env_body, File.read(".env"), "qa-screenshot --dry-run must not mutate .env"
        refute Dir.exist?("node_modules"), "qa-screenshot --dry-run must not install dependencies"
        refute Dir.exist?("dist"), "qa-screenshot --dry-run must not run a build"
      end
    end
  end

  def test_qa_screenshot_rejects_external_urls_before_playwright_or_writes
    in_tmp do |dir|
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      env_body = "SECRET=do-not-print
"
      File.write(".env", env_body)
      bin_dir = File.join(dir, "fake-bin")
      FileUtils.mkdir_p(bin_dir)
      marker = File.join(dir, "pnpm-ran")
      write_fake_executable(bin_dir, "pnpm", "echo ran > #{Shellwords.escape(marker)}")

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "qa-screenshot",
        "--url", "https://example.com",
        "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      assert_equal "error", payload["status"]
      assert_match(/localhost|127\.0\.0\.1|local|external|unsafe/i, payload.dig("error", "message"))
      refute File.exist?(marker), "external URL rejection must happen before pnpm/playwright starts"
      refute Dir.exist?(".ai-web/qa/screenshots"), "external URL rejection must not write screenshot artifacts"
      refute_includes stdout, "do-not-print"
      assert_equal env_body, File.read(".env"), "external URL rejection must not mutate .env"
    end
  end

  def test_qa_screenshot_missing_local_playwright_blocks_with_clear_artifacts
    in_tmp do |dir|
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      env_body = "SECRET=do-not-touch
"
      File.write(".env", env_body)
      FileUtils.mkdir_p("node_modules")
      bin_dir = File.join(dir, "fake-bin")
      FileUtils.mkdir_p(bin_dir)
      write_fake_executable(bin_dir, "pnpm", "echo should-not-run >&2; exit 99")

      stdout, stderr, code = run_aiweb_env(
        { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) },
        "qa-screenshot",
        "--url", "http://127.0.0.1:4321",
        "--json"
      )
      payload = JSON.parse(stdout)

      assert_equal 1, code
      assert_equal "", stderr
      screenshot_qa = payload.fetch("qa_screenshot")
      assert_equal "blocked", screenshot_qa["status"]
      assert_nil screenshot_qa["exit_code"], "missing local Playwright must not execute pnpm"
      assert_match(/Playwright|node_modules\/\.bin\/playwright/i, payload["blocking_issues"].join("
"))
      assert_match(%r{\A\.ai-web/runs/qa-screenshot-\d{8}T\d{6}Z/stdout\.log\z}, screenshot_qa["stdout_log"])
      assert_match(%r{\A\.ai-web/runs/qa-screenshot-\d{8}T\d{6}Z/stderr\.log\z}, screenshot_qa["stderr_log"])
      assert_match(%r{\A\.ai-web/qa/results/qa-\d{8}T\d{6}Z-.*\.json\z}, screenshot_qa["result_path"])
      assert File.file?(screenshot_qa["stdout_log"])
      assert File.file?(screenshot_qa["stderr_log"])
      assert File.file?(screenshot_qa["result_path"])
      result = JSON.parse(File.read(screenshot_qa["result_path"]))
      assert_equal "blocked", result["status"]
      assert_equal "http://127.0.0.1:4321", result.dig("environment", "url")
      assert_equal env_body, File.read(".env"), "missing-local-playwright qa-screenshot must not mutate .env"
      refute Dir.exist?("dist"), "qa-screenshot must not build or deploy"
    end
  end

  def test_qa_screenshot_records_fake_viewport_screenshots_metadata_and_visual_critique_handoff
    in_tmp do |dir|
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      env_body = "SECRET=do-not-touch
"
      File.write(".env", env_body)
      bin_dir = write_fake_qa_screenshot_tooling(dir)
      env = { "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR) }

      stdout, stderr, code = run_aiweb_env(env, "qa-screenshot", "--url", "http://127.0.0.1:4321", "--task-id", "home", "--json")
      payload = JSON.parse(stdout)

      assert_equal 0, code, stdout
      assert_equal "", stderr
      screenshot_qa = payload.fetch("qa_screenshot")
      assert_equal "passed", screenshot_qa["status"]
      assert_equal 0, screenshot_qa["exit_code"]
      assert_equal "http://127.0.0.1:4321", screenshot_qa["url"]
      assert_equal "home", screenshot_qa["task_id"]
      expected_paths = {
        "mobile" => ".ai-web/qa/screenshots/mobile-home.png",
        "tablet" => ".ai-web/qa/screenshots/tablet-home.png",
        "desktop" => ".ai-web/qa/screenshots/desktop-home.png"
      }
      expected_paths.each do |viewport, path|
        assert_equal path, screenshot_path_for(screenshot_qa, viewport)
        assert File.file?(path), "#{viewport} screenshot must be written"
        assert_match(/fake screenshot/, File.read(path))
      end
      screenshot_metadata_path = payload.dig("screenshot_metadata", "metadata_path")
      assert_equal ".ai-web/qa/screenshots/metadata.json", screenshot_metadata_path
      assert File.file?(screenshot_metadata_path)
      assert File.file?(screenshot_qa["result_path"])

      metadata = JSON.parse(File.read(screenshot_metadata_path))
      assert_equal 1, metadata["schema_version"]
      assert_equal "http://127.0.0.1:4321", metadata["url"]
      assert_equal expected_paths, screenshot_paths_by_viewport(metadata)
      refute_match(Regexp.escape(dir), JSON.generate(metadata), "metadata must stay artifact-relative and not leak absolute project paths")

      state = load_state
      assert_equal screenshot_metadata_path, state.dig("qa", "latest_screenshot_metadata")
      assert_equal screenshot_qa["result_path"], state.dig("qa", "latest_screenshot_result")
      assert_equal env_body, File.read(".env"), "qa-screenshot must not mutate .env"
      refute Dir.exist?("dist"), "qa-screenshot must not build or deploy"

      critique_stdout, critique_stderr, critique_code = run_aiweb("visual-critique", "--from-screenshots", "latest", "--dry-run", "--json")
      critique_payload = JSON.parse(critique_stdout)
      assert_equal 0, critique_code, critique_stdout
      assert_equal "", critique_stderr
      assert_equal screenshot_metadata_path, critique_payload.dig("visual_critique", "metadata_path")
      assert_equal expected_paths["desktop"], critique_payload.dig("visual_critique", "screenshot_path")
    end
  end


  def test_qa_screenshot_records_fake_failure_result_without_build_preview_or_install
    in_tmp do |dir|
      prepare_profile_d_design_flow
      json_cmd("scaffold", "--profile", "D")
      env_body = "SECRET=do-not-touch
"
      File.write(".env", env_body)
      bin_dir = write_fake_qa_screenshot_tooling(dir)
      env = {
        "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
        "QA_SCREENSHOT_FAKE_STATUS" => "failed"
      }

      stdout, stderr, code = run_aiweb_env(env, "qa-screenshot", "--url", "http://localhost:4321", "--task-id", "home-fail", "--json")
      payload = JSON.parse(stdout)

      assert_equal 1, code, stdout
      assert_equal "", stderr
      screenshot_qa = payload.fetch("qa_screenshot")
      assert_equal "failed", screenshot_qa["status"]
      assert_equal 1, screenshot_qa["exit_code"]
      assert_match(%r{\A\.ai-web/runs/qa-screenshot-\d{8}T\d{6}Z/stdout\.log\z}, screenshot_qa["stdout_log"])
      assert_match(%r{\A\.ai-web/runs/qa-screenshot-\d{8}T\d{6}Z/stderr\.log\z}, screenshot_qa["stderr_log"])
      assert_match(%r{\A\.ai-web/qa/results/qa-\d{8}T\d{6}Z-.*\.json\z}, screenshot_qa["result_path"])
      assert File.file?(screenshot_qa["stderr_log"])
      assert_match(/fake screenshot failure/, File.read(screenshot_qa["stderr_log"]))
      fail_result = JSON.parse(File.read(screenshot_qa["result_path"]))
      assert_equal "failed", fail_result["status"]
      assert_equal "home-fail", fail_result["task_id"]
      assert_equal "http://localhost:4321", fail_result.dig("environment", "url")
      assert_equal env_body, File.read(".env"), "failed qa-screenshot must not mutate .env"
      refute Dir.exist?("dist"), "failed qa-screenshot must not build or deploy"
    end
  end

  def test_qa_screenshot_help_and_webbuilder_passthrough
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr
    assert_includes stdout, "qa-screenshot"
    assert_match(/qa-screenshot: captures safe local screenshot evidence/i, stdout)

    help_stdout, help_stderr, help_code = run_webbuilder("--help")
    assert_equal 0, help_code
    assert_equal "", help_stderr
    assert_match(/qa-screenshot/, help_stdout)

    in_tmp do |dir|
      target = File.join(dir, "passthrough-screenshot")
      Dir.mkdir(target)
      Dir.chdir(target) do
        prepare_profile_d_design_flow
        json_cmd("scaffold", "--profile", "D")
        File.write(".env", "SECRET=do-not-touch
")
      end

      web_stdout, web_stderr, web_code = run_webbuilder("--path", target, "qa-screenshot", "--url", "http://localhost:4321", "--task-id", "web-shot", "--dry-run", "--json")
      web_payload = JSON.parse(web_stdout)
      assert_equal 0, web_code, web_stdout
      assert_equal "", web_stderr
      assert_equal "dry_run", web_payload.dig("qa_screenshot", "status")
      assert_equal "web-shot", web_payload.dig("qa_screenshot", "task_id")
      assert_equal "SECRET=do-not-touch
", File.read(File.join(target, ".env"))
      refute Dir.exist?(File.join(target, ".ai-web", "qa", "screenshots")), "webbuilder qa-screenshot --dry-run must not write screenshot artifacts"
      refute Dir.exist?(File.join(target, ".ai-web", "runs")), "webbuilder qa-screenshot --dry-run must not write run artifacts"
    end
  end

  def test_build_help_and_webbuilder_passthrough
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr
    assert_includes stdout, "build"
    assert_match(/build: runs the scaffolded Astro build/, stdout)

    help_stdout, help_stderr, help_code = run_webbuilder("--help")
    assert_equal 0, help_code
    assert_equal "", help_stderr
    assert_match(/build/, help_stdout)

    in_tmp do |dir|
      target = File.join(dir, "passthrough-build")
      Dir.mkdir(target)
      Dir.chdir(target) do
        prepare_profile_d_design_flow
        json_cmd("scaffold", "--profile", "D")
        File.write(".env", "SECRET=do-not-touch\n")
      end

      web_stdout, web_stderr, web_code = run_webbuilder("--path", target, "build", "--dry-run", "--json")
      web_payload = JSON.parse(web_stdout)
      assert_equal 0, web_code
      assert_equal "", web_stderr
      assert_equal "planned scaffold build", web_payload["action_taken"]
      assert_equal "dry_run", web_payload.dig("build", "status")
      assert_equal true, web_payload.dig("build", "dry_run")
      assert_equal "SECRET=do-not-touch\n", File.read(File.join(target, ".env"))
      refute Dir.exist?(File.join(target, ".ai-web", "runs")), "webbuilder build --dry-run must not write run artifacts"
    end
  end

  def valid_qa_result
    {
      "schema_version" => 1,
      "task_id" => "golden",
      "status" => "failed",
      "started_at" => "2026-04-26T00:00:00Z",
      "finished_at" => "2026-04-26T00:01:00Z",
      "duration_minutes" => 1,
      "timed_out" => false,
      "environment" => {
        "url" => "http://localhost:4321",
        "browser" => "codex_browser",
        "browser_version" => "unknown",
        "viewport" => { "width" => 375, "height" => 812, "name" => "mobile" },
        "commit_sha" => "unknown",
        "server_command" => "npm run dev"
      },
      "checks" => [],
      "evidence" => [],
      "console_errors" => [],
      "network_errors" => [],
      "recommended_action" => "create_fix_packet",
      "created_fix_task" => nil
    }
  end
end
