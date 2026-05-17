# frozen_string_literal: true

module Aiweb
  class CLI
    module Output
      private

    def help_payload
      base_payload("help", <<~HELP)
        aiweb — AI Web Director CLI

        Commands:
          start [--path PATH] --idea "..." [--profile A|B|C|D] [--no-advance]
          init [--profile A|B|C|D]
          status
          interview --idea "..."
          intent route --idea "..."
          run
          run-status [--run-id active|latest|ID]
          run-timeline [--limit N] (alias: timeline)
          observability-summary [--limit N] (alias: summary)
          run-cancel [--run-id active|ID] [--force]
          run-resume [--run-id latest|ID]
          engine-run [--goal "..."] [--agent codex|openmanus|openhands|langgraph|openai_agents_sdk] [--mode safe_patch|agentic_local] [--sandbox docker|podman] [--max-cycles N] [--run-id RUN_ID] [--approved] [--approval-hash HASH]
          engine-run --dry-run
          engine-scheduler status [--run-id latest|ID]
          engine-scheduler tick [--run-id latest|ID] [--approved] [--execute]
          engine-scheduler daemon [--run-id latest|ID] [--max-ticks N] [--interval-seconds N] [--workers N] [--approved] [--execute]
          engine-scheduler supervisor [--run-id latest|ID] [--max-ticks 0] [--interval-seconds N] [--workers N]
          engine-scheduler monitor [--dry-run]
          mcp-broker call --server lazyweb --tool lazyweb_health|lazyweb_search [--query QUERY] [--limit N] [--endpoint URL] [--approved]
          mcp-broker call --server project_files --tool project_file_metadata|project_file_list|project_file_excerpt|project_file_search --query RELATIVE_PATH_OR_SEARCH [--limit N] [--approved]
          eval-baseline validate [--path .ai-web/eval/human-baselines.json] [--fixture-id design-fixture-...]
          eval-baseline review-pack [--fixture-id design-fixture-...] [--output .ai-web/eval/human-review-pack.json]
          eval-baseline import --path .ai-web/eval/candidate-human-baselines.json --approved
          design-brief [--force]
          design-research [--provider lazyweb] [--policy off|opportunistic|required] [--limit N] [--force]
          design-system resolve [--force]
          design-prompt [--force]
          design --candidates 3 [--force]
          select-design candidate-01|candidate-02|candidate-03
          scaffold --profile D [--force]
          scaffold --profile S [--force]
          setup --install --dry-run
          setup --install --approved [--allow-lifecycle-scripts] [--audit-exception .ai-web/approvals/setup-audit-exception.json]
          supabase-secret-qa [--force]
          supabase-local-verify [--force]
          runtime-plan (alias: scaffold-status)
          build
          ingest-reference [--type manual|image|gpt-image-2|remote|lazyweb] [--title TITLE] [--source SOURCE] [--notes NOTES] [--force]
          ingest-design [--id ID] [--title TITLE] [--source SOURCE] [--notes NOTES] [--selected] [--force]
          next-task [--type TYPE] [--force]
          qa-checklist [--force]
          qa-report [--from PATH] [--status passed|failed|blocked] [--duration-minutes N] [--timed-out] [--force]
          repair [--from-qa PATH|latest] [--max-cycles N] [--force]
          verify-loop [--max-cycles N:1-10] [--agent codex|openmanus] [--sandbox docker|podman] [--approved] [--force]
          verify-loop --max-cycles 3 --dry-run
          verify-loop --max-cycles 3 --agent codex --approved
          qa-playwright [--url URL] [--task-id ID] [--force]
          qa-screenshot [--url URL] [--task-id ID] [--force]
          qa-a11y [--url URL] [--task-id ID] [--force]
          qa-lighthouse [--url URL] [--task-id ID] [--force]
          visual-critique [--screenshot PATH] [--metadata PATH] [--from-screenshots latest] [--task-id ID] [--force]
          visual-polish --repair [--from-critique PATH|latest] [--max-cycles N] [--force]
          workbench [--export] [--serve] [--approved] [--host localhost|127.0.0.1] [--port N] [--force]
          workbench --serve --dry-run
          workbench --serve --approved
          daemon [--host 127.0.0.1] [--port 4242]
          component-map [--force]
          visual-edit --target DATA_AIWEB_ID --prompt TEXT [--from-map PATH|latest] [--force]
          github-sync [--remote NAME] [--branch NAME]
          deploy-plan [--target cloudflare-pages|vercel]
          deploy --target cloudflare-pages|vercel --dry-run
          deploy --target cloudflare-pages|vercel --approved
          advance
          rollback [--to PHASE] [--failure CODE] [--reason "..."]
          resolve-blocker --reason "..."
          snapshot [--reason "..."]
          design-systems list
          skills list
          craft list

        Global flags:
          --json       machine-readable output
          --dry-run    plan mutation without writing files
          --path PATH  run against a project directory

        Phase-sensitive commands are guarded:
          design-research: phase-3 or phase-3.5; --dry-run writes nothing and calls no network, real runs call Lazyweb only when configured, and implementation agents still receive no Lazyweb MCP/network access
          design-prompt: phase-3 or phase-3.5
          design: creates deterministic HTML design candidates without app scaffold
          select-design: records selected HTML candidate without overwriting DESIGN.md
          scaffold: creates Profile D Astro-style static app skeleton or Profile S local Next.js + Supabase SSR scaffold without installing packages, creating .env.example, contacting Supabase, deploying, or running build/preview
          setup --install: PR20 dependency install surface; --dry-run writes nothing and reports planned pnpm install/log paths, while a real install requires --approved, records stdout/stderr/setup metadata under .ai-web/runs/setup-<timestamp>/, warns on lifecycle scripts, updates safe setup state, and never builds/previews/runs QA/deploys or reads .env/.env.*; --allow-lifecycle-scripts is fail-closed until sandbox and egress-firewall evidence exists; critical/high audit findings stay blocked unless --audit-exception points to an approved .ai-web/approvals JSON file with expiry and rollback plan
          supabase-secret-qa: reruns local-only Profile S secret guard QA against safe scaffold/template paths, including supabase/env.example.template, and records .ai-web/qa/supabase-secret-qa.json; --dry-run writes nothing and never reads .env/.env.*
          supabase-local-verify: verifies generated Profile S files, safe Supabase template, migrations/RLS/storage docs, and SSR client/server stubs locally, records .ai-web/qa/supabase-local-verify.json, and never creates hosted Supabase projects, runs provider CLI/network, deploys, installs, builds, previews, or reads .env/.env.*
          runtime-plan/scaffold-status: read-only runtime readiness metadata; does not install or launch Node
          run-status/run-cancel/run-resume: local run lifecycle control plane backed by .ai-web/runs/active-run.json plus per-run lifecycle/cancel/resume descriptors; status is read-only, cancel/resume support --dry-run no-write planning, cancellation is observed at lifecycle checkpoints, and resume records a descriptor without launching provider or agent commands
          engine-run: Manus-style engine-first task runtime; --dry-run writes nothing and returns a capability envelope, planned run artifacts, event/checkpoint paths, and approval hash; approved agentic_local runs stage a filtered sandbox workspace, let codex/openmanus/experimental OpenHands/LangGraph/OpenAI Agents SDK work there, run local verification where available, then copy back only validated safe source changes while network/install/deploy/provider CLI/git push remain elevated-approval actions
          engine-scheduler: project-local durable graph scheduler service surface; status is read-only, tick records .ai-web/runs/<run-id>/artifacts/scheduler-service.json plus .ai-web/scheduler/ledger.jsonl, daemon records .ai-web/scheduler/daemon.json plus heartbeat/worker-pool artifacts for a foreground loop, supervisor records .ai-web/scheduler/supervisor.json with external service-unit/runbook templates but does not install OS services, monitor records .ai-web/scheduler/monitor.json health evidence over heartbeat/leases/queue/worker-pool artifacts, and --execute resumes through the explicit engine-run bridge only with --approved
          mcp-broker: approved implementation-worker MCP connector broker for Lazyweb health/search plus project_files metadata/list/bounded-excerpt/bounded-literal-search only; --dry-run writes nothing, unapproved calls write deny/block audit evidence only, unknown connectors record a missing-driver fail-closed contract, approved Lazyweb calls require configured credentials, approved project_files calls use no credentials/network and return metadata or safe bounded excerpts/search matches only, redact endpoint/token/output, and record .ai-web/runs/mcp-broker-*/mcp-broker.json plus side-effect-broker.jsonl
          eval-baseline: creates human review packs and validates/imports a human-calibrated eval baseline corpus under .ai-web/eval; review-pack writes placeholders only, validate records redacted validation evidence only, import requires --approved, rejects .env/.env.* paths, raw secrets, invalid 0..100 scores, and non-human-calibrated corpora, and never fabricates reviewer evidence
          run-timeline/observability-summary: read-only timeline and compact observability rollups over safe .ai-web/runs JSON evidence; caps --limit at 50, redacts secret-like keys and .env paths, writes nothing, and launches no processes
          build: runs the scaffolded Astro build only after runtime-plan is ready and records .ai-web/runs logs
          preview: starts/stops the local scaffold dev server after runtime-plan is ready; --dry-run does not write files or launch Node
          agent-run: runs an approved local source-patch agent task packet for repair / visual-polish / visual-edit evidence with logs and diff artifacts; --agent supports codex or openmanus; OpenManus approved runs require --sandbox docker|podman; --dry-run does not write files or launch a process
          qa-playwright: runs safe local Playwright QA browser checks against localhost/127.0.0.1 preview; --dry-run does not write files or launch Node
          qa-screenshot: captures safe local screenshot evidence for mobile/tablet/desktop from localhost/127.0.0.1 preview; --dry-run does not write files, launch browsers, install packages, or start preview
          qa-a11y: runs safe local axe accessibility QA against localhost/127.0.0.1 preview; --dry-run does not write files or launch Node
          qa-lighthouse: runs safe local Lighthouse QA against localhost/127.0.0.1 preview; --dry-run does not write files or launch Node
          visual-critique: records safe local visual critique from explicit screenshot/metadata evidence or --from-screenshots latest only; --dry-run plans .ai-web/visual artifacts without writes, browser launch, installs, repair, deploy, network, or .env access
          verify-loop: runs the local build -> preview -> QA -> critique -> task -> agent-run loop; --agent chooses codex or openmanus for implementation repair cycles, OpenManus repair cycles require --sandbox docker|podman for approved execution, --max-cycles is capped at 10, --dry-run writes nothing and plans build -> preview -> QA -> screenshot -> visual critique -> repair/visual-polish -> agent-run cycles, while real execution requires --approved, uses existing local adapters, records .ai-web/runs/verify-loop-<timestamp>/verify-loop.json plus per-cycle evidence and deploy provenance, never installs packages, never deploys, and stops on pass, max cycles, blockers, unsafe action, or agent-run failure
          agent-run --task latest --agent codex --dry-run
          agent-run --task latest --agent codex --approved
          agent-run --task latest --agent openmanus --dry-run
          agent-run --task latest --agent openmanus --sandbox docker --approved
          workbench: plans, exports, or serves a local UI manifest under .ai-web/workbench using declarative CLI controls only; requires initialized .ai-web/state.yaml, --dry-run writes nothing, export writes only workbench artifacts, serve binds only localhost/127.0.0.1 and requires --approved for real process launch, executes no controls, and never mutates state.yaml
          daemon: starts the local backend API bridge for the future web Workbench; --dry-run reports endpoints and guardrails without binding a port
          ingest-reference: phase-3 or phase-3.5; writes only .ai-web/design-reference-brief.md pattern constraints, never implementation source, and rejects .env/.env.* or secret-looking reference paths
          component-map: scans stable data-aiweb-id regions into .ai-web/component-map.json; --dry-run writes nothing and never reads .env/.env.*
          visual-edit: validates a selected data-aiweb-id target and writes only local handoff artifacts; --dry-run writes nothing and never patches source, runs QA/browser/build, deploys, or calls network/AI
          github-sync: local-only GitHub sync planning surface; never runs git push, provider CLIs, network, build/preview/install, or reads .env/.env.*
          deploy-plan: local-only deploy checklist for Cloudflare Pages or Vercel; never runs provider CLIs, network, build/preview/install, or reads .env/.env.*
          deploy --target cloudflare-pages|vercel --dry-run: reports the deploy plan only without writes/processes; deploy --approved is gated by passing approved verify-loop evidence whose deploy provenance matches the current git/source/package/output/tool-version snapshot plus provider readiness, and records .ai-web/runs/deploy-* evidence before any provider adapter command can run
          ingest-design: phase-3.5
          next-task: phase-6 through phase-11
          qa-checklist: phase-7 through phase-11
          qa-report: phase-7 through phase-11
          repair: phase-7 through phase-11; records a bounded local repair-loop task from failed/blocked QA without running build, QA, preview, deploy, package install, or source auto-patches
          agent-run: phase-7 through phase-11; approved local source-patch task packets only, with logs, diff evidence, and no .env/.env.* access; openmanus runs through an aiweb-managed docker/podman sandbox, isolated workspace, JSON contract, and only validated allowed source files are copied back
          qa-screenshot: phase-7 through phase-11; captures safe local screenshot evidence for critique/human QA without starting preview or installing packages
          visual-critique: phase-7 through phase-11; records deterministic local visual critique evidence from explicit input paths or latest screenshot metadata only
          visual-polish --repair: records safe local visual polish repair loop from failed/repair/redesign critique evidence in phase-7 through phase-11 without source edits, build, QA, preview, browser capture, deploy, package install, network, or AI calls
          component-map / visual-edit: phase-7 through phase-11; map stable DOM regions and create selected-region visual edit handoff records without source auto-patches or external execution
          Profile S: local scaffold/QA only; Supabase SSR placeholders are NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY in supabase/env.example.template, supabase-local-verify records local evidence at .ai-web/qa/supabase-local-verify.json, and .env.example is intentionally not generated under the no-.env guardrail
        Use --force only for manual repair/override.
      HELP
    end

    def base_payload(action, message)
      {
        "schema_version" => 1,
        "current_phase" => nil,
        "action_taken" => action,
        "changed_files" => [],
        "blocking_issues" => [],
        "missing_artifacts" => [],
        "next_action" => message
      }
    end

    def emit_result(result)
      if @json
        puts JSON.pretty_generate(result)
      else
        puts human_result(result)
      end
    end

    def emit_error(message, code)
      payload = {
        "schema_version" => 1,
        "status" => "error",
        "error" => { "code" => code, "message" => message },
        "blocking_issues" => [message],
        "next_action" => "fix the reported issue and rerun the command"
      }
      if @json
        puts JSON.pretty_generate(payload)
      else
        warn "Error: #{message}"
        warn "Next command: #{payload["next_action"]}"
      end
      code
    end

    def human_result(result)
      return human_registry_result(result) if result["registry"]
      return human_intent_result(result) if result["intent"]
      return human_runtime_plan_result(result) if result["runtime_plan"]
      return human_verify_loop_result(result) if result["verify_loop"]
      return human_engine_scheduler_result(result) if result["engine_scheduler"]
      return human_mcp_broker_result(result) if result["mcp_broker"]
      return human_agent_run_result(result) if result["agent_run"]
      return human_eval_baseline_result(result) if result["eval_baseline"]
      return human_repair_result(result) if result["repair_loop"]
      return human_qa_screenshot_result(result) if result["screenshot_qa"]
      return human_visual_critique_result(result) if result["visual_critique"]
      return human_visual_polish_result(result) if result["visual_polish"]
      return human_workbench_result(result) if result["workbench"]
      return human_component_map_result(result) if result["component_map"]
      return human_visual_edit_result(result) if result["visual_edit"]
      return human_supabase_local_verify_result(result) if result["supabase_local_verify"]
      return human_supabase_secret_qa_result(result) if result["supabase_secret_qa"]
      return human_setup_result(result) if result["setup"]
      return human_run_timeline_result(result) if result["run_timeline"]
      return human_observability_summary_result(result) if result["observability_summary"]
      return human_run_lifecycle_result(result) if result["run_lifecycle"]

      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = result["blocking_issues"] || []
      [
        "Current phase: #{result["current_phase"] || "n/a"}",
        "Action taken: #{result["action_taken"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

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

    def human_intent_result(result)
      intent = result.fetch("intent")
      lines = [
        "Intent route",
        "- Archetype: #{intent.fetch("archetype")}",
        "- Surface: #{intent.fetch("surface")}",
        "- Recommended skill: #{intent.fetch("recommended_skill")}",
        "- Recommended design system: #{intent.fetch("recommended_design_system")}",
        "- Recommended profile: #{intent.fetch("recommended_profile")}",
        "- Framework: #{intent.fetch("framework")}",
        "- Safety sensitive: #{intent.fetch("safety_sensitive")}",
        "- Style keywords: #{intent.fetch("style_keywords").join(", ")}",
        "- Forbidden design patterns: #{intent.fetch("forbidden_design_patterns").join("; ")}"
      ]
      lines.join("\n")
    end

    def human_supabase_secret_qa_result(result)
      qa = result.fetch("supabase_secret_qa")
      blockers = qa["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[artifact_path planned_artifact_path].each do |key|
        value = qa[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Supabase secret QA: #{qa["status"] || "n/a"}",
        "Dry run: #{qa.key?("dry_run") ? qa["dry_run"] : "n/a"}",
        "Read .env: #{qa.key?("read_dot_env") ? qa["read_dot_env"] : false}",
        "Scanned paths: #{Array(qa["scanned_paths"]).empty? ? "none" : Array(qa["scanned_paths"]).join(", ")}",
        "Artifacts: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_supabase_local_verify_result(result)
      verify = result.fetch("supabase_local_verify")
      blockers = verify["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[artifact_path planned_artifact_path].each do |key|
        value = verify[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Supabase local verify: #{verify["status"] || "n/a"}",
        "Dry run: #{verify.key?("dry_run") ? verify["dry_run"] : "n/a"}",
        "Read .env: #{verify.key?("read_dot_env") ? verify["read_dot_env"] : false}",
        "External actions performed: #{verify.key?("external_actions_performed") ? verify["external_actions_performed"] : false}",
        "Scanned paths: #{Array(verify["scanned_paths"]).empty? ? "none" : Array(verify["scanned_paths"]).join(", ")}",
        "Artifacts: #{paths.empty? ? "none" : paths.join(", ")}",
        "Findings: #{Array(verify["findings"]).empty? ? "none" : Array(verify["findings"]).map { |finding| finding["message"] || finding.to_s }.join("; ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_setup_result(result)
      setup = result.fetch("setup")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = setup["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[run_dir stdout_path stderr_path metadata_path setup_json_path planned_run_dir planned_stdout_path planned_stderr_path planned_metadata_path planned_setup_json_path].each do |key|
        value = setup[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Setup install: #{setup["status"] || "n/a"}",
        "Package manager: #{setup["package_manager"] || "n/a"}",
        "Dry run: #{setup.key?("dry_run") ? setup["dry_run"] : "n/a"}",
        "Approved: #{setup.key?("approved") ? setup["approved"] : "n/a"}",
        "Command: #{setup["command"] || setup["planned_command"] || "n/a"}",
        "Lifecycle scripts: #{Array(setup["lifecycle_scripts"] || setup["lifecycle_script_warnings"]).empty? ? "none" : Array(setup["lifecycle_scripts"] || setup["lifecycle_script_warnings"]).join(", ")}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Setup paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_qa_screenshot_result(result)
      qa = result.fetch("screenshot_qa")
      blockers = qa["blocking_issues"] || result["blocking_issues"] || []
      screenshots = qa["screenshots"] || qa["screenshot_paths"] || []
      artifacts = []
      %w[metadata_path result_path run_dir stdout_log stderr_log].each do |key|
        value = qa[key]
        artifacts << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Screenshot QA: #{qa["status"] || "n/a"}",
        "Target URL: #{qa["url"] || qa.dig("target", "url") || "n/a"}",
        "Screenshots: #{Array(screenshots).empty? ? "none" : Array(screenshots).join(", ")}",
        "Artifacts: #{artifacts.empty? ? "none" : artifacts.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_visual_critique_result(result)
      critique = result.fetch("visual_critique")
      scores = critique["scores"] || {}
      score_line = if scores.empty?
        "Scores: n/a"
      else
        ordered = %w[first_impression hierarchy typography layout_rhythm spacing color originality mobile_polish brand_fit intent_fit content_credibility interaction_clarity]
        "Scores: " + ordered.select { |key| scores.key?(key) }.map { |key| "#{key}=#{scores[key]}" }.join(", ")
      end
      issues = critique["issues"] || []
      plan = critique["patch_plan"] || []
      paths = []
      %w[artifact_path planned_artifact_path screenshot metadata].each do |key|
        value = critique[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Visual critique: #{critique["status"] || "n/a"}",
        "Approval: #{critique["approval"] || "n/a"}",
        score_line,
        "Evidence: #{paths.empty? ? "none" : paths.join(", ")}",
        "Issues: #{issues.empty? ? "none" : issues.join("; ")}",
        "Patch plan: #{plan.empty? ? "none" : plan.join("; ")}",
        "Blocking issues: #{(result["blocking_issues"] || critique["blocking_issues"] || []).empty? ? "none" : (result["blocking_issues"] || critique["blocking_issues"]).join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_visual_polish_result(result)
      polish = result.fetch("visual_polish")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = polish["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[polish_record_path visual_polish_record_path record_path snapshot_path pre_polish_snapshot polish_task_path task_path planned_polish_record_path planned_visual_polish_record_path planned_record_path planned_snapshot_path planned_polish_task_path planned_task_path].each do |key|
        value = polish[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Visual polish: #{polish["status"] || "n/a"}",
        "Mode: #{polish["mode"] || (polish["repair"] ? "repair" : "n/a")}",
        "Critique source: #{polish["critique_source"] || polish["from_critique"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Polish paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_workbench_result(result)
      workbench = result.fetch("workbench")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = workbench["blocking_issues"] || result["blocking_issues"] || []
      panels = Array(workbench["panels"])
      controls = Array(workbench["controls"])
      paths = []
      %w[index_path manifest_path planned_index_path planned_manifest_path].each do |key|
        value = workbench[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      if workbench["paths"].is_a?(Hash)
        workbench["paths"].each do |key, value|
          paths << "#{key}=#{value}" unless value.to_s.empty?
        end
      end
      serve = workbench["serve"].is_a?(Hash) ? workbench["serve"] : {}
      [
        "Workbench status: #{workbench["status"] || "n/a"}",
        "Dry run: #{workbench.key?("dry_run") ? workbench["dry_run"] : "n/a"}",
        "Serve URL: #{serve["url"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Workbench paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Panels: #{panels.empty? ? "none" : panels.join(", ")}",
        "Controls: #{controls.empty? ? "none" : controls.map { |control| control.is_a?(Hash) ? control["command"] || control["id"] : control }.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_component_map_result(result)
      map = result.fetch("component_map")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = map["blocking_issues"] || result["blocking_issues"] || []
      path = map["artifact_path"] || map["planned_artifact_path"] || result["artifact_path"]
      components = Array(map["components"])
      [
        "Component map: #{map["status"] || "n/a"}",
        "Dry run: #{map.key?("dry_run") ? map["dry_run"] : "n/a"}",
        "Artifact: #{path || "n/a"}",
        "Components: #{components.length}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_visual_edit_result(result)
      edit = result.fetch("visual_edit")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = edit["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[task_path record_path planned_task_path planned_record_path visual_edit_record_path planned_visual_edit_record_path].each do |key|
        value = edit[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Visual edit: #{edit["status"] || "n/a"}",
        "Target: #{edit["target"] || edit.dig("target_mapping", "data_aiweb_id") || "n/a"}",
        "Map source: #{edit["map_source"] || edit["from_map"] || "latest"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Visual edit paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_repair_result(result)
      loop = result.fetch("repair_loop")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = loop["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[repair_record_path snapshot_path fix_task_path planned_repair_record_path planned_snapshot_path planned_fix_task_path].each do |key|
        value = loop[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Repair loop: #{loop["status"] || "n/a"}",
        "QA source: #{loop["qa_source"] || loop["from_qa"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Repair paths: #{paths.empty? ? "none" : paths.join(", ")}",
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

    def human_agent_run_result(result)
      agent_run = result.fetch("agent_run")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = agent_run["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[run_dir stdout_path stderr_path metadata_path diff_path planned_run_dir planned_stdout_path planned_stderr_path planned_metadata_path planned_diff_path].each do |key|
        value = agent_run[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Agent run: #{agent_run["status"] || "n/a"}",
        "Task: #{agent_run["task"] || "n/a"}",
        "Agent: #{agent_run["agent"] || "n/a"}",
        "Dry run: #{agent_run.key?("dry_run") ? agent_run["dry_run"] : "n/a"}",
        "Approved: #{agent_run.key?("approved") ? agent_run["approved"] : "n/a"}",
        "Command: #{agent_run["command"] || "n/a"}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Agent run paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_eval_baseline_result(result)
      baseline = result.fetch("eval_baseline")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = baseline["blocking_issues"] || result["blocking_issues"] || []
      paths = []
      %w[source_path target_path validation_path review_pack_path planned_target_path planned_validation_path planned_review_pack_path candidate_path].each do |key|
        value = baseline[key]
        paths << "#{key}=#{value}" unless value.to_s.empty?
      end
      [
        "Eval baseline: #{baseline["status"] || "n/a"}",
        "Action: #{baseline["action"] || "n/a"}",
        "Dry run: #{baseline.key?("dry_run") ? baseline["dry_run"] : "n/a"}",
        "Approved: #{baseline.key?("approved") ? baseline["approved"] : "n/a"}",
        "Fixtures checked: #{baseline["fixture_count"] || 0}",
        "Calibrated fixtures: #{baseline["calibrated_fixture_count"] || 0}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Paths: #{paths.empty? ? "none" : paths.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_verify_loop_result(result)
      loop = result.fetch("verify_loop")
      changed = result["changed_files"] || result["artifacts_changed"] || []
      blockers = loop["blocking_issues"] || result["blocking_issues"] || []
      steps = Array(loop["planned_steps"]).empty? ? Array(loop["cycles"]).flat_map { |cycle| Array(cycle["steps"]).map { |step| step["name"] } }.uniq : Array(loop["planned_steps"]).flat_map { |cycle| cycle["steps"] }.uniq
      [
        "Verify loop: #{loop["status"] || "n/a"}",
        "Max cycles: #{loop["max_cycles"] || "n/a"}",
        "Cycles run: #{loop["cycle_count"] || 0}",
        "Dry run: #{loop.key?("dry_run") ? loop["dry_run"] : "n/a"}",
        "Approved: #{loop.key?("approved") ? loop["approved"] : "n/a"}",
        "Metadata: #{loop["metadata_path"] || "n/a"}",
        "Run dir: #{loop["run_dir"] || "n/a"}",
        "Steps: #{steps.empty? ? "none" : steps.join(", ")}",
        "Artifacts changed: #{changed.empty? ? "none" : changed.join(", ")}",
        "Blocking issues: #{blockers.empty? ? "none" : blockers.join("; ")}",
        "Next command: #{result["next_action"] || "n/a"}"
      ].join("\n")
    end

    def human_registry_result(result)
      registry_payload = result.fetch("registry")
      items = registry_payload.fetch("items")
      lines = ["#{registry_payload.fetch("label")} (#{registry_payload.fetch("count")})"]
      unless registry_payload.fetch("exists")
        lines << "Directory not found: #{registry_payload.fetch("directory")}/"
      end
      if items.empty?
        lines << "No #{registry_payload.fetch("singular")} entries found."
      else
        items.each do |item|
          description = item["description"].to_s.empty? ? "" : " — #{item["description"]}"
          lines << "- #{item["id"]}: #{item["title"]} (#{item["path"]})#{description}"
        end
      end
      validation_errors = result["validation_errors"] || []
      warnings = result["warnings"] || []
      lines << "Validation errors: #{validation_errors.join("; ")}" unless validation_errors.empty?
      lines << "Warnings: #{warnings.join("; ")}" unless warnings.empty?
      lines.join("\n")
    end
    end
  end
end
