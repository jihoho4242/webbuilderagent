# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"
require "yaml"

require_relative "support/fake_mcp_http_server"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "aiweb/project"

class AiwebCliTest < Minitest::Test
  AIWEB = File.expand_path("../bin/aiweb", __dir__)
  WEBBUILDER = File.expand_path("../bin/webbuilder", __dir__)
  KOREAN_WEBBUILDER = File.expand_path("../bin/웹빌더", __dir__)
  REPO_ROOT = File.expand_path("..", __dir__)

  def in_tmp
    Dir.mktmpdir("aiweb-test-") do |dir|
      Dir.chdir(dir) { yield(dir) }
    end
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
    stdout, stderr, status = Open3.capture3(AIWEB, *args.map(&:to_s))
    [stdout, stderr, status.exitstatus]
  end

  def run_aiweb_env(env, *args)
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, AIWEB, *args.map(&:to_s))
    [stdout, stderr, status.exitstatus]
  end

  def write_fake_executable(dir, name, body)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\n#{body}\n")
    FileUtils.chmod("+x", path)
    path
  end

  def run_aiweb_with_env(env, *args)
    stdout, stderr, status = Open3.capture3(env, AIWEB, *args.map(&:to_s))
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

  def write_fake_pr12_qa_tooling(root)
    write_fake_static_qa_tooling(root)
  end

  def run_webbuilder(*args, input: nil)
    stdout, stderr, status = Open3.capture3(WEBBUILDER, *args.map(&:to_s), stdin_data: input)
    [stdout, stderr, status.exitstatus]
  end

  def run_korean_webbuilder_env(env, *args)
    stdout, stderr, status = Open3.capture3(env, KOREAN_WEBBUILDER, *args.map(&:to_s))
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
      _start_payload, start_code = json_cmd("start", "--path", target, "--idea", "동네 카페 웹사이트")
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

    %w[start design-brief design-system design-prompt ingest-design next-task qa-checklist qa-report repair visual-polish rollback snapshot].each do |command|
      assert_includes stdout, command
    end

    ["start [--path PATH]", "--no-advance", "--path PATH", "design-brief [--force]", "design-system resolve [--force]", "ingest-design [--id ID]", "--selected", "rollback [--to PHASE] [--failure CODE]", "qa-report [--from PATH]", "repair [--from-qa PATH|latest]", "visual-polish --repair [--from-critique PATH|latest]", "--max-cycles N", "--duration-minutes N", "--timed-out"].each do |snippet|
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
      assert_includes prompt, "## DESIGN.md"
      assert_includes prompt, "Design system ID: conversion-saas"
      assert_includes prompt, "Selected design system ID: conversion-saas"
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


  def test_design_system_resolve_synthesizes_design_source_of_truth_from_route_brief_assets_and_craft
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "동네 치과 예약 문의 웹사이트")

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
      json_cmd("interview", "--idea", "성수동 감성 로컬 카페 웹사이트")
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
      json_cmd("interview", "--idea", "성수동 감성 로컬 카페 웹사이트")
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
      json_cmd("interview", "--idea", "동네 카페 예약 서비스 웹사이트")

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

      bodies = %w[candidate-01 candidate-02 candidate-03].map { |id| File.read(".ai-web/design-candidates/#{id}.html") }
      assert_equal 3, bodies.uniq.length, "candidate HTML files must be differentiated"
      state = load_state
      assert_equal 3, state.dig("design_candidates", "candidates").length
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
      json_cmd("interview", "--idea", "동네 카페 예약 서비스 웹사이트")
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
      json_cmd("interview", "--idea", "온라인 쇼핑몰 상품 컬렉션 페이지")
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
      state = load_state
      assert_equal "candidate-02", state.dig("design_candidates", "selected_candidate")
      approved = state.dig("design_candidates", "candidates").find { |candidate| candidate["id"] == "candidate-02" }
      assert_equal "approved", approved["status"]
    end
  end

  def test_design_prompt_and_next_task_reference_selected_design_candidate
    in_tmp do
      json_cmd("init", "--profile", "D")
      json_cmd("interview", "--idea", "프리미엄 컨설턴트 랜딩페이지")
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
      _payload, start_code = json_cmd("start", "--path", target, "--idea", "동네 카페 예약 서비스 웹사이트", "--no-advance")
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
      _payload, start_code = json_cmd("start", "--path", target, "--idea", "동네 카페 예약 서비스 웹사이트", "--no-advance")
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
    json_cmd("interview", "--idea", "프리미엄 콘텐츠 마케팅 사이트")
    json_cmd("design-brief", "--force")
    File.write(".ai-web/DESIGN.md", "# Custom Design System\n\nUse editorial calm, clear hierarchy, and source-backed proof only.\n")
    json_cmd("design", "--candidates", "3")
    json_cmd("select-design", "candidate-02")
  end

  def prepare_profile_s_design_flow
    _init_payload, init_code = json_cmd("init", "--profile", "S")
    assert_equal 0, init_code
    _interview_payload, interview_code = json_cmd("interview", "--idea", "회원 로그인과 대시보드가 있는 Supabase 기반 로컬 우선 웹앱")
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
    Dir.glob("{package.json,next.config.mjs,tsconfig.json,src/**/*,supabase/**/*,.ai-web/scaffold-profile-S.json,.ai-web/qa/supabase-secret-qa.json}", File::FNM_DOTMATCH)
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
      json_cmd("interview", "--idea", "프리미엄 콘텐츠 마케팅 사이트")
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
      json_cmd("interview", "--idea", "프리미엄 콘텐츠 마케팅 사이트")
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

    in_tmp do |dir|
      target = File.join(dir, "passthrough-scaffold")
      _payload, start_code = json_cmd("start", "--path", target, "--profile", "D", "--idea", "콘텐츠 브랜드 사이트", "--no-advance")
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

      state = load_state
      assert_equal true, state.dig("implementation", "scaffold_created")
      assert_equal "S", state.dig("implementation", "scaffold_profile")
      assert_equal "Next.js", state.dig("implementation", "scaffold_framework")
      assert_equal ".ai-web/scaffold-profile-S.json", state.dig("implementation", "scaffold_metadata_path")
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


  def write_fake_pnpm_install_tooling(root, exit_status: 0, stdout: "fake pnpm install stdout", stderr: "fake pnpm install stderr")
    bin_dir = File.join(root, "fake-setup-bin")
    FileUtils.mkdir_p(bin_dir)
    write_fake_executable(
      bin_dir,
      "pnpm",
      <<~SH
        [ "$1" = "install" ] || { echo "unexpected pnpm command: $*" >&2; exit 64; }
        echo #{stdout.shellescape}
        echo #{stderr.shellescape} >&2
        exit #{exit_status.to_i}
      SH
    )
    bin_dir
  end

  def write_fake_codex_tooling(root)
    bin_dir = File.join(root, "fake-agent-bin")
    FileUtils.mkdir_p(bin_dir)
    write_fake_executable(
      bin_dir,
      "codex",
      <<~'SH'
        if [ -n "${FAKE_CODEX_PROMPT_PATH:-}" ]; then
          cat > "${FAKE_CODEX_PROMPT_PATH}"
        else
          cat >/dev/null
        fi
        echo "${FAKE_CODEX_STDOUT:-fake codex stdout}"
        echo "${FAKE_CODEX_STDERR:-fake codex stderr}" >&2
        if [ -n "${FAKE_CODEX_PATCH_PATH:-}" ] && [ -f "${FAKE_CODEX_PATCH_PATH}" ]; then
          printf '\n<!-- patched by fake codex -->\n' >> "${FAKE_CODEX_PATCH_PATH}"
        fi
        if [ -n "${FAKE_CODEX_MARKER:-}" ]; then
          touch "${FAKE_CODEX_MARKER}"
        fi
        exit "${FAKE_CODEX_EXIT_STATUS:-0}"
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
    write_fake_executable(
      bin_dir,
      "codex",
      <<~'SH'
        echo "${FAKE_CODEX_STDOUT:-fake verify-loop codex stdout}"
        echo "${FAKE_CODEX_STDERR:-fake verify-loop codex stderr}" >&2
        if [ -n "${FAKE_CODEX_PATCH_PATH:-}" ] && [ -f "${FAKE_CODEX_PATCH_PATH}" ]; then
          printf '\n<!-- patched by fake verify-loop codex -->\n' >> "${FAKE_CODEX_PATCH_PATH}"
        fi
        if [ -n "${FAKE_CODEX_MARKER:-}" ]; then
          echo run >> "${FAKE_CODEX_MARKER}"
        fi
        exit "${FAKE_CODEX_EXIT_STATUS:-0}"
      SH
    )
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
    Dir.glob(".ai-web/runs/setup-*/*", File::FNM_DOTMATCH).select { |path| File.file?(path) }.each do |path|
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
      assert_equal "pnpm install", payload.dig("setup", "command")
      setup_payload_paths(payload).each do |path|
        assert_match(%r{\A\.ai-web/runs/setup-\d{8}T\d{6}Z/(stdout\.log|stderr\.log|setup\.json)\z}, path)
      end
      assert_no_setup_side_effects(before_entries: before_entries, before_state: before_state, env_size: env_size, env_mtime: env_mtime)
      refute File.exist?(marker), "setup --dry-run must not execute pnpm"
      refute_includes stdout, secret
    end
  end

  def test_setup_install_approved_records_successful_fake_pnpm_artifacts_and_safe_state
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      secret = "SECRET=pr20-approved-do-not-leak"
      File.write(".env", "#{secret}\n")
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
      assert_equal "pnpm install", payload.dig("setup", "command")
      assert_equal 0, payload.dig("setup", "exit_code")
      stdout_log, stderr_log, metadata_path = setup_payload_paths(payload)
      assert_equal "fake install complete\n", File.read(stdout_log)
      assert_equal "fake lifecycle warning\n", File.read(stderr_log)
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
      assert_equal "pnpm install", web_payload.dig("setup", "command")
      assert_equal "fake Korean wrapper install\n", File.read(File.join(target, web_payload.dig("setup", "stdout_log")))
    end
  end

  def test_agent_run_dry_run_plans_source_patch_without_writes_or_process_execution
    in_tmp do |dir|
      task_markdown = <<~MD
        # Task Packet — repair

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

        ## Acceptance Criteria
        - Source patch evidence is recorded.
        - Logs and diff artifacts are written only on approved runs.
      MD
      prepare_agent_run_fixture(task_markdown: task_markdown)
      bin_dir = write_fake_codex_tooling(dir)
      marker = File.join(dir, "codex-was-run")
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")
      before_source = File.read("src/components/Hero.astro")

      stdout, stderr, code = run_aiweb_env(
        {
          "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
          "FAKE_CODEX_MARKER" => marker,
          "FAKE_CODEX_PATCH_PATH" => File.join(dir, "src/components/Hero.astro")
        },
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

  def test_agent_run_without_approval_blocks_without_writes_or_process_execution
    in_tmp do |dir|
      task_markdown = <<~MD
        # Task Packet — repair

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
      MD
      prepare_agent_run_fixture(task_markdown: task_markdown)
      bin_dir = write_fake_codex_tooling(dir)
      marker = File.join(dir, "codex-was-run")
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")
      before_source = File.read("src/components/Hero.astro")

      stdout, stderr, code = run_aiweb_env(
        {
          "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
          "FAKE_CODEX_MARKER" => marker,
          "FAKE_CODEX_PATCH_PATH" => File.join(dir, "src/components/Hero.astro")
        },
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
        # Task Packet — repair

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

        ## Acceptance Criteria
        - Source patch evidence is recorded.
        - Logs, metadata, and diff evidence are written.
      MD
      prepare_agent_run_fixture(task_markdown: task_markdown, secret: secret)
      bin_dir = write_fake_codex_tooling(dir)
      marker = File.join(dir, "codex-was-run")
      before_entries = project_entries
      before_state = File.read(".ai-web/state.yaml")
      before_source = File.read("src/components/Hero.astro")
      env_size = File.size(".env")
      env_mtime = File.mtime(".env")

      stdout, stderr, code = run_aiweb_env(
        {
          "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
          "FAKE_CODEX_MARKER" => marker,
          "FAKE_CODEX_PATCH_PATH" => File.join(dir, "src/components/Hero.astro"),
          "FAKE_CODEX_STDOUT" => "fake codex approved stdout",
          "FAKE_CODEX_STDERR" => "fake codex approved stderr"
        },
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
      assert File.exist?(marker), "approved agent-run must execute the fake codex command"
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

      bin_dir = write_fake_codex_tooling(dir)
      prompt_path = File.join(dir, "captured-codex-prompt.txt")
      stdout, stderr, code = run_aiweb_env(
        {
          "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
          "FAKE_CODEX_PATCH_PATH" => File.join(dir, "src/components/Hero.astro"),
          "FAKE_CODEX_PROMPT_PATH" => prompt_path
        },
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
        # Task Packet — repair

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
      MD
      prepare_agent_run_fixture(task_markdown: task_markdown)
      bin_dir = write_fake_codex_tooling(dir)
      marker = File.join(dir, "codex-was-run")

      stdout, stderr, code = run_aiweb_env(
        {
          "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
          "FAKE_CODEX_MARKER" => marker,
          "FAKE_CODEX_EXIT_STATUS" => "23",
          "FAKE_CODEX_STDOUT" => "fake codex failure stdout",
          "FAKE_CODEX_STDERR" => "fake codex failure stderr"
        },
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
      assert File.exist?(marker), "failed agent-run must still execute the fake codex command"
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
          # Task Packet — repair

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
          # Task Packet — repair

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

  def test_verify_loop_fake_success_records_cycle_evidence_and_safe_state
    in_tmp do |dir|
      prepare_profile_d_scaffold_flow
      File.write(".env", "SECRET=pr23-success-do-not-leak\n")
      bin_dir = write_fake_verify_loop_tooling(dir)
      env = {
        "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
        "FAKE_CODEX_PATCH_PATH" => "src/components/Hero.astro"
      }

      stdout, stderr, code = run_aiweb_env(env, "verify-loop", "--max-cycles", "3", "--approved", "--json")
      payload = JSON.parse(stdout)
      loop = payload.fetch("verify_loop")

      assert_equal 0, code, stdout
      assert_equal "", stderr
      assert_equal "passed", loop["status"]
      assert_equal 1, loop["cycle_count"]
      assert_equal "verify loop passed", payload["action_taken"]
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
      marker = File.join(dir, "codex-runs.log")
      env = {
        "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
        "PLAYWRIGHT_FAKE_STATUS" => "failed",
        "FAKE_CODEX_PATCH_PATH" => "src/components/Hero.astro",
        "FAKE_CODEX_MARKER" => marker
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
      marker = File.join(dir, "codex-runs.log")
      env = {
        "PATH" => [bin_dir, "/usr/bin", "/bin", "/usr/sbin", "/sbin"].join(File::PATH_SEPARATOR),
        "PLAYWRIGHT_FAKE_STATUS" => "failed",
        "FAKE_CODEX_PATCH_PATH" => "src/components/Hero.astro",
        "FAKE_CODEX_MARKER" => marker
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
    assert_match(/runtime-plan 또는 scaffold-status/, help_stdout)

    in_tmp do |dir|
      target = File.join(dir, "passthrough-runtime-plan")
      _payload, start_code = json_cmd("start", "--path", target, "--profile", "D", "--idea", "콘텐츠 브랜드 사이트", "--no-advance")
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
        "aiweb visual-polish"
      ]
      assert_equal expected_controls, controls.map { |control| control.fetch("command") }
      controls.each do |control|
        assert_includes ["cli", "cli_descriptor"], control["kind"] || control["mode"]
        assert_equal false, control["mutates_state"] if control.key?("mutates_state")
        refute_match(/state\.yaml/, control.fetch("command"), "workbench controls must be declarative CLI commands, not direct state writes")
      end
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
        assert_includes deploy.fetch("planned_changes"), ".ai-web/deploy-plan.json"
        assert_includes deploy.fetch("planned_changes"), ".ai-web/deploy/#{target}.json"
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

  def test_github_deploy_help_and_webbuilder_passthrough_surface
    aiweb_stdout, aiweb_stderr, aiweb_code = run_aiweb("help")
    assert_equal 0, aiweb_code
    assert_equal "", aiweb_stderr
    ["github-sync", "deploy-plan", "deploy --target", "cloudflare-pages", "vercel"].each do |snippet|
      assert_includes aiweb_stdout, snippet
    end

    web_stdout, web_stderr, web_code = run_webbuilder("help")
    assert_equal 0, web_code
    assert_equal "", web_stderr
    ["github-sync", "deploy-plan", "deploy", "cloudflare-pages", "vercel"].each do |snippet|
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

      stdout, stderr, code = run_aiweb("visual-edit", "--target", "component.hero.copy", "--prompt", "이 섹션 더 고급스럽게", "--dry-run", "--json")
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

      missing_stdout, missing_stderr, missing_code = run_aiweb("visual-edit", "--target", "missing.region", "--prompt", "수정", "--dry-run", "--json")
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

      payload, code = json_cmd("visual-edit", "--target", "component.hero.copy", "--prompt", "이 섹션 더 고급스럽게")
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

      stdout, stderr, code = run_aiweb("visual-edit", "--target", "component.hero.copy", "--prompt", "수정", "--json")
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

      stdout, stderr, code = run_aiweb("visual-edit", "--target", "component.hero.copy", "--prompt", "수정", "--json")
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
        stdout, stderr, code = run_aiweb("visual-edit", "--target", "component.hero.copy", "--prompt", "수정", "--from-map", forbidden_path, "--json")
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
      edit_stdout, edit_stderr, edit_code = run_webbuilder("--path", target, "visual-edit", "--target", "component.hero.copy", "--prompt", "고급스럽게", "--dry-run", "--json")
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
    assert_includes stdout, "workbench [--export] [--force]"
    assert_match(/workbench: .*local .*UI|workbench: .*local UI manifest/i, stdout)

    help_stdout, help_stderr, help_code = run_webbuilder("--help")
    assert_equal 0, help_code
    assert_equal "", help_stderr
    assert_match(/workbench/, help_stdout)

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
        pid = nil
      ensure
        if pid
          begin
            Process.kill("TERM", pid)
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
    hierarchy
    typography
    spacing
    color
    originality
    mobile_polish
    brand_fit
    intent_fit
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
      refute Dir.exist?("dist"), "visual-polish must not build or deploy"
      refute Dir.exist?(".ai-web/runs"), "visual-polish must not launch browser or QA"
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
