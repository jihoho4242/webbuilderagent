# frozen_string_literal: true

require_relative "visual_polish/artifacts"

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

  end
end
