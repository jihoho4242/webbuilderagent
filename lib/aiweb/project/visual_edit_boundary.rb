# frozen_string_literal: true

module Aiweb
  class Project
    private

    def visual_edit_blockers(source, component_map, component, target, components:, force:)
      blockers = []
      blockers << source["error"] if source["error"]
      return blockers unless source["error"].nil?

      blockers << "component map not found: #{source["relative"]}" unless component_map
      blockers << "target data-aiweb-id not found in component map: #{target}" if component_map && components.empty?
      blockers << "target data-aiweb-id is ambiguous in component map: #{target}" if component_map && components.length > 1
      blockers << "target data-aiweb-id is not editable: #{target}" if component && component["editable"] == false
      if component
        source_path = agent_run_normalized_relative_path(component["source_path"])
        if source_path.empty?
          blockers << "target component source path is missing for data-aiweb-id: #{target}"
        elsif !agent_run_source_path_allowed?(source_path)
          blockers << "target component source path is unsafe or not editable: #{source_path}"
        end
      end
      blockers
    end

    def visual_edit_record(edit_id:, target:, prompt:, source_map:, component:, task_path:, record_path:, status:, blockers:, dry_run:)
      record = {
        "schema_version" => 1,
        "id" => edit_id,
        "status" => status,
        "created_at" => dry_run ? nil : now,
        "dry_run" => dry_run,
        "source_map" => source_map,
        "target" => {
          "data_aiweb_id" => target,
          "source_path" => component && component["source_path"],
          "line" => component && component["line"],
          "kind" => component && component["kind"],
          "route" => component && component["route"],
          "editable" => component ? component["editable"] : nil
        },
        "target_allowlist" => visual_edit_target_allowlist(target, source_map, component),
        "prompt_summary" => visual_edit_prompt_summary(prompt),
        "prompt_sha256" => Digest::SHA256.hexdigest(prompt),
        "guardrails" => [
          "Target only the selected region identified by data-aiweb-id.",
          "Strict source allowlist: patch only the mapped target source path.",
          "Do not regenerate the full page or unrelated components.",
          "No source auto-patch from this visual-edit command.",
          "Run smoke QA before any later source edit is accepted.",
          "Do not read or include .env or .env.* contents."
        ],
        "task_path" => relative(task_path),
        "record_path" => relative(record_path),
        "blocking_issues" => blockers
      }
      if dry_run
        record["planned_task_path"] = record["task_path"]
        record["planned_record_path"] = record["record_path"]
      end
      record
    end

    def visual_edit_target_allowlist(target, source_map, component)
      source_paths = [component && component["source_path"]].compact.map { |path| agent_run_normalized_relative_path(path) }.reject(&:empty?)
      {
        "type" => "visual_edit_target_allowlist",
        "strict" => true,
        "data_aiweb_ids" => [target],
        "source_paths" => source_paths,
        "component_map_path" => source_map,
        "selected_component" => component ? {
          "data_aiweb_id" => target,
          "source_path" => component["source_path"],
          "line" => component["line"],
          "kind" => component["kind"],
          "route" => component["route"],
          "editable" => component["editable"]
        } : nil,
        "full_page_regeneration_allowed" => false
      }
    end

    def visual_edit_prompt_summary(prompt)
      normalized = prompt.gsub(/\s+/, " ").strip
      normalized.length > 160 ? "#{normalized[0, 157]}..." : normalized
    end

    def visual_edit_payload(state:, record:, changed_files:, planned_changes:, action_taken:, blocking_issues:, next_action:)
      payload = status_hash(state: state, changed_files: changed_files)
      payload["action_taken"] = action_taken
      payload["blocking_issues"] = blocking_issues
      payload["planned_changes"] = planned_changes unless planned_changes.empty?
      payload["visual_edit"] = record
      payload["next_action"] = next_action
      payload
    end

    def visual_edit_task_markdown(record)
      target = record.fetch("target")
      <<~MD
        # Task Packet — visual-edit

        Task ID: #{record.fetch("id")}
        Status: planned

        ## Goal
        Apply the requested visual edit only to the mapped target region.

        ## Inputs
        - `.ai-web/state.yaml`
        - `.ai-web/DESIGN.md`
        - `.ai-web/component-map.json`
        - `#{target["source_path"]}`

        ## Constraints
        - Do not read `.env` or `.env.*`.
        - Patch only the strict target source allowlist below.
        - Do not regenerate the full page or unrelated components.

        ## Machine Constraints
        shell_allowed: false
        network_allowed: false
        env_access_allowed: false
        requires_selected_design: true
        allowed_source_paths:
        - #{target["source_path"]}

        ## Target
        - data-aiweb-id: `#{target["data_aiweb_id"]}`
        - source: `#{target["source_path"]}`#{target["line"] ? ":#{target["line"]}" : ""}
        - route: `#{target["route"] || "unknown"}`
        - component map: `#{record["source_map"]}`

        ## Requested change
        #{record["prompt_summary"]}

        ## Guardrails
        #{record.fetch("guardrails").map { |guardrail| "- #{guardrail}" }.join("\n")}

        ## Target Source Allowlist
        Patch only these strict source paths and data-aiweb-id targets. Do not regenerate the full page or unrelated components.

        ```json
        #{JSON.pretty_generate(record.fetch("target_allowlist"))}
        ```

        ## Next step
        A later implementation pass may patch only this mapped source region after smoke QA evidence is available. This command intentionally created a handoff record only.
      MD
    end

  end
end
