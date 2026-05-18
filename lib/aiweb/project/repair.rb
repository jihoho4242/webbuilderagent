# frozen_string_literal: true

module Aiweb
  module ProjectRepair
    def repair(from_qa: "latest", max_cycles: nil, force: false, dry_run: false)
      assert_initialized!
      changes = []
      payload = nil
      mutation(dry_run: dry_run) do
        state = load_state
        phase_guard!(state, "repair", %w[phase-7 phase-8 phase-9 phase-10 phase-11], force)
        source_result = resolve_repair_qa_source(from_qa, state)
        result = source_result["path"] ? load_repair_qa_result(source_result["path"]) : nil

        unless result
          payload = repair_blocked_payload(
            state: state,
            source_result: source_result["relative"],
            reason: source_result["reason"] || "no QA result available for repair",
            dry_run: dry_run
          )
          next
        end

        normalize_qa_result!(result, state)
        validate_qa_result!(result)
        failures = qa_failures_from_result(result, state, source_result["relative"])
        if failures.empty?
          payload = repair_blocked_payload(
            state: state,
            source_result: source_result["relative"],
            reason: "QA result has no blocking failed, blocked, or timed-out condition",
            dry_run: dry_run,
            qa_result: result
          )
          next
        end

        cycle_limit = repair_cycle_limit(max_cycles, state)
        cycles_used = repair_cycles_used(result["task_id"], source_result["relative"])
        if cycles_used >= cycle_limit
          payload = repair_blocked_payload(
            state: state,
            source_result: source_result["relative"],
            reason: "repair cycle budget cap reached for QA task #{result["task_id"].inspect}: #{cycles_used}/#{cycle_limit}",
            dry_run: dry_run,
            qa_result: result,
            cycles_used: cycles_used,
            max_cycles: cycle_limit,
            block_type: "budget"
          )
          next
        end

        timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
        primary_failure = failures.first
        repair_id = "repair-#{timestamp}-#{slug(result["task_id"])}-cycle-#{cycles_used + 1}"
        snapshot_id = "pre-#{repair_id}"
        snapshot_dir = File.join(aiweb_dir, "snapshots", snapshot_id)
        repair_record_path = File.join(aiweb_dir, "repairs", "#{repair_id}.json")
        fix_path = repair_fix_task_path(result, primary_failure)
        planned_changes = [relative(snapshot_dir), relative(File.join(snapshot_dir, "manifest.json")), relative(fix_path), relative(repair_record_path), relative(state_path)]

        record = repair_record(
          repair_id: repair_id,
          result: result,
          source_result: source_result["relative"],
          failures: failures,
          snapshot_dir: snapshot_dir,
          fix_path: fix_path,
          cycles_used: cycles_used,
          max_cycles: cycle_limit,
          dry_run: dry_run,
          repair_record_path: repair_record_path
        )

        if dry_run
          payload = repair_payload(
            state: state,
            record: record,
            changed_files: [],
            planned_changes: planned_changes,
            action_taken: "planned repair loop",
            next_action: "rerun aiweb repair without --dry-run to create the pre-repair snapshot, fix task, and repair record"
          )
          next
        end

        changes << create_dir(snapshot_dir, false)
        copy_repair_snapshot_contents(snapshot_dir)
        snapshot_manifest = repair_snapshot_manifest(snapshot_id, result, source_result["relative"], state)
        changes << write_json(File.join(snapshot_dir, "manifest.json"), snapshot_manifest, false)
        state["snapshots"] ||= []
        state["snapshots"] << snapshot_manifest.merge("path" => relative(snapshot_dir))

        state["qa"] ||= {}
        state["qa"]["open_failures"] ||= []
        merge_open_failures!(state, failures)

        unless File.exist?(fix_path)
          changes << write_file(fix_path, qa_fix_task_markdown(failures, result, state), false)
        end
        state["implementation"] ||= {}
        state["implementation"]["current_task"] = relative(fix_path)
        result["recommended_action"] = "repair_loop"
        result["created_fix_task"] ||= relative(fix_path)

        changes << create_dir(File.dirname(repair_record_path), false)
        changes << write_json(repair_record_path, record, false)
        add_decision!(state, "repair_loop", "Created bounded repair loop #{repair_id} for QA task #{result["task_id"]}")
        state["project"]["updated_at"] = now if state["project"].is_a?(Hash)
        changes << write_yaml(state_path, state, false)

        payload = repair_payload(
          state: state,
          record: record,
          changed_files: compact_changes(changes),
          planned_changes: [],
          action_taken: "created repair loop #{repair_id}",
          next_action: "complete the fix task in #{relative(fix_path)}, then rerun the relevant local QA command manually"
        )
      end
      payload
    end

    private

    def resolve_repair_qa_source(from_qa, state)
      requested = from_qa.to_s.strip
      requested = "latest" if requested.empty?
      if requested == "latest"
        latest = state.dig("qa", "last_result").to_s.strip
        return { "relative" => nil, "path" => nil, "reason" => "state.qa.last_result is empty" } if latest.empty?

        reject_env_path!(latest)
        path = File.expand_path(latest, root)
        return { "relative" => latest, "path" => nil, "reason" => "QA result #{latest} is missing" } unless File.file?(path)

        return { "relative" => latest, "path" => path }
      end

      reject_env_path!(requested)
      path = File.expand_path(requested, root)
      unless File.file?(path)
        raise UserError.new("QA result #{requested.inspect} does not exist", 1)
      end
      unless File.extname(path) == ".json"
        raise UserError.new("repair --from-qa requires a QA result JSON path", 1)
      end

      { "relative" => relative(path), "path" => path }
    end

    def reject_env_path!(path)
      reject_env_file_segment!(path, "refusing to read .env path for repair input")
    end


    def reject_env_file_segment!(path, message)
      raise UserError.new(message, 1) if env_file_segment?(path)
    end

    def env_file_segment?(path)
      path.to_s.split(/[\\\/]+/).any? { |part| part == ".env" || part.start_with?(".env.") }
    end

    def load_repair_qa_result(path)
      JSON.parse(File.read(path))
    rescue JSON::ParserError => e
      raise UserError.new("cannot parse QA result JSON: #{e.message}", 1)
    rescue SystemCallError => e
      raise UserError.new("cannot read QA result JSON: #{e.message}", 1)
    end

    def repair_cycle_limit(max_cycles, state)
      value = max_cycles.nil? || max_cycles.to_s.strip.empty? ? nil : max_cycles.to_i
      value ||= (state.dig("budget", "max_repair_cycles") || state.dig("budget", "max_qa_timeout_recovery_cycles") || 3).to_i
      value.positive? ? value : 1
    end

    def repair_cycles_used(task_id, source_result)
      Dir.glob(File.join(aiweb_dir, "repairs", "repair-*.json")).count do |path|
        data = JSON.parse(File.read(path))
        data["qa_task_id"].to_s == task_id.to_s && data["source_result"].to_s == source_result.to_s
      rescue JSON::ParserError, SystemCallError
        false
      end
    end

    def repair_fix_task_path(result, primary_failure)
      existing = result["created_fix_task"].to_s.strip
      path = if existing.empty?
        File.join(aiweb_dir, "tasks", "fix-#{primary_failure["id"]}.md")
      else
        reject_env_path!(existing)
        File.expand_path(existing, root)
      end
      ensure_repair_task_path!(path)
      path
    end

    def ensure_repair_task_path!(path)
      expanded = File.expand_path(path)
      tasks_dir = File.expand_path(File.join(aiweb_dir, "tasks"))
      return if expanded.start_with?(tasks_dir + File::SEPARATOR) && File.extname(expanded) == ".md"

      raise UserError.new("repair fix task must stay under .ai-web/tasks as markdown", 1)
    end

    def merge_open_failures!(state, failures)
      existing_ids = state["qa"]["open_failures"].map { |failure| failure["id"] }
      failures.each do |failure|
        next if existing_ids.include?(failure["id"])

        state["qa"]["open_failures"] << failure
      end
    end

    def repair_snapshot_manifest(snapshot_id, result, source_result, state)
      {
        "id" => snapshot_id,
        "created_at" => now,
        "reason" => "pre-repair snapshot for QA task #{result["task_id"]}",
        "phase" => state.dig("phase", "current"),
        "source_result" => source_result,
        "state_sha256" => File.exist?(state_path) ? Digest::SHA256.file(state_path).hexdigest : nil
      }
    end

    def copy_repair_snapshot_contents(snapshot_dir)
      Dir.children(aiweb_dir).each do |entry|
        next if entry == "snapshots" || entry == ".lock"
        next if entry == ".env" || entry.start_with?(".env.")

        src = File.join(aiweb_dir, entry)
        dest = File.join(snapshot_dir, entry)
        if File.directory?(src)
          FileUtils.cp_r(src, dest, remove_destination: true)
        else
          FileUtils.cp(src, dest)
        end
      end
    end

    def repair_record(repair_id:, result:, source_result:, failures:, snapshot_dir:, fix_path:, cycles_used:, max_cycles:, dry_run:, repair_record_path:)
      {
        "schema_version" => 1,
        "id" => repair_id,
        "status" => dry_run ? "planned" : "created",
        "dry_run" => dry_run,
        "created_at" => now,
        "source_result" => source_result,
        "repair_record" => relative(repair_record_path),
        "qa_task_id" => result["task_id"],
        "qa_status" => result["status"],
        "timed_out" => result["timed_out"] == true,
        "failures" => failures,
        "cycles_used_before" => cycles_used,
        "max_cycles" => max_cycles,
        "pre_repair_snapshot" => relative(snapshot_dir),
        "fix_task" => relative(fix_path),
        "guardrails" => [
          "no .env read/write",
          "no source auto-patch",
          "no build execution",
          "no QA execution",
          "no install/preview/deploy/external hosting",
          "no visual polish/edit/backend/GitHub/deploy work"
        ]
      }
    end

    def repair_blocked_payload(state:, source_result:, reason:, dry_run:, qa_result: nil, cycles_used: nil, max_cycles: nil, block_type: nil)
      repair_loop = {
        "schema_version" => 1,
        "status" => "blocked",
        "dry_run" => dry_run,
        "source_result" => source_result,
        "qa_task_id" => qa_result && qa_result["task_id"],
        "qa_status" => qa_result && qa_result["status"],
        "cycles_used" => cycles_used,
        "max_cycles" => max_cycles,
        "blocking_issues" => [reason],
        "block_type" => block_type,
        "planned_changes" => []
      }.compact

      status_hash(state: state, changed_files: []).merge(
        "action_taken" => "repair loop blocked",
        "changed_files" => [],
        "blocking_issues" => [reason],
        "repair_loop" => repair_loop,
        "next_action" => "record a failed or blocked QA result before running aiweb repair"
      )
    end

    def repair_payload(state:, record:, changed_files:, planned_changes:, action_taken:, next_action:)
      payload = status_hash(state: state, changed_files: changed_files)
      payload["action_taken"] = action_taken
      repair_loop = record.merge(
        "planned_changes" => planned_changes,
        "changed_files" => changed_files
      )
      unless planned_changes.empty?
        repair_loop["planned_snapshot_path"] = record["pre_repair_snapshot"]
        repair_loop["planned_repair_record_path"] = record["repair_record"]
        repair_loop["planned_fix_task_path"] = record["fix_task"]
      end
      payload["repair_loop"] = repair_loop
      payload["next_action"] = next_action
      payload
    end

  end
end
