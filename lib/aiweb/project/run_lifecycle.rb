# frozen_string_literal: true

require "fileutils"
require "json"
require "shellwords"

module Aiweb
  module ProjectRunLifecycle
    def run_status(run_id: nil)
      assert_initialized!
      state = load_state
      lifecycle = run_lifecycle_status(run_id: run_id)
      payload = status_hash(state: state, changed_files: [])
      payload["action_taken"] = "reported run lifecycle"
      payload["run_lifecycle"] = lifecycle
      payload["next_action"] = lifecycle["active_run"] ? "inspect the active run or request cancellation with aiweb run-cancel --run-id active" : "start a local run such as aiweb verify-loop --max-cycles 3 --dry-run"
      payload
    end

    def run_timeline(limit: 20)
      assert_initialized!
      state = load_state
      bounded_limit = bounded_observability_limit(limit)
      timeline = workbench_run_timeline(bounded_limit)
      payload = status_hash(state: state, changed_files: [])
      payload["action_taken"] = "reported run timeline"
      payload["run_timeline"] = {
        "schema_version" => 1,
        "status" => timeline.empty? ? "empty" : "ready",
        "generated_at" => now,
        "limit" => bounded_limit,
        "active_run" => read_active_run_lock,
        "active_run_live" => active_run_live?(read_active_run_lock),
        "runs" => timeline,
        "blocking_issues" => []
      }
      payload["next_action"] = timeline.empty? ? "run a local command that records .ai-web/runs evidence, then rerun aiweb run-timeline" : "inspect the timeline entries or run aiweb observability-summary for a compact status rollup"
      payload
    end

    def observability_summary(limit: 20)
      assert_initialized!
      state = load_state
      bounded_limit = bounded_observability_limit(limit)
      timeline = workbench_run_timeline(bounded_limit)
      active = read_active_run_lock
      latest_deploy_path = state.dig("deploy", "latest_deploy")
      latest_deploy = latest_deploy_path && !unsafe_env_path?(latest_deploy_path) ? workbench_json_summary(latest_deploy_path, allow_runs: true) : nil
      statuses = timeline.map { |entry| entry["status"].to_s.empty? ? "unknown" : entry["status"].to_s }
      recent_blockers = timeline.flat_map { |entry| Array(entry["blocking_issues"]) }.compact.map(&:to_s).reject(&:empty?).first(10)
      summary = {
        "schema_version" => 1,
        "status" => active_run_live?(active) ? "running" : (timeline.empty? ? "empty" : "ready"),
        "generated_at" => now,
        "limit" => bounded_limit,
        "active_run" => active,
        "active_run_live" => active_run_live?(active),
        "latest_verify_loop" => workbench_verify_loop_status(state),
        "latest_deploy" => latest_deploy,
        "recent_run_count" => timeline.length,
        "recent_status_counts" => statuses.each_with_object(Hash.new(0)) { |status, memo| memo[status] += 1 },
        "recent_blockers" => recent_blockers,
        "recent_runs" => timeline,
        "blocking_issues" => []
      }
      payload = status_hash(state: state, changed_files: [])
      payload["action_taken"] = "reported observability summary"
      payload["observability_summary"] = summary
      payload["next_action"] = active ? "inspect active run with aiweb run-status --run-id active or request cancellation with aiweb run-cancel --run-id active" : "continue with aiweb verify-loop --max-cycles 3 --dry-run or inspect aiweb run-timeline"
      payload
    end

    def run_cancel(run_id: "active", dry_run: false, force: false)
      assert_initialized!
      state = load_state
      target = resolve_run_lifecycle_target(run_id)
      blockers = []
      blockers << "no active or matching run found for #{run_id.to_s.empty? ? "active" : run_id}" unless target
      run_dir = target && run_lifecycle_run_dir(target.fetch("run_id"))
      request_path = run_dir && File.join(run_dir, self.class::RUN_CANCEL_REQUEST_FILE)
      metadata = run_cancel_request_metadata(target, request_path, dry_run: dry_run, force: force, blocking_issues: blockers)

      if dry_run || !blockers.empty?
        payload = status_hash(state: state, changed_files: [])
        payload["action_taken"] = blockers.empty? ? "planned run cancellation" : "run cancellation blocked"
        payload["run_lifecycle"] = {
          "status" => blockers.empty? ? "cancel_planned" : "blocked",
          "selected_run" => target,
          "cancel_request" => metadata,
          "blocking_issues" => blockers
        }
        payload["planned_changes"] = blockers.empty? ? [relative(request_path), relative(run_lifecycle_path(target.fetch("run_id")))] : []
        payload["blocking_issues"] = (payload["blocking_issues"] + blockers).uniq
        payload["next_action"] = blockers.empty? ? "rerun aiweb run-cancel --run-id #{target.fetch("run_id")} without --dry-run to request cancellation" : "inspect aiweb run-status before requesting cancellation"
        return payload
      end

      changes = []
      mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << write_json(request_path, metadata, false)
        changes << write_json(run_lifecycle_path(target.fetch("run_id")), run_lifecycle_record(target).merge(
          "status" => "cancel_requested",
          "cancel_requested_at" => metadata["requested_at"],
          "cancel_request_path" => relative(request_path)
        ), false)
        if active_run_matches?(target.fetch("run_id"))
          active = read_active_run_lock || {}
          active = active.merge(
            "status" => "cancel_requested",
            "cancel_requested_at" => metadata["requested_at"],
            "cancel_request_path" => relative(request_path)
          )
          changes << write_json(active_run_lock_path, active, false)
        end
        if target["kind"] == "workbench-serve" && live_process?(target["pid"].to_i)
          Process.kill("TERM", target["pid"].to_i)
          metadata["process_signal"] = "TERM"
          changes << write_json(request_path, metadata, false)
          workbench_metadata_path = run_main_metadata_path(target.fetch("run_id"))
          workbench_metadata = workbench_metadata_path && read_json_file(workbench_metadata_path)
          if workbench_metadata
            workbench_metadata = workbench_metadata.merge(
              "status" => "cancelled",
              "finished_at" => now,
              "blocking_issues" => []
            )
            changes << write_json(workbench_metadata_path, workbench_metadata, false)
          end
          changes << write_json(run_lifecycle_path(target.fetch("run_id")), run_lifecycle_record(target).merge(
            "status" => "cancelled",
            "finished_at" => now,
            "cancel_requested_at" => metadata["requested_at"],
            "cancel_request_path" => relative(request_path)
          ), false)
          FileUtils.rm_f(active_run_lock_path) if active_run_matches?(target.fetch("run_id"))
        end
      end

      payload = status_hash(state: load_state, changed_files: compact_changes(changes))
      payload["action_taken"] = "requested run cancellation"
      payload["run_lifecycle"] = {
        "status" => "cancel_requested",
        "selected_run" => target,
        "cancel_request" => metadata,
        "blocking_issues" => []
      }
      payload["next_action"] = "poll aiweb run-status; long-running commands stop at their next lifecycle checkpoint"
      payload
    end

    def run_resume(run_id: "latest", dry_run: false)
      assert_initialized!
      state = load_state
      target = resolve_run_lifecycle_target(run_id.to_s.strip.empty? ? "latest" : run_id)
      metadata = target && run_main_metadata(target.fetch("run_id"))
      plan = metadata ? run_resume_plan(target, metadata) : nil
      blockers = []
      blockers << "no matching run found for #{run_id}" unless target
      blockers << "run type is not resumable by descriptor" if target && plan.nil?
      plan_path = target && File.join(run_lifecycle_run_dir(target.fetch("run_id")), self.class::RUN_RESUME_PLAN_FILE)

      if dry_run || !blockers.empty?
        payload = status_hash(state: state, changed_files: [])
        payload["action_taken"] = blockers.empty? ? "planned run resume" : "run resume blocked"
        payload["run_lifecycle"] = {
          "status" => blockers.empty? ? "resume_planned" : "blocked",
          "selected_run" => target,
          "resume_plan" => plan,
          "blocking_issues" => blockers
        }
        payload["planned_changes"] = blockers.empty? ? [relative(plan_path)] : []
        payload["blocking_issues"] = (payload["blocking_issues"] + blockers).uniq
        payload["next_action"] = blockers.empty? ? "rerun aiweb run-resume --run-id #{target.fetch("run_id")} to record the resume descriptor, then execute next_command manually if desired" : "inspect aiweb run-status and choose a resumable run"
        return payload
      end

      changes = []
      mutation(dry_run: false) do
        FileUtils.mkdir_p(File.dirname(plan_path))
        changes << write_json(plan_path, plan, false)
        changes << write_json(run_lifecycle_path(target.fetch("run_id")), run_lifecycle_record(target).merge(
          "status" => "resume_planned",
          "resume_planned_at" => plan["created_at"],
          "resume_plan_path" => relative(plan_path)
        ), false)
      end

      payload = status_hash(state: load_state, changed_files: compact_changes(changes))
      payload["action_taken"] = "recorded run resume descriptor"
      payload["run_lifecycle"] = {
        "status" => "resume_planned",
        "selected_run" => target,
        "resume_plan" => plan,
        "blocking_issues" => []
      }
      payload["next_action"] = plan.fetch("next_command")
      payload
    end

  private

    def active_run_lock_path
      File.join(root, self.class::ACTIVE_RUN_LOCK_PATH)
    end

    def runs_dir
      File.join(aiweb_dir, "runs")
    end

    def run_lifecycle_run_dir(run_id)
      safe_run_id = validate_run_id!(run_id)
      File.join(runs_dir, safe_run_id)
    end

    def run_lifecycle_path(run_id)
      File.join(run_lifecycle_run_dir(run_id), self.class::RUN_LIFECYCLE_FILE)
    end

    def run_cancel_request_path(run_id)
      File.join(run_lifecycle_run_dir(run_id), self.class::RUN_CANCEL_REQUEST_FILE)
    end

    def validate_run_id!(run_id)
      value = run_id.to_s.strip
      raise UserError.new("run id is required", 1) if value.empty?
      raise UserError.new("unsafe run id blocked", 5) if value.include?("/") || value.include?("\\") || value.include?("..") || value.start_with?(".") || unsafe_env_path?(value)

      value
    end

    def read_json_file(path)
      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def read_active_run_lock
      read_json_file(active_run_lock_path)
    end

    def active_run_matches?(run_id)
      active = read_active_run_lock
      active && active["run_id"] == run_id
    end

    def active_run_live?(record)
      return false unless record.is_a?(Hash)
      return false unless %w[running cancel_requested].include?(record["status"].to_s)

      live_process?(record["pid"].to_i)
    end

    def with_active_run(kind:, run_id:, run_dir:, metadata_path:, command:, force: false)
      record = active_run_begin!(kind: kind, run_id: run_id, run_dir: run_dir, metadata_path: metadata_path, command: command, force: force)
      final_status = "completed"
      result = yield
      final_status = run_lifecycle_result_status(result) || final_status
      result
    rescue StandardError
      final_status = "failed"
      raise
    ensure
      active_run_finish!(record, final_status) if record
    end

    def active_run_begin!(kind:, run_id:, run_dir:, metadata_path:, command:, force: false, keep_active: false)
      FileUtils.mkdir_p(runs_dir)
      existing = read_active_run_lock
      if existing && active_run_live?(existing) && !force
        raise UserError.new("active run exists: #{existing["run_id"]} (#{existing["kind"]}); inspect aiweb run-status or request cancellation with aiweb run-cancel --run-id active", 1)
      end

      FileUtils.rm_f(active_run_lock_path) if existing && (!active_run_live?(existing) || force)
      record = {
        "schema_version" => 1,
        "run_id" => run_id,
        "kind" => kind,
        "status" => "running",
        "pid" => Process.pid,
        "started_at" => now,
        "heartbeat_at" => now,
        "run_dir" => relative(run_dir),
        "metadata_path" => relative(metadata_path),
        "command" => command,
        "lock_path" => self.class::ACTIVE_RUN_LOCK_PATH,
        "cancel_request_path" => relative(run_cancel_request_path(run_id)),
        "keep_active" => keep_active
      }
      File.open(active_run_lock_path, File::WRONLY | File::CREAT | File::EXCL) do |file|
        file.write(JSON.pretty_generate(record) + "\n")
      end
      write_json(run_lifecycle_path(run_id), record, false)
      record
    rescue Errno::EEXIST
      raise UserError.new("active run lock exists at #{self.class::ACTIVE_RUN_LOCK_PATH}; inspect aiweb run-status before starting another run", 1)
    end

    def active_run_finish!(record, status)
      return unless record

      final = record.merge(
        "status" => status,
        "finished_at" => now,
        "heartbeat_at" => now
      )
      write_json(run_lifecycle_path(record.fetch("run_id")), final, false)
      if read_active_run_lock&.fetch("run_id", nil) == record.fetch("run_id") && !record["keep_active"]
        FileUtils.rm_f(active_run_lock_path)
      end
    rescue SystemCallError, JSON::ParserError
      nil
    end

    def run_lifecycle_result_status(result)
      return nil unless result.is_a?(Hash)

      result.dig("verify_loop", "status") ||
        result.dig("engine_run", "status") ||
        result.dig("deploy", "status") ||
        result.dig("workbench", "serve", "status") ||
        result.dig("workbench", "status") ||
        result.dig("setup", "status") ||
        result.dig("agent_run", "status")
    end

    def run_lifecycle_status(run_id: nil)
      active = read_active_run_lock
      active_live = active_run_live?(active)
      selected = resolve_run_lifecycle_target(run_id) if run_id && !run_id.to_s.strip.empty?
      {
        "status" => active_live ? "running" : "idle",
        "active_lock_path" => self.class::ACTIVE_RUN_LOCK_PATH,
        "active_run" => active,
        "active_run_live" => active_live,
        "selected_run" => selected,
        "recent_runs" => recent_run_lifecycle_entries(10),
        "blocking_issues" => []
      }
    end

    def resolve_run_lifecycle_target(run_id)
      selector = run_id.to_s.strip
      selector = "active" if selector.empty?
      if selector == "active"
        active = read_active_run_lock
        return active if active

        return nil
      end

      selector = latest_run_id if selector == "latest"
      return nil if selector.to_s.empty?

      safe_run_id = validate_run_id!(selector)
      run_lifecycle_record("run_id" => safe_run_id)
    end

    def latest_run_id
      Dir.glob(File.join(runs_dir, "*")).select { |path| File.directory?(path) }.map { |path| File.basename(path) }.sort.last
    end

    def recent_run_lifecycle_entries(limit)
      Dir.glob(File.join(runs_dir, "*")).select { |path| File.directory?(path) }.sort.last(limit).reverse.map do |dir|
        run_lifecycle_record("run_id" => File.basename(dir))
      end.compact
    end

    def run_lifecycle_record(target)
      run_id = validate_run_id!(target.fetch("run_id"))
      lifecycle = read_json_file(run_lifecycle_path(run_id)) || {}
      metadata_path = run_main_metadata_path(run_id)
      metadata = metadata_path ? (read_json_file(metadata_path) || {}) : {}
      lifecycle.merge(
        "run_id" => run_id,
        "kind" => lifecycle["kind"] || run_kind_from_id(run_id, metadata),
        "status" => lifecycle["status"] || metadata["status"] || "unknown",
        "run_dir" => lifecycle["run_dir"] || relative(run_lifecycle_run_dir(run_id)),
        "metadata_path" => lifecycle["metadata_path"] || metadata["metadata_path"] || (metadata_path ? relative(metadata_path) : nil),
        "pid" => lifecycle["pid"] || metadata["pid"],
        "blocking_issues" => lifecycle["blocking_issues"] || metadata["blocking_issues"] || []
      )
    rescue UserError
      nil
    end

    def run_main_metadata(run_id)
      path = run_main_metadata_path(run_id)
      path ? read_json_file(path) : nil
    end

    def run_main_metadata_path(run_id)
      dir = run_lifecycle_run_dir(run_id)
      self.class::RUN_METADATA_FILENAMES.map { |name| File.join(dir, name) }.find { |path| File.file?(path) } ||
        Dir.glob(File.join(dir, "*.json")).reject { |path| [self.class::RUN_LIFECYCLE_FILE, self.class::RUN_CANCEL_REQUEST_FILE, self.class::RUN_RESUME_PLAN_FILE].include?(File.basename(path)) }.sort.first
    rescue UserError
      nil
    end

    def run_kind_from_id(run_id, metadata)
      return "verify-loop" if run_id.start_with?("verify-loop-")
      return "engine-run" if run_id.start_with?("engine-run-")
      return "deploy" if run_id.start_with?("deploy-")
      return "workbench-serve" if run_id.start_with?("workbench-serve-")
      return "setup" if run_id.start_with?("setup-")
      return "agent-run" if run_id.start_with?("agent-run-")
      return "preview" if run_id.start_with?("preview-")

      metadata["kind"] || metadata["command"]&.first || "unknown"
    end

    def run_cancel_request_metadata(target, request_path, dry_run:, force:, blocking_issues:)
      {
        "schema_version" => 1,
        "run_id" => target && target["run_id"],
        "kind" => target && target["kind"],
        "status" => blocking_issues.empty? ? (dry_run ? "planned" : "cancel_requested") : "blocked",
        "requested_at" => now,
        "requested_by_pid" => Process.pid,
        "dry_run" => dry_run,
        "force" => force,
        "request_path" => request_path ? relative(request_path) : nil,
        "blocking_issues" => blocking_issues
      }
    end

    def run_cancel_requested?(run_id)
      File.file?(run_cancel_request_path(run_id))
    rescue UserError
      false
    end

    def run_resume_plan(target, metadata)
      kind = target["kind"].to_s
      command = case kind
                when "verify-loop"
                  ["aiweb", "verify-loop", "--max-cycles", metadata.fetch("max_cycles", 3).to_s, "--approved"]
                when "deploy"
                  target_name = metadata["target"].to_s
                  target_name.empty? ? nil : ["aiweb", "deploy", "--target", target_name, "--approved"]
                when "workbench-serve"
                  command = ["aiweb", "workbench", "--serve", "--approved"]
                  command += ["--host", metadata["host"].to_s] unless metadata["host"].to_s.empty?
                  command += ["--port", metadata["port"].to_s] unless metadata["port"].to_s.empty?
                  command
                when "setup"
                  ["aiweb", "setup", "--install", "--approved"]
                when "agent-run"
                  ["aiweb", "agent-run", "--task", "latest", "--agent", metadata["agent"].to_s.empty? ? "codex" : metadata["agent"].to_s, "--approved"]
                when "engine-run"
                  command = ["aiweb", "engine-run", "--resume", target.fetch("run_id"), "--agent", metadata["agent"].to_s.empty? ? "codex" : metadata["agent"].to_s, "--mode", metadata["mode"].to_s.empty? ? "agentic_local" : metadata["mode"].to_s, "--approved"]
                  command += ["--sandbox", metadata["sandbox"].to_s] unless metadata["sandbox"].to_s.empty?
                  command
                end
      return nil unless command

      {
        "schema_version" => 1,
        "status" => "planned",
        "run_id" => target.fetch("run_id"),
        "kind" => kind,
        "created_at" => now,
        "source_metadata_path" => target["metadata_path"],
        "command" => command,
        "next_command" => command.shelljoin,
        "executes_process" => false,
        "writes_only_descriptor" => true,
        "guardrails" => ["resume records a descriptor only", "no provider CLI or agent process is launched by run-resume", "no .env/.env.* access"]
      }
    end
  end
end
