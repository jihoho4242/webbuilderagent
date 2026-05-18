# frozen_string_literal: true

module Aiweb
  class Project
    private

    def design_research_paths(state)
      research = state.dig("research", "design_research") || {}
      {
        "reference_brief" => research["reference_brief_path"] || ".ai-web/design-reference-brief.md",
        "normalized_results" => research["normalized_results_path"] || ".ai-web/research/lazyweb/results.json",
        "pattern_matrix" => research["pattern_matrix_path"] || ".ai-web/research/lazyweb/pattern-matrix.md",
        "latest" => ".ai-web/research/lazyweb/latest.json"
      }
    end

    def lazyweb_token_configured?
      return true unless ENV["LAZYWEB_MCP_TOKEN"].to_s.strip.empty?
      ["~/.lazyweb/lazyweb_mcp_token", "~/.codex/lazyweb_mcp_token"].any? do |source|
        path = File.expand_path(source)
        File.file?(path) && !File.read(path).to_s.strip.empty?
      rescue SystemCallError
        false
      end
    end

    def design_research_planned_queries
      intent = load_intent_artifact rescue {}
      text = [intent["archetype"], intent["market"], intent["primary_interaction"], intent["idea"]].compact.join(" ").downcase
      if text.match?(/ecommerce|commerce|shop|checkout|product|store|cart/)
        ["mobile product detail page", "checkout flow", "cart upsell", "subscription paywall"]
      elsif text.match?(/service|booking|appointment|local/)
        ["local service booking page", "trust section", "contact booking CTA"]
      elsif text.match?(/premium|luxury|editorial/)
        ["luxury editorial landing page", "premium product page", "high trust hero"]
      elsif text.match?(/chat|assistant|ai assistant/)
        ["AI assistant onboarding", "chat app first screen", "dashboard empty state"]
      else
        ["B2B SaaS landing page", "developer tools pricing page", "team settings billing", "dashboard onboarding"]
      end
    end

    def run_design_research_helper(state:, provider:, policy:, limit:)
      klass = Aiweb.const_get(:DesignResearch) if Aiweb.const_defined?(:DesignResearch)
      return nil unless klass

      ensure_design_research_state_defaults!(state)
      adapter = state.dig("adapters", "design_research") || {}
      client = Aiweb::LazywebClient.new(
        endpoint: adapter["endpoint"] || "https://www.lazyweb.com/mcp",
        timeout_seconds: adapter["command_timeout_seconds"] || 45,
        token_sources: adapter["token_sources"] || ["LAZYWEB_MCP_TOKEN", "~/.lazyweb/lazyweb_mcp_token", "~/.codex/lazyweb_mcp_token"]
      )
      researcher = klass.new(root: root, client: client)
      return nil unless researcher.respond_to?(:run)

      intent = load_intent_artifact
      design_brief = read_design_research_brief_source
      result = researcher.run(intent: intent, design_brief: design_brief, policy: policy, limit: limit)
      return nil unless result.is_a?(Hash)

      changes = Array(result["changed_files"])
      payload = nil
      mutation(dry_run: false) do
        state = load_state
        ensure_design_research_state_defaults!(state)
        research = state["research"]["design_research"]
        paths = design_research_paths(state)
        research["provider"] = provider
        research["policy"] = policy
        research["status"] = "ready"
        research["latest_run"] = now
        research["skipped_reason"] = nil
        research["last_error"] = nil
        research["reference_brief_path"] = paths["reference_brief"]
        research["pattern_matrix_path"] = paths["pattern_matrix"]
        research["normalized_results_path"] = paths["normalized_results"]
        mark_artifacts_from_files!(state)
        add_decision!(state, "design_research_completed", "Completed Lazyweb design research and wrote reference artifacts")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "completed design research"
        payload["design_research"] = design_research_summary(state).merge(
          "planned_queries" => Array(result.dig("latest", "queries")),
          "planned_artifact_paths" => paths.values,
          "token_configured" => true,
          "side_effect_broker" => result["side_effect_broker"],
          "side_effect_broker_events" => result["side_effect_broker_events"]
        )
        payload["next_action"] = "review .ai-web/design-reference-brief.md, then continue with aiweb design-system resolve"
      end
      payload
    rescue StandardError => e
      raise UserError.new("Lazyweb design research adapter failed: #{redact_lazyweb_secret(e.message)}", 4)
    end

    def read_design_research_brief_source
      path = File.join(aiweb_dir, "design-brief.md")
      return nil unless File.file?(path)
      return nil if stub_file?(path)

      File.read(path)
    rescue SystemCallError
      nil
    end

    def record_design_research_skip!(state, provider, policy, reason, paths, planned_queries, dry_run:)
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        ensure_design_research_state_defaults!(state)
        research = state["research"]["design_research"]
        research["provider"] = provider
        research["policy"] = policy
        research["status"] = policy == "off" ? "skipped" : "skipped"
        research["latest_run"] = now
        research["skipped_reason"] = reason
        research["last_error"] = nil
        add_decision!(state, "design_research_skipped", "Skipped Lazyweb design research: #{reason}")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        mark_artifacts_from_files!(state)
        changes << write_yaml(state_path, state, dry_run)
        payload = status_hash(state: state, changed_files: compact_changes(changes))
        payload["action_taken"] = "skipped design research"
        payload["design_research"] = design_research_summary(state).merge(
          "planned_queries" => planned_queries,
          "planned_artifact_paths" => paths.values,
          "token_configured" => lazyweb_token_configured?
        )
        payload["next_action"] = "continue deterministic design flow with aiweb design-system resolve"
      end
      payload
    end

    def design_research_summary(state)
      ensure_design_research_state_defaults!(state)
      research = state.dig("research", "design_research") || {}
      counts = design_research_reference_counts(state)
      {
        "provider" => research["provider"],
        "policy" => research["policy"],
        "status" => research["status"],
        "latest_run" => research["latest_run"],
        "reference_brief_path" => research["reference_brief_path"],
        "pattern_matrix_path" => research["pattern_matrix_path"],
        "normalized_results_path" => research["normalized_results_path"],
        "min_references" => research["min_references"],
        "min_companies" => research["min_companies"],
        "accepted_references" => counts["accepted_references"],
        "unique_companies" => counts["unique_companies"],
        "skipped_reason" => research["skipped_reason"],
        "last_error" => redact_lazyweb_secret(research["last_error"].to_s)
      }
    end

    def design_research_required_blockers(state)
      ensure_design_research_state_defaults!(state)
      research = state.dig("research", "design_research") || {}
      return [] unless research["policy"] == "required"

      blockers = []
      brief_path = File.join(root, research["reference_brief_path"].to_s)
      matrix_path = File.join(root, research["pattern_matrix_path"].to_s)
      counts = design_research_reference_counts(state)
      min_refs = research["min_references"].to_i
      min_companies = research["min_companies"].to_i

      blockers << "Lazyweb design reference brief is required but missing" unless substantive_design_research_file?(brief_path)
      if counts["accepted_references"] < min_refs
        blockers << "Lazyweb references must include >= #{min_refs} accepted references; currently #{counts["accepted_references"]}"
      end
      if counts["unique_companies"] < min_companies
        blockers << "Lazyweb references must include >= #{min_companies} unique companies; currently #{counts["unique_companies"]}"
      end
      missing_sections = missing_design_research_matrix_sections(matrix_path)
      unless missing_sections.empty?
        blockers << "Lazyweb pattern matrix is missing sections: #{missing_sections.join(", ")}"
      end
      blockers
    end

    def design_research_reference_counts(state)
      research = state.dig("research", "design_research") || {}
      path = File.join(root, research["normalized_results_path"].to_s)
      rows = design_research_result_rows(path)
      companies = rows.map { |row| row["company"].to_s.strip.downcase }.reject(&:empty?).uniq
      { "accepted_references" => rows.length, "unique_companies" => companies.length }
    end

    def design_research_result_rows(path)
      return [] unless File.file?(path)
      data = JSON.parse(File.read(path))
      rows = if data.is_a?(Array)
               data
             elsif data.is_a?(Hash)
               data["references"] || data["results"] || data["items"] || []
             else
               []
             end
      rows.select { |row| row.is_a?(Hash) }
    rescue JSON::ParserError, SystemCallError
      []
    end

    def substantive_design_research_file?(path)
      File.file?(path) && !stub_file?(path) && File.read(path).to_s.strip.length >= 80
    rescue SystemCallError
      false
    end

    def missing_design_research_matrix_sections(path)
      required = {
        "hierarchy" => /hierarchy|information hierarchy/i,
        "cta" => /cta|call[- ]?to[- ]?action/i,
        "layout" => /layout/i,
        "visual style" => /visual (style|language)|style/i,
        "mobile/responsive" => /mobile|responsive/i,
        "no-copy" => /no[- ]?copy|copy risk|do not copy/i
      }
      return required.keys unless File.file?(path)
      content = File.read(path)
      required.select { |_name, pattern| !content.match?(pattern) }.keys
    rescue SystemCallError
      required.keys
    end

    def redact_lazyweb_secret(value)
      value.to_s
        .gsub(/Bearer\s+[^\s"']+/i, "Bearer [REDACTED]")
        .gsub(/(LAZYWEB_MCP_TOKEN=)[^\s"']+/i, "\\1[REDACTED]")
        .gsub(/([?&](?:token|access_token|signature|X-Amz-Signature)=)[^&\s"']+/i, "\\1[REDACTED]")
    end

  end
end
