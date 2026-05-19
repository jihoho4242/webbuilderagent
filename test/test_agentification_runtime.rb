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
    assert_includes stdout, '[--approved] [--dry-run]'
    assert_includes stdout, 'start [--path PATH] --idea "..." [--profile A|B|C|D|S]'

    readme = File.read(File.expand_path("../README.md", __dir__))
    assert_match(/supervised local web-building agent\/director/i, readme)
    assert_match(/aiweb agent/, readme)
    assert_match(/Profile S/i, readme)
    assert_match(/not an unsupervised.*production app generator/i, readme)
    assert_match(/supervised.*--approved/i, readme)
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
      assert_equal "partial_not_complete", payload.dig("agent_runtime", "status")
      assert_equal "S", payload.dig("agent_runtime", "profile")
      assert_equal "not_supported_by_profile", payload.dig("agent_runtime", "browserQa", "status")
      assert_equal "manifest_required_before_source_mutation", payload.dig("agent_runtime", "patchManifest", "verifier_decision")
      assert payload.dig("agent_runtime", "patchManifest", "base_file_hashes").is_a?(Hash)
      assert_equal "engine-run", payload.dig("agent_runtime", "agent_os", "canonical_runtime")
      assert_equal "summary_only_engine_run_wrapper", payload.dig("agent_runtime", "agent_os", "agent_runtime_execution_role")

      run_dir = File.join(dir, payload.dig("agent_runtime", "artifacts", "run_dir"))
      %w[
        agent-session.json
        timeline.jsonl
        tool-result-1.json
        source-patch-manifest.json
        browser-qa-feedback.json
        final-report.json
      ].each do |artifact|
        assert File.file?(File.join(run_dir, artifact)), "expected #{artifact}"
      end

      final_report = JSON.parse(File.read(File.join(run_dir, "final-report.json")))
      assert_equal "partial_not_complete", final_report["status"]
      assert_equal false, final_report.dig("safety", "dot_env_read")
      assert_equal false, final_report.dig("safety", "external_actions_performed")
      assert_equal "delegated_to_engine_run", final_report.dig("toolResults", 0, "status")

      state = YAML.safe_load(File.read(File.join(dir, ".ai-web", "state.yaml")), permitted_classes: [], aliases: false)
      assert_equal payload.dig("agent_runtime", "artifacts", "final_report"), state.dig("implementation", "latest_agent_runtime")
      assert_equal "partial_not_complete", state.dig("implementation", "agent_runtime_status")
    end
  end

  def test_agent_supervised_profile_d_waits_for_approval_before_runtime_tools
    in_tmp do |dir|
      prepare_profile_d_project(dir)

      payload, code, stderr = json_cmd("--path", dir, "agent", "verify rendered site", "--mode", "supervised")

      assert_equal 0, code, stderr
      assert_equal "partial_not_complete", payload.dig("agent_runtime", "status")
      assert_equal "D", payload.dig("agent_runtime", "profile")
      assert_equal %w[build preview browser_qa], Array(payload.dig("agent_runtime", "steps")).map { |step| step["tool"] }
      assert_equal %w[pending_approval pending_approval pending_approval], Array(payload.dig("agent_runtime", "toolResults")).map { |result| result["status"] }
      assert_equal "browser QA awaits --approved in supervised mode", payload.dig("agent_runtime", "browserQa", "not_tested_reason")
      assert_includes payload.dig("agent_runtime", "warnings"), "build pending approval"
      assert_includes payload.dig("agent_runtime", "reflection", "recommended_next_actions"), "rerun with --approved to execute build"
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
      assert_equal "partial_not_complete", panel["status"]
      assert_equal payload.dig("agent_runtime", "artifacts", "final_report"), panel["latest_agent_runtime"]
      assert Array(workbench.dig("workbench", "controls")).any? { |control| control["id"] == "agent" }
    end
  end

  def test_verify_loop_uses_profile_contract_instead_of_profile_d_blockers_for_s
    in_tmp do |dir|
      prepare_profile_s_project(dir)

      payload, code, stderr = json_cmd("--path", dir, "verify-loop", "--max-cycles", "1", "--approved")

      assert_equal 5, code, stderr
      assert_equal "partial_not_complete", payload.dig("verify_loop", "agent_runtime_plan", "status")
      joined = payload["blocking_issues"].join("\n")
      assert_match(/Profile S does not support build/, joined)
      assert_match(/Profile S does not support preview/, joined)
      assert_match(/Profile S does not support browser_qa/, joined)
      refute_match(/Hero\.astro|SectionCard\.astro|Astro/, joined)
    end
  end
end
