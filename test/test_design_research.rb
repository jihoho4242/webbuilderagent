# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "aiweb/design_research"

class DesignResearchTest < Minitest::Test
  FakeClock = Struct.new(:now)

  class FakeClient
    def configured?
      true
    end

    def search(query:, limit:, category: nil, company: nil, platform: "all", max_per_company: 1)
      Array.new(limit) do |index|
        {
          "screenshot_id" => "#{query.hash.abs}-#{index}",
          "company" => ["Acme", "Beta", "Cobalt", "Delta"][index % 4],
          "category" => "Developer Tools",
          "platform" => platform,
          "image_url" => "https://lazyweb.test/image.png?token=secret-token",
          "vision_description" => "Hero CTA pricing layout with mobile responsive hierarchy"
        }
      end
    end
  end

  def test_plans_route_specific_queries_without_network_or_writes
    Dir.mktmpdir("design-research-") do |dir|
      research = Aiweb::DesignResearch.new(root: dir, client: FakeClient.new, clock: FakeClock.new(Time.utc(2026, 5, 4, 14, 0, 0)))

      plan = research.dry_run_plan(
        intent: { "original_intent" => "developer API monitoring SaaS", "market_archetype" => "saas", "archetype" => "landing-page" },
        policy: "opportunistic",
        limit: 5
      )

      assert_equal false, plan.fetch("network_planned")
      assert_equal false, plan.fetch("writes_planned")
      assert_includes plan.fetch("planned_queries"), "B2B SaaS landing page"
      refute File.exist?(File.join(dir, ".ai-web"))
    end
  end

  def test_run_writes_normalized_artifacts_and_redacts_ephemeral_url_tokens
    Dir.mktmpdir("design-research-") do |dir|
      research = Aiweb::DesignResearch.new(root: dir, client: FakeClient.new, clock: FakeClock.new(Time.utc(2026, 5, 4, 14, 0, 0)))

      payload = research.run(
        intent: { "original_intent" => "developer API monitoring SaaS", "market_archetype" => "saas", "archetype" => "landing-page" },
        policy: "opportunistic",
        limit: 5
      )

      expected = [
        ".ai-web/research/lazyweb/latest.json",
        ".ai-web/research/lazyweb/results.json",
        ".ai-web/research/lazyweb/pattern-matrix.md",
        ".ai-web/design-reference-brief.md"
      ]
      assert_equal expected, payload.fetch("changed_files")
      expected.each { |relative| assert File.file?(File.join(dir, relative)), relative }

      results_json = File.read(File.join(dir, ".ai-web/research/lazyweb/results.json"))
      refute_includes results_json, "secret-token"
      results = JSON.parse(results_json).fetch("results")
      assert_operator results.length, :<=, 5
      assert results.all? { |result| result.fetch("copy_risk").include?("pattern-only") }

      brief = File.read(File.join(dir, ".ai-web/design-reference-brief.md"))
      assert_includes brief, "Reference-backed Pattern Constraints"
      assert_includes brief, "Implementation agents must not call Lazyweb"
    end
  end
end
