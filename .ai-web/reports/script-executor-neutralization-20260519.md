# Script Executor Neutralization Audit ? 2026-05-19

Status: **top-level script-executor surfaces neutralized; Manus-grade completion audit still active**.

## Current assessment

WebBuilderAgent is closer to a natural-language, engine-run-centered supervised local web-building Agent OS candidate, but it should **not** claim Manus-grade readiness yet.

## Deleted / converted in this pass set

- Deleted legacy `AgentRuntime::Loop`, `Planner`, and `Executor`.
- Deleted legacy AgentRuntime session/timeline/final-report artifact writer stack.
- Rewired `aiweb agent` to delegate natural-language goals directly to the canonical `engine-run` durable runtime.
- Deleted `lib/aiweb/project/verify_loop/execution.rb` and `lib/aiweb/project/verify_loop/reporting.rb`.
- Converted `aiweb verify-loop` into an `engine-run` compatibility shim with `fixed_pipeline_present=false`, no bespoke steps, and no verify-loop cycle evidence writer.
- Preserved `AgentRuntime::SourcePatchGuard` because it is a safety verifier, not a script runner.

- Deleted legacy deploy provider execution/provenance helpers (`lib/aiweb/project/deploy/execution.rb`, `lib/aiweb/project/deploy/provenance.rb`).
- Replaced the stale deploy `verify_loop_gate` unlock path with a fail-closed `engine_run_release_evidence` release gate; approved deploy no longer executes provider CLI from this local adapter.
- Renamed browser evidence fields from `planner=static_safe_action_plan` / `scenario_plan` / `scenario_results` to `probe_generator=deterministic_local_browser_probe` / `probe_plan` / `probe_results`.
- Demoted eval status from generic `passed` to `expanded_fixture_passed` plus `production_gate_status=blocked`, so fixture suites cannot masquerade as production/Manus-grade eval science.
- Replaced Brain JSON snapshot storage with an append-only JSONL ledger and explicit `SQLite backend unavailable` operational blocker.
- Demoted red-team status from generic `passed` to `catalog_fixture_passed` plus `production_gate_status=blocked`, so local attack catalog fixtures cannot masquerade as production red-team evidence.
- Redacted `redteam/secret_canary.rb` output so it emits only a fingerprint and explicit production gate blocker, never the canary value.
- Demoted self-improvement dry-run evidence to `proposal_fixture_recorded` / `sandbox_planned` with `production_gate_status=blocked`, `patch_generated=false`, and `promotion_allowed=false`.

## Remaining non-completion reasons

- Red-team evidence is now explicitly catalog-fixture-only and production-blocked; self-improvement is dry-run fixture-only and production-blocked; Brain is safer append-only JSONL but still operationally blocked until a real SQLite/dependency-backed kernel exists; eval fixture pass is explicitly production-blocked.
- Operator drill, GitHub Actions run ids, and production release evidence are still blockers.
- External provider/deploy/credential flows remain intentionally blocked; deploy provider execution is now fail-closed until a future engine-run release evidence gate exists.

## Validation

- `ruby -Ilib -e "require 'aiweb'; puts 'ok'"` ? PASS
- `ruby -Itest test/test_agentification_runtime.rb` ? PASS: 11 runs, 138 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_static_surface_audit.rb` ? PASS: 2 runs, 51 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/verify_loop|verify-loop|workbench_dry_run/'` ? PASS: 14 runs, 403 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/deploy/'` ? PASS: 8 runs, 290 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/verify_loop|verify-loop|workbench_dry_run|deploy/'` ? PASS: 18 runs, 616 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/engine_run_captures_screenshot_manifest|engine_run_design_verdict_passes|engine_run_design_gate_blocks_copy_back_on_browser_action_recovery_failure|engine_run_preserves_structured_browser_policy_evidence/'` ? PASS: 4 runs, 648 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_release_evidence.rb` ? PASS: 2 runs, 73 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_evals.rb` ? PASS: 2 runs, 21 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_brain_and_self_improvement.rb` ? PASS: 6 runs, 46 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_redteam.rb` ? PASS: 4 runs, 38 assertions, 0 failures, 0 errors
- `ruby redteam/secret_canary.rb` ? PASS: canary_configured, canary_value_emitted=false, production_gate_status=blocked
- `ruby -Itest test/test_agent_os_v32_policy_kernel.rb` ? PASS: 9 runs, 35 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_tool_gateway.rb` ? PASS: 4 runs, 14 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_decision_packet.rb` ? PASS: 3 runs, 22 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_contracts.rb` ? PASS: 19 runs, 247 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_schema_locks.rb` ? PASS: 3 runs, 883 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_contracts.rb` ? PASS: 3 runs, 66 assertions, 0 failures, 0 errors
- `git diff --check` ? PASS with line-ending warnings only
- `ruby -Itest test/all.rb` ? TIMED OUT after 604s in this session; targeted suites above passed

## Completion

Not complete. The fixed script-runner deletion part is substantially complete, including fail-closing stale deploy execution, demoting browser scenario wording to deterministic probe evidence, preventing fixture evals and red-team catalog probes from claiming production readiness, redacting secret-canary output, demoting self-improvement dry-runs to production-blocked fixtures, and replacing Brain JSON snapshots with append-only JSONL plus a SQLite blocker; the full objective remains active until Manus-grade/natural-language web-app agent readiness is proven requirement-by-requirement.
