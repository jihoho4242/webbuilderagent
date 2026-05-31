# WebBuilderAgent v0.3.2-rc2 P5 Gate Report

Status: scaffold_demo_passed

Production readiness claimed: false

Operational readiness: evidence-backed rc candidate; production readiness remains blocked by documented gaps.

Constitution hash: `sha256:87f5f29f48f18135b27b12f940af93e49e9851df23cf0752d45e0ef4bc73d23c`

GitHub Actions: run `26365437613` / `success` / https://github.com/jihoho4242/webbuilderagent/actions/runs/26365437613

## Gate summary

- Local validation: `ruby bin/check` passed on 2026-05-31 after rc2 evidence work and LF normalization (repository text guard, syntax, load smoke, warning load smoke, test suite, and git diff --check; 500 runs, 13182 assertions, 0 failures, 0 errors, 3 skips).
- Remote CI baseline: CI success on 398ceba29ed6a0c52562c448eeffd70fba9ceb47 with Ruby 3.3/3.4/4.0 and engine runtime matrix smoke.
- Profile D smoke: smoke_completed_with_environment_blockers (runtime-plan ready; build blocked by missing pnpm; browser QA blocked by missing local Playwright executable; no forbidden side effect observed).
- Profile S smoke: local_only_smoke_passed (local-only scaffold, secret QA, and Supabase local verify passed; build/preview remain policy-blocked).
- Eval: expanded_fixture_passed (cases=150, failures=0, safety-critical failures=0, tool routing accuracy=1.0).
- Red-team: catalog_fixture_passed (cases=10, critical/high bypass=0).
- Operator drill: local_dry_run_passed (local dry-run only; production ops drill still required before production readiness claim).
- Node 20 Actions warning: observed; tracked as a known CI maintenance gap, not a failing gate.

## Known gaps / non-claims

- Production readiness is not claimed.
- Final evidence commit cannot contain its own future post-push CI run id; post-push CI must be reported as external GitHub Actions evidence after push.
- Profile D build/browser QA need pnpm and local Playwright installation evidence before claiming full E2E pass.
- Production operator drill, independent holdout eval, independent red-team review, and production Brain SQLite evidence remain future gates.

## Evidence files

- `releases/v0.3.2-rc2/ci_evidence.json`
- `releases/v0.3.2-rc2/profile-d-smoke.json`
- `releases/v0.3.2-rc2/profile-s-smoke.json`
- `releases/v0.3.2-rc2/eval_report.json`
- `releases/v0.3.2-rc2/redteam_report.json`
- `releases/v0.3.2-rc2/operator_drill_report.json`
- `releases/v0.3.2-rc2/release_manifest.yaml`
- `releases/v0.3.2-rc2/evidence_integrity_manifest.yaml`
