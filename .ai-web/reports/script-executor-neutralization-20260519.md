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
- Replaced Brain JSON snapshot storage with a hash-chained append-only JSONL ledger, `brain-index.json` search projection, `memory-health-report.json`, file-lock write serialization, a backup/restore drill fixture, and an independent raw-file audit path; production remains blocked pending SQLite-backed storage evidence.
- Demoted P5 Brain wording from broad safety pass language to `memory_safety_fixture_passed` with production gate blocked.
- Demoted red-team status from generic `passed` to `catalog_fixture_passed` plus `production_gate_status=blocked`, so local attack catalog fixtures cannot masquerade as production red-team evidence.
- Redacted `redteam/secret_canary.rb` output so it emits only a fingerprint and explicit production gate blocker, never the canary value.
- Demoted self-improvement dry-run evidence to `proposal_fixture_recorded` / `sandbox_planned` with `production_gate_status=blocked`, `patch_generated=false`, and `promotion_allowed=false`.
- Demoted release validation evidence from hardcoded `local_bin_check_passed` / `ruby bin/check` to `targeted_validation_only` unless full `ruby bin/check`, `test/all`, and CI evidence are attached.
- Demoted P5 policy coverage from global `all_side_effects...=true` to `gateway_demo_passed` with `coverage_status=unproven` until whole-repo side-effect coverage evidence exists.
- Attached static side-effect surface audit evidence to P5/release reports with `unclassified_count=0`, while keeping runtime universal side-effect enforcement blocked.
- Demoted P5 tool gateway evidence from raw `passed` to `gateway_demo_passed` / production-blocked until a full side-effect tool gateway audit exists.
- Demoted P5 HITL v2 evidence from fixture `passed` to `approval_fixture_passed` with production gate blocked until real operator approval/audit evidence is attached.
- Removed the L3 `approved: true` boolean approval shortcut from PolicyKernel/ToolGateway; L3 side effects now require a hash-bound HITL v2 approval artifact.
- Removed the `schema_version=1, status=passed` verifier-result approval shortcut from PolicyKernel; verifier results are evidence, not execution authority.
- Hardened HITL artifact self-integrity checks: `approval_hash`, `validation_hash`, run id, risk tier, requested capability, approver id, canonical hash ordering, and `single_use` must match before execution.
- Removed the `engine-run --approved` without `--approval-hash` execution shortcut; real engine-run execution now requires the matching dry-run capability hash.
- Removed the direct `agent-run --approved` without `--approval-hash` execution shortcut; dry-run now emits an agent-run capability hash bound to task/source/design/sandbox context, stale hashes are rejected, and daemon bridge calls pass the hash instead of relying on approval token plus a boolean flag.
- Removed the `engine-scheduler --approved --execute` resume-bridge shortcut without `--approval-hash`; tick/daemon dry-runs now expose the selected resume capability hash, missing/stale hashes block before engine-run resume execution, and the delegated resume command carries `--approval-hash HASH`.
- Removed the `setup --install --approved` package-manager shortcut without `--approval-hash`; setup dry-runs now emit a capability hash bound to package/lockfile/lifecycle/audit-exception evidence, and missing/stale hashes block before run artifacts or package-manager processes.
- Demoted P5 replay evidence from generic pass/side-effect-free wording to `replay_demo_passed` with production gate blocked until durable replay/resume audit evidence is attached.
- Added static audit coverage so stale release-ready / production-ready true claims and broad P5 pass wording cannot be reintroduced in release evidence surfaces.
- Demoted CLI help from Manus wording marketing language to supervised local engine-run runtime wording, with static audit coverage.
- Demoted the public `engine-run` contract from product-level Manus wording to supervised, scoped local agentic runtime wording, with static audit coverage.
- Centralized the Codex `agent-run` worker subprocess through `Aiweb::Runtime::ProcessRunner` / `CommandSpec` with bounded `stdin_data` support: approved local source-patch runs still write `side-effect-broker.jsonl`, metadata embeds broker events, and the static surface audit no longer reports `brokered_agent_run_codex_subprocess`.
- Centralized the OpenManus `agent-run` sandbox worker subprocess through `Aiweb::Runtime::ProcessRunner` / `CommandSpec` with bounded `stdin_data` support while preserving aiweb-managed Docker/Podman sandboxing, tool-broker evidence, workspace validation, diff validation, and bounded copy-back checks.
- Centralized the canonical `engine-run` agent worker subprocess through `Aiweb::Runtime::ProcessRunner` / `CommandSpec` with bounded `stdin_data` support while preserving staged tool-broker PATH, scrubbed environment, stdout/stderr redaction, timeout handling, and secret-output quarantine checks.
- Centralized the `engine_run_capture_command` helper through `Aiweb::Runtime::ProcessRunner` / `CommandSpec`; `CommandSpec` still rejects shell metacharacters by default and requires explicit `allow_shell_meta` for known literal shell-script argv boundaries such as sandbox self-attestation probes.
- Centralized setup package install plus SBOM/package-audit supply-chain evidence subprocesses through `Aiweb::Runtime::ProcessRunner` / `CommandSpec` while preserving setup side-effect broker events, clean child environment, redaction, SBOM artifacts, package audit evidence, and vulnerability gates.
- Centralized the backend CLI bridge subprocess through `Aiweb::Runtime::ProcessRunner` / `CommandSpec` while preserving allowlisted structured commands, backend-controlled flags, side-effect broker evidence, redaction, deploy dry-run blocking, read-only inline broker behavior, and timeout failure events.
- Centralized Lazyweb external HTTP transport through `Aiweb::Runtime::HttpRequestSpec` / `HttpClient` while preserving Lazyweb side-effect broker events, endpoint policy decision evidence, token/query redaction, timeout handling, HTTP status failure handling, invalid JSON failure evidence, and transport failure evidence.
- Tightened long-running local preview/workbench process launch so `Aiweb::Runtime::ProcessLauncher` accepts only `LaunchSpec` via `spec:`; scaffold preview, workbench serve, and engine-run sandbox preview callers now construct typed launch specs instead of passing loose argv/cwd/env keyword bundles.
- Centralized `bin/check` and `bin/engine-runtime-matrix-check` subprocess execution through `Aiweb::Runtime::ProcessRunner` / `CommandSpec`, removing the remaining `local_verification_harness_exception` direct Open3 audit exception while preserving argv execution, repo chdir, bounded output, timeout configuration, and failure stdout/stderr evidence.
- Centralized runtime command git revision and Windows preview process-tree cleanup through `Aiweb::Runtime::ProcessRunner` / `CommandSpec`, removing the `local_runtime_command_exception` and `local_process_tree_cleanup` direct process classifications from the static side-effect surface audit.
- Removed stale side-effect broker documented-exception classifier branches for the already-deleted `runtime_commands` direct `system`/`Open3` and `qa_artifacts` direct `Open3` paths, so future direct process reintroduction becomes unclassified instead of being silently allowlisted as a legacy fallback.
- Centralized `agent_run/diff_policy` git diff/status evidence through `Aiweb::Runtime::ProcessRunner` / `CommandSpec`, removed the stale `local_read_only_git_evidence` documented-exception classifier, and removed that direct process classification from the static side-effect surface audit.
- Centralized OpenManus readiness image-inspect preflight through `Aiweb::Runtime::ProcessRunner` / `CommandSpec`, removed the stale `local_runtime_readiness_probe` documented-exception classifier, and added a scrubbed-env regression for fake Docker readiness.
- Centralized agent-run OpenManus image-inspect preflight through `Aiweb::Runtime::ProcessRunner` / `CommandSpec`, removed the stale `openmanus_sandbox_image_preflight` documented-exception classifier, and added a scrubbed-env regression for the approved OpenManus image preflight.
- Centralized engine-run sandbox runtime attestation Docker/Podman inspect/info/rm probes through `Aiweb::Runtime::ProcessRunner` / `CommandSpec`, removed the stale `sandbox_runtime_attestation_exception` documented-exception classifier, and added static audit regression coverage so future direct sandbox attestation probes become unclassified.
- Removed the `workbench --serve --approved` boolean-only local server shortcut: `workbench --serve --dry-run` now emits an `approval_hash` bound to the localhost serve capability envelope, and real serving requires the matching `--approval-hash HASH --approved`; missing or stale hashes block before Workbench artifacts or `ProcessLauncher` server processes are created.
- Removed the backend generic command bridge's approved-without-hash shortcut: approved generic `agent`, `agent-run`, `setup`, `verify-loop`, and direct bridge `engine-run` requests must now include `--approval-hash HASH` or `--approval-request HASH` before the bridge forwards `--approved`; missing hashes produce backend side-effect broker denial evidence before `bin/aiweb` launches.
- Removed the implementation MCP broker's approved-without-hash connector/file-access shortcut: `mcp-broker --dry-run` now emits an `approval_hash` bound to the broker capability envelope, real Lazyweb/project_files broker calls require matching `--approval-hash HASH --approved`, and missing/stale hashes block before connector or project-file drivers run.
- Removed the `eval-baseline import --approved` corpus overwrite shortcut: import dry-runs now emit an `approval_hash` bound to the exact source corpus hash, fixture summaries, target path, and import boundary, while real imports require matching `--approval-hash HASH --approved` before `.ai-web/eval/human-baselines.json` can be written.

- Removed approved-only next-action/live guidance shortcuts: agent facade, verify-loop shim, engine-run resume guidance, eval-baseline import guidance, and human-review-pack reviewer guidance now require dry-run review plus a matching `--approval-hash HASH --approved`.
- Demoted run lifecycle resume/idle guidance: `run-status` and `observability-summary` now suggest natural-language `aiweb agent ... --dry-run`, and `run-resume` records dry-run/hash-discovery descriptors instead of approved-only verify-loop/deploy/workbench/setup/agent-run/engine-run commands.
- Demoted Workbench command controls from executable-button style commands to dry-run descriptors only; the old verify-loop control now points at canonical `engine-run ... --dry-run`, and Workbench side-effect metadata reports no mutation/process/approval shortcut for dry-run descriptors.
- Demoted webbuilder/README verify-loop-first examples: launcher help and README now steer first to natural-language `agent ... --dry-run` and canonical `engine-run ... --dry-run`; verify-loop remains compatibility prose only, not the primary approved execution example.
- Demoted `aiweb help` verify-loop approved examples: CLI help now shows natural-language `agent ... --dry-run` and canonical `engine-run ... --dry-run` planning examples instead of a verify-loop approved command line.

- Removed webbuilder/help approved-only UX guidance: `aiweb help`, `bin/webbuilder`, and README now present dry-run approval hash review before `--approval-hash HASH --approved` execution, and static audit rejects the stale `[--approved] [--dry-run]` / `--approved --approval-hash HASH` guidance patterns.


- Restored clean executable version probing: `Aiweb::Project#executable_version` now uses `ProcessRunner`/`CommandSpec` with `subprocess_path_env`, and the targeted clean-env regression passes.


- Split `bin/check` timeout budgets: syntax/load/smoke checks keep `AIWEB_BIN_CHECK_TIMEOUT_SECONDS`, while the full `ruby -Itest test/all.rb` integration suite now uses `AIWEB_TEST_SUITE_TIMEOUT_SECONDS` defaulting to 3600 seconds. This preserves full-suite coverage instead of substituting a narrower check.
- Added a fail-closed `Aiweb::Brain::SQLiteStore` adapter boundary: when the `sqlite3` Ruby gem is unavailable, MemoryAudit/P5/release evidence records `sqlite_dependency=missing_dependency` and keeps production Brain readiness blocked instead of overclaiming JSONL fixture storage as production SQLite evidence.

## Remaining non-completion reasons

- Red-team evidence is now explicitly catalog-fixture-only and production-blocked; self-improvement is dry-run fixture-only and production-blocked; Brain is safer hash-chained JSONL with projection/health evidence, file-lock write serialization, and backup/restore drill evidence, and independent file-audit evidence but still operationally blocked until real SQLite-backed storage evidence exists; the current runtime explicitly reports `sqlite3` Ruby gem missing; eval fixture pass is explicitly production-blocked.
- Operator drill, GitHub Actions run ids, full `ruby bin/check`/`test/all` evidence, runtime universal side-effect broker enforcement evidence, full side-effect tool gateway audit evidence, real HITL operator/audit evidence, durable replay/resume audit evidence, and production release evidence are still blockers.
- External provider/deploy/credential flows remain intentionally blocked; deploy provider execution is now fail-closed until a future engine-run release evidence gate exists.

## Validation

- `ruby -Itest test/test_aiweb_cli.rb -n /test_verify_loop_help_and_webbuilder_dry_run_passthrough/` after aiweb help demotion ? PASS: 1 run, 49 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_static_surface_audit.rb` after aiweb help demotion ? PASS: 6 runs, 178 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n /test_verify_loop_help_and_webbuilder_dry_run_passthrough|workbench_dry_run/` after webbuilder/README guidance demotion ? PASS: 2 runs, 159 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_static_surface_audit.rb` after webbuilder/README guidance demotion ? PASS: 6 runs, 172 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n /workbench_dry_run/` after Workbench descriptor demotion ? PASS: 1 run, 114 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_static_surface_audit.rb` after Workbench descriptor demotion ? PASS: 6 runs, 158 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n /test_run_status_is_read_only_when_no_active_run|test_observability_summary_rolls_up_latest_runs_without_writes|test_run_cancel_and_resume_record_local_lifecycle_descriptors_without_process_execution/` after run lifecycle guidance demotion ? PASS: 3 runs, 74 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_static_surface_audit.rb` after run lifecycle guidance demotion ? PASS: 6 runs, 148 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_daemon.rb -n /test_backend_job_lifecycle_routes_map_to_bridge_and_require_tokens/` after run lifecycle guidance demotion ? PASS: 1 run, 25 assertions, 0 failures, 0 errors
- `ruby -Ilib -e side_effect_surface_audit` after stale classifier removal ? PASS: coverage=classified, unclassified=0, entry_count=19, stale runtime direct-process classifier entries=false
- `ruby -Itest test/test_contracts.rb -n /side_effect_surface_audit/` after stale direct-process classifier removal ? PASS: 5 runs, 82 assertions, 0 failures, 0 errors
- `ruby -Ilib -e "require 'aiweb'; puts 'ok'"` ? PASS
- `ruby -Itest test/test_agentification_runtime.rb` ? PASS: 11 runs, 138 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_static_surface_audit.rb` ? PASS: 5 runs, 102 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/verify_loop|verify-loop|workbench_dry_run/'` ? PASS: 14 runs, 403 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/deploy/'` ? PASS: 8 runs, 290 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/verify_loop|verify-loop|workbench_dry_run|deploy/'` ? PASS: 18 runs, 616 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/engine_run_captures_screenshot_manifest|engine_run_design_verdict_passes|engine_run_design_gate_blocks_copy_back_on_browser_action_recovery_failure|engine_run_preserves_structured_browser_policy_evidence/'` ? PASS: 4 runs, 648 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_release_evidence.rb` ? PASS: 2 runs, 189 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_evals.rb` ? PASS: 2 runs, 21 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_brain_and_self_improvement.rb` ? PASS: 7 runs, 85 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_redteam.rb` ? PASS: 4 runs, 38 assertions, 0 failures, 0 errors
- `ruby redteam/secret_canary.rb` ? PASS: canary_configured, canary_value_emitted=false, production_gate_status=blocked
- `ruby -Itest test/test_agent_os_v32_policy_kernel.rb` ? PASS: 11 runs, 47 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_tool_gateway.rb` ? PASS: 4 runs, 14 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_decision_packet.rb` ? PASS: 3 runs, 22 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_contracts.rb` ? PASS: 19 runs, 247 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/agent_run_approved_fake_codex_success_records_logs_diff_and_safe_state|agent_run_codex_uses_clean_environment|agent_run_approved_fake_codex_failure_records_failure_and_logs/'` ? PASS: 3 runs, 87 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/agent_run/'` ? PASS after agent-run approval-hash hardening: 26 runs, 624 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/engine_scheduler/'` ? PASS after engine-scheduler resume approval-hash hardening: 2 runs, 205 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/engine_run_approved_without_approval_hash|engine_run_rejects_stale_approval_hash|engine_scheduler/'` ? PASS: 4 runs, 226 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/engine_run_openmanus_uses_aiweb_managed_sandbox_and_copies_back_safe_changes|engine_run_resume_reuses_checkpoint_workspace_before_copy_back|engine_run_design_gate_blocks_copy_back_without_real_browser_evidence|engine_run_blocks_secret_file_created_inside_staged_workspace/'` ? PASS after approved engine-run test helper migration: 4 runs, 275 assertions, 0 failures, 0 errors
- `ruby -Ilib -e "side_effect_surface_audit agent-run classification"` ? HISTORICAL/SUPERSEDED: earlier broker-evidence conversion passed; current audit removes `brokered_agent_run_codex_subprocess` after ProcessRunner centralization
- `ruby -c lib/aiweb/project/runtime_commands.rb test/test_contracts.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_contracts.rb -n '/side_effect_surface_audit/'` ? PASS: 5 runs, 75 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/preview_records_running_fake_dev_server_duplicate_and_stop/'` ? PASS: 1 run, 39 assertions, 0 failures, 0 errors
- `ruby -Ilib -e "side_effect_surface_audit runtime command classification"` ? PASS: coverage=classified, unclassified=0, entry_count=37, removed local_runtime_command_exception/local_process_tree_cleanup
- `ruby -Itest test/test_agent_os_v32_release_evidence.rb` ? PASS: 2 runs, 189 assertions, 0 failures, 0 errors
- `rg "Open3.capture3|system\\(" lib/aiweb/project/runtime_commands.rb` ? PASS: no direct Open3.capture3 or system() forms remain in runtime_commands.rb
- `ruby -Itest test/test_schema_locks.rb` ? PASS: 3 runs, 883 assertions, 0 failures, 0 errors
- release evidence integrity hash check ? PASS: `p5_gate_report.md` and `release_manifest.yaml` hashes match `evidence_integrity_manifest.yaml`
- `ruby -c lib/aiweb/project/agent_run/diff_policy.rb test/test_contracts.rb` ? PASS: Syntax OK
- `ruby -c lib/aiweb/project/agent_run/diff_policy.rb lib/aiweb/project/side_effect_broker/classification.rb test/test_contracts.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_contracts.rb -n '/side_effect_surface_audit/'` ? PASS: 5 runs, 76 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/agent_run_approved_fake_codex_success_records_logs_diff_and_safe_state|agent_run_codex_uses_clean_environment|agent_run_approved_fake_codex_failure_records_failure_and_logs|agent_run_approved_rejects_changes_outside_source_allowlist/'` ? PASS: 4 runs, 106 assertions, 0 failures, 0 errors
- `ruby -Ilib -e "side_effect_surface_audit agent-run diff-policy classification"` ? PASS: coverage=classified, unclassified=0, entry_count=34, removed local_read_only_git_evidence
- `rg "Open3.capture3" lib/aiweb/project/agent_run/diff_policy.rb` ? PASS: no direct Open3.capture3 remains in agent-run diff policy
- `ruby -c lib/aiweb/daemon/openmanus_readiness.rb lib/aiweb/project/side_effect_broker/classification.rb test/test_daemon.rb test/test_contracts.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_daemon.rb -n '/openmanus_readiness/'` ? PASS: 2 runs, 15 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_contracts.rb -n '/side_effect_surface_audit/'` ? PASS: 5 runs, 77 assertions, 0 failures, 0 errors
- `ruby -Ilib -e "side_effect_surface_audit OpenManus readiness classification"` ? PASS: coverage=classified, unclassified=0, entry_count=33, removed local_runtime_readiness_probe
- `rg "Open3.capture3" lib/aiweb/daemon/openmanus_readiness.rb` ? PASS: no direct Open3.capture3 remains in OpenManus readiness
- `ruby -c lib/aiweb/project/agent_run/openmanus.rb lib/aiweb/project/side_effect_broker/classification.rb test/test_contracts.rb test/test_aiweb_cli.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_aiweb_cli.rb -n '/agent_run_openmanus_approved_requires_prepared_local_image|agent_run_approved_fake_openmanus_uses_managed_container_sandbox_contract/'` ? PASS: 2 runs, 88 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_contracts.rb -n '/side_effect_surface_audit/'` ? PASS: 5 runs, 78 assertions, 0 failures, 0 errors
- `ruby -Ilib -e "side_effect_surface_audit agent-run OpenManus image preflight classification"` ? PASS: coverage=classified, unclassified=0, entry_count=32, removed openmanus_sandbox_image_preflight
- `ruby -c lib/aiweb/project/engine_run/sandbox_process.rb lib/aiweb/project/side_effect_broker/classification.rb test/test_contracts.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_aiweb_cli.rb -n '/engine_run_openmanus_sandbox_preflight|engine_run_openmanus_required_runtime_matrix|sandbox_preflight/'` ? PASS: 3 runs, 40 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_contracts.rb -n '/side_effect_surface_audit/'` ? PASS after engine-run sandbox attestation centralization: 5 runs, 79 assertions, 0 failures, 0 errors
- `ruby -Ilib -e "side_effect_surface_audit engine-run sandbox attestation classification"` ? HISTORICAL/SUPERSEDED: removed sandbox_runtime_attestation_exception; current audit also removed the remaining `sandbox_process.rb` brokered_engine_run_capture_command direct Open3 entry
- `ruby -c lib/aiweb/runtime/command_spec.rb lib/aiweb/runtime/process_runner.rb lib/aiweb/project/agent_run/codex_runner.rb lib/aiweb/project/side_effect_broker/classification.rb test/test_contracts.rb test/test_agentification_runtime.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_agentification_runtime.rb -n '/process_runner/'` ? PASS: 3 runs, 16 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/agent_run_approved_fake_codex_success_records_logs_diff_and_safe_state|agent_run_codex_uses_clean_environment|agent_run_approved_fake_codex_failure_records_failure_and_logs|agent_run_approved_rejects_changes_outside_source_allowlist/'` ? PASS after Codex ProcessRunner centralization: 4 runs, 106 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_contracts.rb -n '/side_effect_surface_audit/'` ? PASS after Codex ProcessRunner centralization: 5 runs, 78 assertions, 0 failures, 0 errors
- `ruby -Ilib -e "side_effect_surface_audit Codex agent-run classification"` ? PASS: coverage=classified, unclassified=0, entry_count=27, removed brokered_agent_run_codex_subprocess; no `codex_runner.rb` Open3 entries remain
- `ruby -c lib/aiweb/project/agent_run/openmanus.rb lib/aiweb/project/side_effect_broker/classification.rb test/test_contracts.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_aiweb_cli.rb -n '/agent_run_approved_fake_openmanus_uses_managed_container_sandbox_contract|agent_run_openmanus_blocks_package_install_through_tool_broker|agent_run_openmanus_blocks_unapproved_root_mutation|agent_run_openmanus_approved_requires_prepared_local_image/'` ? PASS after OpenManus worker ProcessRunner centralization: 2 runs, 88 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_contracts.rb -n '/side_effect_surface_audit/'` ? PASS after OpenManus worker ProcessRunner centralization: 5 runs, 77 assertions, 0 failures, 0 errors
- `ruby -Ilib -e "side_effect_surface_audit OpenManus agent-run worker classification"` ? PASS: coverage=classified, unclassified=0, entry_count=26, removed brokered_openmanus_sandbox_subprocess; no `agent_run/openmanus.rb` Open3 entries remain
- `ruby -c lib/aiweb/project/engine_run.rb lib/aiweb/project/side_effect_broker/classification.rb test/test_contracts.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_aiweb_cli.rb -n '/engine_run_openmanus_uses_aiweb_managed_sandbox_and_copies_back_safe_changes|engine_run_waits_for_approval_when_staged_tool_broker_blocks_package_install|engine_run_verification_uses_clean_environment|engine_run_surfaces_verification_tool_broker_blocks_in_policy_and_events/'` ? PASS: 4 runs, 242 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_contracts.rb -n '/side_effect_surface_audit/'` ? PASS after engine-run worker ProcessRunner centralization: 5 runs, 78 assertions, 0 failures, 0 errors
- `ruby -Ilib -e "side_effect_surface_audit engine-run worker classification"` ? HISTORICAL/SUPERSEDED: removed `engine_run.rb` direct Open3; current audit also removed `brokered_engine_run_capture_command` from `sandbox_process.rb`
- `ruby -c lib/aiweb/runtime/command_spec.rb lib/aiweb/project/engine_run/sandbox_process.rb lib/aiweb/project/side_effect_broker/classification.rb test/test_contracts.rb test/test_aiweb_cli.rb test/test_agentification_runtime.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_agentification_runtime.rb -n '/process_runner|command_spec/'` ? PASS: 4 runs, 24 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/engine_run_openmanus_uses_aiweb_managed_sandbox_and_copies_back_safe_changes|engine_run_waits_for_approval_when_staged_tool_broker_blocks_package_install|engine_run_verification_uses_clean_environment|engine_run_surfaces_verification_tool_broker_blocks_in_policy_and_events|engine_run_dry_run_exposes_agent_os_contract/'` ? PASS: 4 runs, 242 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_contracts.rb -n '/side_effect_surface_audit/'` ? PASS after engine-run capture helper centralization: 5 runs, 77 assertions, 0 failures, 0 errors
- `ruby -Ilib -e "side_effect_surface_audit engine-run capture helper classification"` ? PASS: coverage=classified, unclassified=0, entry_count=24, removed brokered_engine_run_capture_command; no `sandbox_process.rb` Open3 entries remain
- `ruby -c lib/aiweb/project/runtime_commands/setup.rb lib/aiweb/project/runtime_commands/setup/supply_chain/broker.rb lib/aiweb/project/side_effect_broker/classification.rb test/test_contracts.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_aiweb_cli.rb -n '/setup_install_approved_records_successful_fake_pnpm_artifacts_and_safe_state|setup_install_approved_records_failed_fake_pnpm_artifact_without_build_preview_qa_or_deploy|setup_install_approved_strips_sensitive_environment_from_pnpm_processes|setup_install_approved_records_broker_events_when_pnpm_is_missing|setup_install_approved_blocks_nonzero_audit_error_json_without_findings/'` ? PASS: 5 runs, 372 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/setup_install_|setup_help_and_korean_webbuilder_passthrough_surface/'` ? PASS after setup approval hash hardening: 27 runs, 1050 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_contracts.rb -n '/side_effect_surface_audit/'` ? PASS after setup supply-chain ProcessRunner centralization: 5 runs, 76 assertions, 0 failures, 0 errors
- `ruby -Ilib -e "side_effect_surface_audit setup supply-chain classification"` ? PASS: coverage=classified, unclassified=0, entry_count=22, removed brokered_setup_supply_chain_command; no `runtime_commands/setup` direct Open3 entries remain
- `ruby -c lib/aiweb/daemon/cli_bridge.rb lib/aiweb/daemon.rb lib/aiweb/project/side_effect_broker/classification.rb test/test_contracts.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_daemon.rb -n '/bridge_records_backend_side_effect_broker_for_cli_execution|bridge_public_response_redacts_secret_args|bridge_treats_shell_metacharacters_as_argv_data_not_shell|bridge_broker_blocks_disallowed_deploy_and_keeps_read_only_inline|bridge_broker_records_failed_event_on_timeout/'` ? PASS: 5 runs, 50 assertions, 0 failures, 0 errors
- `ruby -c lib/aiweb/daemon/cli_bridge.rb test/test_daemon.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_daemon.rb -n '/generic_backend_bridge_rejects_hash_bound|approved_codex_bridge_execution|bridge_rejects_backend_controlled_flags|bridge_broker_blocks/'` ? PASS: 4 runs, 86 assertions, 0 failures, 0 errors
- `ruby -c lib/aiweb/project/mcp_broker.rb lib/aiweb/cli/dispatch.rb test/test_aiweb_cli.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_aiweb_cli.rb -n '/mcp_broker/'` ? PASS: 6 runs, 307 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_schema_locks.rb` ? PASS after MCP broker approval hash schema lock: 3 runs, 889 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_contracts.rb -n '/side_effect_surface_audit/'` ? PASS after MCP broker approval hash hardening: 5 runs, 75 assertions, 0 failures, 0 errors
- `ruby -c lib/aiweb/project/engine_run/eval_baseline.rb lib/aiweb/cli/dispatch.rb test/test_aiweb_cli.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_aiweb_cli.rb -n '/eval_baseline/'` ? PASS: 6 runs, 121 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_schema_locks.rb` ? PASS after eval-baseline hash-bound import schema lock: 3 runs, 890 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_contracts.rb -n '/side_effect_surface_audit/'` ? PASS after backend bridge ProcessRunner centralization: 5 runs, 75 assertions, 0 failures, 0 errors
- `ruby -Ilib -e "side_effect_surface_audit backend bridge classification"` ? PASS: coverage=classified, unclassified=0, entry_count=21, removed brokered_backend_cli_bridge; no `cli_bridge.rb` direct Open3 entries remain
- `ruby -c lib/aiweb/lazyweb_client.rb lib/aiweb/runtime.rb lib/aiweb/runtime/http_client.rb lib/aiweb/runtime/http_request_spec.rb lib/aiweb/runtime/http_result.rb lib/aiweb/project/side_effect_broker/classification.rb test/test_contracts.rb test/test_lazyweb_client.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_lazyweb_client.rb` ? PASS after Lazyweb HttpClient centralization: 7 runs, 47 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_contracts.rb -n '/side_effect_surface_audit/'` ? PASS after Lazyweb HttpClient centralization: 5 runs, 76 assertions, 0 failures, 0 errors
- `ruby -Ilib -e "side_effect_surface_audit Lazyweb HttpClient classification"` ? PASS: coverage=classified, unclassified=0, entry_count=21, removed brokered_lazyweb_http; central_runtime_http_client=1; no `lazyweb_client.rb` direct Net::HTTP entries remain
- `ruby -c lib/aiweb/runtime/launch_spec.rb lib/aiweb/runtime/process_launcher.rb lib/aiweb/runtime.rb lib/aiweb/project/runtime_commands.rb lib/aiweb/project/workbench.rb lib/aiweb/project/engine_run/preview_browser/preview_process.rb test/test_agentification_runtime.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_agentification_runtime.rb -n '/process_runner|command_spec|process_launcher|launch_spec/'` ? PASS: 5 runs, 33 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/preview_records_running_fake_dev_server_duplicate_and_stop|workbench_dry_run|engine_run_captures_screenshot_manifest|engine_run_design_verdict_passes/'` ? PASS: 4 runs, 775 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_contracts.rb -n '/side_effect_surface_audit|process_launcher_callers_use_launch_spec/'` ? PASS: 6 runs, 78 assertions, 0 failures, 0 errors
- `ruby -Ilib -e "side_effect_surface_audit LaunchSpec classification"` ? PASS: coverage=classified, unclassified=0, entry_count=21; ProcessLauncher entries are central runtime launcher boundary entries and LaunchSpec has no direct side-effect entries
- `ruby -c bin/check bin/engine-runtime-matrix-check lib/aiweb/project/side_effect_broker/classification.rb test/test_contracts.rb` ? PASS: Syntax OK
- `ruby bin/engine-runtime-matrix-check --dry-run --json` ? PASS after bin ProcessRunner centralization: planned matrix JSON emitted
- `ruby -Itest test/test_contracts.rb -n '/side_effect_surface_audit/'` ? PASS after bin ProcessRunner centralization: 5 runs, 75 assertions, 0 failures, 0 errors
- `ruby -Ilib -e "side_effect_surface_audit bin verification classification"` ? PASS: coverage=classified, unclassified=0, entry_count=19, removed local_verification_harness_exception; no `bin/*` direct Open3 entries remain
- `rg "Open3.capture3|Open3.popen3" bin` ? PASS: no direct Open3.capture3/Open3.popen3 remains in bin scripts
- `ruby -Itest test/test_agent_os_v32_contracts.rb` ? PASS: 3 runs, 66 assertions, 0 failures, 0 errors
- `ruby -c lib/aiweb/project/runtime_commands/setup.rb lib/aiweb/project/workbench.rb lib/aiweb/cli/dispatch.rb lib/aiweb/cli/exit_codes.rb lib/aiweb/cli/help_text.rb bin/webbuilder test/test_aiweb_cli.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_aiweb_cli.rb -n '/setup_install_|setup_help_and_korean_webbuilder_passthrough_surface|workbench_serve|workbench_help/'` ? PASS: 34 runs, 1192 assertions, 0 failures, 0 errors
- JSON parse for updated reports ? PASS: `agent-os-v32-baseline-audit.json` and `script-executor-neutralization-20260519.json`
- `git diff --check` ? PASS with line-ending warnings only
- `ruby -c lib/aiweb/ops/p5_gate.rb lib/aiweb/ops/release_manifest.rb` ? PASS: Syntax OK
- `ruby -Itest test/all.rb` ? TIMED OUT after 604s in this session; targeted suites above passed

- `ruby -Itest test/test_agent_os_v32_static_surface_audit.rb` ? PASS after approved-only guidance cleanup: 6 runs, 120 assertions, 0 failures, 0 errors

- `ruby -c` hash-bound approval guidance and broker surfaces ? PASS: Syntax OK
- `ruby -Itest test/test_aiweb_cli.rb -n '/mcp_broker|eval_baseline/'` ? PASS: 12 runs, 428 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_schema_locks.rb` ? PASS after broker/eval hash-bound schema locks: 3 runs, 890 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_contracts.rb -n '/side_effect_surface_audit/'` ? PASS after approved-only guidance cleanup: 5 runs, 75 assertions, 0 failures, 0 errors
- JSON parse updated broker/eval schemas and neutralization reports ? PASS

- `ruby -c` help guidance surfaces after webbuilder approved-only cleanup ? PASS: Syntax OK
- `ruby -Itest test/test_agent_os_v32_static_surface_audit.rb` ? PASS after webbuilder approved-only cleanup: 6 runs, 136 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agentification_runtime.rb -n '/help_and_readme|verify_loop/'` ? PASS after webbuilder approved-only cleanup: 2 runs, 41 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_aiweb_cli.rb -n '/webbuilder_help_explains_zero_start_workflow|setup_help_and_korean_webbuilder_passthrough_surface|agent_run_help_and_webbuilder_passthrough|verify_loop_help_and_webbuilder_dry_run_passthrough|github_deploy_help_and_webbuilder_passthrough_surface/'` ? PASS after webbuilder approved-only cleanup: 5 runs, 129 assertions, 0 failures, 0 errors
- `git diff --check` ? PASS after webbuilder approved-only cleanup with line-ending warnings only

- `ruby -Itest test/test_agent_os_v32_release_evidence.rb` ? PASS after Brain release evidence refresh: 2 runs, 240 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_brain_and_self_improvement.rb` ? PASS after independent Brain file audit: 8 runs, 97 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_release_evidence.rb` ? PASS after independent Brain file audit: 2 runs, 251 assertions, 0 failures, 0 errors
- Repository text guard ? PASS after CRLF blocker cleanup: 301 files scanned, 0 CRLF/merge-marker failures

- `ruby -Itest test/test_aiweb_cli.rb -n /test_executable_version_uses_clean_environment/` ? PASS after `executable_version` restoration: 1 run, 1 assertion, 0 failures, 0 errors
- `ruby -w -Ilib -e "require 'aiweb'"` ? PASS after side-effect broker unused-context cleanup: warning load OK
- `AIWEB_BIN_CHECK_TIMEOUT_SECONDS=1800 ruby bin/check` ? BLOCKED: syntax/load/warning phases progressed, but `test/all.rb` still timed out after 1800s before full-suite evidence could be attached

- `ruby -c bin/check` ? PASS after full-suite timeout split: Syntax OK

- `ruby -Itest test/test_aiweb_cli_runtime_qa.rb -n '/test_pr12_|test_qa_|test_build_help/'` ? PASS: 25 runs, 693 assertions, 0 failures, 0 errors
- `ruby -c lib/aiweb/brain/sqlite_store.rb; ruby -c lib/aiweb/brain/memory_audit.rb; ruby -c lib/aiweb/ops/release_manifest.rb` ? PASS: Syntax OK
- `ruby -Itest test/test_agent_os_v32_brain_and_self_improvement.rb` after SQLite dependency gate ? PASS: 9 runs, 107 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_release_evidence.rb` after SQLite release evidence refresh ? PASS: 2 runs, 259 assertions, 0 failures, 0 errors
- `ruby -Itest test/test_agent_os_v32_static_surface_audit.rb` after SQLite release evidence refresh ? PASS: 6 runs, 136 assertions, 0 failures, 0 errors
- `ruby -w -Ilib -e "require 'aiweb'; puts 'warning load OK'"` after SQLite adapter ? PASS
- JSON/YAML/integrity check after SQLite release evidence refresh ? PASS
- repository text guard after SQLite adapter ? PASS: 303 files scanned
- `git diff --check` after SQLite adapter ? PASS

## Completion

Not complete. The fixed script-runner deletion part is substantially complete, including fail-closing stale deploy execution, demoting browser scenario wording to deterministic probe evidence, demoting CLI/contract Manus wording marketing language, preventing fixture evals and red-team catalog probes from claiming production readiness, redacting secret-canary output, demoting self-improvement dry-runs, release validation claims, policy/tool gateway claims, HITL fixture claims, replay demo claims, Brain safety wording to production-blocked/targeted evidence, replacing Brain JSON snapshots with hash-chained JSONL plus projection/health reports, file-lock write serialization, backup/restore drill evidence, and SQLite-backed storage production blocker, centralizing the Codex `agent-run` worker subprocess through ProcessRunner while preserving broker evidence, centralizing the OpenManus `agent-run` sandbox worker subprocess through ProcessRunner, centralizing the canonical `engine-run` agent worker subprocess through ProcessRunner, centralizing the `engine_run_capture_command` helper through ProcessRunner, centralizing setup install/SBOM/audit subprocesses through ProcessRunner, centralizing the backend CLI bridge subprocess through ProcessRunner, centralizing Lazyweb external HTTP transport through HttpClient, enforcing LaunchSpec for long-running preview/workbench ProcessLauncher calls, centralizing bin verification harness subprocesses through ProcessRunner, centralizing runtime command git/taskkill process forms, centralizing `agent_run/diff_policy` git diff/status evidence, centralizing OpenManus readiness image-inspect preflight, centralizing agent-run OpenManus image-inspect preflight, and centralizing engine-run sandbox runtime attestation Docker/Podman probes, removing direct `agent-run --approved` without matching dry-run `--approval-hash`, removing `engine-scheduler --approved --execute` resume bridge execution without a matching resume `--approval-hash`, removing `setup --install --approved` package-manager execution without a matching setup capability `--approval-hash`, removing `workbench --serve --approved` local server launch without a matching Workbench serve capability `--approval-hash`, removing backend generic approved command bridge forwarding without a matching `--approval-hash` / `--approval-request` argument, removing implementation MCP broker approved connector/file-access execution without a matching broker capability `--approval-hash`, and removing eval-baseline import corpus overwrite execution without a matching import capability `--approval-hash`; run lifecycle approved-only resume guidance, Workbench executable-button descriptors, webbuilder/README verify-loop-first examples, and aiweb help verify-loop approved examples have been demoted to dry-run/hash-discovery descriptors; the full objective remains active until Manus-grade/natural-language web-app agent readiness is proven requirement-by-requirement, including full ruby bin/check/test-all evidence or a verified replacement CI evidence bundle.
