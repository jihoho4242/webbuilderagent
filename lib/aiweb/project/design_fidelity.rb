# frozen_string_literal: true

module Aiweb
  module ProjectDesignFidelity
    private

    DESIGN_FIDELITY_THRESHOLD = 0.8

    def engine_run_design_fidelity_result(workspace_dir, policy, contract)
      changed_paths = Array(policy["safe_changes"]) + Array(policy["approval_changes"]) + Array(policy["blocked_changes"])
      return engine_run_design_fidelity_skipped("OpenDesign contract is not ready") unless contract && contract["status"] == "ready"
      return engine_run_design_fidelity_skipped("no changed files to verify") if changed_paths.empty?

      blockers = []
      repair_issues = []
      changed_paths.uniq.each do |path|
        workspace_path = File.join(workspace_dir, path)
        next unless File.file?(workspace_path)

        content = File.read(workspace_path, 512 * 1024)
        engine_run_design_fidelity_hook_issues(path, content, contract).each { |issue| blockers << issue }
        engine_run_design_fidelity_candidate_issues(path, content, contract).each { |issue| blockers << issue }
        engine_run_design_fidelity_reference_issues(path, content, contract).each { |issue| blockers << issue }
        engine_run_design_fidelity_token_issues(path, content, contract).each { |issue| repair_issues << issue }
      rescue SystemCallError, ArgumentError
        blockers << "design fidelity could not read changed file: #{path}"
      end

      selected_design_fidelity = blockers.empty? && repair_issues.empty? ? 1.0 : (blockers.empty? ? 0.6 : 0.0)
      status = if !blockers.empty?
                 "blocked"
               elsif selected_design_fidelity < DESIGN_FIDELITY_THRESHOLD
                 "repair"
               else
                 "passed"
               end

      {
        "schema_version" => 1,
        "status" => status,
        "selected_design_fidelity" => selected_design_fidelity,
        "threshold" => DESIGN_FIDELITY_THRESHOLD,
        "static_fidelity" => {
          "status" => status,
          "checked_files" => changed_paths.uniq,
          "blocking_issues" => blockers,
          "repair_issues" => repair_issues
        },
        "visual_fidelity" => {
          "status" => "pending",
          "reason" => "screenshot-based visual verdict is handled by the browser evidence batches"
        },
        "contract_hash" => contract["contract_hash"],
        "selected_candidate" => contract["selected_candidate"],
        "selected_candidate_sha256" => contract["selected_candidate_sha256"],
        "blocking_issues" => blockers,
        "repair_issues" => repair_issues
      }
    end

    def engine_run_design_fidelity_skipped(reason)
      {
        "schema_version" => 1,
        "status" => "skipped",
        "selected_design_fidelity" => nil,
        "threshold" => DESIGN_FIDELITY_THRESHOLD,
        "static_fidelity" => { "status" => "skipped", "checked_files" => [], "blocking_issues" => [], "repair_issues" => [] },
        "visual_fidelity" => { "status" => "pending" },
        "blocking_issues" => [],
        "repair_issues" => [],
        "reason" => reason
      }
    end

    def engine_run_design_fidelity_hook_issues(path, content, contract)
      Array(contract["component_targets"]).each_with_object([]) do |target, issues|
        next unless target.is_a?(Hash)
        next unless target["source_path"].to_s == path

        id = target["data_aiweb_id"].to_s
        next if id.empty?
        next if content.include?(%(data-aiweb-id="#{id}")) || content.include?(%(data-aiweb-id='#{id}'))

        issues << "changed source lost required data-aiweb-id #{id}: #{path}"
      end
    end

    def engine_run_design_fidelity_candidate_issues(path, content, contract)
      selected = contract["selected_candidate"].to_s
      return [] if selected.empty?
      return [] unless path.end_with?(".json") || content.include?("selected_candidate")

      parsed = JSON.parse(content) rescue nil
      if parsed.is_a?(Hash) && parsed.key?("selected_candidate") && parsed["selected_candidate"].to_s != selected
        return ["changed source selected candidate drifted from #{selected} to #{parsed["selected_candidate"]}: #{path}"]
      end
      content.scan(/selected_candidate["']?\s*[:=]\s*["'](candidate-\d+)["']/).flatten.uniq.reject { |candidate| candidate == selected }.map do |candidate|
        "changed source selected candidate identity drifted from #{selected} to #{candidate}: #{path}"
      end
    end

    def engine_run_design_fidelity_reference_issues(path, content, contract)
      Array(contract["reference_forbidden_terms"]).each_with_object([]) do |term, issues|
        text = term.to_s.strip
        next if text.empty?
        next unless content.match?(/\b#{Regexp.escape(text)}\b/i)

        issues << "changed source contains forbidden reference term #{text}: #{path}"
      end
    end

    def engine_run_design_fidelity_token_issues(path, content, contract)
      return [] unless path.match?(/\.(?:css|scss|astro|tsx?|jsx?)\z/)

      required_vars = Array(contract["token_requirements"]).grep(/\A--[a-z0-9-]+\z/i)
      return [] if required_vars.empty?

      missing = required_vars.reject { |name| content.include?(name) }
      missing.empty? ? [] : ["changed source may have dropped design token references: #{missing.first(8).join(", ")}"]
    end
  end
end
