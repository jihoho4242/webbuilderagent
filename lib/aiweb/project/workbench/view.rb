# frozen_string_literal: true

require "cgi"
require "json"

module Aiweb
  module ProjectWorkbenchView
    private

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
      dry_run = text.match?(/\s--dry-run\b/)
      mutates = !dry_run && text.match?(/\b(?:agent|design|build|preview|qa-|visual-critique|repair|visual-polish|engine-run|component-map|visual-edit)\b/)
      launches = !dry_run && text.match?(/\b(?:agent|build|preview|qa-|engine-run)\b/)
      approval = !dry_run && text.match?(/\b(?:agent|engine-run|visual-polish|visual-edit)\b/)
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
      when "agent_runtime"
        workbench_agent_runtime_status(state)
      when "run_timeline"
        { "status" => "ready", "runs" => workbench_run_timeline }
      when "verify_loop_status"
        workbench_verify_loop_status(state)
      else
        { "status" => "planned" }
      end
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
