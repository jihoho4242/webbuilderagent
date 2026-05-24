# frozen_string_literal: true

module Aiweb
  class Project
    private

    def semantic_qa_items(state)
      intent = load_intent_artifact
      first_view_path = File.join(aiweb_dir, "first-view-contract.md")
      first_view_reference = File.exist?(first_view_path) ? "`.ai-web/first-view-contract.md`" : "missing `.ai-web/first-view-contract.md`"

      archetype = intent["archetype"].to_s
      surface = intent["surface"].to_s
      not_surface = intent["not_surface"].to_s
      primary_interaction = intent["primary_interaction"].to_s
      must_have = Array(intent["must_have_first_view"] || [])
      must_not = Array(intent["must_not_have"] || [])
      risks = Array(intent["semantic_risks"] || [])

      lines = []
      lines << "- [ ] Intent artifact (`.ai-web/intent.yaml`) is present and matches the built product experience."
      lines << "- [ ] First-view contract is present and referenced: #{first_view_reference}."
      lines << "- [ ] First viewport behaves as #{archetype.empty? ? "the detected archetype" : archetype}#{surface.empty? ? "" : " (#{surface})"}, not #{not_surface.empty? ? "the forbidden surface" : not_surface}."
      lines << "- [ ] Primary interaction is visible and testable: #{primary_interaction}." unless primary_interaction.empty?
      must_have.each do |item|
        lines << "- [ ] Required first-view element is visible: #{item.tr("_", " ")}."
      end
      must_not.each do |item|
        lines << "- [ ] Forbidden first-view or safety pattern is absent: #{item}."
      end
      risks.each do |risk|
        lines << "- [ ] Semantic risk is explicitly checked: #{risk}."
      end
      lines.join("\n")
    end

    def load_intent_artifact
      path = File.join(aiweb_dir, "intent.yaml")
      return Archetypes.classify("") unless File.exist?(path)
      return Archetypes.classify("") if stub_file?(path)

      intent = YAML.load_file(path) || {}
      return Archetypes.classify("") unless intent.is_a?(Hash)

      fallback = if intent["archetype"].to_s.empty? || intent["archetype"].to_s.start_with?("TODO")
                   Archetypes.classify("")
                 else
                   begin
                     Archetypes.definition(intent["archetype"]).merge("archetype" => intent["archetype"], "schema_version" => 1)
                   rescue KeyError
                     Archetypes.classify("")
                   end
                 end
      fallback.merge(intent.reject { |_key, value| value.nil? || (value.respond_to?(:empty?) && value.empty?) })
    rescue Psych::SyntaxError
      Archetypes.classify("")
    end

    def semantic_qa_checks(state)
      corpus = semantic_intent_corpus(state)
      checks = []
      checks.concat(stock_app_semantic_qa_checks) if stock_app_intent?(corpus)
      checks
    end

    def semantic_intent_corpus(state)
      artifact_paths = %w[project product content ia data security].map do |key|
        state.dig("artifacts", key, "path")
      end.compact
      default_paths = %w[
        .ai-web/intent.yaml
        .ai-web/first-view-contract.md
        .ai-web/project.md
        .ai-web/product.md
        .ai-web/content.md
        .ai-web/ia.md
        .ai-web/data.md
        .ai-web/security.md
      ]
      (artifact_paths + default_paths).uniq.map do |relative_path|
        next if env_file_segment?(relative_path)

        path = File.expand_path(relative_path.to_s, root)
        next unless path.start_with?(File.expand_path(root))
        next unless File.file?(path)

        File.read(path)
      end.compact.join("\n").downcase
    end

    def stock_app_intent?(corpus)
      stock_terms = [
        "stock", "stocks", "trading", "broker", "brokerage", "quote", "portfolio",
        "주식", "국내 주식", "투자", "증권", "종목", "호가", "포트폴리오"
      ]
      app_terms = [
        "assistant", "chat", "order", "account", "token", "approval", "console",
        "비서", "챗", "채팅", "주문", "계좌", "토큰", "승인", "앱"
      ]
      stock_terms.any? { |term| corpus.include?(term) } &&
        app_terms.any? { |term| corpus.include?(term) }
    end

    def stock_app_semantic_qa_checks
      [
        "The first screen presents an app interface for the stock assistant, not a marketing-only landing page.",
        "A stock question can be entered and produces visible user/assistant message states or mocked response states.",
        "Stock quote/status context is visible when the assistant references a symbol or market request.",
        "Any order-related action is limited to preview/confirmation UI and cannot submit a real broker order.",
        "Real account numbers, access tokens, approval keys, broker credentials, and live trading secrets are absent from UI, code, logs, fixtures, and evidence.",
        "The UI clearly states that real trading/account access is locked, unavailable, mocked, or sandbox-only until explicit human approval and credential setup."
      ]
    end

  end
end
