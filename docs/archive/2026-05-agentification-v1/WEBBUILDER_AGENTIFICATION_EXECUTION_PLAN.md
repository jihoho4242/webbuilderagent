# Webbuilderagent Agentification Execution Plan

Purpose: This document is the repo-local implementation backlog and acceptance checklist for a future `/goal` run. The `/goal` prompt should instruct the agent to read this file first, then implement the plan to completion.

Status: planning document only. It does not unlock deploy/provider/broker/external-production actions.

## 0. Required Operating Context and Workspace Hygiene

This plan is the current task packet for the future `/goal` run. It is subordinate to higher-priority system/developer/user instructions, the repository `AGENTS.md` contract, and the current `.ai-web/state.yaml` phase/gate state.

Before implementation, the executor must:

- read and follow `AGENTS.md`,
- read the required `.ai-web` context files listed by `AGENTS.md` when present,
- run `git status --short --branch`,
- identify unrelated dirty/untracked files and avoid touching them,
- avoid committing generated raw data, screenshots, large artifacts, dependency caches, or temporary browser outputs unless the repo already tracks an intentional fixture location,
- preserve existing public CLI/API/JSON compatibility unless a test-backed migration is explicitly implemented,
- treat this document as planning guidance, not as authority to bypass safety, approval, or gate requirements.

For this `/goal` run, local repository edits, tests, refactors, and documentation updates required to implement this plan are authorized. Product approval requirements described in this plan apply to the runtime behavior being built, not to ordinary safe local implementation edits by the executor.

Dirty workspace adoption rules:

- classify dirty/untracked files as `in_scope_prior_work`, `unrelated_user_work`, or `ambiguous_ownership`,
- inspect and adopt `in_scope_prior_work` instead of overwriting it,
- avoid touching `unrelated_user_work`,
- stop with a blocker if ownership is ambiguous and editing would risk destroying another agent/user's work,
- never use broad reset/clean/revert commands to simplify the workspace.

Workbench/UI/browser-visible changes:

- if the repo already has a Workbench/UI surface, update evidence UX only within existing patterns,
- do not invent visual design changes without satisfying the selected-design/task-packet rules in `AGENTS.md`,
- if a required Workbench/UI change is design-significant and no selected design candidate/task packet exists, record a blocker instead of bypassing the gate.

The first implementation note should summarize current structure, dirty workspace classification, known blockers, and the first safe slice to implement.


## 1. Target Outcome

Transform `webbuilderagent` from a local scaffold/QA director into a supervised local web-building agent that can safely:

1. interpret a user web-building goal,
2. observe the current project and runtime state,
3. plan profile-aware work,
4. execute bounded local actions,
5. verify with build/runtime/browser evidence,
6. reflect on failures,
7. perform bounded repairs,
8. produce a final evidence-backed report.

The final product must be honest about its scope: it is not an unsupervised full-stack SaaS generator and must not silently deploy, create hosted provider resources, read secrets, or use credentials.

## 2. Non-Negotiable Safety Constraints

- Do not read, print, patch, copy, or commit `.env` / `.env.*` or secret-looking files.
- Do not run deploy/provider/external-production actions during this `/goal` run, even if provider/deploy code paths are implemented; only document or test local/manual deploy planning behavior.
- Do not use package installs, external Lighthouse/network services, provider CLIs, MCP servers, Lazyweb, or networked design-research tools unless a human explicitly changes the `.ai-web/state.yaml` adapter contract.
- Preserve `adapters.implementation_agent.network_allowed: false` and `mcp_servers_allowed: []` unless explicitly changed by a human.
- Do not allow source patching outside the workspace.
- Do not use raw shell-string process execution for new runtime code; new subprocesses must use argv-style `CommandSpec -> ProcessRunner` or an existing compatibility facade that is explicitly marked for migration.
- Do not allow unbounded edit loops, unbounded repair loops, or unbounded process output.
- Do not claim `complete` if required validation fails or is missing. Browser QA is required when the active profile contract supports/requires it; otherwise the final report must state the profile state, reason, and Not-tested gap.
- Preserve existing CLI/public JSON compatibility unless a test-backed migration is unavoidable.
- Do not commit or push unless the user explicitly asks after validation.
- Respect repository phase/gate rules in `.ai-web/state.yaml`; do not silently advance release/deploy gates.
- Do not commit transient QA/browser artifacts unless they are explicit small fixtures required by tests.
- Treat approval tokens/hashes as product-runtime concepts, not permission for the implementation agent to perform external, destructive, credentialed, or production actions.

## 3. Product Contract Cleanup

### 3.1 README and Help Positioning

Update README and help so they consistently describe the tool as:

> a supervised local web-building agent/director that plans, scaffolds, edits, checks, repairs, and reports with visible evidence.

Avoid unsupported claims such as:

- complete production app from one prompt,
- unsupervised full-stack web agent,
- silent deploy automation,
- credential/provider setup automation.

Add clear sections:

- What it is
- What it is not
- Capabilities
- Boundaries
- Approval model
- Profile guide
- Agent command workflow
- Validation and QA artifacts

### 3.2 `agent-run` Positioning

Treat `agent-run` as a bounded safe execution slot, not the top-level autonomous agent. Keep backward compatibility, but document it as an advanced/internal execution surface.

Add or clarify a top-level goal-driven agent surface, for example:

```bash
webbuilder agent "Build a premium landing page" --mode supervised --max-steps 20
```

Allowed modes:

- `plan-only`: observe/plan/report only, no writes.
- `supervised`: safe reads/checks continue, meaningful writes require approval or an approval token.
- `autonomous-local`: safe local edits/checks/repairs can continue; destructive/external/credentialed actions remain blocked.

## 4. Profile D/S Runtime Contract

Create a canonical `ProfileRuntimeContract` / `ProfilePolicy` layer. Runtime, verify-loop, build, preview, QA, and help must query the contract instead of hardcoding Profile D required files.

Suggested files:

```text
lib/aiweb/profile_policy/base.rb
lib/aiweb/profile_policy/profile_d.rb
lib/aiweb/profile_policy/profile_s.rb
lib/aiweb/profile_policy/resolver.rb
```

Each contract should declare:

- profile id and display name,
- framework/runtime family,
- required files,
- metadata path,
- package manager,
- setup/build/preview/browser QA capability,
- local verification capability,
- env policy,
- provider/deploy policy,
- forbidden actions,
- readiness states,
- help/documentation summary.

### 4.1 Profile D Semantics

Profile D is the Astro/static/content/frontend runtime contract.

Expected capabilities:

- scaffold,
- setup/build/preview when files are present,
- browser QA,
- screenshot/evidence collection,
- visual critique,
- bounded source patch/repair,
- final deploy-readiness report.

Forbidden by default:

- silent deploy,
- provider CLI,
- credentials,
- external production mutation.

### 4.2 Profile S Semantics

Profile S is a Next.js App Router + Supabase SSR local scaffold contract.

Expected capabilities:

- local scaffold,
- Supabase SSR stubs,
- migrations/RLS/storage docs or local-only artifacts,
- secret QA,
- local verification,
- optional typecheck/build only if safe placeholder public env can be injected without `.env` reads.

Forbidden by default:

- hosted Supabase project creation,
- Supabase provider CLI/network mutation,
- deploy,
- `.env` / `.env.*` reads,
- credential use.

If build/preview/browser QA is not fully supported for Profile S, return an explicit state such as `profile_s_local_verify_only` instead of failing with Profile D/Astro missing-file blockers.

### 4.3 Intent Routing

Update routing so Profile S is reachable from explicit Supabase/local database/storage/auth intent.

Add terms such as:

- supabase,
- rls,
- storage,
- postgres,
- auth,
- oauth,
- magic link,
- upload,
- 수파베이스,
- 인증,
- 로그인,
- 회원,
- 스토리지,
- 업로드.

Add tests proving:

- Supabase/RLS/storage intent recommends S,
- content/blog/docs/SEO intent recommends D,
- unsupported A/B/C runtime states are honest and do not pretend to scaffold/build when unsupported.

## 5. Runtime Safety Layer

Centralize process, path, environment, artifact, and command policy.

Suggested files:

```text
lib/aiweb/runtime/path_policy.rb
lib/aiweb/runtime/env_policy.rb
lib/aiweb/runtime/command_spec.rb
lib/aiweb/runtime/process_runner.rb
lib/aiweb/runtime/artifact_store.rb
lib/aiweb/runtime/tool_result.rb
```

### 5.1 PathPolicy

Responsibilities:

- canonical project-root checks,
- workspace relative path normalization,
- artifact path validation,
- staged workspace path validation,
- source allowlist checks,
- `.env` / `.env.*` segment blocking,
- secret-looking path blocking,
- traversal blocking,
- symlink/hardlink/realpath escape blocking,
- Windows path/backslash handling.

### 5.2 EnvPolicy

Responsibilities:

- clean default env,
- allowlisted env injection,
- profile-specific env capabilities,
- public placeholder env for safe local builds when required,
- forbidden env passthrough,
- secret redaction for stdout/stderr/report/help/log output.

### 5.3 CommandSpec and ProcessRunner

All new subprocess execution must go through:

```text
CommandSpec -> ProcessRunner
```

`CommandSpec` should represent:

- argv array, not shell string,
- cwd,
- env,
- timeout,
- max output bytes,
- expected outputs,
- risk class,
- approval hash/token if required,
- profile support,
- artifact destinations.

`ProcessRunner` should enforce:

- no raw shell interpolation,
- no command chaining/pipe/redirect unless explicitly modeled and safe,
- `unsetenv_others: true` or equivalent clean-env behavior,
- output redaction,
- timeout and cleanup,
- structured result objects,
- side-effect/evidence artifact recording.

## 6. Project Facade Refactor

Keep existing public methods and CLI compatibility, but move policy and execution out of `Project`.

`Project` should own:

- root/context,
- state load/save,
- public method compatibility,
- payload wrapping,
- service wiring.

Move out:

- profile semantics,
- runtime-plan logic,
- build/preview/QA execution,
- browser observation,
- source patch/copy-back policy,
- agent loop planning,
- process/env/path safety.

Suggested service boundaries:

```text
ProfilePolicyResolver
RuntimePlanService
BuildService
PreviewService
BrowserQaService
AgentRunService
VerifyLoopService
ArtifactStore
RunLifecycleService
SecurityBoundary
```

Perform this incrementally: add service objects and delegate existing `Project` methods first; remove old internal logic only after tests pass.

## 7. AgentRuntime Architecture

Introduce or reorganize an explicit AgentRuntime layer.

Suggested files:

```text
lib/aiweb/agent_runtime/session.rb
lib/aiweb/agent_runtime/observer.rb
lib/aiweb/agent_runtime/planner.rb
lib/aiweb/agent_runtime/tool_registry.rb
lib/aiweb/agent_runtime/executor.rb
lib/aiweb/agent_runtime/verifier.rb
lib/aiweb/agent_runtime/reflector.rb
lib/aiweb/agent_runtime/loop.rb
```

### 7.1 Session

Owns:

- run_id,
- goal,
- mode,
- profile contract hash,
- run paths,
- approval tokens/budget,
- max steps,
- max repairs,
- lifecycle status,
- active-run lock,
- resume/cancel/checkpoint state,
- timeline artifact.

### 7.2 Observer

Normalizes:

- `.ai-web/state.yaml`,
- selected profile/contract,
- runtime-plan,
- package/project metadata,
- staged/source manifest,
- latest build/preview/QA evidence,
- browser feedback,
- prior failure signatures.

### 7.3 Planner

Converts goal + observation + profile contract into the next safe task graph/action.

Outputs should include:

- action/tool name,
- reason,
- risk level,
- required approval,
- expected artifacts,
- verification plan,
- stop condition.

### 7.4 ToolRegistry

Declares allowed tools and their policies, for example:

- observe_project,
- runtime_plan,
- build,
- preview,
- browser_qa,
- screenshot,
- a11y,
- lighthouse or fallback quality smoke,
- source_patch,
- create_repair_task,
- final_report.

Each tool must declare profile support, command spec or pure-ruby implementation, writes/reads, approval requirement, and output artifacts.

### 7.5 Executor

Executes only registered tools. No direct process calls outside Runtime ProcessRunner.

### 7.6 Verifier

Determines:

- step pass/fail,
- copy-back eligibility,
- safety gate pass/fail,
- browser QA pass/fail,
- report completeness,
- final completion state.

### 7.7 Reflector

Turns failures into bounded next actions.

Responsibilities:

- classify failure,
- hash failure signature,
- detect repeated failures,
- choose repair strategy,
- stop on max repairs/max steps,
- write reasoned stop report if unrecoverable.

### 7.8 Loop

Runs:

```text
observe -> plan -> execute -> verify -> reflect -> next or finish
```

Hard requirements:

- max_steps,
- max_repairs,
- timeout/cancel support,
- no infinite repeated-failure loop,
- timeline artifact,
- final report artifact.

### 7.9 Terminal States

Every AgentRuntime run must finish with exactly one machine-readable terminal status:

- `complete`: all implementable completion criteria are met and all runnable validation passed.
- `blocked`: a hard safety, ownership, gate, missing authority, or environment blocker prevents safe progress.
- `partial_not_complete`: useful implementation exists, but one or more required acceptance criteria remain incomplete or Not-tested.
- `failed_validation`: implementation was attempted, but required validation failed and no safe repair path remains within max_steps/max_repairs.

Rules:

- Required Not-tested items prevent `complete` unless an explicit accepted-risk policy already exists in the repo and the final report references it.
- If a safe implementation or validation path remains, continue instead of stopping at `partial_not_complete`.
- Final human and JSON reports must use the same terminal status and list blockers, validation failures, Not-tested gaps, and reproduction commands.

## 8. Bounded Source Patch Manifest

Source patching must be manifest-authorized and verifier-approved.

Create an artifact such as:

```text
source-patch-manifest.json
```

Suggested fields:

- run_id,
- profile_contract_hash,
- allowed source paths,
- base file hashes,
- requested changes,
- changed file manifest,
- max changed files,
- max patch bytes,
- create/delete/rename permissions,
- blocked changes,
- approval/safe changes,
- diff path,
- copy-back status,
- secret scan result,
- verifier decision.

Rules:

- Manifest absent: real source copy-back is blocked.
- Manifest mismatch: blocked.
- File hash mismatch: blocked or require re-observe/replan.
- Forbidden file/path: blocked.
- Large or broad patch: blocked or requires explicit approval.
- Diff and summary must be persisted.

## 9. Browser QA Feedback Loop

Browser QA should produce structured feedback, not just logs.

Create or normalize an artifact such as:

```text
browser-qa-feedback.json
```

Fields should include:

- route,
- viewport,
- screenshot path,
- console errors,
- network failures,
- status codes,
- a11y violations,
- visible heading/CTA checks,
- horizontal overflow,
- interaction smoke,
- lighthouse summary or fallback quality smoke,
- pass/fail/warning status,
- suggested repair hints.

Policy:

- localhost-only,
- no external navigation,
- no real form submission,
- reversible interactions only,
- no deploy/provider actions.

Connect this artifact to Reflector so QA failures can produce bounded repair tasks.

## 10. Verify-loop Repositioning

Move direct procedural verify-loop logic behind AgentRuntime.

Keep:

```text
Project#verify_loop
```

as a compatibility facade.

Internally call AgentRuntime with a profile contract.

Profile D expected graph:

```text
runtime_plan -> build -> preview -> browser_qa -> visual_critique -> source_patch/repair -> reverify -> final_report
```

Profile S expected graph:

```text
runtime_plan -> supabase_secret_qa -> local_verify -> optional safe build/typecheck -> optional preview/browser_qa -> source_patch/repair -> final_report
```

Do not let Profile S fail with D/Astro required file blockers.

## 11. CLI Evidence UX and Optional Workbench UX

Expose the agent loop clearly.

CLI output must show:

- goal interpretation,
- selected profile and reason,
- current phase/step,
- plan,
- pending approval,
- files affected,
- risk class,
- build/preview/browser QA evidence,
- repair attempts,
- stop reason,
- final readiness report.

If an existing Workbench surface is present, update it within existing UI/design patterns. Do not create a new Workbench product surface solely for this plan unless tests and `AGENTS.md` design-gate requirements are satisfied.

Optional Workbench target panels:

- Goal / Brief,
- Timeline,
- Live Preview,
- Approval Queue,
- Evidence / Logs,
- Repair Loop,
- Final Report.

## 12. Required Runtime Artifacts and Schemas

The implementation must create or normalize small machine-readable artifacts so the agent can resume, audit, and explain its work.

Default artifact root:

```text
.ai-web/runs/<run_id>/
```

If the repo already has a clearly equivalent run-artifact convention, the implementation may adapt to it, but the final report must document the actual root and schema mapping.

Required artifacts:

- `agent-session.json`: run id, goal, mode, profile, contract hash, budgets, lifecycle status, stop reason.
- `timeline.jsonl`: append-only observe/plan/act/verify/reflect events with timestamps and artifact references.
- `tool-result-*.json`: structured result for build, preview, browser QA, patch, and verification tools.
- `source-patch-manifest.json`: authorized source mutation boundaries, hashes, diff path, verifier decision, copy-back status.
- `browser-qa-feedback.json`: route/viewport/screenshots/console/network/a11y/interaction findings and repair hints.
- `final-report.json` and/or `final-report.md`: human and machine-readable completion evidence.

Artifact rules:

- Artifacts must not contain secrets or `.env` values.
- Large screenshots/videos/logs should be kept out of git unless deliberately small test fixtures.
- Final reports must reference artifact paths, validation commands, failure reasons, and Not-tested gaps.
- Schema tests should cover success, failure, blocked, and partial/Not-tested reports.

### 12.1 Required Acceptance Constants

Use these defaults unless an existing repo convention already defines stricter values:

- `max_steps` default: `20`; hard upper bound without explicit local override: `50`.
- `max_repairs` default: `3`; hard upper bound without explicit local override: `8`.
- process timeout default: `120s`; long-running validations must write bounded logs and be resumable/reproducible.
- process output cap default: `200_000` bytes per stream with redaction before persistence.
- source patch max changed files default: `20`.
- source patch max bytes default: `200_000` bytes.
- allowed source patch roots by default: `src/`, `public/`, documented small config files, and existing test/docs files required for this plan.
- forbidden patch roots: `.git/`, `.ai-web/state.yaml` gate mutations unless explicitly required and test-backed, `.env*`, `node_modules/`, dependency caches, generated screenshots/videos, provider credentials/config containing secrets.
- browser QA localhost-only routes; no external navigation and no real form submission.
- a11y gate: critical/serious violations fail when browser QA is supported by the active profile.
- browser layout gate: horizontal overflow, missing primary heading, missing visible CTA on expected landing routes, or critical console/runtime errors fail Profile D golden path QA.

## 13. Required Tests

Add or update tests for all of the following.

### 13.1 README/help contract tests

- README documented commands appear in help.
- Help profile list includes supported profiles including S.
- Quickstart commands are executable or dry-run executable.
- Deprecated unsupported claims/options are not present.

### 13.2 Profile routing and contract tests

- Profile D resolves to D contract.
- Profile S resolves to S contract.
- Supabase/RLS/storage/auth explicit intent can recommend S.
- Content/blog/docs/SEO intent can recommend D.
- Invalid profile is rejected with a clear error.
- D/S env/process/runtime permissions do not cross-contaminate.

### 13.3 Runtime safety tests

PathPolicy:

- blocks `.env`, `.env.local`, `dir/.env.production`,
- blocks `../` traversal,
- blocks absolute path escape,
- blocks symlink/realpath escape,
- blocks secret-looking files,
- handles Windows separators.

EnvPolicy:

- only allowlisted env is passed,
- secret-looking values are redacted,
- profile-specific env isolation works.

ProcessRunner:

- argv-only execution,
- shell injection/pipe/redirect/chaining blocked,
- timeout works,
- non-zero exit returns structured result,
- output redaction works,
- process cleanup works.

### 13.4 AgentRuntime loop tests

- normal success path,
- act failure path,
- verify failure path,
- max_steps stop,
- max_repairs stop,
- repeated failure stop,
- cancellation/checkpoint if supported,
- final stop reason is written.

### 13.5 Bounded patch tests

- manifest-limited file changes pass,
- manifest-external file changes fail,
- forbidden path changes fail,
- patch size/file count limits work,
- dry-run does not write,
- final report includes manifest summary.

### 13.6 Browser QA tests

- desktop screenshot artifact,
- mobile screenshot artifact,
- console error capture,
- network error capture,
- a11y critical/serious gate,
- CTA visibility,
- no horizontal overflow,
- artifact linked to final report.

### 13.7 D/S E2E smoke and golden path

- Profile D golden path from scaffold/runtime-plan/build/preview/browser QA/report.
- Profile S local scaffold/secret QA/local verify/report.
- README golden path runs in CI or CI-equivalent mode.
- Failures produce machine-readable reports with reproduction commands.

### 13.8 Windows/Korean CLI encoding tests

- Korean intent text must route without encoding crashes on Windows PowerShell and UTF-8 environments.
- Help/README examples containing Korean text must render without mojibake where practical.
- Path normalization tests must include Windows separators and drive-root escape attempts.

### 13.9 Final report schema tests

Final JSON and/or Markdown report must include:

- status: one of `complete`, `blocked`, `partial_not_complete`, `failed_validation`,
- summary,
- profile,
- mode,
- steps,
- tests,
- browserQa,
- patchManifest,
- safety,
- artifacts,
- errors,
- warnings,
- reproduction,
- ci or local validation summary,
- Not-tested if applicable.

Reports must not include secrets.

## 14. Validation Commands

Use the repository's actual commands. Inspect scripts first.

Preferred validation order:

1. Ruby syntax/load checks,
2. existing `ruby bin/check` or equivalent,
3. unit tests,
4. targeted new tests,
5. integration tests,
6. D/S smoke tests,
7. browser QA smoke,
8. final report schema validation.

If a command times out or fails due environment, classify the failure and run the narrowest meaningful replacement. Do not hide validation gaps.

Do not install dependencies or reach the network to satisfy validation unless the repo already has an approved local command and the `.ai-web/state.yaml` adapter contract permits it. If dependencies are missing, prefer syntax/load/unit checks and report the blocked E2E command with reproduction instructions.

## 15. Completion Criteria

Only report terminal status `complete` when all are true:

- README/help/product contract is honest and consistent.
- Profile D/S contract is centralized and used by runtime-plan/build/preview/QA/verify-loop.
- Profile S is reachable and does not fall into D/Astro blockers.
- Runtime PathPolicy/EnvPolicy/CommandSpec/ProcessRunner exists and is used by new execution paths.
- AgentRuntime observe/plan/act/verify/reflect loop exists.
- Bounded source patch manifest gates copy-back/source mutation.
- Browser QA feedback artifact feeds reflect/repair.
- Workbench/CLI surfaces timeline/evidence/failures/reports.
- Required runtime artifacts are written with schemas and secret redaction.
- Required tests are added/updated and pass locally or in CI-equivalent validation.
- Any Not-tested item is non-required, environment-blocked with fallback evidence, or covered by an explicit accepted-risk policy; otherwise the terminal status is `partial_not_complete` or `blocked`, not `complete`.
- Final report includes changed files, validation commands/results, browser QA artifacts or profile-specific Not-tested reason, risks, and next steps.

## 16. Suggested Final Report Template

````md
## 완료 요약

webbuilderagent를 감독형 로컬 웹 제작 에이전트 구조로 개선했습니다.

### 구현한 항목

- [ ] README/help/product contract 정렬
- [ ] Profile D/S runtime contract
- [ ] Profile S routing/help/runtime-plan 처리
- [ ] PathPolicy 중앙화
- [ ] EnvPolicy 중앙화
- [ ] CommandSpec/ProcessRunner 중앙화
- [ ] Project facade화
- [ ] AgentRuntime observe/plan/act/verify/reflect
- [ ] bounded source patch manifest
- [ ] browser QA feedback loop
- [ ] verify-loop 재배치
- [ ] Workbench/CLI evidence UX
- [ ] CI/E2E/safety tests

### 변경 파일

- `...`

### 검증 명령 및 결과

```bash
...
```

### Browser QA evidence

- desktop screenshot:
- mobile screenshot:
- console:
- network:
- a11y:
- visible CTA:
- responsive:

### 남은 리스크

- 없음 / 또는 구체적 항목

### Not-tested

- 없음 / 또는 구체적 이유

### 다음 단계

- 선택 사항
````
