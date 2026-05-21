# frozen_string_literal: true

module Aiweb
  class Project
    private

    def normalize_reference_type(value)
      text = value.to_s.strip.downcase
      text = "manual" if text.empty?
      aliases = {
        "gpt-image" => "gpt-image-2",
        "gpt_image_2" => "gpt-image-2",
        "reference-image" => "image",
        "url" => "remote",
        "lazyweb-reference" => "lazyweb"
      }
      normalized = aliases.fetch(text, text)
      allowed = %w[manual image gpt-image-2 remote lazyweb]
      raise UserError.new("ingest-reference --type must be one of: #{allowed.join(", ")}", 1) unless allowed.include?(normalized)

      normalized
    end

    def default_reference_title(reference_type)
      case reference_type
      when "gpt-image-2" then "GPT Image 2 reference notes"
      when "image" then "Reference image notes"
      when "remote" then "Remote reference notes"
      when "lazyweb" then "Lazyweb reference notes"
      else "Manual reference notes"
      end
    end

    def reference_ingestion_brief(existing_brief:, type:, title:, source:, notes:)
      base = existing_brief.to_s.strip
      lines = base.empty? ? ["# Design Reference Brief", "", "Provider: manual", "Generated at: #{now}"] : [base]
      lines.concat([
        "",
        "## Manually Ingested Reference Evidence",
        "",
        "### #{title}",
        "- Type: #{type}",
        "- Source: #{source.to_s.empty? ? "manual notes" : source}",
        "- Recorded at: #{now}",
        "",
        "#### Pattern Constraints",
        *reference_pattern_constraints(notes),
        "",
        "#### No-copy Guardrails",
        *reference_no_copy_guardrails.map { |guardrail| "- #{guardrail}" },
        "",
        "This reference is pattern evidence only. It is not implementation source and must not be routed directly to scaffold, source edits, copywriting, pricing, trademarks, or brand claims."
      ])
      lines.join("\n").rstrip + "\n"
    end

    def reference_pattern_constraints(notes)
      text = notes.to_s.strip
      return ["- Preserve approved product, brand, IA, and `.ai-web/DESIGN.md` constraints; no additional visual constraint was supplied."] if text.empty?

      text.lines.map(&:strip).reject(&:empty?).first(20).map do |line|
        normalized = line.sub(/\A[-*]\s*/, "")
        "- Interpret as pattern constraint: #{normalized}"
      end
    end

    def reference_no_copy_guardrails
      [
        "Borrow only abstract interaction, hierarchy, mood, spacing, composition, and accessibility patterns.",
        "Do not reproduce exact screenshot layout, visual asset, copy, prices, logos, trademarks, brand marks, signed URLs, or brand-specific claims.",
        "Do not treat GPT Image 2 output or reference images as source assets; convert them into design constraints before implementation.",
        "Implementation agents must use this brief as read-only pattern evidence and must not call external research tools during source edits."
      ]
    end

    def reject_reference_secret_path!(value, label)
      text = value.to_s.strip
      return if text.empty?

      reject_env_file_segment!(text, "ingest-reference refuses to read .env or .env.* #{label} paths")
      path_segments = text.split(/[\\\/]+/)
      if path_segments.any? { |part| part.match?(/\A(?:secrets?|credentials?|private[-_.]?keys?)(?:\.|\z|-|_)/i) }
        raise UserError.new("ingest-reference refuses to read secret-looking #{label} paths", 1)
      end
    end

    def design_reference_brief_present?
      path = File.join(aiweb_dir, "design-reference-brief.md")
      File.file?(path) && File.read(path).to_s.strip.length >= 40
    end
  end
end
