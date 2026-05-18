# /goal 지시문: WebBuilderAgent v3.2 Agent OS 업그레이드 구현

Repo: `C:\dev\webbuilderagent`

Source of truth:

1. `docs/goals/WEBBUILDER_AGENT_OS_V32_GOAL_PLAN.ko.md`
2. `docs/goals/WEBBUILDER_AGENTIFICATION_EXECUTION_PLAN.md`
3. `docs/contracts/engine-run.md`
4. `docs/contracts/security-boundary.md`
5. `.ai-web/state.yaml`
6. v3.2 Agent OS 방법론 요약:
   - Immutable Agent Constitution
   - DecisionPacket
   - PolicyKernel reference monitor
   - ToolGateway
   - HITL approval artifact v2
   - Replay consistency
   - Expert Benchmark Pack
   - Red-Team Arena
   - Personal Brain Kernel
   - Self-Improvement Governor
   - P5 Implementation Evidence Gate

Goal:

WebBuilderAgent를 현재의 supervised local web-building agent/director에서 v3.2 전문 Agent OS 후보로 업그레이드하라. 이 작업은 문서만 수정하는 goal이 아니다. 코드, 스키마, 테스트, 계약 문서, state/docs 정렬, release evidence까지 구현해야 한다.

Core decision:

`engine-run` durable graph/evidence/checkpoint/runtime을 정본 Agent OS runtime으로 승격한다. `aiweb agent`는 별도 split-brain runtime이 아니라 `engine-run`을 호출하는 goal-driven facade가 되어야 한다.

대본 실행기 제거:

아래와 같은 “script-executor / fixed scenario runner / hardcoded pipeline을 에이전트처럼 포장한 엔진”을 제거하거나 ToolGateway-routed 하위 tool/probe로 강등하라.

- `AgentRuntime::Planner/Executor`가 goal reasoning 없이 `build`, `preview`, `browser_qa`, `local_verify`, `finish` 같은 고정 action list를 실행하는 구조
- `verify-loop`가 `build -> preview -> QA -> visual-critique -> repair -> agent-run` 고정 대본을 main agent engine처럼 행동하는 구조
- browser `static_safe_action_plan` / `scenario_plan` / `scenario_results`를 자율 planning으로 주장하는 구조
- PolicyKernel/ToolGateway/DecisionPacket 없이 process/browser/file/copy-back/MCP/memory/deploy/network를 실행할 수 있는 구조

중요: build/preview/QA/browser evidence 기능 자체를 삭제하지 말라. 정본 에이전트 엔진 지위를 제거하고, DecisionPacket + PolicyKernel + ToolGateway를 통과하는 tool/probe/eval fixture로 재배치하라.

Hard prohibitions:

- `.env`, `.env.*`, credential, provider auth store, browser cookie/session/profile 읽기 금지
- external deploy/provider CLI/git push 금지
- hosted Supabase project creation/network/provider flow 금지
- real credential/account/customer/production action 금지
- raw large data/browser dumps/screenshots 무단 commit 금지
- `origin/main` push는 명시 승인 전 금지
- 기존 safety substrate 삭제 금지
- 문서만 고치고 완료 선언 금지
- rename만 하고 대본 실행기 제거라고 주장 금지
- 실패한 eval/red-team/replay/P5를 통과한 것처럼 포장 금지

Preserve:

- `.ai-web` state/gate/evidence 구조
- Profile D/S runtime contracts
- PathPolicy / EnvPolicy / ProcessRunner
- side-effect surface audit
- engine-run checkpoint/event/hash-chain/sandbox/copy-back/eval artifacts
- setup supply-chain SBOM/audit 경계
- local backend authz evidence
- existing CI/schema locks

Mandatory problem-solving / resume loop:

이 goal은 한 번에 직선으로 끝난다고 가정하지 말라. 각 phase와 검증 지점마다 아래 루프를 반드시 적용하라.

```text
implement small slice
  -> run targeted validation
  -> if pass: checkpoint evidence and continue
  -> if fail: freeze current branch
       -> record failure signature/evidence
       -> classify root cause
       -> create or preserve failing test/repro
       -> apply minimal safe fix
       -> rerun targeted validation
       -> rerun dependent upstream/downstream checks
       -> resume from last valid checkpoint
  -> if repeated/unsafe/irrecoverable: honest failure report
```

Failure handling requirements:

- 검증 실패, schema mismatch, compatibility break, red-team bypass, replay mismatch, policy bypass, docs/state drift가 발견되면 추가 진행 전에 해당 문제를 해결하라.
- 실패는 `.ai-web/reports/agent-os-v32-repair-loop.jsonl`에 기록하라.
  - `failure_signature`
  - `phase`
  - `changed_files`
  - `failed_command`
  - `root_cause_class`
  - `minimal_fix_plan`
  - `revalidation_commands`
  - `resume_checkpoint`
- 같은 failure signature는 최대 3회 repair cycle을 허용한다.
- 3회 후에도 해결되지 않거나 안전 경계 위반 가능성이 있으면 success로 포장하지 말고 honest failure report를 작성하라.
- 실패를 숨기기 위해 테스트 삭제, threshold 하향, policy 약화, HITL 약화, permission tier 상승, credential boundary 완화를 하지 말라.
- 외부 network/provider/deploy/package install/credential이 필요해 보이면 real action을 하지 말고 fake fixture, dry-run, blocked evidence로 대체하라.
- 항상 마지막 valid checkpoint에서 재개하고 phase를 건너뛰지 말라.
- `ruby bin/check` 또는 필수 targeted validation이 실패한 상태에서는 완료 선언 금지.

Required implementation order:

1. Workspace and baseline audit
   - `git status --short --branch`
   - dirty files 확인
   - 대본 실행기 후보 inventory 작성
   - 보존 대상 safety substrate inventory 작성
   - baseline report 생성:
     - `.ai-web/reports/agent-os-v32-baseline-audit.json`
     - `docs/goals/WEBBUILDER_AGENT_OS_V32_BASELINE_AUDIT.md`

2. Failing tests first
   - 아래 테스트 파일을 추가/갱신해 v3.2 acceptance criteria를 고정하라.
     - `test/test_agent_os_v32_contracts.rb`
     - `test/test_agent_os_v32_policy_kernel.rb`
     - `test/test_agent_os_v32_tool_gateway.rb`
     - `test/test_agent_os_v32_decision_packet.rb`
     - `test/test_agent_os_v32_approval.rb`
     - `test/test_agent_os_v32_replay.rb`
     - `test/test_agent_os_v32_evals.rb`
     - `test/test_agent_os_v32_redteam.rb`
     - `test/test_agent_os_v32_static_surface_audit.rb`
     - `test/test_agent_os_v32_release_evidence.rb`

3. Immutable Constitution + DecisionPacket
   - 추가/구현:
     - `configs/constitution.yaml`
     - `configs/capability_matrix.yaml`
     - `docs/contracts/agent-os-constitution.md`
     - `docs/schemas/agent-os-constitution.schema.json`
     - `docs/schemas/agent-os-decision-packet.schema.json`
     - `lib/aiweb/constitution/loader.rb`
     - `lib/aiweb/constitution/verifier.rb`
     - `lib/aiweb/tools/decision_packet.rb`
   - run/resume/replay/P5 evidence에 constitution hash를 연결하라.
   - constitution hash mismatch는 fail-closed 하라.

4. PolicyKernel + ToolGateway
   - 추가/구현:
     - `configs/policy_rule_registry.yaml`
     - `configs/tool_registry.yaml`
     - `lib/aiweb/policy/kernel.rb`
     - `lib/aiweb/policy/decision_event.rb`
     - `lib/aiweb/policy/rule_registry.rb`
     - `lib/aiweb/tools/gateway.rb`
     - `lib/aiweb/tools/registry.rb`
     - `docs/contracts/policy-kernel.md`
     - `docs/contracts/tool-gateway.md`
     - `docs/schemas/agent-os-policy-decision-event.schema.json`
     - `docs/schemas/agent-os-tool-gateway-event.schema.json`
   - 모든 side effect는 `DecisionPacket -> PolicyKernel -> ToolGateway` 순서를 통과해야 한다.
   - event order는 `tool.requested -> policy.decision -> tool.started|tool.blocked`여야 한다.

5. Runtime unification
   - `aiweb agent`를 `engine-run` goal facade로 재구성하라.
   - `AgentRuntime::Loop`는 제거하거나 compatibility thin facade로 축소하라.
   - 별도 AgentRuntime timeline/final-report/source-patch-manifest가 있으면 engine-run/EvidenceLedger 형식으로 흡수하라.
   - `engine-run` graph에 goal-driven nodes를 추가하라:
     - observe_goal
     - load_constitution
     - build_decision_packet
     - policy_check
     - hitl_wait_if_required
     - execute_tool
     - verify_result
     - reflect_next_step
     - write_memory_proposal
     - finish_or_continue

6. Script-executor-like engines deletion/demotion
   - `AgentRuntime::Planner/Executor`의 top-level engine 역할 제거
   - `verify-loop`를 verification tool node로 강등
   - browser static scenario는 deterministic local browser probe로 명확히 표기
   - static audit로 script-executor/fixed-runner/bypass-runner 실행 표면 차단
   - README/help/docs에서 fixed pipeline을 자율 에이전트처럼 보이게 하는 표현 제거

7. HITL approval artifact v2 + replay consistency
   - 추가/구현:
     - `lib/aiweb/approval/artifact.rb`
     - `lib/aiweb/approval/verifier.rb`
     - `docs/schemas/agent-os-hitl-approval-v2.schema.json`
     - `docs/contracts/hitl-approval-v2.md`
     - replay consistency support under engine-run
   - approval expiry/scope/action_diff/args/evidence/single-use mismatch를 차단하라.
   - L4/L5는 second reviewer 없으면 차단하라.
   - replay mode는 real side effect 없이 deterministic evidence를 생성해야 한다.

8. Domain Competency + Eval Science + Red-Team Arena
   - 추가:
     - `domain_competency_bundle/webbuilding/*`
     - `evals/eval_sampling_plan.yaml`
     - `evals/packs/*.jsonl`
     - `evals/runner.rb`
     - `evals/leakage_check.rb`
     - `evals/calibration_eval.rb`
     - `redteam/attack_catalog.yaml`
     - `redteam/runner.rb`
     - `redteam/secret_canary.rb`
   - golden safety 100%, critical/high red-team bypass 0을 목표로 한다.
   - 단일 fixture를 production-ready eval로 주장하지 않는다.

9. Personal Brain Kernel MVP
   - 추가/구현:
     - `lib/aiweb/brain/store.rb`
     - `lib/aiweb/brain/context_builder.rb`
     - `lib/aiweb/brain/claims.rb`
     - `lib/aiweb/brain/memory_proposals.rb`
     - `lib/aiweb/brain/search_projection.rb`
     - `lib/aiweb/brain/memory_audit.rb`
     - `docs/schemas/agent-os-brain-context-packet.schema.json`
     - `docs/schemas/agent-os-memory-health-report.schema.json`
   - worker/subagent는 직접 memory write 금지, memory_proposal만 허용.
   - low-grade memory는 action argument로 사용 금지.
   - tombstone/delete 후 retrieval 0건을 증명하라.

10. Self-Improvement Governor
    - 추가/구현:
      - `configs/self_improvement_policy.yaml`
      - `lib/aiweb/self_improvement/governor.rb`
      - `lib/aiweb/self_improvement/proposal_generator.rb`
      - `lib/aiweb/self_improvement/experiment_registry.rb`
      - `lib/aiweb/self_improvement/patch_sandbox.rb`
      - `lib/aiweb/self_improvement/canary_promoter.rb`
      - `docs/schemas/agent-os-improvement-proposal.schema.json`
      - `docs/schemas/agent-os-experiment-record.schema.json`
    - 기본은 dry-run proposal/experiment only.
    - constitution/policy/eval threshold/HITL/credential/self_improvement_policy 직접 patch 금지.

11. P5 Release Evidence Gate + docs/state alignment
    - 추가/구현:
      - `lib/aiweb/ops/release_manifest.rb`
      - `lib/aiweb/ops/p5_gate.rb`
      - `lib/aiweb/observability/evidence_ledger.rb`
      - `docs/contracts/agent-os-p5-release.md`
      - `docs/schemas/agent-os-release-evidence-p5.schema.json`
      - `releases/v0.3.2-rc1/release_manifest.yaml`
      - `releases/v0.3.2-rc1/evidence_integrity_manifest.yaml`
      - `releases/v0.3.2-rc1/p5_gate_report.md`
    - `.ai-web/state.yaml`, README, help, contracts, goals 문서를 실제 구현과 정렬하라.

Acceptance criteria:

- `aiweb agent` and `engine-run` no longer produce competing runtime truth.
- All side effects pass through `DecisionPacket -> PolicyKernel -> ToolGateway`.
- Constitution hash is present in run/resume/replay/P5 evidence.
- HITL v2 blocks expired, mismatched, reused, or insufficient approvals.
- L4/L5 require second reviewer.
- Replay consistency runs without real side effects.
- Script-executor-like top-level engines are deleted, demoted, or fail-closed by static audit.
- Browser static scenarios are labeled deterministic probes, not autonomous planning.
- Domain eval + red-team artifacts are generated.
- Red-team critical/high bypass count is 0, or honest failure report is generated.
- Personal Brain MVP blocks secret memory, tombstone leaks, and low-grade memory action use.
- Self-improvement cannot directly patch forbidden components and defaults to dry-run.
- P5 release evidence exists and schema validates.
- README/help/docs/state match actual behavior.
- Final `ruby bin/check` passes.

Validation commands:

```powershell
git status --short --branch
git diff --check
ruby -Itest test/test_agent_os_v32_contracts.rb
ruby -Itest test/test_agent_os_v32_policy_kernel.rb
ruby -Itest test/test_agent_os_v32_tool_gateway.rb
ruby -Itest test/test_agent_os_v32_decision_packet.rb
ruby -Itest test/test_agent_os_v32_approval.rb
ruby -Itest test/test_agent_os_v32_replay.rb
ruby -Itest test/test_agent_os_v32_evals.rb
ruby -Itest test/test_agent_os_v32_redteam.rb
ruby -Itest test/test_agent_os_v32_static_surface_audit.rb
ruby -Itest test/test_agent_os_v32_release_evidence.rb
ruby -Itest test/all.rb
ruby bin/check
```

If available and safe:

```powershell
ruby bin/engine-runtime-matrix-check --json
```

Stop condition A - Success:

All acceptance criteria pass, P5 evidence is generated, script-executor-like engines are removed/demoted, and `ruby bin/check` passes. Final report must include changed files, validation evidence, P0-P5 gate status, remaining risks, and whether WebBuilderAgent can honestly claim “v3.2 Agent OS candidate”.

Stop condition B - Honest failure:

If the upgrade cannot be completed safely, do not claim success. Write an honest failure report breaking blockers into architecture, policy/security, HITL/replay, eval/red-team, Personal Brain, self-improvement, compatibility, and docs/state drift. Preserve safety and leave repo in a verified non-broken state.

Final output required:

- Success/failure 판정
- 대본 실행기 제거/강등 결과
- AgentRuntime/engine-run 통합 결과
- Constitution/PolicyKernel/ToolGateway 구현 결과
- HITL/replay/eval/red-team/Brain/self-improvement/P5 evidence 경로
- Validation command results
- Remaining risks
- Commit-ready status
