# frozen_string_literal: true

require "json"
require "yaml"

require_relative "../../profile_policy"
require_relative "../../runtime"

module Aiweb
  module ProjectRuntimeReadiness
    private

    def runtime_state_snapshot
      return [nil, "Project is not initialized; run aiweb init --profile D or aiweb start before checking runtime readiness."] unless File.file?(state_path)

      state = YAML.load_file(state_path)
      return [state, nil] if state.is_a?(Hash)

      [nil, ".ai-web/state.yaml must be a YAML mapping; repair state before checking runtime readiness."]
    rescue Psych::Exception => e
      [nil, "Cannot parse .ai-web/state.yaml: #{e.message}"]
    end

    def runtime_profile_contract(scaffold)
      Aiweb::ProfilePolicy::Resolver.fetch(scaffold["profile"].to_s)
    end

    def runtime_contract_readiness(contract)
      contract&.runtime_readiness || "blocked"
    end

    def runtime_plan_next_action(readiness)
      case readiness
      when "ready"
        "runtime tools may inspect scripts next; do not install packages or launch Node from this read-only check"
      when "local_planning_only"
        "use local verification/reporting surfaces for this profile; build/preview/browser QA remain intentionally unsupported"
      else
        "resolve blockers, then rerun aiweb runtime-plan"
      end
    end

    def runtime_unsupported_profile_contract(scaffold)
      {
        "id" => scaffold["profile"],
        "runtime_readiness" => "unsupported",
        "supported_runtime_profiles" => %w[D S],
        "blocking_issues" => ["Runtime contract is only implemented for Profile D or Profile S"]
      }
    end

    def runtime_missing_required_files(contract)
      return [] unless contract

      contract.required_files.reject { |path| File.exist?(File.join(root, path)) }
    end

    def runtime_capability_blockers(contract, capability)
      return ["Runtime contract is not implemented for this profile; supported runtime profiles are D and S."] unless contract
      return [] if contract.supports?(capability)

      ["Profile #{contract.id} does not support #{capability} in the current runtime contract; use local verification/reporting surfaces instead."]
    end

    def runtime_process_runner
      @runtime_process_runner ||= Aiweb::Runtime::ProcessRunner.new
    end

    def runtime_tool_env(values = {}, passthrough: [])
      values = values.transform_keys(&:to_s)
      passthrough.each do |key|
        values[key.to_s] = ENV[key.to_s] if ENV.key?(key.to_s)
      end
      values
    end

    def build_command_argv(command)
      Aiweb::Runtime::CommandSpec.argv_from_command(command, default: ["pnpm", "build"])
    end

    def runtime_scaffold_summary(state)
      implementation = state&.fetch("implementation", {}) || {}
      profile = implementation["scaffold_profile"] || implementation["stack_profile"]
      metadata_path = runtime_scaffold_metadata_path(implementation["scaffold_metadata_path"], profile: profile)
      {
        "scaffold_created" => implementation["scaffold_created"] == true,
        "profile" => profile,
        "framework" => implementation["scaffold_framework"],
        "package_manager" => implementation["scaffold_package_manager"],
        "dev_command" => implementation["scaffold_dev_command"],
        "build_command" => implementation["scaffold_build_command"],
        "metadata_path" => metadata_path.fetch("path"),
        "metadata_path_state_value" => metadata_path.fetch("state_value"),
        "metadata_path_safe" => metadata_path.fetch("safe"),
        "metadata_path_error" => metadata_path.fetch("error")
      }
    end

    def runtime_scaffold_metadata_path(state_value, profile: nil)
      contract = Aiweb::ProfilePolicy::Resolver.fetch(profile.to_s)
      expected_path = contract&.metadata_path || self.class::SCAFFOLD_PROFILE_D_METADATA_PATH
      raw = state_value.to_s.strip
      return { "path" => expected_path, "state_value" => nil, "safe" => true, "error" => nil } if raw.empty?

      normalized = raw.tr("\\", "/")
      normalized = normalized.sub(%r{\A(?:\./)+}, "")
      parts = normalized.split("/")
      error = if raw.start_with?("/") || raw.match?(%r{\A[A-Za-z]:[\\/]})
                "scaffold metadata path must be relative to the project .ai-web directory, not absolute"
              elsif parts.any? { |part| part == ".." }
                "scaffold metadata path must not contain traversal"
              elsif parts.any? { |part| part.start_with?(".env") }
                "scaffold metadata path must not reference .env files"
              elsif normalized != expected_path
                "scaffold metadata path must be #{expected_path}"
              end

      {
        "path" => normalized,
        "state_value" => raw,
        "safe" => error.nil?,
        "error" => error
      }
    end

    def runtime_metadata_summary(scaffold)
      relative_metadata_path = scaffold["metadata_path"]
      summary = {
        "path" => relative_metadata_path,
        "present" => false,
        "valid_json" => false,
        "profile" => nil,
        "framework" => nil,
        "package_manager" => nil,
        "dev_command" => nil,
        "build_command" => nil,
        "selected_candidate" => nil,
        "selected_candidate_path" => nil,
        "path_safe" => scaffold["metadata_path_safe"] == true,
        "error" => scaffold["metadata_path_error"]
      }
      return summary unless summary["path_safe"]

      path = File.join(root, relative_metadata_path)
      summary["present"] = File.file?(path)
      return summary unless File.file?(path)

      data = JSON.parse(File.read(path))
      unless data.is_a?(Hash)
        summary["error"] = "metadata must be a JSON object"
        return summary
      end

      summary.merge!(
        "valid_json" => true,
        "profile" => data["profile"],
        "framework" => data["framework"],
        "package_manager" => data["package_manager"],
        "dev_command" => data["dev_command"],
        "build_command" => data["build_command"],
        "selected_candidate" => data["selected_candidate"],
        "selected_candidate_path" => data["selected_candidate_path"]
      )
    rescue JSON::ParserError => e
      summary["error"] = "invalid JSON: #{e.message}"
      summary
    rescue SystemCallError => e
      summary["error"] = e.message
      summary
    end

    def runtime_design_summary(state, metadata)
      state_selected = state&.dig("design_candidates", "selected_candidate").to_s.strip
      metadata_selected = metadata["selected_candidate"].to_s.strip if metadata && metadata["valid_json"]
      metadata_selected ||= ""
      selected = state_selected.empty? ? metadata_selected : state_selected
      design_path = File.join(aiweb_dir, "DESIGN.md")
      selected_path = selected.empty? ? nil : selected_candidate_artifact_path_from_snapshot(state, selected)
      generated_reference = runtime_generated_design_reference_summary
      {
        "selected_candidate" => selected.empty? ? nil : selected,
        "state_selected_candidate" => state_selected.empty? ? nil : state_selected,
        "metadata_selected_candidate" => metadata_selected.empty? ? nil : metadata_selected,
        "generated_reference" => generated_reference,
        "selected_candidate_present" => selected_path ? File.file?(selected_path) : false,
        "selected_candidate_path" => selected_path ? relative(selected_path) : nil,
        "design_md_path" => ".ai-web/DESIGN.md",
        "design_md_present" => File.file?(design_path),
        "design_md_substantive" => File.file?(design_path) && !stub_file?(design_path)
      }
    end

    def runtime_generated_design_reference_summary
      path = File.join(root, "src/content/site.json")
      summary = {
        "path" => "src/content/site.json",
        "present" => File.file?(path),
        "valid_json" => false,
        "selected_candidate" => nil,
        "selected_candidate_path" => nil,
        "error" => nil
      }
      return summary unless File.file?(path)

      data = JSON.parse(File.read(path))
      unless data.is_a?(Hash)
        summary["error"] = "src/content/site.json must be a JSON object"
        return summary
      end

      summary.merge!(
        "valid_json" => true,
        "selected_candidate" => data["selected_candidate"],
        "selected_candidate_path" => data["selected_candidate_path"]
      )
    rescue JSON::ParserError => e
      summary["error"] = "invalid JSON: #{e.message}"
      summary
    rescue SystemCallError => e
      summary["error"] = e.message
      summary
    end

    def selected_candidate_artifact_path_from_snapshot(state, selected)
      ref = Array(state&.dig("design_candidates", "candidates")).find { |candidate| candidate.is_a?(Hash) && candidate["id"].to_s == selected }
      candidates = []
      candidates << File.join(root, ref["path"].to_s) if ref && !ref["path"].to_s.strip.empty?
      candidates << File.join(aiweb_dir, "design-candidates", "#{selected}.html")
      candidates << File.join(aiweb_dir, "design-candidates", "#{selected}.md")
      candidates.find { |path| File.file?(path) } || candidates.first
    end

    def runtime_package_json_summary(contract = nil)
      expected_scripts = contract&.expected_scripts || {}
      expected_dependencies = Array(contract&.expected_dependencies)
      path = File.join(root, "package.json")
      summary = {
        "path" => "package.json",
        "present" => File.file?(path),
        "valid_json" => false,
        "scripts" => runtime_expected_map(expected_scripts),
        "dependencies" => runtime_expected_map(expected_dependencies.to_h { |name| [name, "present"] }),
        "package_manager" => nil,
        "error" => nil
      }
      return summary unless File.file?(path)

      data = JSON.parse(File.read(path))
      unless data.is_a?(Hash)
        summary["error"] = "package.json must be a JSON object"
        return summary
      end

      scripts = data["scripts"].is_a?(Hash) ? data["scripts"] : {}
      dependencies = data["dependencies"].is_a?(Hash) ? data["dependencies"] : {}
      summary["valid_json"] = true
      summary["package_manager"] = data["packageManager"].to_s.split("@").first unless data["packageManager"].to_s.strip.empty?
      summary["scripts"] = expected_scripts.each_with_object({}) do |(name, expected), memo|
        actual = scripts[name]
        memo[name] = {
          "expected" => expected,
          "actual" => actual,
          "present" => !actual.to_s.empty?,
          "matches" => actual == expected
        }
      end
      summary["dependencies"] = expected_dependencies.each_with_object({}) do |name, memo|
        actual = dependencies[name]
        memo[name] = {
          "expected" => "present",
          "actual" => actual,
          "present" => !actual.to_s.empty?
        }
      end
      summary
    rescue JSON::ParserError => e
      summary["error"] = "invalid JSON: #{e.message}"
      summary
    rescue SystemCallError => e
      summary["error"] = e.message
      summary
    end

    def runtime_expected_map(expected)
      expected.each_with_object({}) do |(name, value), memo|
        memo[name] = {
          "expected" => value,
          "actual" => nil,
          "present" => false,
          "matches" => false
        }
      end
    end

    def runtime_plan_blockers(state, state_error, scaffold, metadata, design, package_json, missing_files, contract)
      blockers = []
      blockers << state_error if state_error
      unless scaffold["scaffold_created"]
        blockers << "Scaffold has not been created; run aiweb scaffold --profile D or --profile S after completing the required planning gates."
      end
      if contract.nil?
        blockers << "Runtime contract for Profile #{scaffold["profile"].inspect} is not implemented; supported runtime profiles are D and S."
        return blockers.compact.uniq
      end
      if scaffold["profile"].to_s != contract.id
        blockers << "Runtime contract mismatch: state requested Profile #{scaffold["profile"].inspect}, but resolved #{contract.id.inspect}."
      end
      unless scaffold["metadata_path_safe"]
        blockers << "Unsafe scaffold metadata path #{scaffold["metadata_path_state_value"].inspect}: #{scaffold["metadata_path_error"]}. Runtime plan only reads #{contract.metadata_path}."
      end
      blockers << "Scaffold metadata #{contract.metadata_path} is missing; rerun aiweb scaffold --profile #{contract.id} after reviewing existing files." if scaffold["metadata_path_safe"] && !metadata["present"]
      blockers << "Scaffold metadata #{metadata["path"]} is malformed: #{metadata["error"]}" if metadata["present"] && !metadata["valid_json"]
      runtime_expected_metadata_blockers(scaffold, metadata, contract).each { |blocker| blockers << blocker } if metadata["valid_json"]

      if contract.id == "D"
        runtime_selected_design_drift_blockers(design, contract).each { |blocker| blockers << blocker }
        unless design["design_md_present"]
          blockers << "Design source .ai-web/DESIGN.md is missing; run aiweb design-system resolve or restore the approved design source."
        end
        if design["design_md_present"] && !design["design_md_substantive"]
          blockers << "Design source .ai-web/DESIGN.md is stub-like; provide substantive design constraints before runtime QA."
        end
        if design["selected_candidate"].to_s.empty?
          blockers << "No selected design candidate recorded; run aiweb design --candidates 3 then aiweb select-design candidate-01|candidate-02|candidate-03."
        elsif !design["selected_candidate_present"]
          blockers << "Selected design candidate artifact #{design["selected_candidate_path"] || design["selected_candidate"]} is missing; rerun aiweb design --candidates 3 or select an existing candidate."
        end
      end

      missing_files.each do |path|
        blockers << "Required scaffold file #{path} is missing for Profile #{contract.id}; rerun aiweb scaffold --profile #{contract.id} to complete safe missing files."
      end
      runtime_package_blockers(package_json, contract).each { |blocker| blockers << blocker }
      blockers.compact.uniq
    end

    def runtime_expected_metadata_blockers(scaffold, metadata, contract)
      expected = contract.expected_metadata
      expected.each_with_object([]) do |(key, value), blockers|
        actual = metadata[key]
        blockers << "Scaffold metadata #{key} should be #{value.inspect}, found #{actual.inspect}; rerun aiweb scaffold --profile #{contract.id} or repair metadata." unless actual == value
        state_actual = scaffold[key]
        next if state_actual.to_s.empty? || state_actual == actual

        blockers << "State scaffold #{key} (#{state_actual.inspect}) does not match metadata (#{actual.inspect}); repair .ai-web/state.yaml or rerun scaffold with reviewed force."
      end
    end

    def runtime_selected_design_drift_blockers(design, contract = Aiweb::ProfilePolicy::ProfileD.contract)
      blockers = []
      state_selected = design["state_selected_candidate"].to_s.strip
      metadata_selected = design["metadata_selected_candidate"].to_s.strip
      generated = design.fetch("generated_reference", {})
      generated_selected = generated["selected_candidate"].to_s.strip

      if state_selected.empty? && !metadata_selected.empty?
        blockers << "Selected design drift: state design_candidates.selected_candidate is missing but scaffold metadata selected_candidate is #{metadata_selected.inspect}; reselect the intended candidate and rerun aiweb scaffold --profile D, or repair .ai-web/state.yaml."
      elsif !state_selected.empty? && metadata_selected.empty?
        blockers << "Selected design drift: state design_candidates.selected_candidate is #{state_selected.inspect} but scaffold metadata selected_candidate is missing; rerun aiweb scaffold --profile #{contract.id} or repair #{contract.metadata_path}."
      elsif state_selected != metadata_selected
        blockers << "Selected design drift: state design_candidates.selected_candidate (#{state_selected.inspect}) does not match scaffold metadata selected_candidate (#{metadata_selected.inspect}); reselect the intended candidate and rerun aiweb scaffold --profile D, or repair .ai-web/state.yaml and #{contract.metadata_path}."
      end

      if generated["present"] && !generated["valid_json"]
        blockers << "Generated scaffold content #{generated["path"]} is malformed: #{generated["error"]}; rerun aiweb scaffold --profile D after reviewing local edits."
      elsif generated["present"] && generated["valid_json"]
        expected = state_selected.empty? ? metadata_selected : state_selected
        if !expected.empty? && generated_selected.empty?
          blockers << "Selected design drift: generated scaffold content #{generated["path"]} selected_candidate is missing but selected design is #{expected.inspect}; rerun aiweb scaffold --profile D after reviewing generated content."
        elsif !expected.empty? && generated_selected != expected
          blockers << "Selected design drift: generated scaffold content #{generated["path"]} selected_candidate (#{generated_selected.inspect}) does not match selected design (#{expected.inspect}); rerun aiweb scaffold --profile D after reviewing generated content."
        end
        if !metadata_selected.empty? && !generated_selected.empty? && generated_selected != metadata_selected
          blockers << "Selected design drift: generated scaffold content #{generated["path"]} selected_candidate (#{generated_selected.inspect}) does not match scaffold metadata selected_candidate (#{metadata_selected.inspect}); rerun aiweb scaffold --profile D after reviewing generated content."
        end
      end

      blockers
    end

    def runtime_package_blockers(package_json, contract)
      blockers = []
      unless package_json["present"]
        blockers << "package.json is missing; rerun aiweb scaffold --profile #{contract.id} before runtime tools."
        return blockers
      end
      unless package_json["valid_json"]
        blockers << "package.json is malformed: #{package_json["error"]}; fix JSON before runtime tools."
        return blockers
      end
      package_json.fetch("scripts").each do |name, status|
        unless status["matches"]
          blockers << "package.json script #{name.inspect} should be #{status["expected"].inspect}; found #{status["actual"].inspect}."
        end
      end
      package_json.fetch("dependencies").each do |name, status|
        blockers << "package.json dependency #{name.inspect} is missing; restore Profile #{contract.id} scaffold dependencies." unless status["present"]
      end
      blockers
    end
  end
end
