# Engine Run Contract

`engine-run` is the Manus-style agentic runtime for WebBuilderAgent.

It does not replace the existing bounded `agent-run` safe patch flow. `safe_patch` stays available for conservative source edits. `agentic_local` adds a staged sandbox workspace where the agent can inspect, edit, run local checks, observe failures, and retry before aiweb validates copy-back.

## Modes

- `safe_patch`: delegates to the existing bounded `agent-run` contract.
- `agentic_local`: stages a filtered project copy, runs the selected sandboxed agent in that workspace, validates changes, and copies back only safe files. Real `agentic_local` cannot use unsandboxed Codex; use `safe_patch` for Codex or `--agent openmanus --sandbox docker|podman` for sandboxed autonomy.
- `external_approval`: reserved for elevated capabilities such as package install, external network, deploy, provider CLI, MCP/connectors, or git push.

## Trust Boundary

The agent never receives a writable host project root. aiweb stages a workspace under `.ai-web/tmp/agentic/<run-id>/workspace` and excludes `.env*`, `.git`, dependency folders, generated bulk output, provider credentials, browser profiles, and secret-looking paths.

The copy-back gate validates:

- writable glob envelope
- denylisted and secret-looking paths
- secret-like file content
- binary files
- symlinks and hardlinks
- deletes and high-risk files such as lockfiles or deploy config

Safe source/test/style changes may be copied back automatically. High-risk changes move the run to `waiting_approval`. Unsafe changes move it to `blocked`.

## Evidence

Every real `engine-run` records:

- `.ai-web/runs/<run-id>/engine-run.json`
- `.ai-web/runs/<run-id>/job.json`
- `.ai-web/runs/<run-id>/events.jsonl`
- `.ai-web/runs/<run-id>/approvals.jsonl`
- `.ai-web/runs/<run-id>/checkpoint.json`
- `.ai-web/runs/<run-id>/artifacts/staged-manifest.json`
- `.ai-web/runs/<run-id>/artifacts/opendesign-contract.json`
- `.ai-web/runs/<run-id>/artifacts/agent-result.json` when the sandbox worker reports one
- `.ai-web/runs/<run-id>/qa/verification.json`
- `.ai-web/runs/<run-id>/qa/preview.json`
- `.ai-web/runs/<run-id>/qa/screenshots.json`
- `.ai-web/runs/<run-id>/qa/design-verdict.json`
- `.ai-web/runs/<run-id>/qa/design-fidelity.json`
- `.ai-web/diffs/<run-id>.patch`

The local backend treats approved real `POST /api/engine/run` and `POST /api/engine/approve` calls as durable background jobs. The HTTP response returns immediately with the selected `run_id`, `.ai-web/runs/<run-id>/job.json`, and the event stream path. The worker then invokes the dedicated `engine-run` bridge with `--run-id <run-id>` so the web console can poll one stable run id from queued through finished.

`engine-run` is not exposed through `POST /api/project/command`. Frontends must use the dedicated engine APIs so raw command composition, approval resume, job status, and run-stream behavior stay inside one typed contract.

`GET /api/engine/openmanus-readiness` reports Docker/Podman executable availability and local `openmanus:latest` image readiness before the web UI enables approved OpenManus run controls.

The event stream includes runtime boundary evidence:

- `sandbox.preflight.started`
- `sandbox.preflight.finished`
- `backend.job.queued`
- `backend.job.started`
- `backend.job.finished`
- `backend.job.failed`
- `design.contract.loaded`
- `design.contract.missing`
- `design.contract.changed`
- `design.fidelity.checked`
- `preview.started`
- `preview.ready`
- `preview.failed`
- `preview.stopped`
- `screenshot.capture.started`
- `screenshot.capture.finished`
- `screenshot.capture.failed`
- `browser.observation.recorded`
- `design.review.started`
- `design.review.finished`
- `design.review.failed`
- `tool.action.requested`
- `tool.action.blocked`

Every event has a monotonically increasing `seq` within the run. `job.json` records the current engine-run job status and points at the event stream so backend clients can poll without reading process state.

Dry-run writes nothing and returns the planned paths plus a capability envelope, OpenDesign contract hashes, and approval hash. The approval hash is stable across dry-run and real execution for the same goal, mode, agent, sandbox, limits, resume target, copy-back envelope, and OpenDesign contract; the transient run id is excluded from the hash.

The OpenDesign contract records `.ai-web/DESIGN.md`, optional `.ai-web/design-reference-brief.md`, `.ai-web/design-candidates/selected.md`, the selected candidate artifact, and optional `.ai-web/component-map.json` by path, bytes, and SHA-256. UI/source work in Profile D is blocked before agent execution when no selected design candidate or selected candidate artifact is available.

Before copy-back, `design-fidelity.json` records deterministic static fidelity. It blocks source that drops required `data-aiweb-id` hooks from the component map, drifts the selected candidate identity, or leaks forbidden reference/brand terms from the design reference brief. `selected_design_fidelity` must meet the configured threshold before safe changes can be copied back.

When `package.json` exposes `dev` or `preview`, engine-run starts the preview command only through the same sandbox command wrapper and records `preview.json` with command, URL, stdout/stderr excerpt, process-tree placeholder, startup status, and stop evidence. Preview failure prevents copy-back.

When preview is ready, engine-run records desktop, tablet, and mobile screenshot evidence in `qa/screenshots.json` plus screenshot files under the run screenshots directory. Browser observation evidence is localhost-only and feeds the later visual-fidelity verdict loop.

`design-verdict.json` is a hard gate. The deterministic local reviewer records hierarchy, spacing, typography, color, originality, mobile polish, brand fit, intent fit, and selected-design fidelity scores. Copy-back is prevented when a required score or average score is below threshold.

When a design verdict fails and cycles remain, `_aiweb/repair-observation.json` includes preview evidence, screenshot metadata, the design verdict, selected OpenDesign contract identity, and repair instructions. The next sandbox cycle records `design.repair.started` and `design.repair.finished`.

Approval records include an explicit `execute` scope, the run id, capability hash, single-use marker, and the approved capability envelope. Reusing an approval hash after the OpenDesign contract changes is rejected before run artifacts are written.

`--resume <run-id>` reads the prior checkpoint and staged manifest, reuses the prior staged workspace when present, records `run.resumed`, and copies back only after the same validation gate passes.

When aiweb's sandbox verification fails and cycles remain, aiweb records `qa.failed`, writes `_aiweb/repair-observation.json` inside the staged workspace, records `repair.planned`, and invokes the worker again with that observation available. Copy-back still happens only after the final policy and verification pass.

## Guardrails

- No host root writable mount.
- Real `agentic_local` agent/tool execution must run through an aiweb-validated Docker/Podman no-network command.
- No `.env`, credentials, provider auth, browser profile, or secret-looking path access.
- Network is disabled by default.
- Package install, external network, deploy, provider CLI, MCP/connectors, and git push are represented as structured blocked actions before copy-back and require explicit elevated approval.
- Web Workbench is a later view/control layer, not a prerequisite for this runtime.
