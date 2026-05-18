# WebBuilderAgent v3.2 Baseline Audit

Status: implementation required and now locked by tests.

## Script-executor inventory

- `AgentRuntime::Loop/Planner/Executor`: compatibility facade only; side effects must pass through DecisionPacket -> PolicyKernel -> ToolGateway.
- `verify-loop`: legacy verification bundle tool/probe, not the canonical agent engine.
- Browser static scenario surfaces: deterministic local browser probes, not autonomous planning.

## Safety substrate to preserve

- `.ai-web` state/gate/evidence structure
- Profile D/S runtime contracts
- PathPolicy / EnvPolicy / ProcessRunner
- engine-run durable checkpoint/event/hash-chain/sandbox/copy-back/eval artifacts

## Required remediation

Constitution, DecisionPacket, PolicyKernel, ToolGateway, HITL approval v2, replay consistency, eval/red-team, Personal Brain MVP, Self-Improvement Governor, and P5 release evidence.
