# AI Web Director CLI

This repository currently ships a working **AI Web Director CLI**. It is the baseline orchestration layer for an AI-assisted webbuilding flow, not a full app generator yet.

Today the CLI manages the project director workspace: `.ai-web` state, phase gates, quality approvals, task packets, QA reports, rollback/blocker state, and snapshots. It can guide a web project through planning, design prompt handoff, implementation task sequencing, QA evidence, and recovery decisions. It does **not** currently generate a complete runnable website or application scaffold for you.

## Current scope

- Initialize a Director workspace with `.ai-web` state and templates.
- Move through guarded phases with explicit quality gates.
- Produce design prompts and ingest selected design candidates.
- Emit implementation task packets for later build work.
- Record QA checklists/results and gate advancement on blocking failures.
- Capture snapshots and rollback/blocker recovery evidence.
- Provide a friendly Korean entry point, `웹빌더`, over the lower-level `aiweb` CLI.
- Expose the PR9 Astro build contract through `aiweb build` / `웹빌더 build`: it must check runtime-plan readiness before executing, preserve `.env` untouched, support `--dry-run` without writes/install/build, record run evidence under `.ai-web`, and report missing package manager, missing `node_modules`, or build failure as explicit statuses.
- Expose the PR10 local preview contract through `aiweb preview` / `웹빌더 preview`: it must gate on runtime-plan readiness, preserve `.env` untouched, avoid dependency installation, start only the scaffold dev server locally, record run evidence under `.ai-web`, support a no-write/no-process `--dry-run`, support `--stop` for the recorded preview PID, and explicitly avoid Playwright, axe/Lighthouse, repair, deploy, or external hosting.
- Expose the PR11 safe Playwright browser QA contract through `aiweb qa-playwright` / `웹빌더 qa-playwright`: it must use a running local preview or explicit localhost/127.0.0.1 `--url`, preserve `.env` untouched, never install packages or start preview, require an already-present project-local Playwright executable, record run/QA evidence under `.ai-web`, support no-write/no-process `--dry-run`, and explicitly avoid axe/Lighthouse, automatic repair, deploy, or external hosting.
- Expose safe accessibility and Lighthouse QA contracts through `aiweb qa-a11y` / `웹빌더 qa-a11y` and `aiweb qa-lighthouse` / `웹빌더 qa-lighthouse`: they follow the same local-preview, no-install, no-repair, no-deploy safety model while requiring already-installed project-local `axe` or `lighthouse` executables.
- Expose the PR13 safe local repair-loop contract through `aiweb repair` / `웹빌더 repair`: it consumes failed/blocked QA evidence into a bounded `repair_loop` record, pre-repair snapshot, and fix task without installing packages, starting preview, running build/QA, auto-patching source, touching `.env`, deploying, or contacting external hosting.
- Expose the PR14 safe local visual critique contract through `aiweb visual-critique` / `웹빌더 visual-critique`: it evaluates explicit local screenshot/metadata evidence only, produces deterministic score/approval artifacts under `.ai-web/visual`, supports no-write `--dry-run`, rejects `.env` / `.env.*` paths without reading them, and never launches browsers, captures screenshots, installs packages, auto-repairs source, deploys, contacts external hosting, or calls network/AI services.

## Upgrade direction

The intended product direction is a design-first, natural-language webbuilder: turn a plain-language command into clean, high-quality web output.

1. Describe the business or service website in natural language.
2. Generate and compare premium, design-first candidates.
3. Preview the selected direction in a browser.
4. Run automated browser QA against visual, content, accessibility, and interaction expectations.
5. Convert failed/blocked QA evidence into bounded local repair tasks and records.
6. Review deterministic visual critique scores/patch plans from local evidence before repair decisions.
7. Repair implementation manually or through later approved automation, then deploy later once gates pass and evidence is recorded.

The current Director CLI is the foundation for that loop: state, gates, QA contracts, snapshots, local preview evidence, and bounded repair-loop records are in place before the system grows into end-to-end generation, source repair automation, and deploy. It is not yet a full app generator.

## Quick start

The friendly entry point is `웹빌더`. Run it with no arguments for a zero-start interview:

```bash
웹빌더
```

Or pass the idea directly:

```bash
웹빌더 --path ~/Desktop/aiweb-premium-service-site \
  "프리미엄 비즈니스/서비스 웹사이트. 핵심 가치, 서비스 소개, 고객 사례, 상담 문의 섹션이 있는 고품질 랜딩 사이트."
```

`웹빌더` knows the Director sequence and calls the lower-level `aiweb` engine for you.

Low-level equivalent:

```bash
./bin/aiweb start \
  --path ~/Desktop/aiweb-premium-service-site \
  --idea "프리미엄 비즈니스/서비스 웹사이트. 핵심 가치, 서비스 소개, 고객 사례, 상담 문의 섹션이 있는 고품질 랜딩 사이트."
```

`start` creates the target folder, initializes profile D by default, drafts the first interview artifacts, and advances to the phase-0.25 quality gate.
Use `--path` on later commands to keep working against that generated project:

```bash
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site status
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site advance
```

After the scaffold runtime plan reports `ready`, PR9 adds the build contract:

```bash
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site build --dry-run
웹빌더 --path ~/Desktop/aiweb-premium-service-site build
```

`build --dry-run` is a no-write preflight: it must not install packages or run the build. A real build records metadata/log evidence under `.ai-web`, never reads or writes `.env`, and returns explicit blocked/failed statuses for missing `pnpm`, missing `node_modules`, runtime-plan not-ready, or build command failures.

PR10 adds the local preview contract on the same readiness boundary:

```bash
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site preview --dry-run
웹빌더 --path ~/Desktop/aiweb-premium-service-site preview
웹빌더 --path ~/Desktop/aiweb-premium-service-site preview --stop
```

`preview --dry-run` is no-write and no-process: it reports the planned scaffold dev command, preview URL, and `.ai-web/runs/<run>/` metadata/log paths without installing dependencies or starting a server. A real preview starts only the local scaffold dev server, records PID/port/URL/cwd/command/status plus stdout/stderr logs under `.ai-web`, never reads or writes `.env`, never installs dependencies, and reports explicit blocked statuses for runtime-plan not-ready, missing `pnpm`, missing `node_modules`, or an already-running recorded preview. `preview --stop` may stop only the recorded preview PID. PR10 preview intentionally does not run Playwright, axe/Lighthouse, repair, deploy, or external hosting.

PR11 adds the safe local Playwright QA contract as a separate step:

```bash
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site qa-playwright --dry-run
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site qa-playwright --url http://127.0.0.1:4321 --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site qa-a11y --url http://127.0.0.1:4321 --dry-run --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site qa-lighthouse --url http://127.0.0.1:4321 --dry-run --json
웹빌더 --path ~/Desktop/aiweb-premium-service-site qa-playwright --url http://127.0.0.1:4321
웹빌더 --path ~/Desktop/aiweb-premium-service-site qa-a11y --url http://127.0.0.1:4321
웹빌더 --path ~/Desktop/aiweb-premium-service-site qa-lighthouse --url http://127.0.0.1:4321
```

`qa-playwright --dry-run`, `qa-a11y --dry-run`, and `qa-lighthouse --dry-run` are planning paths only: they must not create run artifacts, start processes, install packages, touch `.env`, or invoke local QA tools. A real QA run uses the explicit localhost/127.0.0.1 `--url` when provided, otherwise the recorded running preview URL. Playwright runs only after `node_modules/.bin/playwright` exists; accessibility QA requires `node_modules/.bin/axe`; Lighthouse QA requires `node_modules/.bin/lighthouse`. Each command records stdout/stderr/tool metadata under `.ai-web/runs/<tool>-qa-*`, writes a schema-compatible QA result under `.ai-web/qa/results/`, and returns deterministic `blocked`, `failed`, or `passed` status in its JSON payload (`playwright_qa`, `a11y_qa`, or `lighthouse_qa`). Missing runtime readiness, missing preview/URL, missing `pnpm`, or missing local tooling is reported as blocked; these QA commands do not install dependencies, start/stop preview, auto-repair, deploy, or contact external hosting beyond the local preview URL.

PR14 adds the safe local visual critique command as a local-evidence review step:

```bash
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site visual-critique --screenshot ./evidence/home.png --dry-run --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site visual-critique --screenshot ./evidence/home.png --metadata ./evidence/home.json --task-id golden-page --json
웹빌더 --path ~/Desktop/aiweb-premium-service-site visual-critique --screenshot ./evidence/home.png --metadata ./evidence/home.json
```

`visual-critique` accepts only explicit local evidence paths; this PR does not launch a browser, take screenshots, call AI/network services, install packages, start/stop preview, deploy, auto-repair, or touch `.env`. `visual-critique --dry-run` writes nothing and reports the planned `.ai-web/visual/` artifact path. A real run records a schema-versioned `visual_critique` payload with numeric scores for hierarchy, typography, spacing, color, originality, mobile polish, brand fit, and intent fit, plus issues, a patch plan, and an approval of `pass`, `repair`, or `redesign`. Low-score `repair` or `redesign` approvals intentionally return a non-success exit code so shell automation cannot treat visual quality failures as passing.

PR13 adds the safe local repair-loop command as a follow-up to failed or blocked QA:

```bash
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site repair --from-qa latest --dry-run --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site repair --from-qa .ai-web/qa/results/qa-example.json --max-cycles 2 --json
웹빌더 --path ~/Desktop/aiweb-premium-service-site repair --from-qa latest --dry-run
```

`repair --from-qa latest` reads `state.qa.last_result`; an explicit `--from-qa` must point to a QA result JSON and rejects `.env` / `.env.*` paths without reading them. The command is phase-guarded for phase-7 through phase-11 unless `--force` is supplied. If the QA result is not failed, blocked, or timed out, or if the same QA task/source has exceeded `--max-cycles`, it returns a deterministic `repair_loop.status: blocked` and writes nothing. `repair --dry-run` writes nothing, copies no snapshot, starts no process, and reports the planned snapshot, repair record, and fix-task paths. A real repair loop creates a pre-repair snapshot under `.ai-web/snapshots/`, creates or reuses a fix task under `.ai-web/tasks/`, writes `.ai-web/repairs/*.json`, updates `implementation.current_task`, and records a decision. PR13 repair intentionally does not install packages, start/stop preview, run build, run Playwright/axe/Lighthouse, edit source files, auto-patch, deploy, push, or contact external hosting.

Phase-sensitive commands are guarded by the Director state machine:

```bash
# Once current phase is phase-3 or phase-3.5
./bin/aiweb design-prompt

# Once current phase is phase-3.5
./bin/aiweb ingest-design --title "Candidate 1"

# Once current phase is phase-6 through phase-11
./bin/aiweb next-task

# Once current phase is phase-7 through phase-11
./bin/aiweb qa-checklist
./bin/aiweb qa-report --status failed --task-id golden-page --duration-minutes 61
./bin/aiweb repair --from-qa latest --dry-run
```

Quality is an explicit contract. After entering phase-0.25, review `.ai-web/quality.yaml` and set `quality.approved: true` before advancing again.

Global flags:

```bash
./bin/aiweb <command> --json
./bin/aiweb <command> --dry-run
```

Manual repair/override for guarded commands:

```bash
./bin/aiweb design-prompt --force
./bin/aiweb ingest-design --force --title "Candidate 1"
./bin/aiweb qa-report --force --status failed --task-id golden-page
./bin/aiweb repair --force --from-qa latest --dry-run
./bin/aiweb visual-critique --force --screenshot ./evidence/home.png --dry-run
```

Rollback leaves the phase blocked until recovery evidence is recorded:

```bash
./bin/aiweb rollback --failure F-QA --reason "QA root cause"
./bin/aiweb resolve-blocker --reason "root cause fixed and evidence recorded"
```

## Verification

Run the CLI test suite locally:

```bash
ruby test/test_aiweb_cli.rb
```

GitHub Actions runs the same test suite against currently supported CRuby branches.
