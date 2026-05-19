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

## Remaining non-completion reasons

- Eval/red-team/Brain evidence remains MVP/fixture-grade rather than production benchmark evidence.
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
- `ruby -Itest test/test_agent_os_v32_release_evidence.rb` ? PASS: 2 runs, 27 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_policy_kernel.rb` ? PASS: 9 runs, 35 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_tool_gateway.rb` ? PASS: 4 runs, 14 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_decision_packet.rb` ? PASS: 3 runs, 22 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_contracts.rb` ? PASS: 19 runs, 247 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_schema_locks.rb` ? PASS: 3 runs, 883 assertions, 0 failures, 0 errors
- `git diff --check` ? PASS with line-ending warnings only
- `ruby -Itest test/all.rb` ? TIMED OUT after 604s in this session; targeted suites above passed

## Completion

Not complete. The fixed script-runner deletion part is substantially complete, including fail-closing the stale deploy provider execution path and demoting browser scenario wording to deterministic probe evidence, but the full objective remains active until Manus-grade/natural-language web-app agent readiness is proven requirement-by-requirement.
