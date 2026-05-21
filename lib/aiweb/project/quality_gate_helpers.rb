# frozen_string_literal: true

require "digest"
require "yaml"

module Aiweb
  module ProjectQualityGateHelpers
    private

    def qa_failures_block_phase?(current)
      phase_index = self.class::PHASES.index(current)
      threshold = self.class::PHASES.index("phase-7")
      !phase_index.nil? && !threshold.nil? && phase_index >= threshold
    end

    def quality_contract_blockers
      return ["quality.yaml is missing"] unless File.exist?(quality_path)

      quality = YAML.load_file(quality_path)
      errors = validate_json_schema(quality, load_schema("quality.schema.json"))
      return errors.map { |error| "quality.schema: #{error}" } unless errors.empty?

      design_blockers = quality_design_phase0_gate_blockers(quality)
      return design_blockers unless design_blockers.empty?

      approved = quality.dig("quality", "approved")
      approved == true ? [] : ["quality contract must be explicitly approved in .ai-web/quality.yaml (quality.approved: true)"]
    rescue Psych::SyntaxError => e
      ["cannot parse quality.yaml: #{e.message}"]
    end

    def quality_design_phase0_gate_blockers(quality)
      gate = quality.dig("quality", "design", "phase_0_gate")
      return ["quality.design.phase_0_gate is required for human-grade design gating"] unless gate.is_a?(Hash)

      blockers = []
      missing_craft = %w[anti-ai-slop color typography spacing-responsive] - Array(gate["craft_rules_required"]).map(&:to_s)
      blockers << "quality.design.phase_0_gate missing craft rules: #{missing_craft.join(", ")}" unless missing_craft.empty?

      missing_strategies = %w[editorial-premium conversion-focused trust-minimal] - Array(gate["candidate_strategies"]).map(&:to_s)
      blockers << "quality.design.phase_0_gate must require differentiated candidate strategies: #{missing_strategies.join(", ")}" unless missing_strategies.empty?
      blockers << "quality.design.phase_0_gate candidate_strategy_count must be at least 3" if gate["candidate_strategy_count"].to_i < 3

      missing_scores = visual_critique_score_categories - Array(gate["required_score_categories"]).map(&:to_s)
      blockers << "quality.design.phase_0_gate missing visual score categories: #{missing_scores.join(", ")}" unless missing_scores.empty?
      blockers << "quality.design.phase_0_gate min_visual_score_axis must be at least 70" if gate["min_visual_score_axis"].to_f < 70
      blockers << "quality.design.phase_0_gate min_visual_score_average must be at least 78" if gate["min_visual_score_average"].to_f < 78

      missing_widths = [375, 390, 768, 1440] - Array(gate["responsive_first_fold_widths"]).map(&:to_i)
      blockers << "quality.design.phase_0_gate missing responsive widths: #{missing_widths.join(", ")}" unless missing_widths.empty?
      blockers << "quality.design.phase_0_gate first_view_alignment_required must be true" unless gate["first_view_alignment_required"] == true
      blockers << "quality.design.phase_0_gate no_copy_provenance_required must be true" unless gate["no_copy_provenance_required"] == true

      blockers
    end

    def completed_task_evidence_blockers(state, requirements)
      evidence = Array(state.dig("implementation", "completed_tasks")).map(&:to_s)
      requirements.each_with_object([]) do |(label, patterns), blockers|
        matched = evidence.any? { |value| patterns.any? { |pattern| value.match?(pattern) } }
        blockers << "#{label} completed task evidence is required" unless matched
      end
    end

    def stub_file?(path)
      body = File.read(path)
      return true if body.strip.empty?

      substantive = body.lines.map(&:strip).reject do |line|
        line.empty? ||
          line.start_with?("#") ||
          line =~ /^-?\s*TODO\b/i ||
          line =~ /^-?\s*TBD\b/i ||
          line =~ /^-?\s*[A-Za-z0-9가-힣 \/]+:\s*$/ ||
          line =~ /^\|?[-:\s|]+\|?$/ ||
          line =~ /^\|.*\|$/ ||
          line =~ /^Status:\s*(pending)?$/i ||
          line =~ /^Approved (at|by):\s*$/i
      end
      substantive.empty?
    rescue Errno::ENOENT
      true
    end

    def gate_approved?(state, gate_key)
      state.dig("gates", gate_key, "status") == "approved"
    end

    def approved_hash_drift_blockers(state)
      blockers = []
      (state["gates"] || {}).each do |gate_key, gate|
        next unless gate.is_a?(Hash)
        next unless gate["status"] == "approved"
        (gate["approved_artifact_hashes"] || {}).each do |path, expected_hash|
          full_path = File.join(root, path.to_s)
          if !File.exist?(full_path)
            blockers << "#{gate_key} approved artifact missing: #{path}"
          else
            actual_hash = Digest::SHA256.file(full_path).hexdigest
            blockers << "#{gate_key} approved artifact hash drift: #{path}" unless actual_hash == expected_hash
          end
        end
      end
      blockers
    end

    def validate_accepted_risks(state, errors)
      (state["gates"] || {}).each do |gate_key, gate|
        next unless gate.is_a?(Hash)
        (gate["accepted_risks"] || []).each_with_index do |risk, index|
          unless risk.is_a?(Hash)
            errors << "#{gate_key}.accepted_risks[#{index}] must be an object"
            next
          end
          %w[id severity owner mitigation expires_at release_blocker].each do |key|
            errors << "#{gate_key}.accepted_risks[#{index}].#{key} missing" if blank?(risk[key])
          end
        end
      end
    end
  end
end
