# Final /goal Prompt

Repo: `C:\dev\webbuilderagent`.

Read `docs/goals/WEBBUILDER_AGENTIFICATION_EXECUTION_PLAN.md` first. Treat it as the repo-local implementation backlog and acceptance checklist for this `/goal` run, subordinate to system/developer/user instructions, `AGENTS.md`, and the current `.ai-web/state.yaml` phase/gate state.

Goal: Implement the plan to transform webbuilderagent into a supervised local web-building agent with profile-aware D/S runtime contracts, centralized PathPolicy/EnvPolicy/CommandSpec/ProcessRunner safety, AgentRuntime observe/plan/act/verify/reflect loop, bounded source patch manifest, browser QA feedback loop, verify-loop integration, evidence UX, runtime artifacts, and safety/E2E validation.

Pre-read and workspace hygiene:
- Read `AGENTS.md` and the required `.ai-web` context files it names before implementation.
- Treat this prompt plus `docs/goals/WEBBUILDER_AGENTIFICATION_EXECUTION_PLAN.md` as the current task packet for this implementation work.
- Run `git status --short --branch` and classify dirty/untracked files as `in_scope_prior_work`, `unrelated_user_work`, or `ambiguous_ownership` before editing.
- Inspect and adopt in-scope prior work instead of overwriting it. Do not touch unrelated user/agent work. Stop with a blocker if ambiguous ownership would risk destroying work.
- Do not commit transient raw QA/browser/dependency artifacts.
- Local repo edits, tests, refactors, and docs updates required to implement this plan are authorized. Product approval rules apply to the runtime behavior being built, not to this implementation task. Do not ask before safe local reversible edits or validation commands.

Hard constraints:
- Do not read, print, patch, copy, or commit `.env` / `.env.*` or secret-looking files.
- Do not run deploy/provider/external-production actions during this `/goal` run, even if provider/deploy code paths are implemented. Only document or test local/manual deploy planning behavior.
- Do not use package installs, external Lighthouse/network services, provider CLIs, MCP servers, Lazyweb, or networked design-research tools unless a human explicitly changes the `.ai-web/state.yaml` adapter contract.
- Preserve `adapters.implementation_agent.network_allowed: false` and `mcp_servers_allowed: []` unless explicitly changed by a human.
- Do not push or commit unless explicitly requested after validation.
- Do not allow source patching outside the workspace.
- Do not introduce raw shell-string subprocess execution in new runtime code; new process execution must use argv-style `CommandSpec -> ProcessRunner`.
- Respect `.ai-web/state.yaml` phase/gate rules; do not silently advance release/deploy gates.
- Preserve existing CLI/API/JSON compatibility unless a test-backed migration is necessary.
- Do not claim terminal status `complete` while required validation is failing or missing. Browser QA is required when the active profile contract supports/requires it; otherwise report the profile state and Not-tested gap.
- Treat approval tokens/hashes as product-runtime concepts, not permission for this implementation agent to perform external, destructive, credentialed, or production actions.
- Workbench/UI/browser-visible changes must follow existing patterns and `AGENTS.md` design-gate rules. If a design-significant UI change lacks a selected design candidate/task packet, record a blocker instead of bypassing the gate.

Required order:
1. Inspect the repo and summarize current structure, inconsistencies, risks, dirty workspace classification, known blockers, and first safe slice.
2. Add or identify targeted regression tests before refactoring each touched subsystem.
3. Implement D/S ProfileRuntimeContract/ProfilePolicy and intent routing.
4. Centralize PathPolicy, EnvPolicy, CommandSpec, ProcessRunner, ArtifactStore, and ToolResult.
5. Refactor Project toward a compatibility facade while preserving public CLI/API/JSON behavior.
6. Implement AgentRuntime Session/Observer/Planner/ToolRegistry/Executor/Verifier/Reflector/Loop with terminal statuses `complete`, `blocked`, `partial_not_complete`, and `failed_validation`.
7. Add bounded source patch manifest and verifier-gated copy-back/source mutation.
8. Normalize browser QA feedback and connect it to reflect/repair.
9. Reposition verify-loop on AgentRuntime and profile contracts.
10. Update README/help and existing CLI evidence UX. Update Workbench only if an existing Workbench surface is present and design-gate requirements are satisfied.
11. Add required runtime artifacts and schemas under `.ai-web/runs/<run_id>/` or document an existing equivalent artifact root.
12. Add required unit/integration/E2E/safety/final-report schema tests, including Windows/Korean CLI encoding where relevant.
13. Run repo-appropriate validation commands, fix failures, and record any blocked checks with narrow fallback evidence and reproduction commands.
14. Final report must include terminal status, changed files, validation commands/results, browser QA evidence or profile-specific Not-tested reason, artifact paths, risks, and next steps.

Stop condition: Finish only when all implementable completion criteria are met, all runnable validation passes, and any environment-blocked checks have been attempted with the narrowest meaningful fallback and reported under Not-tested with reproduction commands. If required Not-tested items remain without accepted-risk coverage, report `partial_not_complete` or `blocked`, not `complete`. If a safe implementation or validation path remains, continue instead of asking.
