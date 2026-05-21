# frozen_string_literal: true

module Aiweb
  module ProjectWorkbench
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
