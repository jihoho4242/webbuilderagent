# frozen_string_literal: true

require_relative "test_aiweb_cli"

class AiwebCliTest < Minitest::Test
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
end
