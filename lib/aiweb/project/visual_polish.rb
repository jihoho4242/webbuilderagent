# frozen_string_literal: true

module Aiweb
  module ProjectVisualPolish
    def visual_polish(from_critique: "latest", max_cycles: nil, dry_run: false, **_options)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        source_critique = resolve_visual_polish_critique_source(from_critique, state)
        critique = source_critique["path"] ? load_visual_polish_critique(source_critique["path"]) : nil
        validate_visual_polish_critique!(critique) if critique

        unless critique
          payload = visual_polish_blocked_payload(
            state: state,
            source_critique: source_critique["relative"],
            reason: source_critique["reason"] || "no visual critique available for visual polish",
            dry_run: dry_run
          )
          next
        end

        if visual_polish_critique_passed?(critique)
          payload = visual_polish_blocked_payload(
            state: state,
            source_critique: source_critique["relative"],
            reason: "visual critique already passed; visual-polish --repair only accepts repair, redesign, failed, or non-pass critique results",
            dry_run: dry_run,
            critique: critique,
            block_type: "pass"
          )
          next
        end

        cycle_limit = visual_polish_cycle_limit(max_cycles, state)
        cycles_used = visual_polish_cycles_used(source_critique["relative"])
        if cycles_used >= cycle_limit
          payload = visual_polish_blocked_payload(
            state: state,
            source_critique: source_critique["relative"],
            reason: "visual polish cycle budget cap reached for #{source_critique["relative"].inspect}: #{cycles_used}/#{cycle_limit}",
            dry_run: dry_run,
            critique: critique,
            cycles_used: cycles_used,
            max_cycles: cycle_limit,
            block_type: "budget"
          )
          next
        end

        timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
        polish_id = "polish-#{timestamp}-#{slug(critique["task_id"] || critique["id"] || "visual")}-cycle-#{cycles_used + 1}"
        snapshot_id = "pre-#{polish_id}"
        snapshot_dir = File.join(aiweb_dir, "snapshots", snapshot_id)
        task_path = visual_polish_task_path(critique)
        polish_record_path = File.join(aiweb_dir, "visual", "#{polish_id}.json")
        planned_changes = [relative(snapshot_dir), relative(File.join(snapshot_dir, "manifest.json")), relative(task_path), relative(polish_record_path), relative(state_path)]

        record = visual_polish_record(
          polish_id: polish_id,
          critique: critique,
          source_critique: source_critique["relative"],
          snapshot_dir: snapshot_dir,
          task_path: task_path,
          cycles_used: cycles_used,
          max_cycles: cycle_limit,
          dry_run: dry_run,
          polish_record_path: polish_record_path
        )

        if dry_run
          payload = visual_polish_payload(
            state: state,
            record: record,
            changed_files: [],
            planned_changes: planned_changes,
            action_taken: "planned visual polish repair loop",
            next_action: "rerun aiweb visual-polish --repair without --dry-run to create the pre-polish snapshot, task, and polish record"
          )
          next
        end

        changes << create_dir(snapshot_dir, false)
        copy_repair_snapshot_contents(snapshot_dir)
        snapshot_manifest = visual_polish_snapshot_manifest(snapshot_id, critique, source_critique["relative"], state)
        changes << write_json(File.join(snapshot_dir, "manifest.json"), snapshot_manifest, false)
        state["snapshots"] ||= []
        state["snapshots"] << snapshot_manifest.merge("path" => relative(snapshot_dir))

        unless File.exist?(task_path)
          changes << write_file(task_path, visual_polish_task_markdown(record, critique), false)
        end
        state["implementation"] ||= {}
        state["implementation"]["current_task"] = relative(task_path)

        changes << create_dir(File.dirname(polish_record_path), false)
        changes << write_json(polish_record_path, record, false)
        state["visual"] ||= {}
        state["visual"]["latest_polish"] = relative(polish_record_path)
        add_decision!(state, "visual_polish", "Created bounded visual polish repair loop #{polish_id} for #{source_critique["relative"]}")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)

        payload = visual_polish_payload(
          state: state,
          record: record,
          changed_files: compact_changes(changes),
          planned_changes: [],
          action_taken: "created visual polish repair loop #{polish_id}",
          next_action: "complete the local visual polish task in #{relative(task_path)}, then rerun visual critique manually"
        )
      end
      payload
    end

    private

    def resolve_visual_polish_critique_source(from_critique, state)
      requested = from_critique.to_s.strip
      requested = "latest" if requested.empty?
      if requested == "latest"
        latest = state.dig("visual", "latest_critique").to_s.strip
        latest = state.dig("qa", "latest_visual_critique").to_s.strip if latest.empty?
        latest = latest_visual_critique_artifact if latest.empty?
        return { "relative" => nil, "path" => nil, "reason" => "no .ai-web visual critique artifact is available" } if latest.to_s.empty?

        reject_visual_polish_env_path!(latest)
        path = File.expand_path(latest, root)
        return { "relative" => latest, "path" => nil, "reason" => "visual critique #{latest} is missing" } unless File.file?(path)

        return { "relative" => relative(path), "path" => path }
      end

      reject_visual_polish_env_path!(requested)
      path = File.expand_path(requested, root)
      unless File.file?(path)
        raise UserError.new("visual critique #{requested.inspect} does not exist", 1)
      end
      unless File.extname(path) == ".json"
        raise UserError.new("visual-polish --from-critique requires a visual critique JSON path", 1)
      end

      { "relative" => relative(path), "path" => path }
    end

    def latest_visual_critique_artifact
      Dir.glob(File.join(aiweb_dir, "visual", "visual-critique-*.json")).max_by { |path| File.mtime(path) }
    rescue SystemCallError
      nil
    end

    def reject_visual_polish_env_path!(path)
      reject_env_file_segment!(path, "visual-polish refuses to read .env or .env.* critique paths")
    end

    def load_visual_polish_critique(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise UserError.new("cannot parse visual critique JSON: #{e.message}", 1)
    rescue SystemCallError => e
      raise UserError.new("cannot read visual critique JSON: #{e.message}", 1)
    end

    def validate_visual_polish_critique!(critique)
      unless critique.is_a?(Hash)
        raise UserError.new("visual critique JSON must be an object", 1)
      end
      errors = []
      errors << "schema_version must be 1" unless critique["schema_version"] == 1
      errors << "type must be visual_critique" unless critique["type"].to_s == "visual_critique"
      errors << "id is required" if critique["id"].to_s.strip.empty?
      errors << "status is required" if critique["status"].to_s.strip.empty?
      errors << "approval is required" if critique["approval"].to_s.strip.empty?
      errors << "evidence must be an array" unless critique["evidence"].is_a?(Array)
      raise UserError.new("visual critique JSON is malformed: #{errors.join("; ")}", 1) unless errors.empty?

      true
    end

    def visual_polish_critique_passed?(critique)
      approval = critique["approval"].to_s.downcase
      status = critique["status"].to_s.downcase
      approval == "pass" || status == "pass" || status == "passed"
    end

    def visual_polish_cycle_limit(max_cycles, state)
      value = max_cycles.nil? || max_cycles.to_s.strip.empty? ? nil : max_cycles.to_i
      value ||= (state.dig("budget", "max_visual_polish_cycles") || state.dig("budget", "max_repair_cycles") || 3).to_i
      value.positive? ? value : 1
    end

    def visual_polish_cycles_used(source_critique)
      Dir.glob(File.join(aiweb_dir, "visual", "polish-*.json")).count do |path|
        data = JSON.parse(File.read(path))
        data["source_critique"].to_s == source_critique.to_s
      rescue JSON::ParserError, SystemCallError
        false
      end
    end

    def visual_polish_task_path(critique)
      source = critique["artifact"].to_s.strip
      source = critique["artifact_path"].to_s.strip if source.empty?
      source = critique["id"].to_s.strip if source.empty?
      digest = Digest::SHA256.hexdigest(source)[0, 12]
      File.join(aiweb_dir, "tasks", "visual-polish-#{digest}.md")
    end

    def visual_polish_snapshot_manifest(snapshot_id, critique, source_critique, state)
      {
        "id" => snapshot_id,
        "created_at" => now,
        "reason" => "pre-polish snapshot for visual critique #{critique["id"] || source_critique}",
        "phase" => state.dig("phase", "current"),
        "source_critique" => source_critique,
        "state_sha256" => File.exist?(state_path) ? Digest::SHA256.file(state_path).hexdigest : nil
      }
    end

    def visual_polish_record(polish_id:, critique:, source_critique:, snapshot_dir:, task_path:, cycles_used:, max_cycles:, dry_run:, polish_record_path:)
      {
        "schema_version" => 1,
        "type" => "visual_polish",
        "id" => polish_id,
        "status" => dry_run ? "planned" : "created",
        "dry_run" => dry_run,
        "created_at" => now,
        "source_critique" => source_critique,
        "polish_record" => relative(polish_record_path),
        "critique_id" => critique["id"],
        "critique_task_id" => critique["task_id"],
        "critique_status" => critique["status"],
        "critique_approval" => critique["approval"],
        "issues" => critique["issues"] || [],
        "patch_plan" => critique["patch_plan"] || [],
        "design_contract" => critique["design_contract"] || design_contract_context,
        "cycles_used_before" => cycles_used,
        "max_cycles" => max_cycles,
        "pre_polish_snapshot" => relative(snapshot_dir),
        "polish_task" => relative(task_path),
        "guardrails" => [
          "no .env read/write",
          "no exact reference/image/screenshot copying",
          "no source auto-patch",
          "no build execution",
          "no preview/browser/screenshot capture",
          "no QA execution",
          "no package install",
          "no deploy/external hosting",
          "no network/AI calls"
        ]
      }
    end

    def visual_polish_task_markdown(record, critique)
      source_targets = agent_run_default_source_targets
      source_target_lines = source_targets.empty? ? "- TODO: map critique to a safe source target before running agent-run." : source_targets.map { |path| "- `#{path}`" }.join("\n")
      machine_source_targets = source_targets.empty? ? "- TODO" : source_targets.map { |path| "- #{path}" }.join("\n")
      issues = Array(critique["issues"]).map { |issue| "- #{issue}" }.join("\n")
      issues = "- Review #{record["source_critique"]} for non-pass visual critique details." if issues.empty?
      patch_plan = Array(critique["patch_plan"]).map do |item|
        if item.is_a?(Hash)
          "- #{item["area"] || "visual"} (#{item["priority"] || "medium"}): #{item["action"]}"
        else
          "- #{item}"
        end
      end.join("\n")
      patch_plan = "- Make bounded local visual polish edits based on critique evidence." if patch_plan.empty?
      design_contract = visual_polish_design_contract_markdown(record["design_contract"] || critique["design_contract"] || {})

      <<~MD
        # Task Packet — visual-polish

        Task ID: #{record["id"]}
        Phase: visual-polish
        Source critique: #{record["source_critique"]}
        Pre-polish snapshot: #{record["pre_polish_snapshot"]}
        Created at: #{record["created_at"]}
        #{design_contract}

        ## Goal
        Repair or redesign the local visual issues identified by the source critique without expanding scope.

        ## Inputs
        - `.ai-web/state.yaml`
        - `.ai-web/DESIGN.md`
        - `.ai-web/component-map.json`
        - `#{record["source_critique"]}`
        #{source_target_lines}

        ## Issues
        #{issues}

        ## Patch Plan
        #{patch_plan}

        ## Guardrails
        - Do not edit `.env` or `.env.*`.
        - Do not copy exact reference screenshots, layouts, copy, prices, trademarks, or brand claims.
        - Do not run builds, previews, browsers, screenshot capture, package installs, deploys, network calls, or AI calls from the polish loop.
        - Keep source changes manual, reviewable, and verified outside this record-creation command.

        ## Constraints
        - Do not read `.env` or `.env.*`.
        - Patch only the allowed source paths listed below.
        - Keep source changes minimal and reversible.

        ## Machine Constraints
        shell_allowed: false
        network_allowed: false
        env_access_allowed: false
        requires_selected_design: true
        allowed_source_paths:
        #{machine_source_targets}

        ## Acceptance Criteria
        - Visual issues are addressed in local source by a human/agent in a separate implementation step.
        - Visual critique is rerun manually and linked in `.ai-web/visual/`.
      MD
    end

    def visual_polish_design_contract_markdown(contract)
      return "" unless contract.is_a?(Hash) && !contract.empty?

      lines = ["", "## Design Contract Context"]
      lines << "- DESIGN.md: #{contract["design_path"]}" if contract["design_path"]
      lines << "- Design SHA256: #{contract["design_sha256"]}" if contract["design_sha256"]
      lines << "- Reference brief: #{contract["reference_brief_path"]}" if contract["reference_brief_path"]
      lines << "- Selected candidate: #{contract["selected_candidate"]}" if contract["selected_candidate"]
      lines << "- Selected candidate path: #{contract["selected_candidate_path"]}" if contract["selected_candidate_path"]
      lines.join("\n")
    end

    def visual_polish_blocked_payload(state:, source_critique:, reason:, dry_run:, critique: nil, cycles_used: nil, max_cycles: nil, block_type: nil)
      polish_loop = {
        "schema_version" => 1,
        "status" => "blocked",
        "dry_run" => dry_run,
        "source_critique" => source_critique,
        "critique_id" => critique && critique["id"],
        "critique_status" => critique && critique["status"],
        "critique_approval" => critique && critique["approval"],
        "cycles_used" => cycles_used,
        "max_cycles" => max_cycles,
        "blocking_issues" => [reason],
        "block_type" => block_type,
        "planned_changes" => []
      }.compact

      status_hash(state: state, changed_files: []).merge(
        "action_taken" => "visual polish repair loop blocked",
        "changed_files" => [],
        "blocking_issues" => [reason],
        "visual_polish" => polish_loop,
        "next_action" => "record a repair, redesign, failed, or non-pass visual critique before running aiweb visual-polish --repair"
      )
    end

    def visual_polish_payload(state:, record:, changed_files:, planned_changes:, action_taken:, next_action:)
      payload = status_hash(state: state, changed_files: changed_files)
      payload["action_taken"] = action_taken
      polish_loop = record.merge(
        "planned_changes" => planned_changes,
        "changed_files" => changed_files
      )
      unless planned_changes.empty?
        polish_loop["planned_snapshot_path"] = record["pre_polish_snapshot"]
        polish_loop["planned_polish_record_path"] = record["polish_record"]
        polish_loop["planned_task_path"] = record["polish_task"]
        polish_loop["planned_polish_task_path"] = record["polish_task"]
      end
      payload["visual_polish"] = polish_loop
      payload["next_action"] = next_action
      payload
    end

  end
end
