# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    def engine_run_opendesign_contract(state, goal:)
      selected = state.dig("design_candidates", "selected_candidate").to_s.strip
      selected_ref = Array(state.dig("design_candidates", "candidates")).find { |candidate| candidate.is_a?(Hash) && candidate["id"].to_s == selected }
      selected_path = selected.empty? ? nil : selected_candidate_artifact_path(state, selected)
      files = {
        "design" => engine_run_contract_file(File.join(aiweb_dir, "DESIGN.md"), "design"),
        "design_reference_brief" => engine_run_contract_file(File.join(aiweb_dir, "design-reference-brief.md"), "reference_brief"),
        "selected_design" => engine_run_contract_file(File.join(aiweb_dir, "design-candidates", "selected.md"), "selected_design"),
        "selected_candidate" => selected_path ? engine_run_contract_file(selected_path, "selected_candidate") : nil,
        "component_map" => engine_run_contract_file(File.join(aiweb_dir, "component-map.json"), "component_map")
      }.compact.select { |_name, file| file["present"] }
      selected_file = files["selected_candidate"]
      component_map = engine_run_read_json_artifact(File.join(aiweb_dir, "component-map.json"))
      required_ids = selected_file ? engine_run_extract_data_aiweb_ids(File.read(File.join(root, selected_file.fetch("path")))) : []
      component_targets = Array(component_map && component_map["components"]).filter_map do |component|
        next unless component.is_a?(Hash) && !component["data_aiweb_id"].to_s.empty?

        {
          "data_aiweb_id" => component["data_aiweb_id"].to_s,
          "source_path" => component["source_path"].to_s
        }
      end
      component_ids = component_targets.map { |target| target["data_aiweb_id"] }
      requires_selected = engine_run_requires_opendesign_selection?(state, goal)
      blocking_issues = []
      if requires_selected && selected.empty?
        blocking_issues << "engine-run UI/source work requires a selected design candidate before agentic execution"
      elsif requires_selected && selected_file.nil?
        blocking_issues << "engine-run UI/source work requires selected design artifact #{selected_path ? relative(selected_path) : ".ai-web/design-candidates/#{selected}.html"}"
      end

      contract_basis = {
        "selected_candidate" => selected.empty? ? nil : selected,
        "selected_candidate_path" => selected_file && selected_file["path"],
        "artifacts" => files.transform_values { |file| file.slice("path", "sha256", "bytes") },
        "required_data_aiweb_ids" => required_ids,
        "component_data_aiweb_ids" => component_ids,
        "component_targets" => component_targets,
        "route_intent" => engine_run_route_intent(state, selected_ref),
        "required_quality_fields" => engine_run_opendesign_required_quality_fields,
        "token_requirements" => engine_run_token_requirements(files["design"]),
        "reference_no_copy_rules" => engine_run_reference_no_copy_rules(files),
        "reference_forbidden_terms" => engine_run_reference_forbidden_terms(files)
      }
      contract_hash = "sha256:#{Digest::SHA256.hexdigest(json_generate(contract_basis))}"
      contract_basis.merge(
        "schema_version" => 1,
        "status" => selected_file ? "ready" : "missing",
        "contract_hash" => contract_hash,
        "selected_candidate_sha256" => selected_file && selected_file["sha256"],
        "requires_selected_design" => requires_selected,
        "blocking_issues" => blocking_issues
      )
    end

    def engine_run_contract_file(path, kind)
      expanded = File.expand_path(path, root)
      return { "kind" => kind, "path" => relative(expanded), "present" => false } unless File.file?(expanded)

      {
        "kind" => kind,
        "path" => relative(expanded),
        "present" => true,
        "bytes" => File.size(expanded),
        "sha256" => "sha256:#{Digest::SHA256.file(expanded).hexdigest}"
      }
    rescue SystemCallError
      { "kind" => kind, "path" => relative(path), "present" => false }
    end

    def engine_run_read_json_artifact(path)
      return nil unless File.file?(path)

      JSON.parse(File.read(path, 512 * 1024))
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def engine_run_extract_data_aiweb_ids(content)
      content.to_s.scan(/data-aiweb-id\s*=\s*["']([^"']+)["']/).flatten.uniq.sort
    end

    def engine_run_requires_opendesign_selection?(state, goal)
      profile = state.dig("implementation", "scaffold_profile").to_s
      profile = state.dig("implementation", "stack_profile").to_s if profile.empty?
      return false unless profile == "D"

      goal.to_s.match?(/\b(?:ui|ux|web|website|landing|page|hero|component|source|style|design|scaffold|frontend|screen|layout|copy)\b/i)
    end

    def engine_run_route_intent(state, selected_ref)
      intent = read_json_file(File.join(aiweb_dir, "intent.json")) || {}
      {
        "project_idea" => state.dig("project", "idea"),
        "first_view" => selected_ref && selected_ref["first_view"],
        "must_have_first_view" => Array(intent["must_have_first_view"]),
        "selected_strategy_id" => selected_ref && selected_ref["strategy_id"]
      }.compact
    end

    def engine_run_opendesign_required_quality_fields
      {
        "viewport_matrix" => %w[desktop tablet mobile],
        "route_intent" => true,
        "first_viewport_composition" => true,
        "typography_scale" => true,
        "line_height_rules" => true,
        "spacing_grid" => true,
        "density_target" => true,
        "color_contrast_requirements" => true,
        "component_state_matrix" => %w[default hover focus-visible active disabled loading empty error success],
        "motion_transition_expectations" => true,
        "responsive_breakpoint_obligations" => true,
        "required_data_aiweb_id_hooks" => true,
        "no_copy_reference_constraints" => true
      }
    end

    def engine_run_token_requirements(design_file)
      path = design_file && File.join(root, design_file["path"].to_s)
      return [] unless path && File.file?(path)

      text = File.read(path, 128 * 1024)
      css_vars = text.scan(/--[a-z0-9-]+/i)
      rule_lines = text.lines.grep(/\b(?:token|typography|color|palette|spacing|radius|grid|breakpoint)\b/i).map(&:strip)
      (css_vars + rule_lines).reject(&:empty?).uniq.first(80)
    rescue SystemCallError
      []
    end

    def engine_run_reference_no_copy_rules(files)
      defaults = [
        "Use reference material as pattern evidence only.",
        "Do not copy exact reference UI, layouts, copy, prices, trademarks, signed image URLs, or brand-specific claims."
      ]
      rules = files.values_at("design_reference_brief", "selected_design").compact.flat_map do |file|
        path = File.join(root, file["path"].to_s)
        next [] unless File.file?(path)

        File.readlines(path, chomp: true).select { |line| line.match?(/\b(?:do not copy|copy risk|reference|trademark|price|exact)\b/i) }.map(&:strip)
      rescue SystemCallError
        []
      end
      (defaults + rules).reject(&:empty?).uniq.first(40)
    end

    def engine_run_reference_forbidden_terms(files)
      brief = files["design_reference_brief"]
      return [] unless brief

      path = File.join(root, brief["path"].to_s)
      return [] unless File.file?(path)

      text = File.read(path, 128 * 1024)
      company_terms = text.lines.grep(/\A\s*(?:companies|brands|references)\s*:/i).flat_map do |line|
        line.split(":", 2).last.to_s.split(/[,;]/).map(&:strip)
      end
      company_terms.map { |term| term.gsub(/[^A-Za-z0-9 ._-]/, "").strip }
                   .select { |term| term.match?(/[A-Za-z]/) && term.length >= 3 }
                   .uniq
                   .first(40)
    rescue SystemCallError
      []
    end

    def engine_run_capability_opendesign_contract(contract)
      return nil unless contract

      {
        "status" => contract["status"],
        "contract_hash" => contract["contract_hash"],
        "selected_candidate" => contract["selected_candidate"],
        "selected_candidate_path" => contract["selected_candidate_path"],
        "requires_selected_design" => contract["requires_selected_design"]
      }
    end

    def engine_run_checkpoint_opendesign_contract(contract)
      return nil unless contract

      {
        "status" => contract["status"],
        "contract_hash" => contract["contract_hash"],
        "selected_candidate" => contract["selected_candidate"],
        "selected_candidate_path" => contract["selected_candidate_path"]
      }
    end

    def engine_run_opendesign_events(events_path, events, contract, resume_context)
      if contract["status"] == "ready"
        engine_run_event(events_path, events, "design.contract.loaded", "loaded OpenDesign runtime contract", contract_hash: contract["contract_hash"], selected_candidate: contract["selected_candidate"])
      else
        engine_run_event(events_path, events, "design.contract.missing", "OpenDesign runtime contract is incomplete", blocking_issues: contract["blocking_issues"])
      end
      previous_hash = resume_context && resume_context.dig(:metadata, "opendesign_contract", "contract_hash")
      if previous_hash && previous_hash != contract["contract_hash"]
        engine_run_event(events_path, events, "design.contract.changed", "OpenDesign contract changed since resumed run", previous_contract_hash: previous_hash, current_contract_hash: contract["contract_hash"])
      end
    end

    def engine_run_planned_events
      %w[
        run.created
        goal.understood
        design.contract.loaded
        design.contract.missing
        design.contract.changed
        preflight.started
        preflight.finished
        project.indexed
        graph.scheduler.planned
        graph.scheduler.started
        graph.node.finished
        graph.scheduler.finished
        sandbox.preflight.started
        sandbox.preflight.finished
        plan.created
        step.started
        tool.requested
        policy.decision
        tool.started
        tool.finished
        tool.blocked
        tool.action.requested
        tool.action.blocked
        design.fidelity.checked
        artifact.created
        preview.started
        preview.ready
        preview.failed
        preview.stopped
        screenshot.capture.started
        screenshot.capture.finished
        screenshot.capture.failed
        browser.observation.recorded
        browser.action_recovery.recorded
        design.review.started
        design.review.finished
        design.review.failed
        design.fixture.recorded
        design.repair.planned
        design.repair.started
        design.repair.finished
        qa.failed
        repair.planned
        patch.generated
        approval.requested
        approval.granted
        checkpoint.saved
        run.resumed
        run.quarantined
        run.finished
      ]
    end

  end
end
