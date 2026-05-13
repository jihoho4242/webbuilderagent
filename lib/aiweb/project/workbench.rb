# frozen_string_literal: true

module Aiweb
  module ProjectWorkbench
    def workbench(export: false, serve: false, approved: false, host: "127.0.0.1", port: nil, dry_run: false, force: false)
      return workbench_serve(approved: approved, host: host, port: port, dry_run: dry_run, force: force) if serve

      state, state_error = workbench_state_snapshot
      paths = workbench_paths
      should_export = !!export && !dry_run
      status = state_error ? "blocked" : (should_export ? "exported" : "planned")
      blockers = state_error ? [state_error] : []
      planned_changes = [paths["index_html"], paths["manifest_json"]]
      manifest = workbench_manifest(state: state, status: status, export: should_export, dry_run: dry_run, blocking_issues: blockers, paths: paths)

      if blockers.empty? && should_export
        existing_conflicts = workbench_existing_conflicts(paths, manifest)
        unless existing_conflicts.empty? || force
          blockers = existing_conflicts.map { |path| "workbench artifact already exists and differs: #{path}" }
          manifest = workbench_manifest(state: state, status: "blocked", export: true, dry_run: false, blocking_issues: blockers, paths: paths)
          return workbench_payload(state: state, workbench: manifest, changed_files: [], blocking_issues: blockers, next_action: "review existing workbench artifacts or rerun aiweb workbench --export --force")
        end

        changes = []
        mutation(dry_run: false) do
          changes << write_file(File.join(root, paths["index_html"]), workbench_html(manifest), false)
          changes << write_json(File.join(root, paths["manifest_json"]), manifest, false)
        end
        return workbench_payload(state: state, workbench: manifest, changed_files: compact_changes(changes), blocking_issues: [], next_action: "open .ai-web/workbench/index.html locally or inspect .ai-web/workbench/workbench.json")
      end

      workbench_payload(
        state: state,
        workbench: manifest,
        changed_files: blockers.empty? ? planned_changes : [],
        blocking_issues: blockers,
        next_action: blockers.empty? ? "rerun aiweb workbench --export to write the local workbench artifacts" : "run aiweb init or aiweb start before exporting the workbench"
      )
    end

    def workbench_serve(approved:, host:, port:, dry_run:, force:)
      state, state_error = workbench_state_snapshot
      paths = workbench_paths
      bind_host = workbench_serve_host(host)
      bind_port = workbench_serve_port(port)
      timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
      run_id = "workbench-serve-#{timestamp}"
      run_dir = File.join(aiweb_dir, "runs", run_id)
      stdout_path = File.join(run_dir, "stdout.log")
      stderr_path = File.join(run_dir, "stderr.log")
      metadata_path = File.join(run_dir, "workbench-serve.json")
      url = "http://#{bind_host}:#{bind_port}/"
      blockers = []
      blockers << state_error if state_error
      blockers << "workbench --serve requires localhost or 127.0.0.1 host" unless workbench_serve_allowed_host?(bind_host)
      blockers << "workbench --serve requires --approved for real local serving" if !dry_run && !approved
      planned_changes = [paths["index_html"], paths["manifest_json"], relative(run_dir), relative(stdout_path), relative(stderr_path), relative(metadata_path)]
      running = blockers.empty? ? running_workbench_serve_metadata : nil

      if running
        already = running.merge("status" => "already_running", "dry_run" => dry_run, "approved" => approved, "blocking_issues" => [])
        manifest = workbench_manifest(
          state: state,
          status: "already_running",
          export: true,
          dry_run: dry_run,
          blocking_issues: [],
          paths: paths,
          serve: workbench_serve_summary(already)
        )
        return workbench_payload(
          state: state,
          workbench: manifest,
          changed_files: [],
          blocking_issues: [],
          next_action: "open #{already["url"]} locally or stop pid #{already["pid"]} before starting another workbench server"
        )
      end

      status = blockers.empty? ? (dry_run ? "planned" : "serving") : "blocked"
      metadata = workbench_serve_metadata(
        run_id: run_id,
        status: dry_run && blockers.empty? ? "dry_run" : status,
        host: bind_host,
        port: bind_port,
        url: url,
        command: workbench_serve_command(bind_host, bind_port),
        pid: nil,
        started_at: nil,
        finished_at: nil,
        stdout_log: relative(stdout_path),
        stderr_log: relative(stderr_path),
        metadata_path: relative(metadata_path),
        workbench_paths: paths,
        dry_run: dry_run,
        approved: approved,
        blocking_issues: blockers
      )
      manifest = workbench_manifest(
        state: state,
        status: status,
        export: !dry_run && blockers.empty?,
        dry_run: dry_run,
        blocking_issues: blockers,
        paths: paths,
        serve: workbench_serve_summary(metadata)
      )

      if dry_run || !blockers.empty?
        return workbench_payload(
          state: state,
          workbench: manifest,
          changed_files: blockers.empty? ? planned_changes : [],
          blocking_issues: blockers,
          next_action: blockers.empty? ? "rerun aiweb workbench --serve --approved to write artifacts and start the localhost server" : "resolve workbench serve blockers, then rerun with --dry-run or --approved"
        )
      end

      existing_conflicts = workbench_existing_conflicts(paths, manifest)
      unless existing_conflicts.empty? || force
        blockers = existing_conflicts.map { |path| "workbench artifact already exists and differs: #{path}" }
        metadata["status"] = "blocked"
        metadata["blocking_issues"] = blockers
        manifest = workbench_manifest(
          state: state,
          status: "blocked",
          export: true,
          dry_run: false,
          blocking_issues: blockers,
          paths: paths,
          serve: workbench_serve_summary(metadata)
        )
        return workbench_payload(
          state: state,
          workbench: manifest,
          changed_files: [],
          blocking_issues: blockers,
          next_action: "review existing workbench artifacts or rerun aiweb workbench --serve --approved --force"
        )
      end

      active_record = active_run_begin!(
        kind: "workbench-serve",
        run_id: run_id,
        run_dir: run_dir,
        metadata_path: metadata_path,
        command: workbench_serve_command(bind_host, bind_port),
        force: force,
        keep_active: true
      )
      begin
      changes = []
      result = mutation(dry_run: false) do
        FileUtils.mkdir_p(run_dir)
        changes << relative(run_dir)
        changes << write_file(File.join(root, paths["index_html"]), workbench_html(manifest), false)
        changes << write_json(File.join(root, paths["manifest_json"]), manifest, false)
        FileUtils.touch(stdout_path)
        FileUtils.touch(stderr_path)
        stdout_file = File.open(stdout_path, "ab")
        stderr_file = File.open(stderr_path, "ab")
        pid = nil
        begin
          pid = Process.spawn(*workbench_serve_command(bind_host, bind_port), chdir: root, out: stdout_file, err: stderr_file)
          Process.detach(pid)
        ensure
          stdout_file.close
          stderr_file.close
        end
        metadata = workbench_serve_metadata(
          run_id: run_id,
          status: "running",
          host: bind_host,
          port: bind_port,
          url: url,
          command: workbench_serve_command(bind_host, bind_port),
          pid: pid,
          started_at: now,
          finished_at: nil,
          stdout_log: relative(stdout_path),
          stderr_log: relative(stderr_path),
          metadata_path: relative(metadata_path),
          workbench_paths: paths,
          dry_run: false,
          approved: true,
          blocking_issues: []
        )
        manifest["status"] = "running"
        manifest["serve"] = workbench_serve_summary(metadata)
        active_record = active_record.merge(
          "pid" => pid,
          "status" => "running",
          "heartbeat_at" => now,
          "url" => url
        )
        changes << write_json(active_run_lock_path, active_record, false)
        changes << write_json(run_lifecycle_path(run_id), active_record, false)
        changes << write_json(File.join(root, paths["manifest_json"]), manifest, false)
        changes << relative(stdout_path)
        changes << relative(stderr_path)
        changes << write_json(metadata_path, metadata, false)
        workbench_payload(
          state: state,
          workbench: manifest,
          changed_files: compact_changes(changes),
          blocking_issues: [],
          next_action: "open #{url} locally; stop pid #{pid} when finished"
        )
      end
      active_record = nil
      result
      ensure
        active_run_finish!(active_record, "failed") if active_record
      end
    end

    private

    def workbench_state_snapshot
      return [nil, "Project is not initialized; run aiweb init or aiweb start before exporting the workbench."] unless File.file?(state_path)

      state = YAML.load_file(state_path)
      return [refresh_state!(state), nil] if state.is_a?(Hash)

      [nil, ".ai-web/state.yaml must be a YAML mapping; repair state before exporting the workbench."]
    rescue Psych::Exception => e
      [nil, "Cannot parse .ai-web/state.yaml: #{e.message}"]
    end

    def workbench_paths
      {
        "index_html" => ".ai-web/workbench/index.html",
        "manifest_json" => ".ai-web/workbench/workbench.json"
      }
    end

    def workbench_manifest(state:, status:, export:, dry_run:, blocking_issues:, paths:, serve: nil)
      {
        "schema_version" => 1,
        "status" => status,
        "export" => export,
        "dry_run" => dry_run,
        "generated_at" => now,
        "root" => root,
        "paths" => paths,
        "serve" => serve,
        "panels" => workbench_panels(state),
        "controls" => workbench_controls,
        "guardrails" => [
          "declarative CLI command descriptors only",
          "does not directly write .ai-web/state.yaml",
          "excludes local environment secret files from file-tree and artifact summaries",
          "local artifact/server only; no install, build, preview, QA, deploy, provider network, or AI calls",
          "serve mode binds only to localhost or 127.0.0.1 and requires --approved for real process launch"
        ],
        "blocking_issues" => blocking_issues
      }
    end

    def workbench_serve_host(host)
      value = host.to_s.strip
      value.empty? ? "127.0.0.1" : value
    end

    def workbench_serve_port(port)
      value = port.to_i
      value.positive? ? value : 17342
    end

    def workbench_serve_allowed_host?(host)
      %w[localhost 127.0.0.1].include?(host.to_s)
    end

    def workbench_serve_command(host, port)
      [RbConfig.ruby, "-run", "-e", "httpd", File.join(root, ".ai-web", "workbench"), "-b", host.to_s, "-p", port.to_i.to_s]
    end

    def workbench_serve_metadata(run_id:, status:, host:, port:, url:, command:, pid:, started_at:, finished_at:, stdout_log:, stderr_log:, metadata_path:, workbench_paths:, dry_run:, approved:, blocking_issues:)
      {
        "schema_version" => 1,
        "run_id" => run_id,
        "status" => status,
        "host" => host,
        "port" => port,
        "url" => url,
        "local_only" => true,
        "command" => command,
        "cwd" => root,
        "pid" => pid,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "stdout_log" => stdout_log,
        "stderr_log" => stderr_log,
        "metadata_path" => metadata_path,
        "workbench_paths" => workbench_paths,
        "dry_run" => dry_run,
        "approved" => approved,
        "blocking_issues" => blocking_issues
      }
    end

    def workbench_serve_summary(metadata)
      return nil unless metadata

      metadata.slice("status", "host", "port", "url", "local_only", "pid", "metadata_path", "stdout_log", "stderr_log", "approved", "dry_run", "blocking_issues")
    end

    def running_workbench_serve_metadata
      workbench_serve_metadata_files.reverse_each do |path|
        metadata = read_workbench_serve_metadata(path)
        next unless metadata
        next unless metadata["status"] == "running"
        next unless live_process?(metadata["pid"].to_i)

        metadata["metadata_path"] ||= relative(path)
        return metadata
      end
      nil
    end

    def workbench_serve_metadata_files
      Dir.glob(File.join(aiweb_dir, "runs", "workbench-serve-*", "workbench-serve.json")).sort
    end

    def read_workbench_serve_metadata(path)
      data = JSON.parse(File.read(path))
      data.is_a?(Hash) ? data : nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def workbench_payload(state:, workbench:, changed_files:, blocking_issues:, next_action:)
      {
        "schema_version" => 1,
        "current_phase" => state&.dig("phase", "current"),
        "action_taken" => workbench_action_taken(workbench),
        "changed_files" => changed_files,
        "blocking_issues" => blocking_issues,
        "missing_artifacts" => state ? [] : [".ai-web/state.yaml"],
        "workbench" => workbench,
        "next_action" => next_action
      }
    end

    def workbench_action_taken(workbench)
      case workbench["status"]
      when "exported" then "exported workbench UI"
      when "running" then "started workbench server"
      when "already_running" then "workbench server already running"
      when "blocked" then "workbench blocked"
      else "planned workbench UI"
      end
    end

    def workbench_controls
      self.class::WORKBENCH_CONTROLS.map do |id, label, command|
        side_effects = workbench_control_side_effects(command)
        {
          "id" => id,
          "label" => label,
          "command" => command,
          "mode" => "cli_descriptor",
          "mutates_state" => side_effects.fetch("mutates_state"),
          "launches_process" => side_effects.fetch("launches_process"),
          "requires_approval" => side_effects.fetch("requires_approval"),
          "notes" => "UI may invoke this CLI command through an approved shell/daemon adapter; it must not edit state files directly."
        }
      end
    end

    def workbench_control_side_effects(command)
      text = command.to_s
      mutates = text.match?(/\b(?:run|design|build|preview|qa-|visual-critique|repair|visual-polish|verify-loop|component-map|visual-edit)\b/)
      launches = text.match?(/\b(?:build|preview|qa-|verify-loop)\b/)
      approval = text.match?(/\b(?:verify-loop|visual-polish|visual-edit)\b/)
      {
        "mutates_state" => mutates,
        "launches_process" => launches,
        "requires_approval" => approval
      }
    end

    def workbench_panels(state)
      self.class::WORKBENCH_PANELS.map do |panel|
        { "id" => panel }.merge(workbench_panel(panel, state))
      end
    end

    def workbench_panel(panel, state)
      case panel
      when "chat"
        { "status" => "planned", "summary" => "Local chat/command log placeholder; no network or AI calls are made by this static export." }
      when "plan_artifacts"
        { "status" => state ? "ready" : "blocked", "artifacts" => workbench_artifact_summaries(state) }
      when "design_candidates"
        { "status" => workbench_design_candidates(state).empty? ? "empty" : "ready", "candidates" => workbench_design_candidates(state) }
      when "selected_design"
        workbench_selected_design(state)
      when "preview"
        { "status" => latest_preview_metadata ? "ready" : "empty", "latest" => workbench_safe_metadata(latest_preview_metadata) }
      when "file_tree"
        { "status" => "ready", "entries" => workbench_file_tree }
      when "qa_results"
        { "status" => workbench_latest_json(".ai-web/qa/results/*.json") ? "ready" : "empty", "latest" => workbench_latest_json(".ai-web/qa/results/*.json") }
      when "visual_critique"
        path = state&.dig("qa", "latest_visual_critique") || latest_visual_critique_artifact
        { "status" => path ? "ready" : "empty", "latest" => path ? workbench_json_summary(path) : nil }
      when "run_timeline"
        { "status" => "ready", "runs" => workbench_run_timeline }
      when "verify_loop_status"
        workbench_verify_loop_status(state)
      else
        { "status" => "planned" }
      end
    end

    def workbench_artifact_summaries(state)
      return [] unless state

      (state["artifacts"] || {}).sort.map do |name, meta|
        meta = {} unless meta.is_a?(Hash)
        path = meta["path"].to_s
        next if workbench_excluded_path?(path)

        full = File.join(root, path)
        {
          "id" => name,
          "path" => path,
          "status" => meta["status"],
          "exists" => File.exist?(full),
          "directory" => File.directory?(full),
          "size_bytes" => File.file?(full) ? File.size(full) : nil
        }
      end.compact
    end

    def workbench_design_candidates(state)
      refs = Array(state&.dig("design_candidates", "candidates"))
      refs.map do |candidate|
        next unless candidate.is_a?(Hash)
        path = candidate["path"].to_s
        next if workbench_excluded_path?(path)
        full = File.join(root, path)
        candidate.slice("id", "path", "status", "strategy_id", "score", "rubric_scores", "first_view", "proof_pattern", "cta_flow", "mobile_behavior", "risks").merge(
          "exists" => File.exist?(full),
          "size_bytes" => File.file?(full) ? File.size(full) : nil
        )
      end.compact
    end

    def workbench_selected_design(state)
      selected = state&.dig("design_candidates", "selected_candidate")
      design_md = File.join(aiweb_dir, "DESIGN.md")
      selected_md = File.join(aiweb_dir, "design-candidates", "selected.md")
      selected_ref = Array(state&.dig("design_candidates", "candidates")).find { |candidate| candidate.is_a?(Hash) && candidate["id"] == selected }
      {
        "status" => selected.to_s.empty? ? "empty" : "ready",
        "selected_candidate" => selected,
        "strategy_id" => selected_ref && selected_ref["strategy_id"],
        "score" => selected_ref && selected_ref["score"],
        "risks" => selected_ref && selected_ref["risks"],
        "design_md" => { "path" => ".ai-web/DESIGN.md", "exists" => File.file?(design_md), "substantive" => File.file?(design_md) && !stub_file?(design_md) },
        "selected_notes" => { "path" => ".ai-web/design-candidates/selected.md", "exists" => File.file?(selected_md) }
      }
    end

    def workbench_file_tree
      entries = []
      return entries unless File.directory?(root)

      Find.find(root) do |path|
        rel = relative(path)
        next if rel.empty?
        if workbench_excluded_path?(rel)
          Find.prune if File.directory?(path)
          next
        end
        entries << {
          "path" => rel,
          "type" => File.directory?(path) ? "directory" : "file",
          "size_bytes" => File.file?(path) ? File.size(path) : nil
        }
        Find.prune if entries.length >= 200
      end
      entries
    end

    def bounded_observability_limit(limit)
      value = limit.to_i
      value = 20 unless value.positive?
      [[value, 1].max, 50].min
    end

    def workbench_run_timeline(limit = 20)
      bounded_limit = bounded_observability_limit(limit)
      Dir.glob(File.join(aiweb_dir, "runs", "*", "*.json"))
         .reject { |path| unsafe_env_path?(relative(path)) }
         .sort_by { |path| [File.mtime(path), path] }
         .last(bounded_limit)
         .map do |path|
        workbench_json_summary(relative(path), allow_runs: true)
      end.compact
    end

    def workbench_verify_loop_status(state)
      implementation = state&.dig("implementation").is_a?(Hash) ? state.dig("implementation") : {}
      latest_path = implementation["latest_verify_loop"]
      latest = latest_path && !unsafe_env_path?(latest_path) ? workbench_json_summary(latest_path, allow_runs: true) : nil
      {
        "status" => implementation["verify_loop_status"] || (latest ? latest["status"] : "empty"),
        "latest_verify_loop" => latest_path,
        "cycle_count" => implementation["verify_loop_cycle_count"],
        "latest_blocker" => implementation["latest_blocker"],
        "latest" => latest
      }
    end

    def workbench_latest_json(pattern)
      path = Dir.glob(File.join(root, pattern)).sort.last
      path ? workbench_json_summary(relative(path)) : nil
    end

    def workbench_json_summary(path, allow_runs: false)
      return nil if workbench_excluded_path?(path) && !(allow_runs && path.to_s.start_with?(".ai-web/runs/"))

      full = File.expand_path(path, root)
      data = JSON.parse(File.read(full))
      summary = workbench_safe_metadata(data)
      summary["path"] = relative(full)
      summary["size_bytes"] = File.size(full) if File.file?(full)
      summary
    rescue JSON::ParserError, SystemCallError
      { "path" => path, "status" => "unreadable" }
    end

    def workbench_safe_metadata(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), memo|
          key = key.to_s
          next if key.match?(/secret|token|password|api[_-]?key|credential/i)
          next if workbench_excluded_path?(item.to_s)

          memo[key] = workbench_safe_metadata(item)
        end
      when Array
        value.first(20).map { |item| workbench_safe_metadata(item) }
      when String
        workbench_excluded_path?(value) ? "[excluded]" : value[0, 300]
      else
        value
      end
    end

    def workbench_excluded_path?(path)
      value = path.to_s
      return true if value.empty? && path
      parts = value.split(/[\\\/]+/)
      return true if parts.any? { |part| part == ".env" || part.start_with?(".env.") }

      normalized = value.sub(%r{\A\./}, "")
      self.class::WORKBENCH_FILE_TREE_EXCLUDES.any? do |excluded|
        normalized == excluded || normalized.start_with?(excluded + "/")
      end
    end

    def workbench_existing_conflicts(paths, manifest)
      index_path = File.join(root, paths["index_html"])
      manifest_path = File.join(root, paths["manifest_json"])
      conflicts = []
      conflicts << paths["index_html"] if File.file?(index_path) && File.read(index_path) != workbench_html(manifest)
      conflicts << paths["manifest_json"] if File.file?(manifest_path) && File.read(manifest_path) != JSON.pretty_generate(manifest) + "\n"
      conflicts
    end

    def workbench_html(manifest)
      panels = manifest.fetch("panels").map do |panel|
        name = panel["id"].to_s
        "<section class=\"panel\"><h2>#{CGI.escapeHTML(name.tr("_", " ").split.map(&:capitalize).join(" "))}</h2><pre>#{CGI.escapeHTML(JSON.pretty_generate(panel))}</pre></section>"
      end.join("\n")
      controls = manifest.fetch("controls").map do |control|
        "<li><code>#{CGI.escapeHTML(control["command"])}</code><span>#{CGI.escapeHTML(control["label"])}</span></li>"
      end.join("\n")
      <<~HTML
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>AI Web Director Workbench</title>
          <style>
            :root { color-scheme: light dark; font-family: Inter, ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
            body { margin: 0; background: #0f172a; color: #e2e8f0; }
            header { padding: 32px; border-bottom: 1px solid #334155; background: linear-gradient(135deg, #111827, #1e293b); }
            main { display: grid; grid-template-columns: minmax(220px, 320px) 1fr; gap: 20px; padding: 24px; }
            aside, .panel { border: 1px solid #334155; border-radius: 16px; background: #111827; box-shadow: 0 18px 50px rgba(0, 0, 0, 0.25); }
            aside { padding: 20px; align-self: start; position: sticky; top: 16px; }
            .grid { display: grid; gap: 20px; }
            .panel { padding: 20px; overflow: hidden; }
            h1, h2 { margin: 0 0 12px; }
            p { color: #94a3b8; }
            ul { list-style: none; padding: 0; display: grid; gap: 12px; }
            li { display: grid; gap: 4px; padding: 12px; border: 1px solid #334155; border-radius: 12px; background: #0f172a; }
            code, pre { white-space: pre-wrap; word-break: break-word; color: #bfdbfe; }
            pre { max-height: 360px; overflow: auto; padding: 12px; border-radius: 12px; background: #020617; }
          </style>
        </head>
        <body>
          <header>
            <h1>AI Web Director Workbench</h1>
            <p>Status: #{CGI.escapeHTML(manifest["status"])} · Manifest: #{CGI.escapeHTML(manifest.dig("paths", "manifest_json"))}</p>
          </header>
          <main>
            <aside>
              <h2>Declarative controls</h2>
              <ul>#{controls}</ul>
              <p>Controls describe approved CLI commands only. This static UI does not directly mutate .ai-web/state.yaml.</p>
            </aside>
            <div class="grid">#{panels}</div>
          </main>
        </body>
        </html>
      HTML
    end


  end
end
