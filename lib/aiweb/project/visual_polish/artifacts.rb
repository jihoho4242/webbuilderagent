# frozen_string_literal: true

module Aiweb
  module ProjectVisualPolish
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
