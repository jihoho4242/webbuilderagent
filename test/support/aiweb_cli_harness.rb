# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

require_relative "fake_mcp_http_server"

module AiwebCliHarness
  AIWEB = File.expand_path("../../bin/aiweb", __dir__)
  WEBBUILDER = File.expand_path("../../bin/webbuilder", __dir__)
  KOREAN_WEBBUILDER = File.expand_path("../../bin/\uC6F9\uBE4C\uB354", __dir__)
  REPO_ROOT = File.expand_path("../..", __dir__)

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

  def agent_run_approval_hash(env = nil, task: "latest", agent: "codex", sandbox: nil)
    args = ["agent-run", "--task", task, "--agent", agent]
    args.concat(["--sandbox", sandbox]) if sandbox
    args.concat(["--dry-run", "--json"])
    stdout, stderr, code = env ? run_aiweb_env(env, *args) : run_aiweb(*args)
    payload = JSON.parse(stdout)
    assert_equal 0, code, "agent-run dry-run should produce approval_hash: #{stdout} #{stderr}"
    assert_equal "", stderr
    hash = payload.dig("agent_run", "approval_hash")
    assert_match(/\A[0-9a-f]{64}\z/, hash)
    assert_includes payload["next_action"].to_s, hash
    hash
  end

  def run_approved_agent_run(env = nil, task: "latest", agent: "codex", sandbox: nil)
    hash = agent_run_approval_hash(env, task: task, agent: agent, sandbox: sandbox)
    args = ["agent-run", "--task", task, "--agent", agent]
    args.concat(["--sandbox", sandbox]) if sandbox
    args.concat(["--approval-hash", hash, "--approved", "--json"])
    env ? run_aiweb_env(env, *args) : run_aiweb(*args)
  end

  def engine_run_approval_hash_for(env = nil, *args)
    full_args = ["engine-run", *args, "--dry-run", "--json"]
    stdout, stderr, code = env ? run_aiweb_with_env(env, *full_args) : run_aiweb(*full_args)
    payload = JSON.parse(stdout)
    assert_equal 0, code, "engine-run dry-run should produce approval_hash: #{stdout} #{stderr}"
    assert_equal "", stderr
    hash = payload.dig("engine_run", "approval_hash")
    assert_match(/\A[0-9a-f]{64}\z/, hash)
    hash
  end

  def json_approved_engine_run_with_env(env, *args)
    clean_args = args.reject { |arg| arg == "--approved" }
    hash = engine_run_approval_hash_for(env, *clean_args)
    json_cmd_with_env(env, "engine-run", *clean_args, "--approval-hash", hash, "--approved")
  end

  def json_approved_engine_run(*args)
    clean_args = args.reject { |arg| arg == "--approved" }
    hash = engine_run_approval_hash_for(nil, *clean_args)
    json_cmd("engine-run", *clean_args, "--approval-hash", hash, "--approved")
  end

  def setup_install_clean_flags(args)
    cleaned = []
    skip_next = false
    args.each do |arg|
      if skip_next
        skip_next = false
        next
      end
      case arg
      when "--approved", "--dry-run", "--json"
        next
      when "--approval-hash", "--approval-request"
        skip_next = true
      else
        cleaned << arg
      end
    end
    cleaned
  end

  def setup_install_approval_hash_for(env = nil, *args)
    clean_args = setup_install_clean_flags(args)
    stdout, stderr, code = env ? run_aiweb_env(env, "setup", "--install", *clean_args, "--dry-run", "--json") : run_aiweb("setup", "--install", *clean_args, "--dry-run", "--json")
    payload = JSON.parse(stdout)
    assert_equal 0, code, "setup dry-run should produce approval_hash: #{stdout} #{stderr}"
    assert_equal "", stderr
    hash = payload.dig("setup", "approval_hash")
    assert_match(/\A[0-9a-f]{64}\z/, hash)
    assert_includes payload["next_action"].to_s, hash
    hash
  end

  def run_approved_setup_env(env = nil, *args)
    clean_args = setup_install_clean_flags(args)
    hash = setup_install_approval_hash_for(env, *clean_args)
    env ? run_aiweb_env(env, "setup", "--install", *clean_args, "--approval-hash", hash, "--approved", "--json") : run_aiweb("setup", "--install", *clean_args, "--approval-hash", hash, "--approved", "--json")
  end

  def workbench_serve_clean_flags(args)
    cleaned = []
    skip_next = false
    args.each do |arg|
      if skip_next
        skip_next = false
        next
      end
      case arg
      when "--approved", "--dry-run", "--json"
        next
      when "--approval-hash", "--approval-request"
        skip_next = true
      else
        cleaned << arg
      end
    end
    cleaned
  end

  def workbench_serve_approval_hash_for(*args)
    clean_args = workbench_serve_clean_flags(args)
    stdout, stderr, code = run_aiweb("workbench", "--serve", *clean_args, "--dry-run", "--json")
    payload = JSON.parse(stdout)
    assert_equal 0, code, "workbench --serve dry-run should produce approval_hash: #{stdout} #{stderr}"
    assert_equal "", stderr
    hash = payload.dig("workbench", "serve", "approval_hash")
    assert_match(/\A[0-9a-f]{64}\z/, hash)
    assert_includes payload["next_action"].to_s, hash
    hash
  end

  def run_approved_workbench_serve(*args)
    clean_args = workbench_serve_clean_flags(args)
    hash = workbench_serve_approval_hash_for(*clean_args)
    run_aiweb("workbench", "--serve", *clean_args, "--approval-hash", hash, "--approved", "--json")
  end

  def mcp_broker_clean_flags(args)
    cleaned = []
    skip_next = false
    args.each do |arg|
      if skip_next
        skip_next = false
        next
      end
      case arg
      when "--approved", "--dry-run", "--json"
        next
      when "--approval-hash", "--approval-request"
        skip_next = true
      else
        cleaned << arg
      end
    end
    cleaned
  end

  def mcp_broker_approval_hash_for(env = nil, *args)
    clean_args = mcp_broker_clean_flags(args)
    stdout, stderr, code = env ? run_aiweb_env(env, "mcp-broker", "call", *clean_args, "--dry-run", "--json") : run_aiweb("mcp-broker", "call", *clean_args, "--dry-run", "--json")
    payload = JSON.parse(stdout)
    assert_equal 0, code, "mcp-broker dry-run should produce approval_hash: #{stdout} #{stderr}"
    assert_equal "", stderr
    hash = payload.dig("mcp_broker", "approval_hash")
    assert_match(/\A[0-9a-f]{64}\z/, hash)
    assert_includes payload.fetch("next_action"), hash
    hash
  end

  def json_approved_mcp_broker(env = nil, *args)
    clean_args = mcp_broker_clean_flags(args)
    hash = mcp_broker_approval_hash_for(env, *clean_args)
    env ? json_cmd_with_env(env, "mcp-broker", "call", *clean_args, "--approval-hash", hash, "--approved") : json_cmd("mcp-broker", "call", *clean_args, "--approval-hash", hash, "--approved")
  end

  def eval_baseline_import_clean_flags(args)
    cleaned = []
    skip_next = false
    args.each do |arg|
      if skip_next
        skip_next = false
        next
      end
      case arg
      when "--approved", "--dry-run", "--json"
        next
      when "--approval-hash", "--approval-request"
        skip_next = true
      else
        cleaned << arg
      end
    end
    cleaned
  end

  def eval_baseline_import_approval_hash_for(*args)
    clean_args = eval_baseline_import_clean_flags(args)
    payload, code = json_cmd("eval-baseline", "import", *clean_args, "--dry-run")
    assert_equal 0, code, "eval-baseline import dry-run should produce approval_hash: #{payload.inspect}"
    hash = payload.dig("eval_baseline", "approval_hash")
    assert_match(/\A[0-9a-f]{64}\z/, hash)
    assert_includes payload.fetch("next_action"), hash
    hash
  end

  def json_approved_eval_baseline_import(*args)
    clean_args = eval_baseline_import_clean_flags(args)
    hash = eval_baseline_import_approval_hash_for(*clean_args)
    json_cmd("eval-baseline", "import", *clean_args, "--approval-hash", hash, "--approved")
  end

  def project_setup_approval_hash(project, **kwargs)
    clean_kwargs = kwargs.reject { |key, _| %i[approved approval_hash dry_run].include?(key) }
    payload = project.setup(**clean_kwargs.merge(install: true, dry_run: true))
    hash = payload.dig("setup", "approval_hash")
    assert_match(/\A[0-9a-f]{64}\z/, hash)
    hash
  end

  def run_approved_project_setup(project, **kwargs)
    clean_kwargs = kwargs.reject { |key, _| %i[approved approval_hash dry_run].include?(key) }
    hash = project_setup_approval_hash(project, **clean_kwargs)
    project.setup(**clean_kwargs.merge(install: true, approved: true, approval_hash: hash))
  end

  def with_env_values(values)
    old = values.keys.to_h { |key| [key, ENV[key]] }
    values.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    old&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def with_stubbed_singleton_method(receiver, method_name, replacement)
    singleton_class = class << receiver; self; end
    original = singleton_class.instance_method(method_name)
    singleton_class.define_method(method_name) do |*args, &block|
      replacement.respond_to?(:call) ? replacement.call(*args, &block) : replacement
    end
    yield
  ensure
    singleton_class.define_method(method_name, original) if original
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
end
