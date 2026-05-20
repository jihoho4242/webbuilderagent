# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

require_relative "support/test_helper"

require "aiweb"

class AgentificationRuntimeTest < Minitest::Test
  AIWEB = File.expand_path("../bin/aiweb", __dir__)

  def in_tmp
    dir = Dir.mktmpdir("aiweb-agentification-test-")
    begin
      Dir.chdir(dir) { yield(dir) }
    ensure
      Dir.chdir(File.expand_path("..", __dir__)) if File.expand_path(Dir.pwd).start_with?(File.expand_path(dir))
      FileUtils.rm_rf(dir) if File.basename(dir).start_with?("aiweb-agentification-test-")
    end
  end

  def run_aiweb(*args)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, AIWEB, *args.map(&:to_s))
    [stdout, stderr, status.exitstatus]
  end

  def json_cmd(*args)
    stdout, stderr, code = run_aiweb(*args, "--json")
    [JSON.parse(stdout), code, stderr]
  end

  def prepare_profile_s_project(dir)
    payload, code, = json_cmd("--path", dir, "init", "--profile", "S")
    assert_equal 0, code, payload.inspect
    _payload, code, = json_cmd("--path", dir, "interview", "--idea", "local Supabase app with member login and profile management")
    assert_equal 0, code
    _payload, code, = json_cmd("--path", dir, "design-brief", "--force")
    assert_equal 0, code
    File.write(File.join(dir, ".ai-web", "DESIGN.md"), "# Supabase App Design System\n\nUse authenticated app clarity, local-first data boundaries, and explicit secret handling.\n")
    _payload, code, = json_cmd("--path", dir, "design", "--candidates", "3")
    assert_equal 0, code
    _payload, code, = json_cmd("--path", dir, "select-design", "candidate-02")
    assert_equal 0, code
    payload, code, = json_cmd("--path", dir, "scaffold", "--profile", "S")
    assert_equal 0, code, payload.inspect
  end

  def prepare_profile_d_project(dir)
    payload, code, = json_cmd("--path", dir, "init", "--profile", "D")
    assert_equal 0, code, payload.inspect
    _payload, code, = json_cmd("--path", dir, "interview", "--idea", "SEO docs content library for a premium service")
    assert_equal 0, code
    _payload, code, = json_cmd("--path", dir, "design-brief", "--force")
    assert_equal 0, code
    File.write(File.join(dir, ".ai-web", "DESIGN.md"), "# Content Site Design System\n\nUse editorial clarity and accessible landing-page structure.\n")
    _payload, code, = json_cmd("--path", dir, "design", "--candidates", "3")
    assert_equal 0, code
    _payload, code, = json_cmd("--path", dir, "select-design", "candidate-02")
    assert_equal 0, code
    payload, code, = json_cmd("--path", dir, "scaffold", "--profile", "D")
    assert_equal 0, code, payload.inspect
  end

  def test_intent_router_routes_supabase_and_korean_auth_terms_to_profile_s
    assert_equal "S", Aiweb::IntentRouter.route("Supabase RLS storage login app")["recommended_profile"]
    assert_equal "S", Aiweb::IntentRouter.route("\u{C218}\u{D30C}\u{BCA0}\u{C774}\u{C2A4} \u{B85C}\u{ADF8}\u{C778} \u{D68C}\u{C6D0} \u{C5C5}\u{B85C}\u{B4DC}")["recommended_profile"]
    assert_equal "D", Aiweb::IntentRouter.route("SEO blog docs content library")["recommended_profile"]
  end

  def test_help_and_readme_describe_agent_and_profile_s_without_full_generator_claim
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr
    assert_includes stdout, 'agent "..."'
    assert_includes stdout, '[--dry-run] [--approval-hash HASH] [--approved]'
    assert_includes stdout, 'start [--path PATH] --idea "..." [--profile A|B|C|D|S]'

    readme = File.read(File.expand_path("../README.md", __dir__))
    assert_match(/supervised local web-building agent\/director/i, readme)
    assert_match(/aiweb agent/, readme)
    assert_match(/Profile S/i, readme)
    assert_match(/not an unsupervised.*production app generator/i, readme)
    assert_match(/supervised.*approval[-_ ]hash.*--approved/i, readme)
  end

  def test_runtime_path_policy_blocks_env_secret_absolute_and_traversal_paths
    policy = Aiweb::Runtime::PathPolicy

    refute policy.safe_relative_path?(".env")
    refute policy.safe_relative_path?("nested/.env.production/config.json")
    refute policy.safe_relative_path?("..\\outside.txt")
    refute policy.safe_relative_path?("C:\\outside\\file.txt")
    refute policy.safe_relative_path?("config/credentials.yml")
    assert policy.safe_relative_path?("src/app/page.tsx")
    assert policy.safe_workspace_path?(Dir.pwd, "src/app/page.tsx")
    refute policy.safe_workspace_path?(Dir.pwd, "..\\outside.txt")
  end

  def test_process_runner_uses_clean_env_and_redacts_secret_output
    in_tmp do |dir|
      script = File.join(dir, "env_probe.rb")
      File.write(script, "puts ENV.key?('SECRET_TOKEN')\nputs ENV['SAFE_EXTRA']\nputs 'TOKEN=super-secret-value'\n")

      result = Aiweb::Runtime::ProcessRunner.new.capture(
        Aiweb::Runtime::CommandSpec.new(
          argv: [RbConfig.ruby, script],
          cwd: dir,
          env: { "SECRET_TOKEN" => "must-not-pass", "SAFE_EXTRA" => "visible" },
          timeout: 10
        )
      ).to_h

      assert_equal "passed", result["status"]
      assert_match(/false/, result["stdout"])
      assert_match(/visible/, result["stdout"])
      refute_includes result["stdout"], "super-secret-value"
      assert_includes result["stdout"], "TOKEN=[REDACTED]"
    end
  end

  def test_process_runner_writes_stdin_through_command_spec
    in_tmp do |dir|
      script = File.join(dir, "stdin_probe.rb")
      File.write(script, "input = STDIN.read\nputs input.reverse\n")

      result = Aiweb::Runtime::ProcessRunner.new.capture(
        Aiweb::Runtime::CommandSpec.new(
          argv: [RbConfig.ruby, script],
          cwd: dir,
          stdin_data: "agent prompt",
          timeout: 10
        )
      ).to_h

      assert_equal "passed", result["status"]
      assert_match(/tpmorp tnega/, result["stdout"])
    end
  end

  def test_command_spec_requires_explicit_shell_meta_opt_in
    in_tmp do |dir|
      error = assert_raises(ArgumentError) do
        Aiweb::Runtime::CommandSpec.new(argv: [RbConfig.ruby, "-e", "puts 'x'; puts 'y'"], cwd: dir)
      end
      assert_match(/unsafe shell metacharacter/, error.message)

      spec = Aiweb::Runtime::CommandSpec.new(
        argv: [RbConfig.ruby, "-e", "puts 'x'; puts 'y'"],
        cwd: dir,
        allow_shell_meta: true
      )
      result = Aiweb::Runtime::ProcessRunner.new.capture(spec).to_h
      assert_equal "passed", result["status"]
      assert_match(/x/, result["stdout"])
      assert_match(/y/, result["stdout"])
    end
  end

  def test_process_runner_times_out_with_structured_result
    in_tmp do |dir|
      script = File.join(dir, "slow.rb")
      File.write(script, "sleep 2\n")
      result = Aiweb::Runtime::ProcessRunner.new.capture(
        Aiweb::Runtime::CommandSpec.new(argv: [RbConfig.ruby, script], cwd: dir, timeout: 0.1)
      ).to_h

      assert_equal "timeout", result["status"]
      assert_nil result["exit_code"]
      assert_match(/timed out/, result["stderr"])
    end
  end

  def test_process_launcher_requires_launch_spec_and_clean_env
    in_tmp do |dir|
      script = File.join(dir, "launch_env_probe.rb")
      stdout_path = File.join(dir, "launch-stdout.log")
      stderr_path = File.join(dir, "launch-stderr.log")
      File.write(script, "puts ENV.key?('SECRET_TOKEN')\nputs ENV['SAFE_EXTRA']\n")

      error = assert_raises(ArgumentError) do
        Aiweb::Runtime::LaunchSpec.new(argv: [RbConfig.ruby, "-e", "puts 'x'; puts 'y'"], cwd: dir)
      end
      assert_match(/unsafe shell metacharacter/, error.message)

      pid = Aiweb::Runtime::ProcessLauncher.spawn(
        spec: Aiweb::Runtime::LaunchSpec.new(
          argv: [RbConfig.ruby, script],
          cwd: dir,
          env: { "SECRET_TOKEN" => "must-not-pass", "SAFE_EXTRA" => "visible" },
          stdout: stdout_path,
          stderr: stderr_path,
          risk_class: "test_launch"
        )
      )
      Process.wait(pid)

      assert_equal 0, $?.exitstatus
      assert_match(/false/, File.read(stdout_path))
      assert_match(/visible/, File.read(stdout_path))
      assert_equal "", File.read(stderr_path)
    end
  end

  def test_source_patch_guard_enforces_manifest_bounds
    manifest = {
      "allowed_source_paths" => %w[src public package.json],
      "max_changed_files" => 2,
      "max_patch_bytes" => 10
    }
    guard = Aiweb::AgentRuntime::SourcePatchGuard.new

    passed = guard.validate(manifest: manifest, changed_files: ["src/app/page.tsx", "package.json"], patch_bytes: 10)
    assert_equal "passed", passed["status"]
    assert_equal true, passed["copy_back_allowed"]

    forbidden = guard.validate(manifest: manifest, changed_files: [".env"], patch_bytes: 1)
    assert_equal "blocked", forbidden["status"]
    assert_match(/unsafe|forbidden|outside/, forbidden["blocking_issues"].join("\n"))

    outside = guard.validate(manifest: manifest, changed_files: ["docs/plan.md"], patch_bytes: 1)
    assert_equal "blocked", outside["status"]
    assert_match(/outside manifest/, outside["blocking_issues"].join("\n"))

    too_large = guard.validate(manifest: manifest, changed_files: ["src/app/page.tsx"], patch_bytes: 11)
    assert_equal "blocked", too_large["status"]
    assert_match(/exceeds max_patch_bytes/, too_large["blocking_issues"].join("\n"))
  end

  def test_profile_s_runtime_plan_is_local_planning_only_without_astro_blockers
    in_tmp do |dir|
      prepare_profile_s_project(dir)

      payload, code, stderr = json_cmd("--path", dir, "runtime-plan")

      assert_equal 0, code, stderr
      assert_equal "local_planning_only", payload.dig("runtime_plan", "readiness")
      assert_equal "S", payload.dig("runtime_plan", "profile_contract", "id")
      assert_equal ".ai-web/scaffold-profile-S.json", payload.dig("runtime_plan", "scaffold", "metadata_path")
      assert_empty payload["blocking_issues"]
      refute_match(/Astro|Profile D|Hero\.astro|src\/components/, JSON.generate(payload))
    end
  end

  def test_agent_cli_records_profile_aware_audit_artifacts
    in_tmp do |dir|
      prepare_profile_s_project(dir)

      payload, code, stderr = json_cmd("--path", dir, "agent", "--goal", "verify local Supabase scaffold", "--mode", "supervised")

      assert_equal 0, code, stderr
      assert_equal "dry_run", payload.dig("agent_runtime", "status")
      assert_equal "engine-run", payload.dig("agent_runtime", "canonical_runtime")
      assert_equal "removed_script_runner", payload.dig("agent_runtime", "agent_runtime_execution_role")
      assert_equal true, payload.dig("agent_runtime", "script_executor_neutralized")
      assert_equal false, payload.dig("agent_runtime", "fixed_action_planner_present")
      assert_equal false, payload.dig("agent_runtime", "direct_tool_executor_present")
      assert_equal "engine-run", payload.dig("agent_runtime", "canonical_runtime")
      assert_equal "agentic_local", payload.dig("engine_run", "mode")
      assert_match(/\A[0-9a-f]{64}\z/, payload.dig("agent_runtime", "engine_run", "approval_hash").to_s)
      assert_empty Dir.glob(File.join(dir, ".ai-web", "runs", "agent-session-*")), "agent facade must not create legacy AgentRuntime session artifacts"
    end
  end

  def test_agent_supervised_profile_d_waits_for_approval_before_runtime_tools
    in_tmp do |dir|
      prepare_profile_d_project(dir)

      payload, code, stderr = json_cmd("--path", dir, "agent", "verify rendered site", "--mode", "supervised")

      assert_equal 0, code, stderr
      assert_equal "dry_run", payload.dig("agent_runtime", "status")
      assert_equal "engine-run", payload.dig("agent_runtime", "canonical_runtime")
      assert_equal "removed_script_runner", payload.dig("agent_runtime", "agent_runtime_execution_role")
      assert_equal false, payload.dig("agent_runtime", "fixed_action_planner_present")
      assert_equal false, payload.dig("agent_runtime", "direct_tool_executor_present")
      assert_equal "agentic_local", payload.dig("agent_runtime", "engine_run", "mode")
      assert_match(/--approval-hash [0-9a-f]{64}/, payload["next_action"])
    end
  end

  def test_workbench_surfaces_latest_agent_runtime_evidence
    in_tmp do |dir|
      prepare_profile_s_project(dir)
      payload, code, stderr = json_cmd("--path", dir, "agent", "--goal", "verify local Supabase scaffold", "--mode", "supervised")
      assert_equal 0, code, stderr

      workbench, code, stderr = json_cmd("--path", dir, "workbench", "--dry-run")
      assert_equal 0, code, stderr
      panel = Array(workbench.dig("workbench", "panels")).find { |item| item["id"] == "agent_runtime" }
      refute_nil panel
      assert_equal "empty", panel["status"]
      assert_nil panel["latest_agent_runtime"]
      assert_nil panel["latest_engine_run"]
      assert_equal true, payload.dig("agent_runtime", "script_executor_neutralized")
      assert Array(workbench.dig("workbench", "controls")).any? { |control| control["id"] == "agent" }
    end
  end

  def test_verify_loop_is_engine_run_shim_instead_of_profile_d_pipeline_for_s
    in_tmp do |dir|
      prepare_profile_s_project(dir)

      payload, code, stderr = json_cmd("--path", dir, "verify-loop", "--max-cycles", "1", "--approved")

      assert_equal 5, code, stderr
      assert_equal "engine-run", payload.dig("verify_loop", "canonical_runtime")
      assert_equal true, payload.dig("verify_loop", "legacy_execution_removed")
      assert_equal true, payload.dig("verify_loop", "script_executor_neutralized")
      assert_equal false, payload.dig("verify_loop", "fixed_pipeline_present")
      assert_empty payload.dig("verify_loop", "steps")
      joined = payload["blocking_issues"].join("\n")
      assert_match(/approval/i, joined)
      refute_match(/Profile S does not support build/, joined)
      refute_match(/Profile S does not support preview/, joined)
      refute_match(/Profile S does not support browser_qa/, joined)
      refute_match(/Hero\.astro|SectionCard\.astro|Astro/, joined)
    end
  end
end
