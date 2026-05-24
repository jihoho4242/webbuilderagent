# frozen_string_literal: true

module Aiweb
  module ProjectStateBoundary
    private

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

  end
end
