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
- Expose the PR21 local screenshot evidence contract through `aiweb qa-screenshot` / `웹빌더 qa-screenshot`: it captures safe local screenshot evidence for mobile/tablet/desktop from an explicit localhost/127.0.0.1 preview URL, writes `.ai-web/qa/screenshots/*-home.png` plus `metadata.json` and run/result evidence, supports no-write/no-process `--dry-run`, feeds `visual-critique --from-screenshots latest`, and never installs packages, starts preview, auto-repairs, deploys, contacts external hosts, or reads `.env` / `.env.*`.
- Expose safe accessibility and Lighthouse QA contracts through `aiweb qa-a11y` / `웹빌더 qa-a11y` and `aiweb qa-lighthouse` / `웹빌더 qa-lighthouse`: they follow the same local-preview, no-install, no-repair, no-deploy safety model while requiring already-installed project-local `axe` or `lighthouse` executables.
- Expose the PR13 safe local repair-loop contract through `aiweb repair` / `웹빌더 repair`: it consumes failed/blocked QA evidence into a bounded `repair_loop` record, pre-repair snapshot, and fix task without installing packages, starting preview, running build/QA, auto-patching source, touching `.env`, deploying, or contacting external hosting.
- Expose the PR14 safe local visual critique contract through `aiweb visual-critique` / `웹빌더 visual-critique`: it evaluates explicit local screenshot/metadata evidence only, produces deterministic score/approval artifacts under `.ai-web/visual`, supports no-write `--dry-run`, rejects `.env` / `.env.*` paths without reading them, and never launches browsers, captures screenshots, installs packages, auto-repairs source, deploys, contacts external hosting, or calls network/AI services.
- Expose the PR15 safe local visual polish contract through `aiweb visual-polish --repair` / `웹빌더 visual-polish --repair`: it consumes failed, `repair`, or `redesign` visual critique evidence into a bounded `visual_polish` record, pre-polish snapshot, and polish task without editing source, installing packages, starting preview, running build/QA, capturing screenshots, touching `.env`, deploying, contacting external hosting, or calling network/AI services.
- Expose the PR22 local source-patch agent-run contract through `aiweb agent-run` / `웹빌더 agent-run`: it requires an explicit task and agent, supports `--dry-run` without writes or processes, requires `--approved` for real execution, captures stdout/stderr/diff evidence under `.ai-web`, rejects `.env` / `.env.*` access, and does not run build/preview/QA/deploy, provider CLI, or treat `--force` as approval.
- Expose the PR23 local verify-loop contract through `aiweb verify-loop` / `웹빌더 verify-loop`: it connects build → preview → Playwright/accessibility/Lighthouse/screenshot QA → visual critique → repair or visual-polish task → approved agent-run cycles, supports no-write/no-process `--dry-run`, requires `--approved` for real local execution, records `.ai-web/runs/verify-loop-<timestamp>/verify-loop.json` plus per-cycle evidence, blocks missing dependencies with a `setup --install --approved` next action, and never installs packages, deploys, calls provider CLIs, or reads `.env` / `.env.*`.
- Expose the PR16 local Workbench UI foundation through `aiweb workbench` / `웹빌더 workbench`: it plans or exports `.ai-web/workbench/index.html` and `.ai-web/workbench/workbench.json` from existing Director state/artifacts, represents controls as declarative CLI command descriptors, supports no-write `--dry-run`, excludes `.env` / `.env.*` from surfaced artifacts, and never directly mutates `.ai-web/state.yaml`.
- Expose the PR17 Component Map + Visual Edit planning foundation through `aiweb component-map` / `웹빌더 component-map` and `aiweb visual-edit` / `웹빌더 visual-edit`: it maps stable `data-aiweb-id` DOM regions to source files in `.ai-web/component-map.json`, creates selected-region visual edit handoff artifacts under `.ai-web/tasks/` and `.ai-web/visual/`, supports no-write `--dry-run`, rejects `.env` / `.env.*` map paths without reading them, and never auto-patches source, runs build/QA/browser/preview, deploys, installs packages, or calls network/AI services.
- Expose the PR18 Profile S local scaffold and Supabase secret QA surface through `aiweb scaffold --profile S` / `웹빌더 scaffold --profile S` and `aiweb supabase-secret-qa` / `웹빌더 supabase-secret-qa`: Profile S is a local-only Next.js + Supabase SSR placeholder scaffold, uses `supabase/env.example.template` instead of `.env.example`, includes only `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` placeholders, and intentionally performs no external Supabase project creation, network calls, deploy, install, build, or preview.
- Expose the PR19 GitHub sync and deploy planning surfaces through `aiweb github-sync`, `aiweb deploy-plan`, and `aiweb deploy --target cloudflare-pages|vercel --dry-run` / matching `웹빌더` commands: they are local-only planning commands that never run `git push`, provider CLIs, external deploys, network calls, build/preview/install, or read `.env` / `.env.*`; unsafe real deploy attempts are blocked.
- Expose the PR20 approved dependency setup surface through `aiweb setup --install --approved` / `웹빌더 setup --install --approved`: `--dry-run` writes nothing and reports the planned install/log paths; a real install requires `--approved`, records stdout/stderr/setup metadata under `.ai-web/runs/setup-<timestamp>/`, warns about package lifecycle scripts, updates only safe setup state, and never builds, previews, runs QA, repairs, deploys, calls provider CLIs, or reads/prints `.env` / `.env.*`.
- Expose the local backend bridge through `aiweb daemon` / `aiweb backend`: it binds only to localhost-class hosts by default, allows only local browser origins, requires `X-Aiweb-Token` for every `/api/*` request, exposes JSON endpoints for the future web Workbench, invokes this repository's `bin/aiweb` by absolute path instead of shell interpolation, keeps approved Codex/setup execution behind `X-Aiweb-Approval-Token`, and blocks raw shell, frontend-supplied backend flags, missing project paths, unsafe deploy, and `.env` / `.env.*` paths.

## Upgrade direction

The intended product direction is a design-first, natural-language webbuilder: turn a plain-language command into clean, high-quality web output.

1. Describe the business or service website in natural language.
2. Generate and compare premium, design-first candidates.
3. Preview the selected direction in a browser.
4. Run automated browser QA against visual, content, accessibility, and interaction expectations.
5. Convert failed/blocked QA evidence into bounded local repair tasks and records.
6. Review deterministic visual critique scores/patch plans from local evidence before repair decisions.
7. Convert failed visual critique evidence into bounded local visual polish tasks and records.
8. Review the local Workbench UI panels for chat, artifacts, design, preview, file tree, QA, critique, and run timeline status.
9. Select a mapped `data-aiweb-id` region and create a bounded visual edit handoff instead of regenerating the full page.
10. For Supabase-backed work, scaffold Profile S locally with safe SSR placeholders and rerun `supabase-secret-qa` before copying values into a private local env file outside the generator guardrail.
11. Review local-only GitHub sync and Cloudflare Pages/Vercel deploy dry-run plans before any separately approved external release work.
12. Run `setup --install --dry-run` to inspect the planned dependency install, then `setup --install --approved` only when you explicitly approve local package installation.
13. Repair implementation manually or through later approved automation, then deploy later once gates pass and evidence is recorded.

The current Director CLI is the foundation for that loop: state, gates, QA contracts, snapshots, local preview evidence, bounded repair-loop records, visual polish records/tasks/snapshots, component maps, targeted visual edit handoff records, and local-only Profile S Supabase scaffold/secret-QA records are in place before the system grows into end-to-end generation, source repair automation, and deploy. It is not yet a full app generator.

The intended product surface is now a browser Workbench, not terminal UX. Until a frontend exists, `aiweb daemon --dry-run --json` exposes the backend/API contract that the frontend should call later. The daemon keeps the Ruby Director engine as the backend source of truth and uses a guarded Codex CLI bridge only through approved `agent-run` jobs.

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

After the scaffold runtime plan reports `ready`, PR20 can install project dependencies with explicit approval:

```bash
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site setup --install --dry-run
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site setup --install --approved
웹빌더 --path ~/Desktop/aiweb-premium-service-site setup --install --approved
```

`setup --install --dry-run` is a no-write/no-process preflight: it reports the planned `pnpm install` command and `.ai-web/runs/setup-<timestamp>/stdout.log`, `stderr.log`, and `setup.json` paths. Omitting both `--dry-run` and `--approved` is blocked and writes nothing. A real approved setup run supports the local `pnpm` install path, records stdout/stderr/setup metadata under `.ai-web/runs/setup-<timestamp>/`, reports lifecycle-script warnings from `package.json`, updates safe setup state such as latest run/package manager/node_modules presence, and intentionally does not build, preview, run QA, repair, deploy, call provider CLIs, or read/print `.env` / `.env.*`.

Local backend bridge for the future web Workbench:

```bash
./bin/aiweb daemon --host 127.0.0.1 --port 4242 --dry-run --json
AIWEB_DAEMON_TOKEN="$(ruby -rsecurerandom -e 'print SecureRandom.hex(24)')" \
  ./bin/aiweb daemon --host 127.0.0.1 --port 4242
```

`daemon --dry-run` writes nothing and reports the local API contract. A real daemon exposes `GET /health`, `GET /api/engine`, `GET /api/project/status`, `GET /api/project/workbench`, `GET /api/project/runs`, `POST /api/project/command`, and `POST /api/codex/agent-run`. The frontend must send structured JSON only; the daemon never accepts raw shell commands, rejects non-local `Origin` headers, requires `X-Aiweb-Token` for every `/api/*` request, requires an explicit project `path` for project/Codex operations, rejects `.env` / `.env.*` paths, owns backend flags (`--path`, `--json`, `--dry-run`, `--approved`), calls this repository's `bin/aiweb` by absolute path, serializes command execution, caps request bodies at 1 MiB, limits request/header reads, times out long bridge commands, redacts secret-looking run summary values, and keeps real Codex source patching behind both `agent-run --approved` and a matching `X-Aiweb-Approval-Token` header.

If `AIWEB_DAEMON_TOKEN` is omitted, the real daemon generates and prints a one-session local token. The future frontend should store that token only in local session state and send it as `X-Aiweb-Token`. For any future frontend control that sets `"approved": true`, either reuse the same token or set a stronger `AIWEB_DAEMON_APPROVAL_TOKEN` and send it as `X-Aiweb-Approval-Token`:

```bash
AIWEB_DAEMON_TOKEN="$(ruby -rsecurerandom -e 'print SecureRandom.hex(24)')" \
AIWEB_DAEMON_APPROVAL_TOKEN="$(ruby -rsecurerandom -e 'print SecureRandom.hex(24)')" \
  ./bin/aiweb daemon --host 127.0.0.1 --port 4242
```

After dependencies are present, PR9 adds the build contract:

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
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site qa-screenshot --url http://127.0.0.1:4321 --dry-run --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site qa-a11y --url http://127.0.0.1:4321 --dry-run --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site qa-lighthouse --url http://127.0.0.1:4321 --dry-run --json
웹빌더 --path ~/Desktop/aiweb-premium-service-site qa-playwright --url http://127.0.0.1:4321
웹빌더 --path ~/Desktop/aiweb-premium-service-site qa-screenshot --url http://127.0.0.1:4321
웹빌더 --path ~/Desktop/aiweb-premium-service-site qa-a11y --url http://127.0.0.1:4321
웹빌더 --path ~/Desktop/aiweb-premium-service-site qa-lighthouse --url http://127.0.0.1:4321
```

`qa-playwright --dry-run`, `qa-screenshot --dry-run`, `qa-a11y --dry-run`, and `qa-lighthouse --dry-run` are planning paths only: they must not create run artifacts, start processes, install packages, touch `.env`, or invoke local QA tools. A real QA run uses the explicit localhost/127.0.0.1 `--url` when provided, otherwise the recorded running preview URL. `qa-screenshot` captures safe local screenshot evidence for mobile, tablet, and desktop home-route screenshots into `.ai-web/qa/screenshots/mobile-home.png`, `tablet-home.png`, `desktop-home.png`, and `metadata.json`, plus run/result evidence for later critique. It uses only local Playwright tooling already present in the project. Playwright runs only after `node_modules/.bin/playwright` exists; accessibility QA requires `node_modules/.bin/axe`; Lighthouse QA requires `node_modules/.bin/lighthouse`. Each command records stdout/stderr/tool metadata under `.ai-web/runs/<tool>-qa-*`, writes a schema-compatible QA result under `.ai-web/qa/results/`, and returns deterministic `blocked`, `failed`, or `passed` status in its JSON payload (`playwright_qa`, `screenshot_qa`, `a11y_qa`, or `lighthouse_qa`). Missing runtime readiness, missing preview/URL, missing `pnpm`, or missing local tooling is reported as blocked; these QA commands do not install dependencies, start/stop preview, auto-repair, deploy, or contact external hosting beyond the local preview URL.

PR13 adds the safe local repair-loop command as a follow-up to failed or blocked QA:

```bash
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site repair --from-qa latest --dry-run --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site repair --from-qa .ai-web/qa/results/qa-example.json --max-cycles 2 --json
웹빌더 --path ~/Desktop/aiweb-premium-service-site repair --from-qa latest --dry-run
```

`repair --from-qa latest` reads `state.qa.last_result`; an explicit `--from-qa` must point to a QA result JSON and rejects `.env` / `.env.*` paths without reading them. The command is phase-guarded for phase-7 through phase-11 unless `--force` is supplied. If the QA result is not failed, blocked, or timed out, or if the same QA task/source has exceeded `--max-cycles`, it returns a deterministic `repair_loop.status: blocked` and writes nothing. `repair --dry-run` writes nothing, copies no snapshot, starts no process, and reports the planned snapshot, repair record, and fix-task paths. A real repair loop creates a pre-repair snapshot under `.ai-web/snapshots/`, creates or reuses a fix task under `.ai-web/tasks/`, writes `.ai-web/repairs/*.json`, updates `implementation.current_task`, and records a decision. PR13 repair intentionally does not install packages, start/stop preview, run build, run Playwright/axe/Lighthouse, edit source files, auto-patch, deploy, push, or contact external hosting.

PR14 adds the safe local visual critique command as a local-evidence review step:

```bash
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site visual-critique --from-screenshots latest --dry-run --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site visual-critique --screenshot ./evidence/home.png --dry-run --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site visual-critique --screenshot ./evidence/home.png --metadata ./evidence/home.json --task-id golden-page --json
웹빌더 --path ~/Desktop/aiweb-premium-service-site visual-critique --screenshot ./evidence/home.png --metadata ./evidence/home.json
```

`visual-critique` accepts explicit local evidence paths or `--from-screenshots latest`; this PR does not launch a browser, take screenshots, call AI/network services, install packages, start/stop preview, deploy, auto-repair, or touch `.env`. `visual-critique --dry-run` writes nothing and reports the planned `.ai-web/visual/` artifact path. A real run records a schema-versioned `visual_critique` payload with numeric scores for hierarchy, typography, spacing, color, originality, mobile polish, brand fit, and intent fit, plus issues, a patch plan, and an approval of `pass`, `repair`, or `redesign`. Low-score `repair` or `redesign` approvals intentionally return a non-success exit code so shell automation cannot treat visual quality failures as passing.

PR15 adds the safe local visual polish repair-loop command as a follow-up to failed, `repair`, or `redesign` visual critique evidence:

```bash
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site visual-polish --repair --from-critique latest --dry-run --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site visual-polish --repair --from-critique .ai-web/visual/visual-critique-example.json --max-cycles 2 --json
웹빌더 --path ~/Desktop/aiweb-premium-service-site visual-polish --repair --from-critique latest --dry-run
```

`visual-polish --repair --from-critique latest` reads the latest visual critique recorded in `state.visual.latest_critique` or `state.qa.latest_visual_critique`; an explicit `--from-critique` must point to a visual critique JSON and rejects `.env` / `.env.*` paths without reading them. The command is phase-guarded for phase-7 through phase-11 unless `--force` is supplied. If the visual critique already passed, or if the same critique source has exceeded `--max-cycles`, it returns a deterministic `visual_polish.status: blocked` and writes nothing. `visual-polish --repair --dry-run` writes nothing, copies no snapshot, starts no process, and reports the planned snapshot, polish record, and polish-task paths. A real visual polish loop creates a pre-polish snapshot under `.ai-web/snapshots/`, creates or reuses a polish task under `.ai-web/tasks/`, writes `.ai-web/visual/polish-*.json`, updates `visual.latest_polish` and `implementation.current_task`, and records a decision. PR15 visual polish intentionally does not edit source files, auto-patch, install packages, start/stop preview, run build, run Playwright/axe/Lighthouse, capture screenshots, deploy, push, contact external hosting, call network/AI services, or touch `.env`.

PR16 adds the local Workbench UI foundation as a static artifact export:

```bash
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site workbench --dry-run
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site workbench --export --json
웹빌더 --path ~/Desktop/aiweb-premium-service-site workbench --dry-run
웹빌더 --path ~/Desktop/aiweb-premium-service-site workbench --export
```

`workbench --dry-run` is a no-write planning path: it reports `workbench.status: planned`, the panel list, declarative control descriptors, and planned `.ai-web/workbench/index.html` / `.ai-web/workbench/workbench.json` paths without creating files or changing `.ai-web/state.yaml`. A real `workbench --export` may write only the Workbench HTML and JSON manifest under `.ai-web/workbench/`; it summarizes existing Director artifacts for panels such as chat, plan/artifacts, design candidates, selected `DESIGN.md`, preview, file tree, QA results, visual critique, and run timeline. Workbench controls are descriptors for existing CLI/daemon commands (`aiweb run`, `aiweb design`, `aiweb build`, `aiweb preview`, `aiweb qa-playwright`, `aiweb visual-critique`, `aiweb repair`, `aiweb visual-polish`, `aiweb component-map`, `aiweb visual-edit --target DATA_AIWEB_ID --prompt TEXT`) and do not directly write state. Export executes no controls, launches no preview/browser/QA/daemon, installs no packages, calls no network/AI services, and writes no files outside `.ai-web/workbench/index.html` and `.ai-web/workbench/workbench.json`. The file tree and summaries intentionally exclude `.env`, `.env.*`, `.git`, `node_modules`, and bulky generated directories so local secrets are not surfaced.

PR18 adds the local-only Profile S Supabase scaffold and secret QA surface:

```bash
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site scaffold --profile S --dry-run
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site scaffold --profile S
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site supabase-secret-qa --dry-run --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site supabase-secret-qa --json
웹빌더 --path ~/Desktop/aiweb-premium-service-site scaffold --profile S --dry-run
웹빌더 --path ~/Desktop/aiweb-premium-service-site supabase-secret-qa --dry-run
```

Profile S is a local scaffold/QA path for Next.js + Supabase SSR placeholders. It writes a safe non-dot template at `supabase/env.example.template` and intentionally does **not** generate `.env.example` while the no-`.env` guardrail is active. The only documented public placeholders are `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`; service-role, password, private-key, and other secret placeholders are rejected by the secret QA contract. `supabase-secret-qa --dry-run` writes nothing and must not read `.env` / `.env.*`; a real QA run records its artifact at `.ai-web/qa/supabase-secret-qa.json`. Real Profile S scaffold/QA remains local-only: it does not run `supabase login`, `supabase link`, `supabase projects create`, `supabase init`, `supabase start`, `supabase db push`, package install, build, preview, deploy, external hosting, or other network/project-creation actions.

PR17 adds the local Component Map + Visual Edit planning foundation:

```bash
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site component-map --dry-run
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site component-map --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site visual-edit --target component.hero.copy --prompt "이 섹션 더 고급스럽게" --dry-run --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site visual-edit --target component.hero.copy --prompt "이 섹션 더 고급스럽게" --from-map latest --json
웹빌더 --path ~/Desktop/aiweb-premium-service-site component-map --dry-run
웹빌더 --path ~/Desktop/aiweb-premium-service-site visual-edit --target component.hero.copy --prompt "이 섹션 더 고급스럽게" --dry-run
```

`component-map --dry-run` writes nothing and reports the planned `.ai-web/component-map.json` path plus planned/blocked status. A real `component-map` may write only `.ai-web/component-map.json`, with entries for stable `data_aiweb_id`, source path, kind, route, editability, and safe snippet/line summaries from scaffold/source files. It must not read or surface `.env` / `.env.*`, bulky generated directories, or secret-bearing content.

`visual-edit` requires `--target DATA_AIWEB_ID` and `--prompt TEXT`; `--from-map` defaults to `latest`. The command validates that the selected target exists in the component map and creates only local handoff records such as `.ai-web/tasks/visual-edit-*.md` and `.ai-web/visual/visual-edit-*.json`. It intentionally does not patch source files, run build/QA/browser/preview, install packages, deploy, contact external hosting, call network/AI services, or mutate `.ai-web/state.yaml`. Explicit `.env` / `.env.*` map paths are rejected without reading. `visual-edit --dry-run` writes nothing and reports planned task/record paths so a user request like “이 섹션 더 고급스럽게” stays scoped to the selected region instead of triggering full-page regeneration.

PR19 adds local-only GitHub sync and deploy planning commands:

```bash
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site github-sync --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site deploy-plan --target cloudflare-pages --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site deploy --target cloudflare-pages --dry-run --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site deploy --target vercel --dry-run --json
웹빌더 --path ~/Desktop/aiweb-premium-service-site github-sync
웹빌더 --path ~/Desktop/aiweb-premium-service-site deploy-plan --target vercel
웹빌더 --path ~/Desktop/aiweb-premium-service-site deploy --target vercel --dry-run
```

`github-sync` only reports the intended GitHub sync command shape; it does not run `git push`, contact GitHub, invoke provider CLIs, build, preview, install packages, or read `.env` / `.env.*`. `deploy-plan` only reports the target-specific deploy checklist for `cloudflare-pages` or `vercel`; it performs no provider CLI, network, build, preview, install, or `.env` access. `deploy` intentionally supports only `--target cloudflare-pages|vercel --dry-run`; omitting `--dry-run` returns an unsafe-deploy-blocked result so shell automation cannot accidentally treat a real deploy request as successful.

PR22 adds the local source-patch agent-run surface for repair / visual-polish / visual-edit task packets:

```bash
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site agent-run --task latest --agent codex --dry-run --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site agent-run --task latest --agent codex --approved --json
웹빌더 --path ~/Desktop/aiweb-premium-service-site agent-run --task latest --agent codex --dry-run
웹빌더 --path ~/Desktop/aiweb-premium-service-site agent-run --task latest --agent codex --approved
```

`agent-run --dry-run` is a no-write / no-process preflight: it reports the planned `.ai-web/runs/agent-run-<timestamp>/agent-run.json`, `stdout.log`, `stderr.log`, and `.ai-web/diffs/agent-run-<timestamp>.patch` paths without executing a local agent. A real `agent-run` requires `--approved`; omitting `--approved` blocks execution with approval-required semantics and writes nothing. The command is limited to task packets with safe task/source hints, reads only task/design/component-map/source context that is already allowed by the task packet, refuses `.env` / `.env.*` paths, captures stdout/stderr and a git/source diff patch when it runs, and records the latest run metadata in `.ai-web` safe state. PR22 does not run build/preview/QA/deploy/provider CLIs and does not treat `--force` as approval.

PR23 adds the first approved local closed loop:

```bash
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site verify-loop --max-cycles 3 --dry-run --json
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site verify-loop --max-cycles 3 --approved --json
웹빌더 --path ~/Desktop/aiweb-premium-service-site verify-loop --max-cycles 3 --dry-run
웹빌더 --path ~/Desktop/aiweb-premium-service-site verify-loop --max-cycles 3 --approved
```

`verify-loop --dry-run` writes nothing and launches no processes; it only reports the planned build, preview, QA, screenshot, visual critique, repair/visual-polish, and agent-run cycle evidence paths. A real verify loop requires `--approved`, requires local dependencies to already exist, and blocks with a `setup --install --approved` next action when `node_modules` or local QA tools are missing. It reuses the existing build/preview/QA/screenshot/visual-critique/repair/visual-polish/agent-run adapters, records per-cycle step JSON under `.ai-web/runs/verify-loop-<timestamp>/cycle-N/`, writes the loop summary to `.ai-web/runs/verify-loop-<timestamp>/verify-loop.json`, updates safe implementation state (`latest_verify_loop`, status, cycle count, latest blocker), and stops on pass, max cycles, blocking issue, unsafe action, or agent-run failure. It never installs packages, deploys, pushes, calls provider CLIs, or reads/prints `.env` / `.env.*`.

Phase-sensitive commands are guarded by the Director state machine:

```bash
# Once current phase is phase-3 or phase-3.5
./bin/aiweb design-prompt
./bin/aiweb design-research --provider lazyweb --dry-run

# Once current phase is phase-3.5
./bin/aiweb ingest-design --title "Candidate 1"

# Once current phase is phase-6 through phase-11
./bin/aiweb next-task

# Once current phase is phase-7 through phase-11
./bin/aiweb qa-checklist
./bin/aiweb qa-report --status failed --task-id golden-page --duration-minutes 61
./bin/aiweb repair --from-qa latest --dry-run
./bin/aiweb visual-polish --repair --from-critique latest --dry-run
./bin/aiweb agent-run --task latest --agent codex --dry-run
./bin/aiweb verify-loop --max-cycles 3 --dry-run
./bin/aiweb workbench --dry-run
./bin/aiweb component-map --dry-run
./bin/aiweb visual-edit --target component.hero.copy --prompt "이 섹션 더 고급스럽게" --dry-run
./bin/aiweb agent-run --task latest --agent codex --approved
./bin/aiweb verify-loop --max-cycles 3 --approved
./bin/aiweb github-sync --json
./bin/aiweb deploy-plan --target cloudflare-pages --json
./bin/aiweb deploy --target cloudflare-pages --dry-run --json
./bin/aiweb scaffold --profile S --dry-run
./bin/aiweb supabase-secret-qa --dry-run
```

Lazyweb design research is represented in `.ai-web/state.yaml` as a separate
`research.design_research` contract plus a sibling `adapters.design_research`
adapter. Its default policy is `opportunistic`: use Lazyweb when configured,
otherwise keep the research artifacts missing/skipped without changing the core
webbuilder UX. The planned local outputs are `.ai-web/design-reference-brief.md`,
`.ai-web/research/lazyweb/results.json`, and
`.ai-web/research/lazyweb/pattern-matrix.md`. This is intentionally separate
from the implementation agent: `adapters.implementation_agent.network_allowed`
remains `false` and `mcp_servers_allowed` remains `[]` by default, so source
patching stays local/no-MCP while design phases can consume normalized reference
evidence.

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
./bin/aiweb visual-polish --repair --force --from-critique latest --dry-run
./bin/aiweb workbench --force --export
./bin/aiweb component-map --force
./bin/aiweb visual-edit --target component.hero.copy --prompt "이 섹션 더 고급스럽게" --from-map latest --force
./bin/aiweb scaffold --profile S --force
./bin/aiweb supabase-secret-qa --force
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
