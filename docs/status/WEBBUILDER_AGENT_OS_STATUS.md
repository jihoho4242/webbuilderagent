# WebBuilderAgent Agent OS Status

Last updated: 2026-05-31

## Current objective

Make `webbuilderagent` an evidence-backed supervised local web-building Agent OS candidate, not a legacy script runner or unproven one-shot website generator.

## Canonical status

- Current release evidence: `releases/v0.3.2-rc3/`
- Canonical runtime: `engine-run`
- User-facing facade: `aiweb agent`
- Safety path for side effects: `DecisionPacket -> PolicyKernel -> ToolGateway`
- Production readiness: **not claimed**
- Current label: **evidence-backed rc candidate / production blocked**

## Completed in rc3

- Migrated GitHub Actions workflow to Node 24-compatible official actions:
  - `actions/checkout@v5`
  - `actions/upload-artifact@v6`
  - Profile D E2E job uses `actions/setup-node@v5` with Node `24`
- Added CI job `profile-d-e2e-smoke`.
- Added `bin/profile-d-e2e-smoke` to run a real Profile D local web loop:
  - Profile D scaffold
  - `pnpm add -D @playwright/test --ignore-scripts`
  - Playwright Chromium install
  - `aiweb build`
  - `aiweb preview`
  - localhost readiness probe
  - `aiweb qa-playwright`
  - preview stop cleanup
- Local Profile D E2E smoke passed:
  - build: passed
  - preview: running then stopped by cleanup
  - Playwright QA: passed
  - `.env` files: none
  - deploy/provider/production side effects: none
- Expanded eval packs with repo-local holdout seed cases:
  - total cases: 240
  - holdout cases: 90
  - failures: 0
  - safety-critical failures: 0
  - holdout tool routing accuracy: 1.0
- Expanded red-team with holdout attack catalog:
  - total cases: 22
  - holdout cases: 12
  - critical/high bypass: 0

## rc3 evidence files

- `releases/v0.3.2-rc3/release_manifest.yaml`
- `releases/v0.3.2-rc3/evidence_integrity_manifest.yaml`
- `releases/v0.3.2-rc3/p5_gate_report.md`
- `releases/v0.3.2-rc3/ci_evidence.json`
- `releases/v0.3.2-rc3/profile-d-e2e-smoke.json`
- `releases/v0.3.2-rc3/profile-d-smoke.json`
- `releases/v0.3.2-rc3/eval_report.json`
- `releases/v0.3.2-rc3/redteam_report.json`
- `releases/v0.3.2-rc3/operator_drill_report.json`

## Previous rc2 baseline

- Post-push CI success: run `26713769331`, conclusion `success`.
- rc2 evidence: `releases/v0.3.2-rc2/`
- rc2 limitation now improved by rc3: Profile D full build/browser QA was previously blocked by missing local `pnpm` and Playwright.

## Local full validation

- `ruby bin/check` passed on 2026-05-31 after rc3 changes.
- Test suite result inside `bin/check`: 501 runs, 13271 assertions, 0 failures, 0 errors, 3 skips.

## Known gaps / non-claims

- The evidence commit cannot contain its own future post-push CI run id without creating a self-referential CI loop; post-push rc3 CI must be reported as external GitHub Actions evidence after push.
- Production readiness remains blocked.
- Holdout eval/red-team sets are repo-local seed holdouts, not sealed third-party holdouts.
- Production operator drill is not claimed; rc3 includes local rc drill evidence only.
- Production Brain SQLite evidence is still blocked by missing `sqlite3` gem in this runtime.

## Next recommended goal

After rc3 post-push CI is green:

1. Add sealed or third-party reviewed eval/red-team holdout evidence.
2. Add production-style operator/rollback drill evidence.
3. Add SQLite-backed Brain evidence or explicitly keep Brain as project-local JSONL MVP.
4. Consider a later rc only after post-push CI artifacts include Profile D E2E smoke evidence.
