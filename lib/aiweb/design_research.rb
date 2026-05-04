# frozen_string_literal: true

require "json"
require "fileutils"
require "time"

require_relative "lazyweb_client"
require_relative "archetypes"

module Aiweb
  class DesignResearch
    PROVIDER = "lazyweb".freeze
    LATEST_PATH = ".ai-web/research/lazyweb/latest.json".freeze
    RESULTS_PATH = ".ai-web/research/lazyweb/results.json".freeze
    MATRIX_PATH = ".ai-web/research/lazyweb/pattern-matrix.md".freeze
    BRIEF_PATH = ".ai-web/design-reference-brief.md".freeze

    QUERY_SETS = {
      "saas" => ["B2B SaaS landing page", "developer tools pricing page", "team settings billing", "dashboard onboarding"],
      "ecommerce" => ["mobile product detail page", "checkout flow", "cart upsell", "subscription paywall"],
      "service" => ["local service booking page", "trust section", "contact booking CTA"],
      "premium" => ["luxury editorial landing page", "premium product page", "high trust hero"],
      "chat-assistant-webapp" => ["AI assistant onboarding", "chat app first screen", "dashboard empty state"],
      "dashboard" => ["dashboard onboarding", "analytics dashboard", "team settings billing"],
      "tool" => ["developer tools landing page", "AI tool onboarding", "dashboard empty state"],
      "commerce" => ["mobile product detail page", "checkout flow", "cart upsell"],
      "fallback" => ["high trust hero", "modern landing page", "conversion CTA section"]
    }.freeze

    PATTERN_SECTIONS = {
      "hierarchy" => [/hero|headline|above the fold|hierarchy|headline/i, "clear hierarchy"],
      "cta" => [/cta|button|signup|sign up|trial|buy|checkout|book/i, "decisive CTA treatment"],
      "layout" => [/layout|grid|card|split|sidebar|navigation|nav/i, "structured layout"],
      "visual_style" => [/visual|color|typography|gradient|editorial|premium|minimal/i, "distinct visual language"],
      "mobile_responsive" => [/mobile|responsive|tap|bottom sheet|drawer/i, "responsive/mobile affordances"],
      "copy_risk" => [/copy|pricing|testimonial|brand|logo/i, "pattern-only use; do not copy exact text, marks, or layout"]
    }.freeze

    attr_reader :root, :client, :clock

    def initialize(root:, client: LazywebClient.new, clock: Time)
      @root = File.expand_path(root)
      @client = client
      @clock = clock
    end

    def configured?
      client.configured?
    end

    def artifact_paths
      {
        "latest" => LATEST_PATH,
        "results" => RESULTS_PATH,
        "pattern_matrix" => MATRIX_PATH,
        "design_reference_brief" => BRIEF_PATH
      }
    end

    def dry_run_plan(intent:, design_brief: nil, policy: "opportunistic", limit: 8)
      {
        "schema_version" => 1,
        "provider" => PROVIDER,
        "policy" => policy.to_s,
        "configured" => configured?,
        "network_planned" => false,
        "writes_planned" => false,
        "planned_queries" => planned_queries(intent: intent, design_brief: design_brief),
        "planned_artifact_paths" => artifact_paths,
        "limit" => Integer(limit)
      }
    end

    def run(intent:, design_brief: nil, policy: "opportunistic", limit: 8)
      queries = planned_queries(intent: intent, design_brief: design_brief)
      results = queries.flat_map do |query|
        client.search(query: query, limit: per_query_limit(limit, queries.length), max_per_company: 1).map do |item|
          normalize_result(item, query: query)
        end
      end
      results = dedupe(results).first(Integer(limit))
      matrix = pattern_matrix(results)
      brief = reference_brief(intent: intent, queries: queries, results: results, matrix: matrix, policy: policy)
      latest = latest_payload(policy: policy, queries: queries, results: results)

      {
        "latest" => latest,
        "results" => results_payload(results),
        "pattern_matrix" => matrix,
        "design_reference_brief" => brief,
        "changed_files" => write_artifacts(latest: latest, results: results_payload(results), matrix: matrix, brief: brief)
      }
    end

    def planned_queries(intent:, design_brief: nil)
      route_keys = route_keys_for(intent, design_brief)
      queries = route_keys.flat_map { |key| QUERY_SETS.fetch(key, []) }
      queries << intent_query(intent)
      queries.compact.map { |query| query.to_s.strip }.reject(&:empty?).uniq.first(6)
    end

    def normalize_result(item, query:)
      now = timestamp
      screenshot_id = item["screenshot_id"] || item["screenshotId"] || item["id"] || item["screenshotName"] || item["siteId"]
      description = item["vision_description"] || item["visionDescription"] || item["description"] || item["text"] || item["title"] || item["screenshotName"]
      {
        "schema_version" => 1,
        "provider" => PROVIDER,
        "retrieved_at" => now,
        "query" => query,
        "screenshot_id" => screenshot_id,
        "site_id" => item["site_id"] || item["siteId"],
        "screenshot_name" => item["screenshot_name"] || item["screenshotName"],
        "company" => item["company"] || item["company_name"] || item["companyName"] || item["brand"],
        "category" => item["category"],
        "platform" => item["platform"],
        "page_url" => item["page_url"] || item["pageUrl"] || item["url"],
        "image_url" => redact_ephemeral_url(item["image_url"] || item["imageUrl"] || item["screenshot_url"] || item["screenshotUrl"]),
        "image_url_ephemeral" => true,
        "vision_description" => description,
        "similarity" => item["similarity"] || item["score"],
        "match_count" => item["match_count"] || item["matchCount"],
        "accepted_patterns" => accepted_patterns(description),
        "copy_risk" => "pattern-only; do not reproduce exact layout/copy"
      }.compact
    end

    def pattern_matrix(results)
      lines = ["# Lazyweb Pattern Matrix", "", "Use these references as pattern evidence only. Do not clone screenshots, exact layouts, copy, prices, trademarks, or signed image URLs.", ""]
      PATTERN_SECTIONS.each do |section, (_regex, fallback)|
        lines << "## #{section.tr("_", " ").split.map(&:capitalize).join(" ")}"
        matches = results.select { |result| Array(result["accepted_patterns"]).any? { |pattern| pattern.include?(fallback) || pattern.include?(section.tr("_", " ")) } }
        matches = results if section == "copy_risk"
        if matches.empty?
          lines << "- No strong #{section.tr("_", " ")} reference identified yet; keep existing design brief constraints."
        else
          matches.first(5).each do |result|
            label = [result["company"], result["category"], result["screenshot_id"] && "##{result["screenshot_id"]}"].compact.join(" / ")
            lines << "- #{label.empty? ? "Reference" : label}: #{Array(result["accepted_patterns"]).join("; ")}"
          end
        end
        lines << ""
      end
      lines.join("\n").rstrip + "\n"
    end

    def reference_brief(intent:, queries:, results:, matrix:, policy: "opportunistic")
      companies = results.map { |result| result["company"].to_s.strip }.reject(&:empty?).uniq
      lines = [
        "# Design Reference Brief",
        "",
        "Provider: Lazyweb",
        "Policy: #{policy}",
        "Generated at: #{timestamp}",
        "Original intent: #{intent.fetch("original_intent", "unspecified")}",
        "",
        "## Planned Search Queries",
        *queries.map { |query| "- #{query}" },
        "",
        "## Reference Coverage",
        "- Accepted references: #{results.length}",
        "- Unique companies: #{companies.length}#{companies.empty? ? "" : " (#{companies.join(", ")})"}",
        "- Image URLs are ephemeral evidence and are not durable licensed assets.",
        "",
        "## Reference-backed Pattern Constraints"
      ]
      constraints = extract_constraints(results)
      lines.concat(constraints.empty? ? ["- No accepted Lazyweb references yet; preserve deterministic design brief constraints."] : constraints.map { |item| "- #{item}" })
      lines.concat(["", "## No-copy Guardrails", "- Borrow interaction and hierarchy patterns only.", "- Do not reproduce exact screenshot layout, copy, prices, brand marks, or trademark styling.", "- Implementation agents must not call Lazyweb or use external network during source edits.", "", matrix])
      lines.join("\n").rstrip + "\n"
    end

    private

    def route_keys_for(intent, design_brief)
      keys = [intent["market_archetype"], intent["archetype"]].map(&:to_s)
      corpus = [intent["original_intent"], design_brief].join(" ").downcase
      keys << "saas" if corpus.match?(/saas|developer|api|dashboard|b2b|subscription|개발자|대시보드/)
      keys << "ecommerce" if corpus.match?(/shop|store|checkout|commerce|product|cart|상품|쇼핑|결제/)
      keys << "service" if corpus.match?(/booking|appointment|local|clinic|service|예약|상담/)
      keys << "premium" if corpus.match?(/premium|luxury|editorial|high trust|프리미엄|럭셔리/)
      keys << "chat-assistant-webapp" if corpus.match?(/chat|assistant|ai assistant|챗|비서/)
      keys << "fallback"
      keys.reject(&:empty?).uniq
    end

    def intent_query(intent)
      text = intent["original_intent"].to_s.strip
      return nil if text.empty?

      "#{text} UI patterns"
    end

    def per_query_limit(limit, query_count)
      [1, (Integer(limit).to_f / [query_count, 1].max).ceil].max
    end

    def dedupe(results)
      seen = {}
      results.each_with_object([]) do |result, memo|
        key = [result["screenshot_id"], result["company"], result["vision_description"]].compact.join("|")
        next if seen[key]

        seen[key] = true
        memo << result
      end
    end

    def results_payload(results)
      {
        "schema_version" => 1,
        "provider" => PROVIDER,
        "retrieved_at" => timestamp,
        "results" => results
      }
    end

    def latest_payload(policy:, queries:, results:)
      companies = results.map { |result| result["company"].to_s.strip }.reject(&:empty?).uniq
      {
        "schema_version" => 1,
        "provider" => PROVIDER,
        "policy" => policy.to_s,
        "retrieved_at" => timestamp,
        "queries" => queries,
        "accepted_reference_count" => results.length,
        "unique_company_count" => companies.length,
        "artifact_paths" => artifact_paths
      }
    end

    def write_artifacts(latest:, results:, matrix:, brief:)
      files = {
        LATEST_PATH => JSON.pretty_generate(latest) + "\n",
        RESULTS_PATH => JSON.pretty_generate(results) + "\n",
        MATRIX_PATH => matrix,
        BRIEF_PATH => brief
      }
      files.each do |relative_path, content|
        path = File.join(root, relative_path)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      files.keys
    end

    def accepted_patterns(description)
      text = description.to_s
      patterns = PATTERN_SECTIONS.map do |section, (regex, fallback)|
        "#{fallback} from #{section.tr("_", " ")} evidence" if text.match?(regex)
      end.compact
      patterns.empty? ? ["reference-worthy UI pattern; review manually before adopting"] : patterns.uniq
    end

    def extract_constraints(results)
      results.flat_map do |result|
        label = [result["company"], result["category"]].compact.join(" / ")
        Array(result["accepted_patterns"]).map do |pattern|
          [label.empty? ? nil : label, pattern].compact.join(": ")
        end
      end.uniq.first(12)
    end

    def redact_ephemeral_url(url)
      LazywebClient.redact(url)
    end

    def timestamp
      clock.now.utc.iso8601
    end
  end
end
