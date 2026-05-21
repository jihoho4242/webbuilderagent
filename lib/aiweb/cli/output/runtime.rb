# frozen_string_literal: true

module Aiweb
  class CLI
    module Output
      private

    def human_engine_scheduler_result(result)
      scheduler = result.fetch("engine_scheduler")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = scheduler["blocking_issues"] || result["blocking_issues"] || []
      [
        "Engine scheduler: #{scheduler["status"] || "n/a"}",
        "Decision: #{scheduler["decision"] || "n/a"}",
        "Run: #{scheduler["selected_run_id"] || "none"}",
        "Start node: #{scheduler["derived_start_node_id"] || "none"}",
        ("Daemon: #{scheduler["daemon_driver"]} ticks=#{scheduler["tick_count"]} stop=#{scheduler["stop_reason"]}" if scheduler["daemon_driver"]),
        ("Supervisor: #{scheduler["supervisor_driver"]} install=#{scheduler["install_status"] || "n/a"}" if scheduler["supervisor_driver"]),
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].compact.join("\n")
    end

    def human_mcp_broker_result(result)
      broker = result.fetch("mcp_broker")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = broker["blocking_issues"] || result["blocking_issues"] || []
      [
        "MCP broker: #{broker["status"] || "n/a"}",
        "Server/tool: #{broker["server"] || "n/a"}/#{broker["tool"] || "n/a"}",
        "Broker: #{broker["broker_driver"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_run_lifecycle_result(result)
      lifecycle = result.fetch("run_lifecycle")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = lifecycle["blocking_issues"] || result["blocking_issues"] || []
      active = lifecycle["active_run"]
      selected = lifecycle["selected_run"]
      [
        "Run lifecycle: #{lifecycle["status"] || "n/a"}",
        "Active run: #{active ? "#{active["run_id"]} (#{active["kind"] || "unknown"})" : "none"}",
        "Selected run: #{selected ? "#{selected["run_id"]} (#{selected["kind"] || "unknown"})" : "none"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_run_timeline_result(result)
      timeline = result.fetch("run_timeline")
      runs = Array(timeline["runs"])
      blockers = timeline["blocking_issues"] || result["blocking_issues"] || []
      [
        "Run timeline: #{timeline["status"] || "n/a"}",
        "Limit: #{timeline["limit"] || "n/a"}",
        "Runs: #{runs.length}",
        "Latest: #{runs.last ? runs.last["path"] : "none"}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_observability_summary_result(result)
      summary = result.fetch("observability_summary")
      blockers = summary["blocking_issues"] || result["blocking_issues"] || []
      counts = summary["recent_status_counts"].is_a?(Hash) ? summary["recent_status_counts"].map { |k, v| "#{k}=#{v}" }.join(", ") : "none"
      [
        "Observability: #{summary["status"] || "n/a"}",
        "Active run: #{summary["active_run"] ? summary["active_run"]["run_id"] : "none"}",
        "Recent runs: #{summary["recent_run_count"] || 0}",
        "Status counts: #{counts.empty? ? "none" : counts}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_runtime_plan_result(result)
      plan = result.fetch("runtime_plan")
      blockers = plan.fetch("blockers", [])
      lines = [
        "Runtime readiness: #{plan.fetch("readiness")}",
        "Scaffold: profile=#{plan.dig("scaffold", "profile") || "n/a"} framework=#{plan.dig("scaffold", "framework") || "n/a"} package_manager=#{plan.dig("scaffold", "package_manager") || "n/a"}",
        "Commands: dev=#{plan.dig("scaffold", "dev_command") || "n/a"} build=#{plan.dig("scaffold", "build_command") || "n/a"}",
        "Selected design: #{plan.dig("design", "selected_candidate") || "none"}",
        "Missing files: #{plan.fetch("missing_required_scaffold_files").empty? ? "none" : plan.fetch("missing_required_scaffold_files").join(", ")}",
        "Blockers: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ]
      lines.join("\n")
    end
    end
  end
end
