# frozen_string_literal: true

module Aiweb
  module ProjectVisualCommands
    def component_map(force: false, dry_run: false)
      assert_initialized!

      state = load_state
      artifact_path = File.join(aiweb_dir, "component-map.json")
      components = discover_component_map_components
      blockers = component_map_blockers(components, force: force)
      status = blockers.empty? ? (dry_run ? "planned" : "ready") : "blocked"
      component_map = component_map_record(
        status: status,
        artifact_path: artifact_path,
        components: components,
        blockers: blockers,
        dry_run: dry_run
      )
      planned_changes = [relative(artifact_path)]

      if dry_run || !blockers.empty?
        return component_map_payload(
          state: state,
          component_map: component_map,
          changed_files: [],
          planned_changes: blockers.empty? ? planned_changes : [],
          action_taken: blockers.empty? ? "planned component map" : "component map blocked",
          blocking_issues: blockers,
          next_action: blockers.empty? ? "rerun aiweb component-map without --dry-run to write #{relative(artifact_path)}" : "run aiweb scaffold --profile D or restore source files with stable data-aiweb-id hooks, then rerun aiweb component-map"
        )
      end

      changes = []
      payload = nil
      mutation(dry_run: false) do
        changes << write_json(artifact_path, component_map, false)
        payload = component_map_payload(
          state: state,
          component_map: component_map,
          changed_files: compact_changes(changes),
          planned_changes: [],
          action_taken: "created component map",
          blocking_issues: [],
          next_action: "select a data-aiweb-id target, then run aiweb visual-edit --target DATA_AIWEB_ID --prompt TEXT"
        )
      end
      payload
    end

    def visual_edit(target:, prompt:, from_map: "latest", force: false, dry_run: false)
      assert_initialized!

      target = target.to_s.strip
      prompt = prompt.to_s.strip
      raise UserError.new("visual-edit requires --target DATA_AIWEB_ID", 1) if target.empty?
      raise UserError.new("visual-edit requires --prompt TEXT", 1) if prompt.empty?

      state = load_state
      source = resolve_component_map_source(from_map)
      component_map = source["path"] ? load_component_map_for_visual_edit(source["path"]) : nil
      components = component_map ? component_map_components(component_map, target) : []
      component = components.length == 1 ? components.first : nil
      blockers = visual_edit_blockers(source, component_map, component, target, components: components, force: force)

      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      edit_id = "visual-edit-#{timestamp}-#{slug(target)}"
      task_path = File.join(aiweb_dir, "tasks", "#{edit_id}.md")
      record_path = File.join(aiweb_dir, "visual", "#{edit_id}.json")
      record = visual_edit_record(
        edit_id: edit_id,
        target: target,
        prompt: prompt,
        source_map: source["relative"],
        component: component,
        task_path: task_path,
        record_path: record_path,
        status: blockers.empty? ? (dry_run ? "planned" : "created") : "blocked",
        blockers: blockers,
        dry_run: dry_run
      )
      planned_changes = [relative(task_path), relative(record_path)]

      if dry_run || !blockers.empty?
        return visual_edit_payload(
          state: state,
          record: record,
          changed_files: [],
          planned_changes: blockers.empty? ? planned_changes : [],
          action_taken: blockers.empty? ? "planned visual edit" : "visual edit blocked",
          blocking_issues: blockers,
          next_action: blockers.empty? ? "rerun aiweb visual-edit without --dry-run to create the local handoff artifacts" : "create a component map and choose an editable data-aiweb-id target, then rerun aiweb visual-edit"
        )
      end

      changes = []
      payload = nil
      mutation(dry_run: false) do
        changes << write_file(task_path, visual_edit_task_markdown(record), false)
        changes << write_json(record_path, record, false)
        payload = visual_edit_payload(
          state: state,
          record: record,
          changed_files: compact_changes(changes),
          planned_changes: [],
          action_taken: "created visual edit handoff",
          blocking_issues: [],
          next_action: "review #{relative(task_path)}; source patching and smoke QA are intentionally outside this command"
        )
      end
      payload
    end

    def visual_critique(paths: nil, evidence_paths: nil, screenshot: nil, screenshots: nil, from_screenshots: nil, metadata: nil, task_id: nil, dry_run: false, **_options)
      assert_initialized!
      evidence = visual_critique_evidence_paths(paths, evidence_paths, screenshot, [screenshots, from_screenshots], metadata)
      raise UserError.new("visual-critique requires at least one local evidence path", 1) if evidence.empty?

      evidence.each { |path| validate_visual_critique_input_path!(path) }

      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      critique_slug = slug(task_id)
      critique_id = ["visual-critique", timestamp, critique_slug].reject { |part| part.to_s.empty? }.join("-")
      artifact_path = File.join(aiweb_dir, "visual", "#{critique_id}.json")
      planned_changes = [relative(File.dirname(artifact_path)), relative(artifact_path), relative(state_path)]

      if dry_run
        state = load_state
        payload = visual_critique_payload(
          state: state,
          critique: visual_critique_record(
            critique_id: critique_id,
            task_id: task_id,
            evidence_paths: evidence,
            artifact_path: artifact_path,
            dry_run: true
          ),
          changed_files: [],
          planned_changes: planned_changes,
          action_taken: "planned visual critique",
          next_action: "rerun aiweb visual-critique without --dry-run to write #{relative(artifact_path)} and update project state"
        )
        return payload
      end

      changes = []
      payload = nil
      mutation(dry_run: false) do
        state = load_state
        critique = visual_critique_record(
          critique_id: critique_id,
          task_id: task_id,
          evidence_paths: evidence,
          artifact_path: artifact_path,
          dry_run: false
        )
        changes << write_json(artifact_path, critique, false)
        state["qa"] ||= {}
        state["qa"]["latest_visual_critique"] = relative(artifact_path)
        state["visual"] ||= {}
        state["visual"]["latest_critique"] = relative(artifact_path)
        add_decision!(state, "visual_critique", "Recorded visual critique #{critique["approval"]} at #{relative(artifact_path)}")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)
        payload = visual_critique_payload(
          state: state,
          critique: critique,
          changed_files: compact_changes(changes),
          planned_changes: [],
          action_taken: "recorded visual critique",
          next_action: visual_critique_next_action(critique)
        )
      end
      payload
    end

  end
end
