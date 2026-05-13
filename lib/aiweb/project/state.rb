# frozen_string_literal: true

module Aiweb
  module ProjectStateBoundary
    private

    def ensure_defaults!(state)
      state["invalidations"] ||= []
      state["decisions"] ||= []
      state["snapshots"] ||= []
      state["qa"] ||= {}
      state["qa"]["open_failures"] ||= []
      state["design_candidates"] ||= {}
      state["design_candidates"]["candidates"] ||= []
      ensure_research_state_defaults!(state)
      ensure_pr19_deploy_defaults!(state)
      ensure_setup_state_defaults!(state)
      ensure_scaffold_state_defaults!(state)
      ensure_design_research_state_defaults!(state)
      state["budget"] ||= {}
      state["budget"]["cost_mode"] ||= "subscription_usage"
      state["budget"]["meter_model_cost"] = false if state["budget"]["meter_model_cost"].nil?
      state["budget"]["max_design_generations_total"] ||= 10
      state["budget"]["max_design_candidates"] ||= 10
      state["budget"]["max_qa_runtime_minutes"] ||= 60
      state["budget"]["qa_timeout_action"] ||= "self_diagnose_fix_rerun"
      state["budget"]["max_qa_timeout_recovery_cycles"] ||= 3
      state
    end

    def ensure_research_state_defaults!(state)
      state["artifacts"] ||= {}
      state["artifacts"]["design_reference_brief"] ||= { "path" => self.class::DESIGN_REFERENCE_BRIEF_PATH, "status" => "missing" }
      state["artifacts"]["design_reference_results"] ||= { "path" => self.class::DESIGN_REFERENCE_RESULTS_PATH, "status" => "missing" }
      state["artifacts"]["design_pattern_matrix"] ||= { "path" => self.class::DESIGN_PATTERN_MATRIX_PATH, "status" => "missing" }

      state["research"] ||= {}
      state["research"]["design_research"] ||= {}
      design_research = state["research"]["design_research"]
      design_research["policy"] ||= "opportunistic"
      design_research["provider"] ||= "lazyweb"
      design_research["latest_run"] = nil unless design_research.key?("latest_run")
      design_research["status"] ||= "missing"
      design_research["reference_brief_path"] ||= self.class::DESIGN_REFERENCE_BRIEF_PATH
      design_research["pattern_matrix_path"] ||= self.class::DESIGN_PATTERN_MATRIX_PATH
      design_research["normalized_results_path"] ||= self.class::DESIGN_REFERENCE_RESULTS_PATH
      design_research["min_references"] ||= 5
      design_research["min_companies"] ||= 3
      design_research["last_error"] = nil unless design_research.key?("last_error")
      design_research["skipped_reason"] = nil unless design_research.key?("skipped_reason")

      state["adapters"] ||= {}
      state["adapters"]["design_research"] ||= {}
      adapter = state["adapters"]["design_research"]
      adapter["provider"] ||= "lazyweb"
      adapter["transport"] ||= "streamable-http"
      adapter["endpoint"] ||= "https://www.lazyweb.com/mcp"
      adapter["network_allowed"] = true unless adapter.key?("network_allowed")
      adapter["mcp_servers_allowed"] ||= ["lazyweb"]
      adapter["token_sources"] ||= [
        "LAZYWEB_MCP_TOKEN",
        "~/.lazyweb/lazyweb_mcp_token",
        "~/.codex/lazyweb_mcp_token"
      ]
      adapter["token_storage_allowed_in_repo"] = false unless adapter.key?("token_storage_allowed_in_repo")
      adapter["command_timeout_seconds"] ||= 45

      state
    end

    def refresh_state!(state)
      ensure_defaults!(state)
      mark_artifacts_from_files!(state)
      update_design_counts!(state)
      state
    end

    def mark_artifacts_from_files!(state)
      artifacts = state["artifacts"] || {}
      artifacts.each do |name, meta|
        next unless meta.is_a?(Hash)
        path = meta["path"]
        next if path.nil?
        full = File.join(root, path)
        if File.directory?(full)
          meta["status"] = Dir.children(full).empty? ? "missing" : "draft"
        elsif File.exist?(full)
          meta["status"] = stub_file?(full) ? "stub" : "draft"
        else
          meta["status"] = "missing"
        end
      end
      state
    end

    def update_design_counts!(state)
      dir = File.join(aiweb_dir, "design-candidates")
      candidate_files = Dir.exist?(dir) ? Dir.glob(File.join(dir, "candidate-*.{md,html}"), File::FNM_EXTGLOB).sort : []
      refs = state.dig("design_candidates", "candidates") || []
      known = refs.map { |r| r["path"] }
      candidate_files.each do |path|
        rel = relative(path)
        next if known.include?(rel)
        refs << {
          "id" => File.basename(path, File.extname(path)),
          "path" => rel,
          "status" => "draft"
        }
      end
      state["design_candidates"]["candidates"] = refs
      count = refs.length
      state["design_candidates"]["max_allowed"] ||= state.dig("budget", "max_design_candidates") || 10
      if state.dig("artifacts", "design_candidates")
        state["artifacts"]["design_candidates"]["count"] = count
        state["artifacts"]["design_candidates"]["status"] = count.zero? ? "missing" : "draft"
      end
      state
    end

    def validate_state_shape(state)
      errors = []
      schema_errors = validate_json_schema(state, load_schema("state.schema.json"))
      schema_errors = suppress_stale_design_research_schema_errors(schema_errors)
      errors.concat(schema_errors.map { |error| "state.schema: #{error}" })
      errors.concat(validate_intent_shape)
      self.class::REQUIRED_TOP_LEVEL_STATE_KEYS.each { |key| errors << "missing #{key}" unless state.key?(key) }
      unknown = state.keys - self.class::REQUIRED_TOP_LEVEL_STATE_KEYS
      errors << "unknown top-level keys: #{unknown.join(", ")}" unless unknown.empty?
      errors << "schema_version must be 1" unless state["schema_version"] == 1
      current = state.dig("phase", "current")
      errors << "unknown phase #{current.inspect}" unless self.class::PHASES.include?(current)
      budget = state["budget"] || {}
      errors << "budget.cost_mode missing" unless budget.key?("cost_mode")
      errors << "budget.max_design_candidates must be >= 1" if budget["max_design_candidates"].to_i < 1
      errors << "budget.max_qa_runtime_minutes must be >= 1" if budget["max_qa_runtime_minutes"].to_i < 1
      errors << "Gate 1B key missing" unless state.dig("gates", "gate_1b_product_content_ia_data_security")
      validate_accepted_risks(state, errors)
      errors
    end

    def validate_intent_shape
      path = File.join(aiweb_dir, "intent.yaml")
      return ["intent artifact missing"] unless File.exist?(path)
      return [] if stub_file?(path)

      intent = YAML.load_file(path)
      validate_json_schema(intent, load_schema("intent.schema.json")).map { |error| "intent.schema: #{error}" }
    rescue Psych::SyntaxError => e
      ["intent.yaml parse failed: #{e.message}"]
    end

    def validate_qa_result!(result)
      errors = validate_json_schema(result, load_schema("qa-result.schema.json"))
      raise UserError.new("QA result schema failed: #{errors.join("; ")}", 1) unless errors.empty?
      true
    end

    def load_schema(name)
      project_schema = name == "qa-result.schema.json" ? File.join(aiweb_dir, "qa", name) : File.join(aiweb_dir, name)
      path = File.exist?(project_schema) ? project_schema : File.join(templates_dir, name)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise UserError.new("cannot parse schema #{name}: #{e.message}", 1)
    end


    def suppress_stale_design_research_schema_errors(errors)
      allowed = [
        "$.research is not allowed",
        "$.adapters.design_research is not allowed",
        "$.artifacts.design_reference_brief is not allowed",
        "$.artifacts.design_reference_results is not allowed",
        "$.artifacts.design_pattern_matrix is not allowed"
      ]
      errors.reject { |error| allowed.include?(error) }
    end

    def validate_json_schema(value, schema, path = "$", root_schema = nil)
      root_schema ||= schema
      if schema["$ref"]
        schema = resolve_schema_ref(root_schema, schema["$ref"])
      end

      errors = []
      if schema.key?("const") && value != schema["const"]
        errors << "#{path} must equal #{schema["const"].inspect}"
      end
      if schema.key?("enum") && !schema["enum"].include?(value)
        errors << "#{path} must be one of #{schema["enum"].map(&:inspect).join(", ")}"
      end
      if schema["type"] && !schema_type_match?(value, schema["type"])
        errors << "#{path} expected #{Array(schema["type"]).join("|")}, got #{value.class}"
        return errors
      end
      if schema.key?("minimum") && value.is_a?(Numeric) && value < schema["minimum"]
        errors << "#{path} must be >= #{schema["minimum"]}"
      end

      if value.is_a?(Hash)
        required = schema["required"] || []
        required.each do |key|
          errors << "#{path}.#{key} is required" unless value.key?(key)
        end

        properties = schema["properties"] || {}
        properties.each do |key, child_schema|
          next unless value.key?(key)
          errors.concat(validate_json_schema(value[key], child_schema, "#{path}.#{key}", root_schema))
        end

        additional = schema["additionalProperties"]
        unknown = value.keys - properties.keys
        if additional == false
          unknown.each { |key| errors << "#{path}.#{key} is not allowed" }
        elsif additional.is_a?(Hash)
          unknown.each do |key|
            errors.concat(validate_json_schema(value[key], additional, "#{path}.#{key}", root_schema))
          end
        end
      elsif value.is_a?(Array) && schema["items"]
        value.each_with_index do |item, index|
          errors.concat(validate_json_schema(item, schema["items"], "#{path}[#{index}]", root_schema))
        end
      end

      errors
    end

    def resolve_schema_ref(root_schema, ref)
      unless ref.start_with?("#/")
        raise UserError.new("unsupported schema ref #{ref}", 1)
      end
      ref.sub("#/", "").split("/").reduce(root_schema) do |node, part|
        key = part.gsub("~1", "/").gsub("~0", "~")
        node.fetch(key)
      end
    end

    def schema_type_match?(value, type)
      Array(type).any? do |kind|
        case kind
        when "null" then value.nil?
        when "object" then value.is_a?(Hash)
        when "array" then value.is_a?(Array)
        when "string" then value.is_a?(String)
        when "integer" then value.is_a?(Integer) && !value.is_a?(TrueClass) && !value.is_a?(FalseClass)
        when "number" then value.is_a?(Numeric) && !value.is_a?(TrueClass) && !value.is_a?(FalseClass)
        when "boolean" then value == true || value == false
        else true
        end
      end
    end

    def phase_blockers(state)
      blockers = []
      current = state.dig("phase", "current")
      artifacts = state["artifacts"] || {}
      blockers.concat(phase_lock_blockers(state))
      case current
      when "phase-0"
        blockers.concat(missing_artifacts(artifacts, %w[project product intent first_view_contract]))
      when "phase-0.25"
        blockers.concat(missing_artifacts(artifacts, %w[quality]))
        blockers.concat(quality_contract_blockers)
      when "phase-0.5"
        blockers << "implementation.stack_profile is required" if blank?(state.dig("implementation", "stack_profile"))
        blockers.concat(missing_artifacts(artifacts, %w[stack]))
        blockers << "Gate 1A approval artifact is missing" unless File.exist?(File.join(root, state.dig("gates", "gate_1a_scope_quality_stack", "artifact").to_s))
        blockers << "Gate 1A approval is pending" unless gate_approved?(state, "gate_1a_scope_quality_stack")
      when "phase-1"
        blockers.concat(missing_artifacts(artifacts, %w[product]))
      when "phase-1.5"
        blockers.concat(missing_artifacts(artifacts, %w[brand content]))
      when "phase-2"
        blockers.concat(missing_artifacts(artifacts, %w[ia]))
      when "phase-2.5"
        blockers.concat(missing_artifacts(artifacts, %w[data security]))
        blockers << "Gate 1B approval artifact is missing" unless File.exist?(File.join(root, state.dig("gates", "gate_1b_product_content_ia_data_security", "artifact").to_s))
        blockers << "Gate 1B approval is pending" unless gate_approved?(state, "gate_1b_product_content_ia_data_security")
      when "phase-3"
        blockers.concat(missing_artifacts(artifacts, %w[design_brief]))
      when "phase-3.5"
        count = state.dig("artifacts", "design_candidates", "count").to_i
        min = state.dig("design_candidates", "min_required").to_i
        blockers << "design candidates must be >= #{min}; currently #{count}" if count < min
        blockers.concat(missing_artifacts(artifacts, %w[design_comparison selected_design_candidate]))
        blockers << "Gate 2 design draft is missing" unless File.exist?(File.join(root, state.dig("design_candidates", "gate_2_draft_path").to_s))
        selected = state.dig("design_candidates", "selected_candidate")
        candidate_ids = (state.dig("design_candidates", "candidates") || []).map { |candidate| candidate["id"] }
        blockers << "selected design candidate is required" if blank?(selected)
        blockers << "selected design candidate #{selected.inspect} is not in candidates" if !blank?(selected) && !candidate_ids.include?(selected)
        blockers << "Gate 2 design approval is pending" unless gate_approved?(state, "gate_2_design")
        blockers.concat(design_research_required_blockers(state))
      when "phase-4"
        blockers.concat(missing_artifacts(artifacts, %w[design_system]))
      when "phase-5"
        blockers << "root AGENTS.md is missing" unless File.exist?(File.join(root, "AGENTS.md"))
      when "phase-6"
        blockers << "implementation.current_task is required for bootstrap" if blank?(state.dig("implementation", "current_task"))
      when "phase-7"
        blockers.concat(completed_task_evidence_blockers(state, {
          "design tokens" => [/design[-_ ]?tokens?/i],
          "component primitives" => [/component[-_ ]?primitives?/i],
          "component audit" => [/component[-_ ]?audit/i]
        }))
      when "phase-8"
        blockers << "Gate 3 golden flow artifact is missing" unless File.exist?(File.join(root, state.dig("gates", "gate_3_golden_flow", "artifact").to_s))
        blockers << "Gate 3 golden flow approval is pending" unless gate_approved?(state, "gate_3_golden_flow")
      when "phase-9"
        blockers.concat(completed_task_evidence_blockers(state, {
          "remaining page/feature completion" => [/phase[-_ ]?9/i, /remaining/i, /page/i, /feature/i]
        }))
      when "phase-10"
        blockers << "QA checklist is required" if blank?(state.dig("qa", "current_checklist")) || !File.exist?(File.join(root, state.dig("qa", "current_checklist").to_s))
      when "phase-11"
        blockers.concat(missing_artifacts(artifacts, %w[deploy final_qa_report post_launch_backlog]))
        blockers << "Gate 4 predeploy approval artifact is missing" unless File.exist?(File.join(root, state.dig("gates", "gate_4_predeploy", "artifact").to_s))
        blockers << "Gate 4 predeploy approval is pending" unless gate_approved?(state, "gate_4_predeploy")
        blockers << "deploy.rollback_defined must be true" unless state.dig("deploy", "rollback_defined") == true
        blockers << "deploy.rollback_dry_run_result is required" if blank?(state.dig("deploy", "rollback_dry_run_result"))
      end
      blockers.concat(approved_hash_drift_blockers(state))
      open_failures = state.dig("qa", "open_failures") || []
      blocking_open_failures = open_failures.select { |failure| failure["blocking"] != false }
      blockers << "open QA failures: #{blocking_open_failures.length}" if qa_failures_block_phase?(current) && !blocking_open_failures.empty?
      blockers
    end


    def ensure_design_research_state_defaults!(state)
      state["research"] ||= {}
      state["research"]["design_research"] ||= {}
      research = state["research"]["design_research"]
      research["policy"] ||= "opportunistic"
      research["provider"] ||= "lazyweb"
      research["latest_run"] = nil unless research.key?("latest_run")
      research["status"] ||= "missing"
      research["reference_brief_path"] ||= ".ai-web/design-reference-brief.md"
      research["pattern_matrix_path"] ||= ".ai-web/research/lazyweb/pattern-matrix.md"
      research["normalized_results_path"] ||= ".ai-web/research/lazyweb/results.json"
      research["min_references"] ||= 5
      research["min_companies"] ||= 3
      research["last_error"] = nil unless research.key?("last_error")
      research["skipped_reason"] = nil unless research.key?("skipped_reason")

      state["artifacts"] ||= {}
      state["artifacts"]["design_reference_brief"] ||= { "path" => research["reference_brief_path"], "status" => "missing" }
      state["artifacts"]["design_reference_results"] ||= { "path" => research["normalized_results_path"], "status" => "missing" }
      state["artifacts"]["design_pattern_matrix"] ||= { "path" => research["pattern_matrix_path"], "status" => "missing" }

      state["adapters"] ||= {}
      state["adapters"]["design_research"] ||= {}
      adapter = state["adapters"]["design_research"]
      adapter["provider"] ||= "lazyweb"
      adapter["transport"] ||= "streamable-http"
      adapter["endpoint"] ||= "https://www.lazyweb.com/mcp"
      adapter["network_allowed"] = true if adapter["network_allowed"].nil?
      adapter["mcp_servers_allowed"] ||= ["lazyweb"]
      adapter["token_sources"] ||= ["LAZYWEB_MCP_TOKEN", "~/.lazyweb/lazyweb_mcp_token", "~/.codex/lazyweb_mcp_token"]
      adapter["token_storage_allowed_in_repo"] = false if adapter["token_storage_allowed_in_repo"].nil?
      adapter["command_timeout_seconds"] ||= 45
      state
    end

  end
end
