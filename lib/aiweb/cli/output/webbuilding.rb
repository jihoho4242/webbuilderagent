# frozen_string_literal: true

module Aiweb
  class CLI
    module Output
      private

    def human_intent_result(result)
      intent = result.fetch("intent")
      lines = [
        "Intent route",
        "- Archetype: #{intent.fetch("archetype")}",
        "- Surface: #{intent.fetch("surface")}",
        "- Recommended skill: #{intent.fetch("recommended_skill")}",
        "- Recommended design system: #{intent.fetch("recommended_design_system")}",
        "- Recommended profile: #{intent.fetch("recommended_profile")}",
        "- Framework: #{intent.fetch("framework")}",
        "- Safety sensitive: #{intent.fetch("safety_sensitive")}",
        "- Style keywords: #{intent.fetch("style_keywords").join(", ")}",
        "- Forbidden design patterns: #{intent.fetch("forbidden_design_patterns").join("; ")}"
      ]
      lines.join("\n")
    end

    def human_supabase_secret_qa_result(result)
      qa = result.fetch("supabase_secret_qa")
      blockers = qa["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[artifact_path planned_artifact_path].each do |key|
        value = qa[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Supabase secret QA: #{qa["status"] || "n/a"}",
        "Dry run: #{qa.key?("dry_run") ? qa["dry_run"] : "n/a"}",
        "Read .env: #{qa.key?("read_dot_env") ? qa["read_dot_env"] : false}",
        "Scanned paths: #{Array(qa["scanned_paths"]).empty? ? "none" : Array(qa["scanned_paths"]).join(", ")}",
        "Artifacts: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_supabase_local_verify_result(result)
      verify = result.fetch("supabase_local_verify")
      blockers = verify["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[artifact_path planned_artifact_path].each do |key|
        value = verify[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Supabase local verify: #{verify["status"] || "n/a"}",
        "Dry run: #{verify.key?("dry_run") ? verify["dry_run"] : "n/a"}",
        "Read .env: #{verify.key?("read_dot_env") ? verify["read_dot_env"] : false}",
        "External actions performed: #{verify.key?("external_actions_performed") ? verify["external_actions_performed"] : false}",
        "Scanned paths: #{Array(verify["scanned_paths"]).empty? ? "none" : Array(verify["scanned_paths"]).join(", ")}",
        "Artifacts: #{paths.empty? ? "none" : paths.join(", ")}",
        "Findings: #{Array(verify["findings"]).empty? ? "none" : Array(verify["findings"]).map { |finding| finding["message"] || finding.to_s }.join("; ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_setup_result(result)
      setup = result.fetch("setup")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = setup["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[run_dir stdout_path stderr_path metadata_path setup_json_path planned_run_dir planned_stdout_path planned_stderr_path planned_metadata_path planned_setup_json_path].each do |key|
        value = setup[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Setup install: #{setup["status"] || "n/a"}",
        "Package manager: #{setup["package_manager"] || "n/a"}",
        "Dry run: #{setup.key?("dry_run") ? setup["dry_run"] : "n/a"}",
        "Approved: #{setup.key?("approved") ? setup["approved"] : "n/a"}",
        "Command: #{setup["command"] || setup["planned_command"] || "n/a"}",
        "Lifecycle scripts: #{Array(setup["lifecycle_scripts"] || setup["lifecycle_script_warnings"]).empty? ? "none" : Array(setup["lifecycle_scripts"] || setup["lifecycle_script_warnings"]).join(", ")}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Setup paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_qa_screenshot_result(result)
      qa = result.fetch("screenshot_qa")
      blockers = qa["blocking_issues"] || result["blocking_issues"] || []
      screenshots = qa["screenshots"] || qa["screenshot_paths"] || []
      artifacts = []
      %w[metadata_path result_path run_dir stdout_log stderr_log].each do |key|
        value = qa[key]
        artifacts << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Screenshot QA: #{qa["status"] || "n/a"}",
        "Target URL: #{qa["url"] || qa.dig("target", "url") || "n/a"}",
        "Screenshots: #{Array(screenshots).empty? ? "none" : Array(screenshots).join(", ")}",
        "Artifacts: #{artifacts.empty? ? "none" : artifacts.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_visual_critique_result(result)
      critique = result.fetch("visual_critique")
      scores = critique["scores"] || {}
      score_line = if scores.empty?
        "Scores: n/a"
      else
        ordered = %w[first_impression hierarchy typography layout_rhythm spacing color originality mobile_polish brand_fit intent_fit content_credibility interaction_clarity]
        "Scores: " + ordered.select { |key| scores.key?(key) }.map { |key| "#{key}=#{scores[key]}" }.join(", ")
      end
      issues = critique["issues"] || []
      plan = critique["patch_plan"] || []
      paths = []
      %w[artifact_path planned_artifact_path screenshot metadata].each do |key|
        value = critique[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Visual critique: #{critique["status"] || "n/a"}",
        "Approval: #{critique["approval"] || "n/a"}",
        score_line,
        "Evidence: #{paths.empty? ? "none" : paths.join(", ")}",
        "Issues: #{issues.empty? ? "none" : issues.join("; ")}",
        "Patch plan: #{plan.empty? ? "none" : plan.join("; ")}",
        "Blocking issues: #{(result["blocking_issues"] || critique["blocking_issues"] || []).empty? ? "none" : (result["blocking_issues"] || critique["blocking_issues"]).join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_visual_polish_result(result)
      polish = result.fetch("visual_polish")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = polish["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[polish_record_path visual_polish_record_path record_path snapshot_path pre_polish_snapshot polish_task_path task_path planned_polish_record_path planned_visual_polish_record_path planned_record_path planned_snapshot_path planned_polish_task_path planned_task_path].each do |key|
        value = polish[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Visual polish: #{polish["status"] || "n/a"}",
        "Mode: #{polish["mode"] || (polish["repair"] ? "repair" : "n/a")}",
        "Critique source: #{polish["critique_source"] || polish["from_critique"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Polish paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_workbench_result(result)
      workbench = result.fetch("workbench")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = workbench["blocking_issues"] || result["blocking_issues"] || []
      panels = Array(workbench["panels"])
      controls = Array(workbench["controls"])
      paths = []
      %w[index_path manifest_path planned_index_path planned_manifest_path].each do |key|
        value = workbench[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      if workbench["paths"].is_a?(Hash)
        workbench["paths"].each do |key, value|
          paths << "#{key}=#{value}" unless value.to_s.empty?
        end
      end
      serve = workbench["serve"].is_a?(Hash) ? workbench["serve"] : {}
      [
        "Workbench status: #{workbench["status"] || "n/a"}",
        "Dry run: #{workbench.key?("dry_run") ? workbench["dry_run"] : "n/a"}",
        "Serve URL: #{serve["url"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Workbench paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Panels: #{panels.empty? ? "none" : panels.join(", ")}",
        "Controls: #{controls.empty? ? "none" : controls.map { |control| control.is_a?(Hash) ? control["command"] || control["id"] : control }.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_component_map_result(result)
      map = result.fetch("component_map")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = map["blocking_issues"] || result["blocking_issues"] || []
      path = map["artifact_path"] || map["planned_artifact_path"] || result["artifact_path"]
      components = Array(map["components"])
      [
        "Component map: #{map["status"] || "n/a"}",
        "Dry run: #{map.key?("dry_run") ? map["dry_run"] : "n/a"}",
        "Artifact: #{path || "n/a"}",
        "Components: #{components.length}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_visual_edit_result(result)
      edit = result.fetch("visual_edit")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = edit["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[task_path record_path planned_task_path planned_record_path visual_edit_record_path planned_visual_edit_record_path].each do |key|
        value = edit[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Visual edit: #{edit["status"] || "n/a"}",
        "Target: #{edit["target"] || edit.dig("target_mapping", "data_aiweb_id") || "n/a"}",
        "Map source: #{edit["map_source"] || edit["from_map"] || "latest"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Visual edit paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_repair_result(result)
      loop = result.fetch("repair_loop")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = loop["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[repair_record_path snapshot_path fix_task_path planned_repair_record_path planned_snapshot_path planned_fix_task_path].each do |key|
        value = loop[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Repair loop: #{loop["status"] || "n/a"}",
        "QA source: #{loop["qa_source"] || loop["from_qa"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Repair paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end
    end
  end
end
