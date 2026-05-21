# frozen_string_literal: true

require_relative "workbench/artifacts"
require_relative "workbench/view"

module Aiweb
  module ProjectWorkbench
    include ProjectWorkbenchView
    WORKBENCH_PANELS = %w[
      chat
      plan_artifacts
      design_candidates
      selected_design
      preview
      file_tree
      qa_results
      visual_critique
      agent_runtime
      run_timeline
      verify_loop_status
    ].freeze

    WORKBENCH_CONTROLS = [
      ["agent", "Plan supervised natural-language agent run", "aiweb agent \"Improve this local site\" --mode supervised --dry-run"],
      ["design", "Plan design candidates", "aiweb design --dry-run"],
      ["build", "Plan scaffold build", "aiweb build --dry-run"],
      ["preview", "Plan local preview", "aiweb preview --dry-run"],
      ["qa_playwright", "Plan Playwright QA", "aiweb qa-playwright --dry-run"],
      ["visual_critique", "Plan visual critique", "aiweb visual-critique --dry-run"],
      ["repair", "Plan repair packet", "aiweb repair --dry-run"],
      ["visual_polish", "Plan visual polish loop", "aiweb visual-polish --repair --dry-run"],
      ["engine_run", "Plan canonical engine-run handoff", "aiweb engine-run --agent codex --mode agentic_local --max-cycles 3 --dry-run"]
    ].freeze

    WORKBENCH_FILE_TREE_EXCLUDES = %w[
      .git
      .ai-web/workbench
      .ai-web/snapshots
      .ai-web/runs
      node_modules
      dist
      build
      coverage
      tmp
      vendor/bundle
    ].freeze

    def workbench(export: false, serve: false, approved: false, approval_hash: nil, host: "127.0.0.1", port: nil, dry_run: false, force: false)
      return workbench_serve(approved: approved, approval_hash: approval_hash, host: host, port: port, dry_run: dry_run, force: force) if serve

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

    def workbench_serve(approved:, approval_hash:, host:, port:, dry_run:, force:)
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
      capability = workbench_serve_approval_capability(state: state, host: bind_host, port: bind_port, url: url, paths: paths)
      expected_hash = workbench_serve_approval_hash(capability)
      supplied_hash = approval_hash.to_s.strip
      approval_blockers = workbench_serve_approval_blockers(approved: approved, supplied_hash: supplied_hash, expected_hash: expected_hash)
      blockers = []
      blockers << state_error if state_error
      blockers << "workbench --serve requires localhost or 127.0.0.1 host" unless workbench_serve_allowed_host?(bind_host)
      blockers.concat(approval_blockers) unless dry_run
      planned_changes = [paths["index_html"], paths["manifest_json"], relative(run_dir), relative(stdout_path), relative(stderr_path), relative(metadata_path)]
      running = blockers.empty? ? running_workbench_serve_metadata : nil

      if running
        already = running.merge("status" => "already_running", "dry_run" => dry_run, "approved" => approved, "approval_hash" => expected_hash, "supplied_approval_hash" => supplied_hash.empty? ? nil : supplied_hash, "blocking_issues" => [])
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
        approval_hash: expected_hash,
        supplied_approval_hash: supplied_hash.empty? ? nil : supplied_hash,
        capability: capability,
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
          next_action: blockers.empty? ? "review workbench serve approval_hash #{expected_hash}; real serve is a lower-level localhost ops action, not a Workbench control shortcut" : "resolve workbench serve blockers, then rerun workbench --serve --dry-run for a fresh approval_hash"
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
          next_action: "review existing workbench artifacts or rerun workbench --serve --dry-run after deciding whether to replace them"
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
          pid = Aiweb::Runtime::ProcessLauncher.spawn(
            spec: Aiweb::Runtime::LaunchSpec.new(
              argv: workbench_serve_command(bind_host, bind_port),
              cwd: root,
              stdout: stdout_file,
              stderr: stderr_file,
              risk_class: "workbench_local_server",
              description: "workbench local server"
            )
          )
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
          approval_hash: expected_hash,
          supplied_approval_hash: supplied_hash.empty? ? nil : supplied_hash,
          capability: capability,
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
          "serve mode binds only to localhost or 127.0.0.1 and requires --approval-hash HASH plus --approved for real process launch"
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

    def workbench_serve_approval_capability(state:, host:, port:, url:, paths:)
      {
        "schema_version" => 1,
        "capability" => "aiweb.workbench.serve.v1",
        "constitution_hash" => Aiweb::Constitution::Loader.new.content_hash,
        "policy_kernel_version" => Aiweb::Tools::DecisionPacket::POLICY_KERNEL_VERSION,
        "risk_class" => "workbench_local_server",
        "host" => host,
        "port" => port,
        "url" => url,
        "local_only" => true,
        "command" => workbench_serve_command(host, port),
        "cwd" => root,
        "state_sha256" => File.file?(state_path) ? Digest::SHA256.file(state_path).hexdigest : nil,
        "workbench_paths" => paths,
        "workbench_artifact_fingerprints" => workbench_artifact_fingerprints(paths),
        "serve_boundary" => {
          "requires_dry_run_review" => true,
          "requires_matching_approval_hash" => true,
          "allowed_hosts" => %w[localhost 127.0.0.1],
          "writes_under" => %w[.ai-web/workbench .ai-web/runs/workbench-serve-*],
          "forbidden" => %w[workbench_control_execution install build preview qa deploy provider_cli external_network env_read state_mutation]
        },
        "state_present" => state.is_a?(Hash)
      }
    end

    def workbench_artifact_fingerprints(paths)
      paths.to_h.transform_values do |relative_path|
        path = File.join(root, relative_path.to_s)
        if File.file?(path)
          {
            "present" => true,
            "bytes" => File.size(path),
            "sha256" => Digest::SHA256.file(path).hexdigest
          }
        else
          { "present" => false }
        end
      end
    end

    def workbench_serve_approval_hash(capability)
      Digest::SHA256.hexdigest(JSON.generate(capability))
    end

    def workbench_serve_approval_blockers(approved:, supplied_hash:, expected_hash:)
      return ["workbench --serve requires --approved and --approval-hash HASH for real local serving"] unless approved
      return ["--approval-hash is required for real workbench serve"] if supplied_hash.to_s.empty?
      return ["workbench serve approval hash does not match the current serve capability envelope"] unless supplied_hash == expected_hash

      []
    end

    def workbench_serve_approved_command(approval_hash, host:, port:)
      parts = ["aiweb", "workbench", "--serve", "--host", host.to_s, "--port", port.to_i.to_s, "--approval-hash", approval_hash.to_s, "--approved"]
      Shellwords.join(parts)
    end

    def workbench_serve_metadata(run_id:, status:, host:, port:, url:, command:, pid:, started_at:, finished_at:, stdout_log:, stderr_log:, metadata_path:, workbench_paths:, dry_run:, approved:, approval_hash: nil, supplied_approval_hash: nil, capability: nil, blocking_issues:)
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
        "approval_hash" => approval_hash,
        "supplied_approval_hash" => supplied_approval_hash,
        "capability" => capability,
        "blocking_issues" => blocking_issues
      }
    end

    def workbench_serve_summary(metadata)
      return nil unless metadata

      metadata.slice("status", "host", "port", "url", "local_only", "pid", "metadata_path", "stdout_log", "stderr_log", "approved", "approval_hash", "supplied_approval_hash", "dry_run", "blocking_issues")
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

    def workbench_existing_conflicts(paths, manifest)
      index_path = File.join(root, paths["index_html"])
      manifest_path = File.join(root, paths["manifest_json"])
      conflicts = []
      conflicts << paths["index_html"] if File.file?(index_path) && File.read(index_path) != workbench_html(manifest)
      conflicts << paths["manifest_json"] if File.file?(manifest_path) && File.read(manifest_path) != JSON.pretty_generate(manifest) + "\n"
      conflicts
    end



  end
end
