# WebBuilderAgent v3.2 Baseline Audit

Status: top-level script-executor surfaces neutralized; completion audit remains active for broader Manus-grade gaps.

## Script-executor inventory

- `AgentRuntime::Loop/Planner/Executor`: removed. `aiweb agent` now delegates natural-language goals directly to the canonical `engine-run` durable runtime instead of producing a fixed build/preview/browser-QA action list.
- `verify-loop`: converted to a thin `engine-run` compatibility shim. The fixed build/preview/QA/visual-critique/repair/agent-run pipeline and its direct execution helpers have been deleted.
- Browser deterministic probe surfaces: deterministic local browser probes, not autonomous planning.

## Safety substrate to preserve

- `.ai-web` state/gate/evidence structure
- Profile D/S runtime contracts
- PathPolicy / EnvPolicy / ProcessRunner
- engine-run durable checkpoint/event/hash-chain/sandbox/copy-back/eval artifacts

## Required remediation

Constitution, DecisionPacket, PolicyKernel, ToolGateway, HITL approval v2, replay consistency, eval/red-team, Personal Brain MVP, Self-Improvement Governor, and P5 release evidence.
