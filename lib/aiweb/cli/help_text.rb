# frozen_string_literal: true

module Aiweb
  class CLI
    module HelpText
      TEXT = <<~HELP
        aiweb — AI Web Director CLI

        Commands:
          start [--path PATH] --idea "..." [--profile A|B|C|D|S] [--no-advance]
          init [--profile A|B|C|D|S]
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
          agent "..." [--mode plan-only|supervised|autonomous-local] [--profile D|S] [--max-steps N] [--approved] [--dry-run]
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
          runtime-plan/scaffold-status: read-only profile-aware runtime readiness metadata; Profile D reports build/preview/browser QA readiness and Profile S reports local-only Supabase verification readiness without installing or launching Node
          run-status/run-cancel/run-resume: local run lifecycle control plane backed by .ai-web/runs/active-run.json plus per-run lifecycle/cancel/resume descriptors; status is read-only, cancel/resume support --dry-run no-write planning, cancellation is observed at lifecycle checkpoints, and resume records a descriptor without launching provider or agent commands
          engine-run: Manus-style engine-first task runtime; --dry-run writes nothing and returns a capability envelope, planned run artifacts, event/checkpoint paths, and approval hash; approved agentic_local runs stage a filtered sandbox workspace, let codex/openmanus/experimental OpenHands/LangGraph/OpenAI Agents SDK work there, run local verification where available, then copy back only validated safe source changes while network/install/deploy/provider CLI/git push remain elevated-approval actions
          engine-scheduler: project-local durable graph scheduler service surface; status is read-only, tick records .ai-web/runs/<run-id>/artifacts/scheduler-service.json plus .ai-web/scheduler/ledger.jsonl, daemon records .ai-web/scheduler/daemon.json plus heartbeat/worker-pool artifacts for a foreground loop, supervisor records .ai-web/scheduler/supervisor.json with external service-unit/runbook templates but does not install OS services, monitor records .ai-web/scheduler/monitor.json health evidence over heartbeat/leases/queue/worker-pool artifacts, and --execute resumes through the explicit engine-run bridge only with --approved
          mcp-broker: approved implementation-worker MCP connector broker for Lazyweb health/search plus project_files metadata/list/bounded-excerpt/bounded-literal-search only; --dry-run writes nothing, unapproved calls write deny/block audit evidence only, unknown connectors record a missing-driver fail-closed contract, approved Lazyweb calls require configured credentials, approved project_files calls use no credentials/network and return metadata or safe bounded excerpts/search matches only, redact endpoint/token/output, and record .ai-web/runs/mcp-broker-*/mcp-broker.json plus side-effect-broker.jsonl
          eval-baseline: creates human review packs and validates/imports a human-calibrated eval baseline corpus under .ai-web/eval; review-pack writes placeholders only, validate records redacted validation evidence only, import requires --approved, rejects .env/.env.* paths, raw secrets, invalid 0..100 scores, and non-human-calibrated corpora, and never fabricates reviewer evidence
          run-timeline/observability-summary: read-only timeline and compact observability rollups over safe .ai-web/runs JSON evidence; caps --limit at 50, redacts secret-like keys and .env paths, writes nothing, and launches no processes
          build: runs the scaffolded Astro build for Profile D only after runtime-plan is ready and records .ai-web/runs logs; Profile S remains local-verify-only until safe placeholder-env build support is explicitly implemented
          preview: starts/stops the local scaffold dev server after runtime-plan is ready; --dry-run does not write files or launch Node
          agent: goal-driven supervised local web-building loop facade over AgentRuntime; plan-only/dry-run writes no source, supervised runs local checks only when --approved is supplied, autonomous-local may run bounded local build/preview/browser QA, and source mutation remains manifest/verifier gated
          agent-run: advanced bounded safe execution slot for approved local source-patch task packets used by repair / visual-polish / visual-edit evidence with logs and diff artifacts; --agent supports codex or openmanus; OpenManus approved runs require --sandbox docker|podman; --dry-run does not write files or launch a process
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
  end
end
