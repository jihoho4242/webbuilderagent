# OpenManus Agent Run Contract

This contract defines the first supported integration between aiweb and OpenManus.

OpenManus is never the project director. aiweb owns `.ai-web` state, phase gates, task packets, QA evidence, snapshots, patch validation, and deploy provenance. OpenManus is only a bounded implementation adapter behind:

```bash
aiweb agent-run --task latest --agent openmanus --dry-run --json
aiweb agent-run --task latest --agent openmanus --sandbox docker --approved --json
```

## Invocation

Version 1 uses an aiweb-managed container sandbox plus a JSON file contract. HTTP wrappers and daemon-mediated execution are future Workbench infrastructure, not the v1 agent-run boundary.

Approved execution requires:

1. `--sandbox docker` or `--sandbox podman`.
2. A matching `docker` or `podman` executable on `PATH`.
3. An OpenManus image, defaulting to `openmanus:latest` or overridden by `AIWEB_OPENMANUS_IMAGE`.

aiweb constructs the sandbox argv itself and validates that it includes `--network none`, `--read-only`, `--cap-drop ALL`, `--security-opt no-new-privileges`, non-root `--user`, process/memory/CPU limits, a restricted `/tmp` tmpfs, and exactly one writable host mount: the staging workspace mounted at `/workspace:rw`.

Sandbox validation is fail-closed and evidence-based. A real run is blocked unless the adapter can produce preflight evidence with generated argv, resolved executable path, container image reference/digest evidence, runtime container id via `--cidfile` and post-run `docker|podman inspect` HostConfig cross-check proving network none, read-only rootfs, cap-drop ALL, no-new-privileges, non-root user, exactly one writable `/workspace` bind, and `/workspace` source matching the staged workspace, inside-container self-attestation (container hostname, effective user, env guards, workspace writability, read-only root check, `/proc/self/status` no-new-privs/seccomp/capability evidence, `/proc/self/cgroup` evidence, mountinfo excerpt), rootless/rootful observation, host and inside mounts, network mode plus an inside-container egress-denial probe, effective capabilities, seccomp/AppArmor profile where available, cgroup CPU/memory/PID limits, tmpfs configuration, and negative checks proving no project root, `.git`, `.env*`, cloud credentials, browser profiles, or host home directories are mounted. Empty, malformed, or digestless image inspect output blocks the run before worker execution.

Set `AIWEB_ENGINE_RUN_RUNTIME_MATRIX=docker,podman` or `AIWEB_ENGINE_RUN_REQUIRE_RUNTIME_MATRIX=1` when a release gate must prove the same sandbox command shape, image availability, runtime info, inside-container self-attestation, egress denial, and post-run inspect evidence across both Docker and Podman. Matrix failure or an unsupported matrix runtime name blocks worker execution before copy-back.

`bin/engine-runtime-matrix-check` is the real-runtime smoke lane for CI/release use. It builds a minimal local OpenManus-compatible smoke image for each requested runtime, creates a temporary aiweb project, runs `engine-run` with the Docker/Podman matrix enabled, and fails unless `sandbox-preflight.json.runtime_matrix.status` is `passed`. The default CI workflow runs this smoke lane on `push`, `pull_request`, and manual `workflow_dispatch`, then uploads `.ai-web/ci/engine-runtime-matrix-smoke.json` as release evidence.

`openmanus:latest` is acceptable only as a local development default. Production-ready configurations should pin a prepared local image by digest and record that digest in preflight evidence before worker execution. Set `AIWEB_OPENMANUS_REQUIRE_DIGEST=1`, `AIWEB_REQUIRE_PINNED_OPENMANUS_IMAGE=1`, `AIWEB_ENGINE_RUN_STRICT_SANDBOX=1`, or `AIWEB_ENV=production`/`AIWEB_RUNTIME_ENV=production` to fail closed unless `AIWEB_OPENMANUS_IMAGE` is `name@sha256:<digest>`.

The container receives only aiweb contract variables:

- `AIWEB_AGENT_RUN_CONTEXT_PATH` (authoritative JSON manifest path; large context is not passed inline through environment variables)
- `AIWEB_AGENT_RUN_ALLOWED_SOURCE_PATHS_JSON`
- `AIWEB_AGENT_RUN_TASK_PATH`
- `AIWEB_AGENT_RUN_APPROVED`
- `AIWEB_AGENT_RUN_DRY_RUN`
- `AIWEB_AGENT_RUN_RUN_ID`
- `AIWEB_AGENT_RUN_DIFF_PATH`
- `AIWEB_AGENT_RUN_METADATA_PATH`
- `AIWEB_OPENMANUS_WORKSPACE`
- `AIWEB_OPENMANUS_RESULT_PATH`
- `AIWEB_OPENMANUS_SANDBOX`
- `AIWEB_NETWORK_ALLOWED=0`
- `AIWEB_MCP_ALLOWED=0`
- `AIWEB_ENV_ACCESS_ALLOWED=0`
- `AIWEB_TOOL_BROKER_EVENTS_PATH`
- `PATH` with `/workspace/_aiweb/tool-broker-bin` first for engine-run and OpenManus agent-run staged workers

The staged `_aiweb/tool-broker-bin` directory contains deny-by-default shims for package install commands, external-network tools, deploy/provider CLIs, `git push`, and raw environment reads. Package-manager and git shims fail closed when any argument requests package installation (`add`, `install`, `i`) or `git push`, so flag-prefixed forms such as `npm --loglevel silly install`, `npm --prefix . install`, `git --work-tree . push`, and `git -C repo push` are blocked before delegation. A shim block exits non-zero, writes a structured tool-broker event inside the workspace, and is surfaced as `tool.blocked` plus a pending elevated approval request before copy-back. OpenManus agent-run also copies this workspace event stream to `.ai-web/runs/<run-id>/tool-broker-events.jsonl` as host-side evidence and fails before source copy-back when prohibited staged actions are observed.

## Context Schema

The context manifest must include:

```json
{
  "schema_version": 1,
  "mode": "dry_run|approved",
  "run_id": "agent-run-20260512T000000Z",
  "task_id": "task-123",
  "task_path": ".ai-web/tasks/task-123.md",
  "project_root_hash": "sha256:...",
  "workspace_root": ".ai-web/tmp/openmanus/agent-run-20260512T000000Z",
  "design_path": ".ai-web/DESIGN.md",
  "selected_candidate_path": ".ai-web/design-candidates/candidate-02.html",
  "component_map_path": ".ai-web/component-map.json",
  "allowed_source_paths": ["src/pages/index.astro", "src/components/Hero.astro"],
  "allowed_globs": ["src/pages/index.astro", "src/components/Hero.astro"],
  "denied_globs": [".env*", ".git/**", "node_modules/**", ".ssh/**", ".aws/**", ".vercel/**", ".netlify/**", "*.pem", "*.key"],
  "base_hashes": {
    "src/pages/index.astro": "sha256:..."
  },
  "timeout_sec": 180,
  "max_output_bytes": 200000,
  "permission_profile": "implementation-local-no-network",
  "sandbox_mode": "docker",
  "sandbox_required": true,
  "forbidden_actions": ["read_env", "install", "deploy", "external_network", "mcp_tools", "modify_unlisted_files"],
  "tool_broker": {
    "events_path": "_aiweb/tool-broker-events.jsonl",
    "host_evidence_path": ".ai-web/runs/agent-run-20260512T000000Z/tool-broker-events.jsonl",
    "bin_path": "_aiweb/tool-broker-bin",
    "path_prepend_required": true,
    "blocks": ["package_install", "external_network", "deploy", "provider_cli", "git_push", "env_read"]
  },
  "expected_output": "source changes inside the isolated workspace only"
}
```

## Result Schema

The normalized result must include:

```json
{
  "schema_version": 1,
  "status": "planned|passed|failed|blocked|no_changes",
  "mode": "dry_run|approved",
  "agent": "openmanus",
  "exit_code": 0,
  "agent_version": "openmanus:unknown",
  "permission_profile": "implementation-local-no-network",
  "changed_source_files": [],
  "diff_path": ".ai-web/diffs/agent-run-20260512T000000Z.patch",
  "patch_hash": "sha256:...",
  "patch_base_hashes": {},
  "redactions": [],
  "blocking_issues": [],
  "error_code": null,
  "evidence": {
    "stdout_log": ".ai-web/runs/agent-run-20260512T000000Z/stdout.log",
    "stderr_log": ".ai-web/runs/agent-run-20260512T000000Z/stderr.log",
    "context_manifest": ".ai-web/runs/agent-run-20260512T000000Z/openmanus-context.json",
    "validator_result": ".ai-web/runs/agent-run-20260512T000000Z/openmanus-validator.json",
    "network_log": ".ai-web/runs/agent-run-20260512T000000Z/network.log",
    "browser_request_log": ".ai-web/runs/agent-run-20260512T000000Z/browser-requests.log",
    "tool_broker_log": ".ai-web/runs/agent-run-20260512T000000Z/tool-broker-events.jsonl",
    "denied_access_log": ".ai-web/runs/agent-run-20260512T000000Z/denied-access.log"
  }
}
```

## Workspace Boundary

aiweb creates a workspace-scoped staging directory under `.ai-web/tmp/openmanus/<run-id>/`.

Approved execution never runs a host `openmanus` executable directly. It launches the container command generated by aiweb, with the project root excluded from mounts and only the staging workspace writable. If `--sandbox` is omitted, the sandbox executable is missing, or the generated command fails validation, the run is blocked before OpenManus starts.

Only these files may be copied into that workspace:

- allowed source files
- selected design candidate evidence
- `.ai-web/DESIGN.md`
- component map
- task packet
- generated context JSON and prompt

Secret surfaces, `.git`, dependency folders, deploy folders, package caches, and user environment files are never copied.

OpenManus edits the workspace copy. aiweb compares the allowed source copies against the original base hashes, validates the staged diff, then copies back only allowed changed source files after validation.

aiweb also snapshots the project before and after the sandboxed process. Any direct mutation outside the workspace is treated as a failed run and prevents copy-back of staged workspace changes.

## Status Rules

- `planned`: dry-run only; no files written and no process launched.
- `blocked`: contract, safety, approval, executable, workspace, or validation issue.
- `failed`: subprocess exits non-zero or produced invalid/unsafe changes.
- `no_changes`: subprocess succeeds but no allowed source file changes.
- `passed`: subprocess succeeds and only allowed source files changed.

Approved runs may never report `planned`.
