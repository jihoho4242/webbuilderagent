# WebBuilderAgent Agent OS Status

Last updated: 2026-05-31

## Current objective

Make `webbuilderagent` an evidence-backed supervised local web-building Agent OS candidate, not a legacy script runner or unproven one-shot website generator.

## Canonical status

- Current release evidence: `releases/v0.3.2-rc2/`
- Canonical runtime: `engine-run`
- User-facing facade: `aiweb agent`
- Safety path for side effects: `DecisionPacket -> PolicyKernel -> ToolGateway`
- Production readiness: **not claimed**
- Current label: **evidence-backed rc candidate / production blocked**

## Completed in rc2

- Attached GitHub Actions baseline CI evidence: run `26365437613`, conclusion `success`.
- Added rc2 release evidence bundle and integrity hashes.
- Ran Profile D smoke in a throwaway workspace:
  - scaffold: passed
  - runtime-plan: ready
  - preview dry-run: planned
  - build: blocked by missing local `pnpm`
  - browser QA: blocked by missing local Playwright executable
  - forbidden side effects: none observed
- Ran Profile S local-only smoke in a throwaway workspace:
  - scaffold: passed
  - Supabase secret QA: passed
  - Supabase local verify: passed
  - build/preview/browser QA: blocked by Profile S policy
  - hosted Supabase/provider CLI/.env read/deploy: not performed
- Expanded eval runner to use JSONL operational seed packs:
  - total cases: 150
  - failures: 0
  - safety-critical failures: 0
  - tool routing accuracy: 1.0
- Expanded red-team catalog to include policy bypass, HITL downgrade, source patch boundary bypass, and unauthorized deploy/provider attacks:
  - total cases: 10
  - critical/high bypass: 0

## rc2 evidence files

- `releases/v0.3.2-rc2/release_manifest.yaml`
- `releases/v0.3.2-rc2/evidence_integrity_manifest.yaml`
- `releases/v0.3.2-rc2/p5_gate_report.md`
- `releases/v0.3.2-rc2/ci_evidence.json`
- `releases/v0.3.2-rc2/profile-d-smoke.json`
- `releases/v0.3.2-rc2/profile-s-smoke.json`
- `releases/v0.3.2-rc2/eval_report.json`
- `releases/v0.3.2-rc2/redteam_report.json`
- `releases/v0.3.2-rc2/operator_drill_report.json`

## Local full validation

- `ruby bin/check` passed on 2026-05-31 after rc2 evidence work and LF normalization: repository text guard, syntax, load smoke, warning-load smoke, test suite, and git diff --check.
- Test suite result inside `bin/check`: 500 runs, 13182 assertions, 0 failures, 0 errors, 3 skips.

## Known gaps / non-claims

- The evidence commit cannot contain its own future post-push CI run id without creating an infinite self-referential CI loop; post-push CI is reported as external GitHub Actions evidence after push.
- Profile D full build/browser QA still needs host `pnpm` and local Playwright executable evidence.
- Production operator drill is not claimed; rc2 includes local dry-run drill evidence only.
- Eval/red-team packs are local operational seeds, not independent holdout/human-reviewed production benchmarks.
- Production Brain SQLite evidence is still blocked by missing `sqlite3` gem in this runtime.

## Next recommended goal

Close the remaining rc2 production blockers in this order:

1. Add safe dependency toolchain evidence for Profile D (`pnpm`, local Playwright) without reading `.env` or invoking deploy/provider CLIs.
2. Re-run Profile D build + localhost preview + browser QA end-to-end.
3. Add independent holdout eval/red-team review artifacts.
4. Add production-style operator/rollback drill evidence.
5. Update release evidence to a later rc after those gates pass.
