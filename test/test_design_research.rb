# frozen_string_literal: true

require "json"
require "tmpdir"

require_relative "support/test_helper"
require_relative "support/fake_mcp_http_server"

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

  class FakeCamelCaseClient
    def configured?
      true
    end

    def search(query:, limit:, category: nil, company: nil, platform: "all", max_per_company: 1)
      [{
        "siteId" => 220600,
        "screenshotName" => "#{query} pricing page",
        "companyName" => "Acme",
        "category" => "Developer Tools",
        "platform" => "desktop",
        "pageUrl" => "https://example.test/pricing",
        "imageUrl" => "https://lazyweb.test/image.png?token=secret-token",
        "visionDescription" => "Hero CTA pricing layout with mobile responsive hierarchy",
        "similarity" => 0.49,
        "matchCount" => 1
      }].first(limit)
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

  def test_run_with_real_lazyweb_client_persists_external_http_broker_evidence
    responses = lambda do |payload|
      case payload.fetch("method")
      when "initialize"
        { "jsonrpc" => "2.0", "id" => payload.fetch("id"), "result" => { "capabilities" => {} } }
      when "notifications/initialized"
        { "jsonrpc" => "2.0", "result" => {} }
      when "tools/call"
        {
          "jsonrpc" => "2.0",
          "id" => payload.fetch("id"),
          "result" => {
            "content" => [{ "type" => "text", "text" => JSON.generate("results" => [
              { "screenshot_id" => "lazy-1", "company" => "Acme", "vision_description" => "Hero CTA pricing layout" }
            ]) }]
          }
        }
      else
        flunk "unexpected MCP method #{payload.fetch("method")}"
      end
    end

    FakeMcpHttpServer.open(responses) do |endpoint, _received|
      Dir.mktmpdir("design-research-") do |dir|
        client = Aiweb::LazywebClient.new(endpoint: "#{endpoint}?token=secret-token", token: "secret-token", timeout_seconds: 5)
        research = Aiweb::DesignResearch.new(root: dir, client: client, clock: FakeClock.new(Time.utc(2026, 5, 4, 14, 0, 0)))

        payload = research.run(
          intent: { "original_intent" => "developer API monitoring SaaS", "market_archetype" => "saas", "archetype" => "landing-page" },
          policy: "opportunistic",
          limit: 2
        )

        broker = payload.fetch("side_effect_broker")
        assert_equal "aiweb.lazyweb.side_effect_broker", broker.fetch("broker")
        assert_equal true, broker.fetch("events_recorded")
        assert_match(%r{\A\.ai-web/runs/lazyweb-research-[^/]+/side-effect-broker\.jsonl\z}, broker.fetch("events_path"))
        assert_includes payload.fetch("changed_files"), broker.fetch("events_path")
        events = File.readlines(File.join(dir, broker.fetch("events_path")), chomp: true).map { |line| JSON.parse(line) }
        assert_includes events.map { |event| event.fetch("event") }, "tool.requested"
        assert_includes events.map { |event| event.fetch("event") }, "tool.finished"
        encoded = JSON.generate(events)
        refute_includes encoded, "secret-token"
        assert_includes encoded, "[REDACTED]"
      end
    end
  end

  def test_run_normalizes_real_lazyweb_camel_case_fields
    Dir.mktmpdir("design-research-") do |dir|
      research = Aiweb::DesignResearch.new(root: dir, client: FakeCamelCaseClient.new, clock: FakeClock.new(Time.utc(2026, 5, 4, 14, 0, 0)))

      research.run(
        intent: { "original_intent" => "developer API monitoring SaaS", "market_archetype" => "saas", "archetype" => "landing-page" },
        policy: "opportunistic",
        limit: 1
      )

      result = JSON.parse(File.read(File.join(dir, ".ai-web/research/lazyweb/results.json"))).fetch("results").first
      assert_equal "Acme", result.fetch("company")
      assert_equal 220600, result.fetch("site_id")
      assert_equal "Developer Tools", result.fetch("category")
      assert_equal "desktop", result.fetch("platform")
      assert_equal "https://example.test/pricing", result.fetch("page_url")
      assert_equal 1, result.fetch("match_count")
      assert_includes result.fetch("vision_description"), "Hero CTA"
      refute_includes result.fetch("image_url"), "secret-token"
      assert_includes result.fetch("accepted_patterns").join(" "), "decisive CTA"
    end
  end
end
