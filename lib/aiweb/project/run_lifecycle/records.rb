# frozen_string_literal: true

require "fileutils"
require "json"

module Aiweb
  module ProjectRunLifecycle
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
  end
end
