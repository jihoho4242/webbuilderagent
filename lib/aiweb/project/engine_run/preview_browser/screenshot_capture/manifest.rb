# frozen_string_literal: true

module Aiweb
  module ProjectEngineRun
    def engine_run_browser_runtime_attestation(paths:, preview:, agent:, sandbox:, browser_commands:)
      sandbox_required = agent.to_s == "openmanus" && !sandbox.to_s.strip.empty?
      preview_command = preview.to_h["command"].to_s
      browser_tool_wrapped = if sandbox_required
                               Array(browser_commands).all? { |command| File.basename(command.first.to_s).sub(/\.cmd\z/i, "") == sandbox.to_s }
                             else
                               true
                             end
      preview_tool_wrapped = if sandbox_required
                               File.basename(preview_command.split(/\s+/).first.to_s).sub(/\.cmd\z/i, "") == sandbox.to_s
                             else
                               true
                             end
      blockers = []
      blockers << "browser evidence preview command did not use the selected sandbox wrapper" if sandbox_required && !preview_tool_wrapped
      blockers << "browser evidence observation command did not use the selected sandbox wrapper" if sandbox_required && !browser_tool_wrapped
      blockers << "browser evidence requires a ready local preview before attestation" unless preview.to_h["status"] == "ready"
      blockers << "browser evidence did not record any browser observation commands" if preview.to_h["status"] == "ready" && Array(browser_commands).empty?
      {
        "schema_version" => 1,
        "status" => blockers.empty? ? "passed" : (preview.to_h["status"] == "ready" ? "failed" : "skipped"),
        "agent" => agent,
        "sandbox" => sandbox,
        "sandbox_required" => sandbox_required,
        "workspace_path" => relative(paths.fetch(:workspace_dir)),
        "same_staged_workspace" => true,
        "same_container_instance" => false,
        "same_container_instance_reason" => "local Docker/Podman tool commands are isolated invocations; aiweb attests shared staged workspace and sandbox/tool-broker boundary, not a single long-lived container",
        "preview_status" => preview.to_h["status"],
        "preview_url" => preview.to_h["url"],
        "preview_command" => preview_command.empty? ? nil : preview_command,
        "preview_tool_wrapped" => preview_tool_wrapped,
        "browser_observe_commands" => Array(browser_commands).map { |command| command.join(" ") },
        "browser_tool_wrapped" => browser_tool_wrapped,
        "tool_broker_bin_path" => "_aiweb/tool-broker-bin",
        "tool_broker_path_prepend_required" => true,
        "network_policy" => "localhost-only",
        "browser_evidence_workspace_dir" => relative(File.join(paths.fetch(:workspace_dir), "_aiweb", "browser-evidence")),
        "blocking_issues" => blockers
      }
    end

    def engine_run_browser_evidence_manifest(preview, captures, blockers, runtime_attestation)
      screenshots = captures.select { |capture| capture.dig("screenshot", "path") && capture.dig("screenshot", "sha256") }.map do |capture|
        shot = capture.fetch("screenshot", {})
        {
          "viewport" => capture.fetch("viewport"),
          "width" => capture.fetch("width"),
          "height" => capture.fetch("height"),
          "url" => preview["url"],
          "path" => shot.fetch("path"),
          "sha256" => shot.fetch("sha256"),
          "bytes" => shot.fetch("bytes"),
          "capture_mode" => shot.fetch("capture_mode"),
          "mime_type" => shot.fetch("mime_type"),
          "png_signature_valid" => shot.fetch("png_signature_valid"),
          "image_width" => shot.fetch("image_width"),
          "image_height" => shot.fetch("image_height")
        }
      end
      {
        "schema_version" => 1,
        "status" => blockers.empty? && captures.length == 3 ? "captured" : "failed",
        "preview_status" => preview["status"],
        "preview_url" => preview["url"],
        "network_policy" => "localhost-only",
        "browser_runtime" => "playwright",
        "sandbox_boundary" => "staged_workspace_tool_broker",
        "runtime_attestation" => runtime_attestation,
        "screenshots" => screenshots,
        "viewport_evidence" => captures,
        "console_errors" => engine_run_merge_browser_observations(captures, "console_errors"),
        "network_errors" => engine_run_merge_browser_observations(captures, "network_errors"),
        "dom_snapshot" => engine_run_merge_browser_evidence(captures, "dom_snapshot"),
        "a11y_report" => engine_run_merge_browser_evidence(captures, "a11y_report"),
        "computed_style_summary" => engine_run_merge_browser_evidence(captures, "computed_style_summary"),
        "interaction_states" => engine_run_merge_interaction_states(captures),
        "keyboard_focus_traversal" => engine_run_merge_focus_traversal(captures),
        "action_recovery" => engine_run_merge_action_recovery(captures),
        "action_loop" => engine_run_browser_action_loop(captures),
        "blocking_issues" => blockers.uniq
      }
    end
  end
end
