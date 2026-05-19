# WebBuilderAgent v0.3.2-rc1 P5 Gate Report

Status: scaffold_demo_passed

Production readiness claimed: false

Operational readiness: blocked_pending_ci_operator_drill_and_production_benchmarks

Constitution hash: `sha256:87f5f29f48f18135b27b12f940af93e49e9851df23cf0752d45e0ef4bc73d23c`

Evidence integrity: `releases/v0.3.2-rc1/evidence_integrity_manifest.yaml`

## Gate summary

- Policy coverage: passed
- Tool gateway: passed
- HITL v2: passed
- Replay: passed
- Red-team: catalog_fixture_passed (6 local catalog cases; production gate remains blocked)
- Red-team secret canary: canary_configured, value emitted=false, production gate blocked
- Red-team critical/high bypass count: 0
- Eval: expanded_fixture_passed (50 synthetic fixture cases; production gate remains blocked)
- Brain: safety passed (JSONL ledger MVP; SQLite operational gate blocked)
- Self-improvement source changed: false

## Scaffold/demo blockers

- none

## Operational blockers

- production readiness not claimed: GitHub Actions run id is not attached
- operator drill evidence is placeholder only
- production-ready eval science requires independent holdout, leakage check, CI artifact, and human baseline
- production-ready red-team requires independent adversarial review, CI artifact, secret canary transcript, and expanded attack coverage
- SQLite backend unavailable; JSONL ledger is a local MVP persistence layer
