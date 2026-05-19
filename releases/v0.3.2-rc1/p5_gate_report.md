# WebBuilderAgent v0.3.2-rc1 P5 Gate Report

Status: scaffold_demo_passed

Production readiness claimed: false

Operational readiness: blocked_pending_ci_operator_drill_and_production_benchmarks

Constitution hash: `sha256:87f5f29f48f18135b27b12f940af93e49e9851df23cf0752d45e0ef4bc73d23c`

Evidence integrity: `releases/v0.3.2-rc1/evidence_integrity_manifest.yaml`

## Gate summary

- Policy coverage: gateway_demo_passed (whole-repo side-effect coverage unproven; production gate blocked)
- Side-effect surface audit: static_audit_attached (entries=21; unclassified=0; runtime universal enforcement unproven)
- Tool gateway: gateway_demo_passed (finish demo only; full side-effect gateway audit not attached; production gate blocked)
- HITL v2: approval_fixture_passed (fixture approver only; production gate blocked)
- Replay: replay_demo_passed (durable replay/resume audit not attached; production gate blocked)
- Validation: targeted_validation_only (full ruby bin/check, test/all, and CI evidence not attached)
- Red-team: catalog_fixture_passed (6 local catalog cases; production gate remains blocked)
- Red-team secret canary: canary_configured, value emitted=false, production gate blocked
- Red-team critical/high bypass count: 0
- Eval: expanded_fixture_passed (50 synthetic fixture cases; production gate remains blocked)
- Brain: memory_safety_fixture_passed (JSONL ledger MVP; SQLite operational gate blocked)
- Self-improvement: proposal_fixture_recorded / sandbox_planned (production gate blocked; no patch generated)

## Scaffold/demo blockers

- none

## Operational blockers

- production readiness not claimed: GitHub Actions run id is not attached
- operator drill evidence is placeholder only
- full ruby bin/check evidence is not attached to this release evidence
- full ruby -Itest test/all.rb evidence is not attached to this release evidence
- tool gateway demo only exercised finish; full side-effect tool gateway audit is not attached to this release evidence
- static side-effect surface audit is attached, but runtime universal side-effect enforcement is not proven by this release evidence
- side-effect surface audit is static classification evidence only; runtime universal enforcement still requires release-bound broker execution evidence
- production HITL evidence requires a real operator approval artifact, expiry/single-use consumption proof, and audit trail
- durable replay/resume audit with artifact hash validation is not attached to this release evidence
- production-ready eval science requires independent holdout, leakage check, CI artifact, and human baseline
- production-ready red-team requires independent adversarial review, CI artifact, secret canary transcript, and expanded attack coverage
- SQLite backend unavailable; JSONL ledger is a local MVP persistence layer
- production-ready self-improvement requires sandbox patch diff, static checks, eval/red-team pass, HITL v2 approval, canary, rollback plan, and monitor evidence
