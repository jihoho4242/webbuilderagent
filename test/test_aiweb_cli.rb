# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "aiweb/project"

class AiwebCliTest < Minitest::Test
  AIWEB = File.expand_path("../bin/aiweb", __dir__)
  WEBBUILDER = File.expand_path("../bin/webbuilder", __dir__)
  REPO_ROOT = File.expand_path("..", __dir__)

  def in_tmp
    Dir.mktmpdir("aiweb-test-") do |dir|
      Dir.chdir(dir) { yield(dir) }
    end
  end

  def run_aiweb(*args)
    stdout, stderr, status = Open3.capture3(AIWEB, *args.map(&:to_s))
    [stdout, stderr, status.exitstatus]
  end

  def run_webbuilder(*args, input: nil)
    stdout, stderr, status = Open3.capture3(WEBBUILDER, *args.map(&:to_s), stdin_data: input)
    [stdout, stderr, status.exitstatus]
  end

  def json_cmd(*args)
    stdout, stderr, code = run_aiweb(*args, "--json")
    assert_equal "", stderr, "stderr should be empty for JSON command: #{stderr}"
    [JSON.parse(stdout), code]
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
      assert_equal 1, code
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
      assert_equal 1, code
      assert_match(/does not accept extra positional arguments: extra/, payload.dig("error", "message"))
    end
  end

  def test_start_preserves_chat_assistant_intent_as_app_not_landing_page
    in_tmp do |dir|
      target = File.join(dir, "jubi-assistant")

      payload, code = json_cmd(
        "start",
        "--path", target,
        "--idea", "주비서, 국내 주식 투자자를 위한 conversational stock assistant"
      )

      assert_equal 0, code
      assert_includes payload["changed_files"], ".ai-web/intent.yaml"

      intent = YAML.load_file(File.join(target, ".ai-web", "intent.yaml"))
      assert_equal "주비서, 국내 주식 투자자를 위한 conversational stock assistant", intent["original_intent"]
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
        "--idea", "성수동 감성 로컬 카페 웹사이트"
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
      assert_match(/성수동 감성 로컬 카페/, File.read(File.join(target, ".ai-web", "project.md")))
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
        "--idea", "드라이런 카페 웹사이트",
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

      assert_equal 1, code
      assert_match(/start requires --idea/, payload.dig("error", "message"))
      refute Dir.exist?(File.join(dir, "missing-idea"))
    end
  end

  def test_global_path_runs_followup_commands_against_target_project
    in_tmp do |dir|
      target = File.join(dir, "path-target")
      start_payload, start_code = json_cmd("start", "--path", target, "--idea", "동네 병원 웹사이트")
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

      stdout, stderr, code = run_webbuilder("--path", target, "--json", "성수동 카페 웹사이트")
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
        "동네 카페 웹사이트",
        target,
        "D",
        "Y"
      ].join("\n") + "\n"

      stdout, stderr, code = run_webbuilder(input: input)

      assert_equal 0, code
      assert_equal "", stderr
      assert_match(/웹빌더를 시작합니다/, stdout)
      assert_match(/웹빌더 실행 순서/, stdout)
      assert File.exist?(File.join(target, ".ai-web", "state.yaml"))
      state = YAML.load_file(File.join(target, ".ai-web", "state.yaml"))
      assert_equal "phase-0.25", state.dig("phase", "current")
    end
  end

  def test_webbuilder_passthrough_commands_use_aiweb_engine
    in_tmp do |dir|
      target = File.join(dir, "passthrough-cafe")
      _payload, start_code = json_cmd("start", "--path", target, "--idea", "동네 카페 웹사이트")
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
    assert_match(/웹빌더/, stdout)
    assert_match(/Phase 0/, stdout)
    assert_match(/웹빌더 --path/, stdout)
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
      json_cmd("interview", "--idea", "주비서 대화형 국내 주식 assistant")
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

  def test_interview_product_artifact_names_safety_mocked_blocked_excluded_scope
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "주비서, conversational domestic stock assistant")

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
        "주비서: 국내 주식 질문에 답하고 주문 미리보기를 보여주는 대화형 stock assistant app"
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
      json_cmd("interview", "--idea", "성수동 감성 로컬 카페 웹사이트")
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
      json_cmd("interview", "--idea", "로컬 카페 웹사이트")
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
      json_cmd("interview", "--idea", "로컬 카페 웹사이트")
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
      json_cmd("interview", "--idea", "로컬 카페 웹사이트")
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

  def test_help_and_cli_spec_include_option_surface
    stdout, stderr, code = run_aiweb("help")
    assert_equal 0, code
    assert_equal "", stderr

    %w[start design-brief design-prompt ingest-design next-task qa-checklist qa-report rollback snapshot].each do |command|
      assert_includes stdout, command
    end

    ["start [--path PATH]", "--no-advance", "--path PATH", "design-brief [--force]", "ingest-design [--id ID]", "--selected", "rollback [--to PHASE] [--failure CODE]", "qa-report [--from PATH]", "--duration-minutes N", "--timed-out"].each do |snippet|
      assert_includes stdout, snippet
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
      "프리미엄 경영 코칭 랜딩페이지. 대표 신뢰, 고가 상담 신청, 세련된 브랜드 무드." => {
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
      "성수동 병원 예약과 보험 안내를 포함한 로컬 서비스 웹사이트" => {
        "archetype" => "service",
        "surface" => "website",
        "recommended_skill" => "service-business-site",
        "recommended_design_system" => "local-service-trust",
        "recommended_profile" => "A",
        "safety_sensitive" => true
      },
      "로컬 병원 랜딩페이지. 전화 예약, 위치, 영업시간, 진료 안내." => {
        "archetype" => "service",
        "surface" => "website",
        "recommended_skill" => "service-business-site",
        "recommended_design_system" => "local-service-trust",
        "recommended_profile" => "B",
        "safety_sensitive" => true
      },
      "성수동 도수치료 클리닉 웹사이트. 전화 예약, 위치, 영업시간, 리뷰, 첫 방문 안내가 필요해." => {
        "archetype" => "service",
        "surface" => "website",
        "recommended_skill" => "service-business-site",
        "recommended_design_system" => "local-service-trust",
        "recommended_profile" => "B",
        "safety_sensitive" => true
      },
      "동네 카페 예약 서비스 웹사이트" => {
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
    %w[치과 피부과 한의원 의원 정형외과 내과 외과 안과 이비인후과 산부인과].each do |specialty|
      payload, code = json_cmd("intent", "route", "--idea", "성수동 #{specialty} 예약 안내 웹사이트")
      assert_equal 0, code
      assert_equal true, payload.dig("intent", "safety_sensitive"), specialty
    end
  end

  def test_intent_route_accepts_positional_idea_and_human_output
    stdout, stderr, code = run_aiweb("intent", "route", "동네 카페 예약 서비스 웹사이트")

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
      payload, code = json_cmd("interview", "--idea", "성수동 감성 로컬 카페 웹사이트")

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
        "--idea", "주비서, 국내 주식 투자자를 위한 conversational stock assistant",
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
      "프리미엄 고급스럽게 부티크 스튜디오 랜딩페이지" => [/고급스럽게\/프리미엄/, /luxurious/, /refined materials/],
      "인스타 감성 카페 예약 웹사이트" => [/인스타 감성\/감성/, /atmospheric/, /shareable detail/],
      "믿음직하게 신뢰 주는 세무 상담 웹사이트" => [/믿음직하게\/신뢰/, /credible/, /stable hierarchy/]
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
      "온라인 쇼핑몰 상품 컬렉션 페이지" => %w[mobile-commerce ecommerce-category-page Shoppable],
      "동네 치과 예약 문의 웹사이트" => %w[local-service-trust service-business-site Local],
      "프리미엄 컨설턴트 랜딩페이지" => %w[luxury-editorial premium-landing-page Premium]
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
      assert_includes prompt, "Design system ID: conversion-saas"
      assert_includes prompt, "Skill ID: saas-product-page"
    end
  end

  def test_design_brief_preserves_custom_content_unless_force_regenerated
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "성수동 감성 로컬 카페 웹사이트")
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
