# WebBuilderAgent v3.2 Baseline Audit

Status: script-executor neutralization in progress and locked by tests.

## Script-executor inventory

- `AgentRuntime::Loop/Planner/Executor`: removed. `aiweb agent` now delegates natural-language goals directly to the canonical `engine-run` durable runtime instead of producing a fixed build/preview/browser-QA action list.
- `verify-loop`: remaining legacy verification bundle tool/probe, not the canonical agent engine. It is the next fixed-pipeline surface to delete or convert into an engine-run verification node.
- Browser static scenario surfaces: deterministic local browser probes, not autonomous planning.

## Safety substrate to preserve

- `.ai-web` state/gate/evidence structure
- Profile D/S runtime contracts
- PathPolicy / EnvPolicy / ProcessRunner
- engine-run durable checkpoint/event/hash-chain/sandbox/copy-back/eval artifacts

## Required remediation

Constitution, DecisionPacket, PolicyKernel, ToolGateway, HITL approval v2, replay consistency, eval/red-team, Personal Brain MVP, Self-Improvement Governor, and P5 release evidence.
