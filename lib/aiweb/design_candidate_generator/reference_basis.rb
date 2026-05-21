# frozen_string_literal: true

module Aiweb
  class DesignCandidateGenerator
    private

    def reference_card_html
      return "" unless reference_brief_present?

      <<~HTML.chomp
        <div class="card" data-aiweb-id="candidate.reference-basis">
          <strong>Reference basis</strong>
          <p>Use `.ai-web/design-reference-brief.md` for pattern grounding only: hierarchy, CTA, layout, visual language, responsive behavior, and trust cues. Do not copy exact reference UI, copy, prices, trademarks, or signed image URLs.</p>
        </div>
      HTML
    end

    def reference_basis_markdown
      return "Reference basis: none recorded; generated from deterministic local design artifacts only." unless reference_brief_present?

      summary = reference_brief_summary
      <<~MD.rstrip
        ## Reference basis
        - Source: `.ai-web/design-reference-brief.md`
        - Use only pattern-level guidance from the reference brief; avoid exact copying, brand imitation, signed image URL dependence, prices, trademarks, or reference-specific copy.
        #{summary.empty? ? "- Summary: reference brief present; review it before selecting a candidate." : "- Summary: #{summary}"}
      MD
    end

    def reference_brief_present?
      reference_brief.length >= 40
    end

    def reference_brief
      @reference_brief ||= begin
        path = File.join(@aiweb_dir, "design-reference-brief.md")
        File.file?(path) ? File.read(path).to_s.strip : ""
      end
    end

    def reference_brief_summary
      reference_brief
        .lines
        .map(&:strip)
        .reject { |line| line.empty? || line.start_with?("#") || line.start_with?("!") }
        .first(2)
        .join(" ")
        .gsub("|", "/")
        .slice(0, 220)
        .to_s
    end
  end
end
