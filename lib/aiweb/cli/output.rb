# frozen_string_literal: true

module Aiweb
  class CLI
    module Output
      private

    def help_payload
      base_payload("help", HelpText::TEXT)
    end

    def base_payload(action, message)
      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => action,
        "changed_files" => [],
        "blocking_issues" => [],
        "missing_artifacts" => [],
        "next_action" => message
      }
    end

    def emit_result(result)
      if @json
        puts JSON.pretty_generate(json_safe_value(result))
      else
        puts human_result(result)
      end
    end

    def emit_error(message, code)
      payload = {
        "schema_version" => 1,
        "status" => "error",
        "error" => { "code" => code, "message" => message },
        "blocking_issues" => [message],
        "next_action" => "fix the reported issue and rerun the command"
      }
      if @json
        puts JSON.pretty_generate(json_safe_value(payload))
      else
        warn "Error: #{message}"
        warn "Next command: #{payload["next_action"]}"
      end
      code
    end

    def json_safe_value(value)
      Aiweb::JsonSafety.safe_value(value)
    end

    def json_safe_string(value)
      Aiweb::JsonSafety.safe_string(value)
    end

    def human_result(result)
      return human_registry_result(result) if result["registry"]
      return human_intent_result(result) if result["intent"]
      return human_runtime_plan_result(result) if result["runtime_plan"]
      return human_verify_loop_result(result) if result["verify_loop"]
      return human_engine_scheduler_result(result) if result["engine_scheduler"]
      return human_mcp_broker_result(result) if result["mcp_broker"]
      return human_agent_runtime_result(result) if result["agent_runtime"]
      return human_agent_run_result(result) if result["agent_run"]
      return human_eval_baseline_result(result) if result["eval_baseline"]
      return human_repair_result(result) if result["repair_loop"]
      return human_qa_screenshot_result(result) if result["screenshot_qa"]
      return human_visual_critique_result(result) if result["visual_critique"]
      return human_visual_polish_result(result) if result["visual_polish"]
      return human_workbench_result(result) if result["workbench"]
      return human_component_map_result(result) if result["component_map"]
      return human_visual_edit_result(result) if result["visual_edit"]
      return human_supabase_local_verify_result(result) if result["supabase_local_verify"]
      return human_supabase_secret_qa_result(result) if result["supabase_secret_qa"]
      return human_setup_result(result) if result["setup"]
      return human_run_timeline_result(result) if result["run_timeline"]
      return human_observability_summary_result(result) if result["observability_summary"]
      return human_run_lifecycle_result(result) if result["run_lifecycle"]

      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = result["blocking_issues"] || []
      [
        "Current phase: #{result["current_phase"] || "n/a"}",
        "Action taken: #{result["action_taken"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_engine_scheduler_result(result)
      scheduler = result.fetch("engine_scheduler")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = scheduler["blocking_issues"] || result["blocking_issues"] || []
      [
        "Engine scheduler: #{scheduler["status"] || "n/a"}",
        "Decision: #{scheduler["decision"] || "n/a"}",
        "Run: #{scheduler["selected_run_id"] || "none"}",
        "Start node: #{scheduler["derived_start_node_id"] || "none"}",
        ("Daemon: #{scheduler["daemon_driver"]} ticks=#{scheduler["tick_count"]} stop=#{scheduler["stop_reason"]}" if scheduler["daemon_driver"]),
        ("Supervisor: #{scheduler["supervisor_driver"]} install=#{scheduler["install_status"] || "n/a"}" if scheduler["supervisor_driver"]),
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].compact.join("\n")
    end

    def human_mcp_broker_result(result)
      broker = result.fetch("mcp_broker")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = broker["blocking_issues"] || result["blocking_issues"] || []
      [
        "MCP broker: #{broker["status"] || "n/a"}",
        "Server/tool: #{broker["server"] || "n/a"}/#{broker["tool"] || "n/a"}",
        "Broker: #{broker["broker_driver"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_run_lifecycle_result(result)
      lifecycle = result.fetch("run_lifecycle")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = lifecycle["blocking_issues"] || result["blocking_issues"] || []
      active = lifecycle["active_run"]
      selected = lifecycle["selected_run"]
      [
        "Run lifecycle: #{lifecycle["status"] || "n/a"}",
        "Active run: #{active ? "#{active["run_id"]} (#{active["kind"] || "unknown"})" : "none"}",
        "Selected run: #{selected ? "#{selected["run_id"]} (#{selected["kind"] || "unknown"})" : "none"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_run_timeline_result(result)
      timeline = result.fetch("run_timeline")
      runs = Array(timeline["runs"])
      blockers = timeline["blocking_issues"] || result["blocking_issues"] || []
      [
        "Run timeline: #{timeline["status"] || "n/a"}",
        "Limit: #{timeline["limit"] || "n/a"}",
        "Runs: #{runs.length}",
        "Latest: #{runs.last ? runs.last["path"] : "none"}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_observability_summary_result(result)
      summary = result.fetch("observability_summary")
      blockers = summary["blocking_issues"] || result["blocking_issues"] || []
      counts = summary["recent_status_counts"].is_a?(Hash) ? summary["recent_status_counts"].map { |k, v| "#{k}=#{v}" }.join(", ") : "none"
      [
        "Observability: #{summary["status"] || "n/a"}",
        "Active run: #{summary["active_run"] ? summary["active_run"]["run_id"] : "none"}",
        "Recent runs: #{summary["recent_run_count"] || 0}",
        "Status counts: #{counts.empty? ? "none" : counts}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

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

    def human_runtime_plan_result(result)
      plan = result.fetch("runtime_plan")
      blockers = plan.fetch("blockers", [])
      lines = [
        "Runtime readiness: #{plan.fetch("readiness")}",
        "Scaffold: profile=#{plan.dig("scaffold", "profile") || "n/a"} framework=#{plan.dig("scaffold", "framework") || "n/a"} package_manager=#{plan.dig("scaffold", "package_manager") || "n/a"}",
        "Commands: dev=#{plan.dig("scaffold", "dev_command") || "n/a"} build=#{plan.dig("scaffold", "build_command") || "n/a"}",
        "Selected design: #{plan.dig("design", "selected_candidate") || "none"}",
        "Missing files: #{plan.fetch("missing_required_scaffold_files").empty? ? "none" : plan.fetch("missing_required_scaffold_files").join(", ")}",
        "Blockers: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ]
      lines.join("\n")
    end

    def human_agent_run_result(result)
      agent_run = result.fetch("agent_run")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = agent_run["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[run_dir stdout_path stderr_path metadata_path diff_path planned_run_dir planned_stdout_path planned_stderr_path planned_metadata_path planned_diff_path].each do |key|
        value = agent_run[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Agent run: #{agent_run["status"] || "n/a"}",
        "Task: #{agent_run["task"] || "n/a"}",
        "Agent: #{agent_run["agent"] || "n/a"}",
        "Dry run: #{agent_run.key?("dry_run") ? agent_run["dry_run"] : "n/a"}",
        "Approved: #{agent_run.key?("approved") ? agent_run["approved"] : "n/a"}",
        "Command: #{agent_run["command"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Agent run paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_agent_runtime_result(result)
      runtime = result.fetch("agent_runtime")
      session = runtime["agent_session"] || result["agent_session"] || {}
      artifacts = runtime["artifacts"] || {}
      blockers = runtime["blocking_issues"] || result["blocking_issues"] || []
      steps = Array(runtime["steps"]).map { |step| step["tool"] || step["name"] }.compact
      tool_statuses = Array(runtime["toolResults"]).map { |tool| "#{tool["tool"]}=#{tool["status"]}" }
      [
        "Agent runtime: #{runtime["status"] || "n/a"}",
        "Goal: #{session["goal"] || "n/a"}",
        "Mode/profile/approved: #{runtime["mode"] || session["mode"] || "n/a"}/#{runtime["profile"] || session["profile"] || "n/a"}/#{session.key?("approved") ? session["approved"] : "n/a"}",
        "Planned tools: #{steps.empty? ? "none" : steps.join(", ")}",
        "Tool results: #{tool_statuses.empty? ? "none" : tool_statuses.join(", ")}",
        "Browser QA: #{runtime.dig("browserQa", "status") || "n/a"}",
        "Patch manifest: #{runtime.dig("patchManifest", "verifier_decision") || "n/a"}",
        "Run dir: #{artifacts["run_dir"] || session.dig("artifact_paths", "run_dir") || "n/a"}",
        "Final report: #{artifacts["final_report"] || session.dig("artifact_paths", "final_report") || "n/a"}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_eval_baseline_result(result)
      baseline = result.fetch("eval_baseline")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = baseline["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[source_path target_path validation_path review_pack_path planned_target_path planned_validation_path planned_review_pack_path candidate_path].each do |key|
        value = baseline[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Eval baseline: #{baseline["status"] || "n/a"}",
        "Action: #{baseline["action"] || "n/a"}",
        "Dry run: #{baseline.key?("dry_run") ? baseline["dry_run"] : "n/a"}",
        "Approved: #{baseline.key?("approved") ? baseline["approved"] : "n/a"}",
        "Fixtures checked: #{baseline["fixture_count"] || 0}",
        "Calibrated fixtures: #{baseline["calibrated_fixture_count"] || 0}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_verify_loop_result(result)
      loop = result.fetch("verify_loop")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = loop["blocking_issues"] || result["blocking_issues"] || []
      steps = Array(loop["planned_steps"]).empty? ? Array(loop["cycles"]).flat_map { |cycle| Array(cycle["steps"]).map { |step| step["name"] } }.uniq : Array(loop["planned_steps"]).flat_map { |cycle| cycle["steps"] }.uniq
      [
        "Verify loop: #{loop["status"] || "n/a"}",
        "Max cycles: #{loop["max_cycles"] || "n/a"}",
        "Cycles run: #{loop["cycle_count"] || 0}",
        "Dry run: #{loop.key?("dry_run") ? loop["dry_run"] : "n/a"}",
        "Approved: #{loop.key?("approved") ? loop["approved"] : "n/a"}",
        "Metadata: #{loop["metadata_path"] || "n/a"}",
        "Run dir: #{loop["run_dir"] || "n/a"}",
        "Steps: #{steps.empty? ? "none" : steps.join(", ")}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_registry_result(result)
      registry_payload = result.fetch("registry")
      items = registry_payload.fetch("items")
      lines = ["#{registry_payload.fetch("label")} (#{registry_payload.fetch("count")})"]
      unless registry_payload.fetch("exists")
        lines << "Directory not found: #{registry_payload.fetch("directory")}/"
      end
      if items.empty?
        lines << "No #{registry_payload.fetch("singular")} entries found."
      else
        items.each do |item|
          description = item["description"].to_s.empty? ? "" : " — #{item["description"]}"
          lines << "- #{item["id"]}: #{item["title"]} (#{item["path"]})#{description}"
        end
      end
      validation_errors = result["validation_errors"] || []
      warnings = result["warnings"] || []
      lines << "Validation errors: #{validation_errors.join("; ")}" unless validation_errors.empty?
      lines << "Warnings: #{warnings.join("; ")}" unless warnings.empty?
      lines.join("\n")
    end
    end
  end
end
