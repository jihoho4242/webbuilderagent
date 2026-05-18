# WebBuilderAgent v3.2 Agent OS 업그레이드 실행 계획서

문서 상태: Implementation-ready goal plan
작성일: 2026-05-18
대상 repo: `C:\dev\webbuilderagent`
최종 목표: WebBuilderAgent를 “감독형 로컬 웹빌드 디렉터”에서 v3.2 전문 Agent OS 후보로 승격한다.
주의: 이 문서는 구현 지시의 source-of-truth이다. 문서만 수정하고 끝내는 작업이 아니다.

---

## 0. 입력 근거

이 계획은 아래 입력을 통합한다.

1. `전문_에이전트_운영체제_방법론_v3.2_ImplementationReady_최종보완판_20260518.docx`
2. 현재 `webbuilderagent` repo 분석
3. 사용자와의 대화에서 확정된 방향
   - 현재 구조는 “에이전트가 들어올 자리를 만든 로컬 디렉터/오케스트레이터”에서 많이 발전했지만 아직 완성형 Agent OS는 아니다.
   - “대본 실행기”, “고정 시나리오 실행기”, “정해진 루프를 에이전트처럼 포장한 엔진”은 제거하거나 하위 도구로 강등한다.
   - 최종 방향은 goal-driven `observe -> reason/plan -> act -> verify -> reflect` 구조다.
4. 전문가 서브에이전트 회의 결과
   - Architect: `engine-run` durable graph/evidence를 정본 런타임으로 삼고, `AgentRuntime`/`verify-loop`/browser static scenario를 목표 기반 런타임의 하위 tool/probe로 재배치해야 한다.
   - Test Engineer: Constitution, PolicyKernel, ToolGateway, DecisionPacket, HITL v2, replay, red-team, eval, Personal Brain, self-improvement, P5 evidence, script-executor 제거를 테스트 가능한 acceptance criteria로 고정해야 한다.

---

## 1. 현재 판정

현재 WebBuilderAgent는 다음 수준이다.

> 안전 경계가 강한 supervised local web-building agent/director + 일부 agentic runtime + 일부 durable evidence 구조

아직 v3.2 기준 완성형 Agent OS는 아니다. 부족한 핵심은 다음이다.

- Immutable Agent Constitution 없음
- 중앙 PolicyKernel / ToolGateway 없음
- DecisionPacket 표준 없음
- HITL approval artifact v2 부족
- `aiweb agent`와 `engine-run`의 split-brain 가능성
- 고정 대본 실행기형 루프 잔존
- Domain Competency Bundle 부족
- Eval Science / Red-Team Arena 부족
- Personal Brain Kernel 없음
- Self-Improvement Governor 없음
- P5 release evidence bundle 없음
- `.ai-web/state.yaml`과 실제 구현 상태 정렬 부족

현재 방향성은 좋다. 특히 아래 자산은 반드시 보존해야 한다.

- `.ai-web` 상태/게이트/증거 구조
- Profile D/S 정책 분리
- PathPolicy / EnvPolicy / ProcessRunner
- engine-run checkpoint/event/hash-chain/sandbox/copy-back/eval evidence
- side-effect surface audit
- setup supply-chain SBOM/audit 경계
- local backend authz evidence
- CI와 schema lock 테스트

---

## 2. 업그레이드 원칙

### 2.1 제품 포지셔닝

WebBuilderAgent는 당분간 다음으로 정의한다.

> v3.2 Agent OS 원칙을 적용한 supervised local web-building agent OS candidate

금지 표현:

- 완전 자동 production SaaS generator
- 한 줄 명령으로 hosted app 생성/배포
- 승인 없이 provider/deploy/network/secret 처리 가능
- Manus급 완성품이라고 무근거 주장

완성 주장은 P0-P5 evidence gate 결과로만 한다.

### 2.2 단일 정본 런타임

정본 런타임은 `engine-run` durable graph/evidence substrate다.

목표 구조:

```text
aiweb agent
  -> GoalRouter / GoalContract
  -> ConstitutionVerifier
  -> DecisionPacketBuilder
  -> PolicyKernel
  -> EngineRun durable graph
  -> ToolGateway
  -> Profile-aware tools / probes / worker adapters
  -> EvidenceLedger
  -> Verifier / Reflector
  -> FinalReport / P5 Evidence
```

`AgentRuntime::Loop`는 독립 런타임으로 키우지 않는다. 다음 중 하나로 처리한다.

1. 삭제하고 `aiweb agent`를 `engine-run` facade로 재구현
2. 하위 호환을 위해 thin facade만 남기고 내부는 `engine-run`으로 위임

`verify-loop`는 제품의 “에이전트 엔진”이 아니라 검증 도구 노드로 강등한다.

### 2.3 대본 실행기 제거 원칙

“대본 실행기”란 아래 조건 중 하나를 만족하는 실행 표면이다.

- goal 이해 없이 정해진 단계 목록만 실행한다.
- `build -> preview -> qa -> visual-critique -> repair -> agent-run` 같은 고정 pipeline을 에이전트 판단처럼 포장한다.
- `static_safe_action_plan`, `scenario_plan`, `scenario_results`를 자율 브라우저 에이전트처럼 주장한다.
- ToolGateway/PolicyKernel/DecisionPacket 없이 subprocess, browser, file write, MCP, deploy, network, memory write를 실행한다.
- 실패 원인에 따라 계획을 바꾸지 않고 같은 대본을 재시도한다.

삭제/강등 대상:

- `AgentRuntime::Planner/Executor`의 top-level engine 역할
- `verify-loop`의 director/agent engine 역할
- browser `static_safe_action_plan`의 agentic planning 주장
- legacy `agent-run`의 public mental model; worker adapter compatibility로만 유지

보존할 것:

- 안전한 build/preview/QA 기능 자체
- browser evidence capture 자체
- verify-loop가 남긴 증거 포맷 중 유효한 부분
- worker adapter compatibility

즉 기능을 버리는 게 아니라, “정본 에이전트 엔진” 지위를 제거하고 ToolGateway-routed tool/probe로 재배치한다.

---

## 3. Non-negotiable constraints

구현자는 아래를 절대 위반하지 않는다.

1. `.env`, `.env.*`, credential, provider auth store, browser profile/cookie/session을 읽거나 artifact로 노출하지 않는다.
2. external deploy/provider CLI/git push는 명시 승인 전 금지한다.
3. hosted Supabase project creation, provider network flow, real credential flow는 금지한다.
4. `origin/main` push는 별도 사용자 승인 전 금지한다.
5. raw large data, screenshots, browser dumps, generated bulk artifacts를 무단 commit하지 않는다.
6. 기존 safety substrate는 삭제하지 않는다.
   - `.ai-web` gates
   - PathPolicy / EnvPolicy / ProcessRunner
   - side-effect broker/audit
   - engine-run evidence/checkpoint/copy-back
   - Profile D/S contracts
7. 문서만 수정하고 완료 처리하지 않는다. 이 goal은 구현 goal이다.
8. 단순 renaming으로 “대본 실행기 제거”를 주장하지 않는다. 런타임 권한과 실행 경계가 실제로 바뀌어야 한다.
9. 새로운 agent/autonomous-local 경로는 PolicyKernel과 ToolGateway 없이 side effect를 실행할 수 없다.
10. 실패하면 honest failure report를 남긴다. “완료”라고 포장하지 않는다.

---

## 4. 필수 문제 해결 / 재개 루프

이 goal은 긴 구현 작업이므로 한 번에 직선으로 끝난다고 가정하지 않는다. 구현자는 각 phase와 검증 지점마다 아래 루프를 적용한다.

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

### 4.1 실패 처리 규칙

검증 실패, schema mismatch, compatibility break, red-team bypass, replay mismatch, policy bypass, docs/state drift가 발견되면 즉시 다음을 수행한다.

1. 해당 branch의 추가 side effect를 멈춘다.
2. 실패를 `.ai-web/reports/agent-os-v32-repair-loop.jsonl`에 기록한다.
   - `failure_signature`
   - `phase`
   - `changed_files`
   - `failed_command`
   - `root_cause_class`
   - `minimal_fix_plan`
   - `revalidation_commands`
   - `resume_checkpoint`
3. 실패 유형을 분류한다.
   - architecture
   - policy/security
   - HITL/replay
   - eval/red-team
   - Personal Brain
   - self-improvement
   - compatibility
   - documentation/state drift
   - environment/tooling
4. 실패를 숨기기 위해 테스트를 삭제하거나 threshold를 낮추지 않는다.
5. Constitution, PolicyKernel, HITL, eval threshold, permission tier, credential boundary를 약화하는 방식으로 “수정”하지 않는다.
6. 외부 network/provider/deploy/package install/credential이 필요해 보이면 real action을 하지 말고 fake fixture, dry-run, blocked evidence로 대체한다.

### 4.2 재시도 예산과 중단 조건

- 같은 failure signature는 최대 3회까지 repair cycle을 허용한다.
- 3회 후에도 해결되지 않으면 honest failure report를 작성한다.
- 안전 경계 위반 가능성이 있으면 즉시 실행 branch를 멈추고 fail-closed evidence를 남긴다.
- `ruby bin/check` 또는 필수 targeted test가 실패한 상태에서는 success로 끝낼 수 없다.
- “완료”는 open blocker 0, required validation 통과, P5 evidence 생성 후에만 가능하다.

### 4.3 재개 규칙

- 항상 마지막 valid checkpoint에서 재개한다.
- phase를 건너뛰지 않는다.
- 실패한 테스트를 먼저 통과시킨 뒤 다음 phase로 넘어간다.
- 변경 범위가 넓어졌다면 baseline audit와 acceptance criteria를 업데이트한다.
- 최종 보고에는 모든 repair cycle, 해결/미해결 blocker, 재검증 결과를 포함한다.

---

## 5. 목표 아키텍처

### 4.1 새/강화 모듈 경계

```text
configs/
  constitution.yaml
  capability_matrix.yaml
  policy_rule_registry.yaml
  tool_registry.yaml
  domain_registry.yaml
  self_improvement_policy.yaml

docs/contracts/
  agent-os-constitution.md
  agent-os-runtime.md
  policy-kernel.md
  tool-gateway.md
  hitl-approval-v2.md
  agent-os-p5-release.md

docs/schemas/
  agent-os-constitution.schema.json
  agent-os-decision-packet.schema.json
  agent-os-policy-decision-event.schema.json
  agent-os-hitl-approval-v2.schema.json
  agent-os-tool-gateway-event.schema.json
  agent-os-brain-context-packet.schema.json
  agent-os-memory-health-report.schema.json
  agent-os-improvement-proposal.schema.json
  agent-os-experiment-record.schema.json
  agent-os-red-team-case.schema.json
  agent-os-release-evidence-p5.schema.json

lib/aiweb/
  constitution/
    loader.rb
    verifier.rb
  policy/
    kernel.rb
    decision_event.rb
    rule_registry.rb
  tools/
    gateway.rb
    registry.rb
    decision_packet.rb
  approval/
    artifact.rb
    verifier.rb
  goal_runtime/
    router.rb
    contract.rb
    planner.rb
    verifier.rb
    reflector.rb
  domain/
    competency_bundle.rb
    rubric.rb
  evals/
    runner.rb
    sampling_plan.rb
    leakage_check.rb
    calibration.rb
  redteam/
    arena.rb
    secret_canary.rb
  brain/
    store.rb
    context_builder.rb
    memory_audit.rb
  self_improvement/
    governor.rb
    proposal_generator.rb
    experiment_registry.rb
  observability/
    evidence_ledger.rb
  ops/
    release_manifest.rb
    p5_gate.rb
```

### 4.2 Runtime source of truth

- `engine-run` remains durable execution substrate.
- `aiweb agent` becomes user-friendly goal facade.
- `AgentRuntime` does not own separate timeline/source-patch/final-report truth unless those artifacts are engine-run-compatible and hash-chained.
- Any new timeline must reuse engine-run event schema or go through `EvidenceLedger`.

### 4.3 Decision flow

Every action follows this sequence.

```text
GoalContract
  -> ObservationPacket
  -> DecisionPacket
  -> ConstitutionVerifier
  -> PolicyKernel.decide
  -> HITL verifier if required
  -> ToolGateway.execute
  -> ToolResult
  -> EvidenceLedger append
  -> Verifier
  -> Reflector
  -> Next DecisionPacket or Finish
```

LLM or planner output is never directly executable. It is only a draft until converted to a valid DecisionPacket and accepted by PolicyKernel.

---

## 6. 구현 단계

### Phase 0. Workspace and baseline audit

목표: 현재 repo 상태와 기존 자산을 보호한다.

작업:

1. `git status --short --branch` 확인
2. dirty 파일 식별
3. 기존 docs/goals 계획서와 실제 구현 상태 비교
4. 대본 실행기 후보 inventory 생성
   - `lib/aiweb/agent_runtime/*`
   - `lib/aiweb/project/verify_loop*`
   - browser action scenario/probe 코드
   - legacy `agent-run` public API/README 표현
5. side-effect surface audit 현재 결과 기록

산출물:

- `.ai-web/reports/agent-os-v32-baseline-audit.json`
- `docs/goals/WEBBUILDER_AGENT_OS_V32_BASELINE_AUDIT.md`

수용 기준:

- 다른 작업자의 dirty file을 덮어쓰지 않는다.
- 삭제/대체 대상과 보존 대상을 분리한다.
- 기존 safety files를 보존 목록에 넣는다.

---

### Phase 1. Failing contract tests first

목표: 구현 전 v3.2 acceptance criteria를 테스트로 고정한다.

추가/수정 테스트 후보:

```text
test/test_agent_os_v32_contracts.rb
test/test_agent_os_v32_policy_kernel.rb
test/test_agent_os_v32_tool_gateway.rb
test/test_agent_os_v32_decision_packet.rb
test/test_agent_os_v32_approval.rb
test/test_agent_os_v32_replay.rb
test/test_agent_os_v32_evals.rb
test/test_agent_os_v32_redteam.rb
test/test_agent_os_v32_static_surface_audit.rb
test/test_agent_os_v32_release_evidence.rb
```

수용 기준:

- Constitution hash mismatch blocks run/resume/replay.
- 모든 side effect는 PolicyKernel decision 없이는 실행되지 않는다.
- ToolGateway 밖 실행 경로는 static audit에서 실패한다.
- DecisionPacket schema 누락/불일치가 차단된다.
- HITL v2 approval expiry/scope/single-use mismatch가 차단된다.
- replay는 실제 side effect 없이 deterministic evidence를 만든다.
- script-executor-like runner가 실행 가능한 top-level engine으로 남으면 실패한다.

---

### Phase 2. Immutable Constitution + DecisionPacket

목표: Agent OS 불변 조건과 실행 결정 단위를 도입한다.

추가 파일:

```text
configs/constitution.yaml
configs/capability_matrix.yaml
docs/contracts/agent-os-constitution.md
docs/schemas/agent-os-constitution.schema.json
docs/schemas/agent-os-decision-packet.schema.json
lib/aiweb/constitution/loader.rb
lib/aiweb/constitution/verifier.rb
lib/aiweb/tools/decision_packet.rb
```

Constitution 최소 규칙:

```yaml
constitution_version: "3.2.0"
immutable: true
rules:
  - id: NO_SELF_PERMISSION_ESCALATION
    severity: critical
  - id: NO_POLICY_KERNEL_BYPASS
    severity: critical
  - id: NO_HITL_DOWNGRADE
    severity: critical
  - id: NO_EVAL_THRESHOLD_DOWNGRADE
    severity: critical
  - id: NO_SECRET_READ
    severity: critical
change_process:
  requires_signed_pr: true
  requires_security_owner: true
  requires_two_person_review_for_l4_l5: true
```

DecisionPacket 필수 필드:

- `packet_id`
- `run_id`
- `goal_hash`
- `constitution_hash`
- `policy_kernel_version`
- `tool_registry_version`
- `inputs_hash`
- `requested_tool`
- `risk_tier`
- `permission_tier`
- `expected_outputs`
- `approval_requirement`
- `idempotency_key`
- `replay_policy`
- `blockers`

수용 기준:

- 모든 engine-run/agent run artifact에 constitution hash가 들어간다.
- constitution hash가 바뀌면 resume/replay가 차단된다.
- planner/LLM output은 DecisionPacket validation 전에는 실행되지 않는다.

---

### Phase 3. PolicyKernel + ToolGateway 중앙화

목표: 모든 side effect 앞에 reference monitor를 둔다.

추가 파일:

```text
configs/policy_rule_registry.yaml
configs/tool_registry.yaml
lib/aiweb/policy/kernel.rb
lib/aiweb/policy/decision_event.rb
lib/aiweb/policy/rule_registry.rb
lib/aiweb/tools/gateway.rb
lib/aiweb/tools/registry.rb
docs/contracts/policy-kernel.md
docs/contracts/tool-gateway.md
docs/schemas/agent-os-policy-decision-event.schema.json
docs/schemas/agent-os-tool-gateway-event.schema.json
```

PolicyKernel 결정값:

- `allow`
- `block`
- `approval_required`
- `quarantine`

위험 tier:

```text
L0 read-only local metadata
L1 local read artifact
L2 local write evidence only
L3 local process/browser/source patch/copy-back
L4 external network/package install/provider/deploy/git push/MCP credentials
L5 irreversible production/account/customer/financial/security action
```

기본 정책:

- L0-L2만 autonomous-local에서 자동 허용 가능
- L3는 PolicyKernel decision + local approval policy 필요
- L4-L5는 explicit HITL v2 approval 없이는 block
- `.env`/secret read는 항상 block
- deploy/provider/git push는 항상 approval_required 또는 block

수용 기준:

- 파일 쓰기, process, browser, MCP, setup, deploy, copy-back, memory write는 ToolGateway 경유
- `tool.requested -> policy.decision -> tool.started|tool.blocked` 순서가 evidence에 남음
- side-effect surface audit가 “unclassified direct execution”을 허용하지 않음

---

### Phase 4. Runtime 단일화: `aiweb agent` -> `engine-run`

목표: split-brain을 제거한다.

작업:

1. `aiweb agent` public command를 유지하되 내부 실행은 `engine-run` graph로 위임한다.
2. `AgentRuntime::Loop`는 제거하거나 compatibility facade로 축소한다.
3. `AgentRuntime`의 별도 timeline/final-report/source-patch-manifest가 있다면 engine-run/EvidenceLedger 형식으로 흡수한다.
4. `engine-run` graph node에 goal-driven nodes를 추가한다.

예상 node:

```text
observe_goal
load_constitution
build_decision_packet
policy_check
hitl_wait_if_required
execute_tool
verify_result
reflect_next_step
write_memory_proposal
finish_or_continue
```

수용 기준:

- `aiweb agent`와 `engine-run`이 경쟁하는 별도 정본 artifact를 만들지 않는다.
- `aiweb agent` 결과가 engine-run run_id, checkpoint, events, policy decisions, gateway events를 참조한다.
- 기존 CLI/JSON compatibility는 보존하거나 명확한 migration note와 테스트를 추가한다.

---

### Phase 5. 대본 실행기 삭제/강등

목표: “정해진 대본 실행”을 에이전트 엔진으로 주장하지 못하게 한다.

작업:

1. `AgentRuntime::Planner`의 고정 action chooser 제거 또는 goal taxonomy 기반 planner로 교체
2. `AgentRuntime::Executor`의 직접 `@project.build`, `@project.preview`, `@project.qa_*` 호출 제거; ToolGateway로만 실행
3. `verify-loop`는 top-level agent/director가 아니라 `verification_bundle_tool` 또는 `legacy_verify_tool`로 강등
4. browser `static_safe_action_plan`은 `deterministic_local_browser_probe`로 명명/문서화
5. README/help/docs에서 “자동 에이전트 planning”으로 오해되는 표현 제거
6. static audit 추가: `script-executor`, `fixed scenario runner`, `hardcoded scenario executor`, `bypass runner` 류가 executable surface로 남으면 실패

중요:

- build/preview/QA 기능을 삭제하라는 뜻이 아니다.
- 고정 pipeline이 “에이전트 엔진”인 척하는 구조를 삭제한다.
- 고정 검증은 tool/probe/eval fixture로 남길 수 있다.

수용 기준:

- top-level agent path가 고정 step list를 그대로 실행하지 않는다.
- 모든 tool action은 DecisionPacket + PolicyKernel + ToolGateway를 통한다.
- browser probe는 deterministic probe라고 기록된다.
- “대본 실행기 제거 감사”가 P5 evidence에 포함된다.

---

### Phase 6. HITL approval artifact v2 + replay consistency

목표: approval과 replay를 실행 안전성의 핵심 게이트로 만든다.

추가 파일:

```text
lib/aiweb/approval/artifact.rb
lib/aiweb/approval/verifier.rb
docs/schemas/agent-os-hitl-approval-v2.schema.json
docs/contracts/hitl-approval-v2.md
lib/aiweb/project/engine_run/replay_consistency.rb
```

Approval v2 필수 필드:

- `approval_id`
- `schema_version: 2`
- `run_id`
- `decision_packet_ids`
- `risk_tier`
- `requested_capabilities`
- `action_diff_hash`
- `args_hash`
- `evidence_hash`
- `approval_hash`
- `expires_at`
- `single_use: true`
- `consumed_at`
- `approver_id`
- `second_reviewer_id` for L4/L5
- `validation_hash`

Replay consistency:

- 같은 `DecisionReplayKey`는 같은 intent/reason/blocker tuple 생성
- replay mode는 실제 side effect를 수행하지 않음
- artifact hash mismatch는 fail-closed

수용 기준:

- approval args/action/evidence 중 하나라도 바뀌면 승인 무효
- expired/single-use 재사용 차단
- L4/L5 second reviewer 없으면 차단
- replay demo report 생성

---

### Phase 7. Domain Competency + Eval Science + Red-Team Arena

목표: “좋은 웹사이트를 만드는 전문성”과 “공격을 막는 능력”을 테스트 가능한 체계로 만든다.

추가 구조:

```text
domain_competency_bundle/webbuilding/
  task_taxonomy.yaml
  domain_ontology.yaml
  source_of_truth_registry.yaml
  expert_rubric.md
  gold_case_set.jsonl
  failure_case_set.jsonl
  skill_bundle_manifest.yaml
  domain_playbook.md
  domain_expert_signoff.md

evals/
  eval_sampling_plan.yaml
  packs/webbuilding_gold.jsonl
  packs/webbuilding_adversarial.jsonl
  packs/abstention_cases.jsonl
  packs/tool_selection_cases.jsonl
  runner.rb
  leakage_check.rb
  calibration_eval.rb

redteam/
  attack_catalog.yaml
  runner.rb
  secret_canary.rb
```

웹빌더 expert rubric 최소 항목:

- visual hierarchy
- typography
- spacing
- responsive quality
- accessibility
- content clarity
- conversion flow
- technical correctness
- brand fit
- source-backed claims

Red-team attack catalog:

- goal hijack
- approval bypass
- tool misuse
- privilege escalation
- direct shell/process bypass
- `.env`/secret exfiltration
- external network/provider/deploy attempt
- RAG/memory poisoning
- replay tampering
- self-modification bypass

수용 기준:

- golden safety 100%
- critical/high red-team bypass 0
- tool routing accuracy target 명시
- leakage check 통과
- 단일 fixture로 production-ready eval 주장 금지

---

### Phase 8. Personal Brain Kernel MVP

목표: run-memory를 durable Personal Brain으로 과장하지 않고, 감사 가능한 Brain MVP를 만든다.

추가 파일:

```text
lib/aiweb/brain/store.rb
lib/aiweb/brain/context_builder.rb
lib/aiweb/brain/claims.rb
lib/aiweb/brain/memory_proposals.rb
lib/aiweb/brain/search_projection.rb
lib/aiweb/brain/memory_audit.rb
docs/schemas/agent-os-brain-context-packet.schema.json
docs/schemas/agent-os-memory-health-report.schema.json
```

Brain MVP 원칙:

- local-first SQLite 가능하면 사용
- memory write는 PolicyKernel + ToolGateway 경유
- subagent/worker는 직접 memory write 금지; memory_proposal만 생성
- low-grade memory는 action argument로 사용 금지
- tombstone/delete 후 retrieval 0건 증명
- context_hash를 모든 DecisionPacket에 연결

Memory audit metrics:

- stale_claim_rate
- duplicate_claim_rate
- contradiction_count
- tombstone_leak
- low_grade_action_use
- pii_over_retention
- search_projection_lag
- context_packet_bloat

수용 기준:

- `.env`/secret-like memory write 차단
- tombstone leak 0
- low-grade memory action use 0
- memory health report 생성

---

### Phase 9. Self-Improvement Governor

목표: 자가개선은 직접 production patch가 아니라 evidence-based proposal + sandbox experiment로 제한한다.

추가 파일:

```text
configs/self_improvement_policy.yaml
lib/aiweb/self_improvement/governor.rb
lib/aiweb/self_improvement/proposal_generator.rb
lib/aiweb/self_improvement/experiment_registry.rb
lib/aiweb/self_improvement/patch_sandbox.rb
lib/aiweb/self_improvement/canary_promoter.rb
docs/schemas/agent-os-improvement-proposal.schema.json
docs/schemas/agent-os-experiment-record.schema.json
```

금지 컴포넌트:

- constitution
- policy kernel
- permission tier
- legal/security registry
- eval threshold
- HITL gate
- credential store
- self_improvement_policy

수용 기준:

- self-improvement 기본은 dry-run
- dry-run은 proposal/eval impact만 쓰고 source 변경 없음
- real apply는 HITL v2 없이는 fail-closed
- forbidden component patch는 항상 block
- repeated failure는 improvement_debt + human review로 전환

---

### Phase 10. P5 Release Evidence Gate + Workbench/state/docs 정렬

목표: “완료”를 말할 수 있는 evidence bundle을 만든다.

추가 파일:

```text
lib/aiweb/ops/release_manifest.rb
lib/aiweb/ops/p5_gate.rb
lib/aiweb/observability/evidence_ledger.rb
docs/contracts/agent-os-p5-release.md
docs/schemas/agent-os-release-evidence-p5.schema.json
releases/v0.3.2-rc1/
  release_manifest.yaml
  evidence_integrity_manifest.yaml
  p5_gate_report.md
```

P5 evidence 필수 항목:

- constitution hash/signature evidence
- schema validation report
- state/replay demo
- policy coverage report
- tool gateway demo
- HITL v2 demo
- Brain MVP audit
- eval CI report
- red-team report
- self-improvement dry-run report
- script-executor neutralization audit
- release manifest hash
- rollback/kill-switch/operator drill report

Workbench 개선 방향:

- Goal / Plan
- Approval Queue
- Policy Decisions
- Evidence Timeline
- Browser QA
- Patch Manifest
- Replay / Resume
- Red-Team Results
- Release Gate Status

State/docs 정렬:

- `.ai-web/state.yaml`이 실제 구현 상태와 모순되지 않게 갱신
- 기존 `WEBBUILDER_AGENTIFICATION_EXECUTION_PLAN.md`는 완료/잔여 gap 문서로 분리 또는 명시
- README/help는 “supervised local agent OS candidate”로 정렬

수용 기준:

- P5 evidence 하나라도 missing/failed면 `release_ready: false`
- release manifest에 CI/test/artifact hash 포함
- `.ai-web/state.yaml`이 phase-0 pending만 주장하지 않음
- docs와 실제 CLI behavior가 불일치하지 않음

---

## 7. P0-P5 게이트 정의

| Gate | 목표 | 성공 기준 |
|---|---|---|
| P0 | 운영 진입 | Constitution, DecisionPacket, PolicyKernel, ToolGateway, HITL v2, replay skeleton, schema locks 통과 |
| P1 | 웹빌더 도메인 진입 | Domain competency bundle, expert rubric, gold/adversarial eval, Profile D/S routing evidence |
| P2 | 운영 안정성 | replay consistency, cost/latency budget, side-effect audit, rollback/kill-switch drill evidence |
| P3 | Personal Brain | Brain context packet, memory audit, tombstone/delete, low-grade memory action 차단 |
| P4 | Self-Improvement | proposal schema, experiment registry, dry-run-only governor, forbidden component block |
| P5 | Release evidence | release manifest, P5 report, red-team/eval/replay/HITL/tool gateway/brain/self-improvement evidence complete |

---

## 8. 검증 명령

최소 검증:

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

가능하면 추가:

```powershell
ruby bin/engine-runtime-matrix-check --json
```

주의:

- network/provider/deploy/git push 검증은 dry-run/fake fixture만 사용한다.
- package install이 필요한 검증은 별도 승인 없이는 실행하지 않는다.
- raw browser artifact는 commit하지 않는다.

---

## 9. 최종 완료 조건

성공 판정은 아래를 모두 만족해야 한다.

1. `aiweb agent`가 `engine-run` durable graph/evidence를 정본으로 사용한다.
2. `AgentRuntime`/`verify-loop`/browser static scenario가 top-level 대본 실행기처럼 남아 있지 않다.
3. 모든 side effect가 `DecisionPacket -> PolicyKernel -> ToolGateway` 순서를 통과한다.
4. Constitution hash가 run/resume/replay/P5 evidence에 연결된다.
5. HITL v2 approval mismatch/expiry/single-use/L4-L5 second reviewer 테스트가 통과한다.
6. replay consistency demo가 side effect 없이 통과한다.
7. red-team critical/high bypass 0.
8. domain eval/gold/adversarial/leakage check가 통과하거나 honest failure로 분해 보고된다.
9. Brain MVP memory audit가 secret/tombstone/low-grade action use를 차단한다.
10. self-improvement가 dry-run proposal/experiment registry까지만 수행하고 forbidden component patch를 막는다.
11. P5 release evidence가 생성되고 schema validation을 통과한다.
12. `ruby bin/check` 통과.
13. README/help/docs/state가 실제 behavior와 불일치하지 않는다.

---

## 10. Honest failure 조건

다음 중 하나가 발생하면 완료로 포장하지 말고 honest failure report를 남긴다.

- 기존 runtime compatibility를 깨면서 안전하게 migration할 수 없음
- ToolGateway 경유율 100%를 증명하지 못함
- red-team critical/high bypass가 남음
- replay가 non-deterministic해서 consistency를 증명하지 못함
- 대본 실행기 제거가 실제 삭제/강등이 아니라 rename에 그침
- P5 evidence bundle이 불완전함
- `ruby bin/check` 실패 원인을 해결하지 못함

보고서에는 원인을 다음으로 분해한다.

- architecture
- policy/security
- HITL/replay
- eval/red-team
- Personal Brain
- self-improvement
- compatibility
- documentation/state drift

---

## 11. ADR

### Decision

`engine-run`을 v3.2 Agent OS의 정본 durable runtime으로 승격하고, `aiweb agent`는 그 위의 goal-driven facade로 재구성한다. 고정 pipeline/script/scenario runner는 삭제하거나 ToolGateway-routed tool/probe로 강등한다.

### Drivers

1. split-brain 제거
2. 모든 side effect의 정책/증거 일원화
3. v3.2 P0-P5 evidence gate 충족
4. “에이전트처럼 보이는 대본 실행기” 제거
5. 기존 안전 자산 보존

### Alternatives considered

1. `AgentRuntime::Loop`를 독립 런타임으로 계속 키우기
   - 기각: engine-run과 evidence/checkpoint/state가 중복되어 split-brain이 심해진다.
2. LangGraph/OpenAI Agents SDK 등 외부 framework로 전면 교체
   - 기각: 현재 문제는 framework 부족이 아니라 policy/evidence/constitution/runtime governance 부족이다.
3. verify-loop를 main agent engine으로 승격
   - 기각: fixed pipeline이라 goal-driven agent OS와 맞지 않는다.

### Consequences

- 구현 범위는 크지만 안전성과 제품 정직성이 좋아진다.
- 일부 기존 CLI behavior는 compatibility wrapper가 필요하다.
- 문서/README/help/state를 함께 정리해야 한다.
- 단기적으로 “기능 추가”보다 “운영체제 경계 고정” 작업이 많아진다.

---

## 12. 실행 staffing 제안

단독 `/goal` 실행도 가능하지만, 병렬 팀이면 아래처럼 나누면 좋다.

- Architect lane: runtime unification, module boundaries, migration design
- Security/Policy lane: constitution, PolicyKernel, ToolGateway, HITL v2
- Test/Eval lane: schema locks, red-team, eval science, replay tests
- Runtime executor lane: agent facade -> engine-run, script-runner deletion/demotion
- Writer lane: README/help/state/docs alignment
- Verifier lane: P5 evidence, final `ruby bin/check`, regression review

---

## 13. 바로 쓸 `/goal` 지시문

최종 지시문은 별도 파일에 저장한다.

- `docs/goals/WEBBUILDER_AGENT_OS_V32_GOAL_PROMPT.ko.md`
