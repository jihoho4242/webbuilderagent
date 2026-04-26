# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

class AiwebCliTest < Minitest::Test
  AIWEB = File.expand_path("../bin/aiweb", __dir__)

  def in_tmp
    Dir.mktmpdir("aiweb-test-") do |dir|
      Dir.chdir(dir) { yield(dir) }
    end
  end

  def run_aiweb(*args)
    stdout, stderr, status = Open3.capture3(AIWEB, *args.map(&:to_s))
    [stdout, stderr, status.exitstatus]
  end

  def json_cmd(*args)
    stdout, stderr, code = run_aiweb(*args, "--json")
    assert_equal "", stderr, "stderr should be empty for JSON command: #{stderr}"
    [JSON.parse(stdout), code]
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

  def test_init_profile_d_creates_director_workspace_without_app_scaffold
    in_tmp do
      payload, code = json_cmd("init", "--profile", "D")
      assert_equal 0, code
      assert_equal "phase-0", payload["current_phase"]
      assert File.exist?(".ai-web/state.yaml")
      assert File.exist?(".ai-web/quality.yaml")
      assert File.exist?(".ai-web/qa/final-report.md")
      assert File.exist?(".ai-web/deploy.md")
      assert File.exist?(".ai-web/post-launch-backlog.md")
      assert File.exist?("AGENTS.md")
      assert File.exist?("DESIGN.md")
      refute File.exist?("package.json"), "init must not scaffold app code"

      state = load_state
      assert_equal "D", state.dig("implementation", "stack_profile")
      assert_match(/Astro \+ MDX\/Content Collections \+ Cloudflare Pages \+ Tailwind \+ sitemap\/RSS/, state.dig("implementation", "scaffold_target"))
      assert_equal "subscription_usage", state.dig("budget", "cost_mode")
      assert_equal 10, state.dig("budget", "max_design_candidates")
      assert_equal 60, state.dig("budget", "max_qa_runtime_minutes")
    end
  end

  def test_init_dry_run_writes_nothing_and_outputs_planned_changes
    in_tmp do
      payload, code = json_cmd("init", "--profile", "D", "--dry-run")
      assert_equal 0, code
      refute File.exist?(".ai-web")
      assert_includes payload["changed_files"], ".ai-web/state.yaml"
      assert_equal true, payload["dry_run"]
    end
  end

  def test_status_json_reports_validation_error_for_unknown_top_level_key
    in_tmp do
      json_cmd("init")
      state = load_state
      state["unexpected"] = true
      write_state(state)

      payload, code = json_cmd("status")
      assert_equal 1, code
      assert payload["validation_errors"].any? { |error| error.include?("unknown top-level") }
      assert_match(/repair/, payload["next_action"])
    end
  end

  def test_interview_then_advance_phase_zero
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "로컬 카페 웹사이트")
      payload, code = json_cmd("advance")
      assert_equal 0, code
      assert_equal "phase-0.25", payload["current_phase"]
      assert_empty payload["blocking_issues"]
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
      assert_equal 1, code
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

      blocked_ingest, ingest_code = json_cmd("ingest-design", "--title", "Too early")
      assert_equal 2, ingest_code
      assert_match(/ingest-design requires current phase/, blocked_ingest.dig("error", "message"))

      blocked_qa, qa_code = json_cmd("qa-report", "--status", "passed", "--task-id", "too-early")
      assert_equal 2, qa_code
      assert_match(/qa-report requires current phase/, blocked_qa.dig("error", "message"))
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
