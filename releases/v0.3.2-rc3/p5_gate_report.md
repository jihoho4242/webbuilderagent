# webbuilderagent v0.3.2-rc3 P5 Evidence Report

Status: evidence-backed rc candidate; production readiness is not claimed.

## What improved since rc2

- GitHub Actions workflow migrated to Node 24-compatible official actions: `actions/checkout@v5`, `actions/upload-artifact@v6`, and Profile D `actions/setup-node@v5` with Node 24.
- Added CI job `profile-d-e2e-smoke` for real Profile D pnpm/Astro build, localhost preview, and Playwright QA.
- Local Profile D E2E smoke passed with pnpm 11.0.9, build `passed`, and Playwright QA `passed`.
- Eval packs now include holdout seed cases: total 240, holdout 90, failures 0.
- Red-team now includes holdout attack catalog: total 22, holdout 12, critical/high bypass 0.

## CI evidence

Baseline green CI before this rc3 commit: run `26713769331` / `success` / https://github.com/jihoho4242/webbuilderagent/actions/runs/26713769331.

The post-push rc3 CI run cannot be embedded in this commit without creating a self-referential evidence loop. It must be reported as external GitHub Actions evidence after push.

## Known gaps

- Production readiness remains blocked.
- Holdout eval/red-team sets are repo-local seed holdouts, not sealed third-party holdouts.
- Human operator drill and independent adversarial review remain required for a production-ready claim.
