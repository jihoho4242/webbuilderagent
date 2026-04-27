# 12. State Validation Spec

이 문서는 `aiweb init/status/advance` 구현 전에 `state.yaml` 검증 기준이 흔들리지 않도록 닫는 strict validation 계약이다.

## 1. Source of truth

- 상태 파일: `.ai-web/state.yaml`
- 스키마 템플릿: `docs/templates/state.schema.json`
- 초기 상태 템플릿: `docs/templates/state.yaml`

`aiweb` 구현체는 `state.yaml`을 로드한 뒤 이 문서와 `state.schema.json`을 기준으로 구조 검증을 수행해야 한다.

## 2. Validation levels

### Level 1. Parse validation

필수:

- `state.yaml`은 YAML로 파싱 가능해야 한다.
- `state.schema.json`은 JSON으로 파싱 가능해야 한다.

실패 시:

- `aiweb status`는 state를 신뢰하지 않고 parse error를 출력한다.
- `aiweb advance`는 즉시 차단한다.

### Level 2. Shape validation

필수 top-level keys:

```text
schema_version
project
phase
gates
artifacts
design_candidates
implementation
qa
deploy
budget
adapters
invalidations
decisions
snapshots
```

불명확한 top-level key는 금지한다. 새 top-level key가 필요하면 `state.schema.json`과 이 문서를 먼저 갱신한다.

### Level 3. Enum validation

허용 artifact status:

```text
missing
stub
draft
ready_for_gate
approved
invalidated
archived
```

허용 gate status:

```text
pending
approved
rejected
invalidated
```

허용 stack profile:

```text
A
B
C
D
null
```

### Level 4. Path contract validation

다음 path는 schema와 일치해야 한다.

```text
.ai-web/design-candidates/comparison.md
.ai-web/design-candidates/selected.md
.ai-web/gates/gate-2-design.md
.ai-web/deploy.md
.ai-web/qa/final-report.md
.ai-web/post-launch-backlog.md
```

`aiweb init`은 위 path를 기준으로 directory와 stub을 생성한다.

### Level 5. Cross-field validation

JSON Schema만으로 부족한 Phase별 의미 검증은 구현체의 guard로 수행한다.

#### Quality contract approval

- Phase 0.25 → Phase 0.5는 `.ai-web/quality.yaml`이 `quality.schema.json`을 통과해야 한다.
- `quality.approved`는 `true`여야 한다.
- `aiweb init`이 복사한 기본값 `false`는 사용자 승인으로 간주하지 않는다.

#### Design candidate consistency

- `artifacts.design_candidates.count`는 실제 `candidate-*.md` 파일 수와 일치해야 한다.
- `design_candidates.candidates.length`는 `artifacts.design_candidates.count`와 일치해야 한다.
- `design_candidates.min_required`는 2 이상이어야 한다.
- `design_candidates.selected_candidate`가 null이 아니면 해당 ID가 `design_candidates.candidates[].id`에 존재해야 한다.

#### Deploy consistency

- `deploy.plan`은 `.ai-web/deploy.md`여야 한다.
- `qa.final_report`는 `.ai-web/qa/final-report.md`여야 한다.
- `deploy.post_launch_backlog`는 `.ai-web/post-launch-backlog.md`여야 한다.
- Phase 11 완료에는 `deploy.rollback_defined: true`와 rollback dry-run evidence가 필요하다.

#### QA failure scope

- `qa.open_failures[]`는 `task_id`, `check_id`, `source_result`, severity, blocking 여부를 기록한다.
- blocking open failure는 Phase 7 이상에서만 일반 `advance` blocker로 작동한다.
- Phase 0~6 rollback/re-entry는 해당 Phase 자체 guard가 만족되면 QA failure 때문에 차단하지 않는다.

## 3. Phase-specific advance validation

### Phase 3.5 → Phase 4

`aiweb advance`는 다음을 모두 검사한다.

- `artifacts.design_candidates.count >= design_candidates.min_required`
- `design_candidates.candidates.length >= design_candidates.min_required`
- `.ai-web/design-candidates/comparison.md` 존재
- `.ai-web/design-candidates/selected.md` 존재
- `design_candidates.selected_candidate != null`
- selected candidate ID가 후보 목록에 존재
- `.ai-web/gates/gate-2-design.md` 존재
- Gate 2가 `approved`. approval 대기는 Phase 3.5 blocked 상태로 유지

### Phase 7 → Phase 8

`aiweb advance`는 다음 completion evidence를 모두 검사한다.

- `implementation.completed_tasks[]`에 design tokens 완료 증거
- `implementation.completed_tasks[]`에 component primitives 완료 증거
- `implementation.completed_tasks[]`에 component audit 통과 증거

### Phase 9 → Phase 10

`aiweb advance`는 remaining page/feature task completion evidence가 `implementation.completed_tasks[]`에 기록되어 있는지 검사한다.

### Phase 11 completion

`aiweb advance` 또는 release completion check는 다음을 모두 검사한다.

- `.ai-web/deploy.md` 존재
- `.ai-web/qa/final-report.md` 존재
- `.ai-web/post-launch-backlog.md` 존재
- `gates.gate_4_predeploy.status == approved`
- `deploy.rollback_defined == true`
- final QA report에 critical/high open failure가 없음. accepted risk는 owner/mitigation/expiry를 포함해야 함

## 4. `aiweb status` behavior

`aiweb status`는 validation 결과를 다음 순서로 출력한다.

```text
1. parse status
2. schema status
3. current phase
4. gate status
5. missing/invalid artifacts
6. design candidate status
7. deploy readiness status
8. next recommended command
```

state validation 실패 시 `next recommended command`는 일반 작업이 아니라 state repair command 또는 missing artifact generation이어야 한다.

## 5. `aiweb init` behavior

`aiweb init`은 다음을 보장한다.

- `docs/templates/state.yaml`을 기반으로 `.ai-web/state.yaml` 생성
- `docs/templates/state.schema.json`을 참조 가능한 위치에 복사하거나 package에 포함
- `state.yaml`이 `state.schema.json` shape validation을 통과
- `.ai-web/design-candidates/`, `.ai-web/qa/`, `.ai-web/gates/` directory 생성
- deploy/final-report/post-launch-backlog stub 생성

## 6. `aiweb advance` behavior

`aiweb advance`는 다음 순서로 실패해야 한다.

1. YAML parse 실패
2. schema validation 실패
3. cross-field validation 실패
4. current phase required artifacts 누락
5. gate approval 누락
6. Phase 7 이상 QA/open failure block
7. invalidated artifact 존재

처음 발견한 blocker를 명확히 출력하고, destructive repair를 자동 수행하지 않는다.

## 7. Schema change policy

`state.yaml` 구조 변경 시 반드시 함께 변경한다.

- `docs/templates/state.yaml`
- `docs/templates/state.schema.json`
- `docs/03_ARTIFACTS_STATE_SCHEMA.md`
- `docs/12_STATE_VALIDATION_SPEC.md`
- 관련 CLI guard 문서

## 8. Remaining implementation risks memo

아래는 문서 단계에서 당장 닫지 않고 구현 중 참고할 리스크다.

| Risk | Why not closed now | Future close point |
|---|---|---|
| 실제 `aiweb init --profile` 구현 없음 | 문서/스키마 기준은 닫혔고 구현 작업 자체에 해당 | CLI MVP 구현 시 |
| `final-report.md` parser 없음 | Markdown template로 충분하며 자동 판정은 QA adapter 구현 영역 | QA Adapter Skeleton |
| 각 스택별 scaffold generator 세부 명령 없음 | canonical default와 scaffold target은 닫혔고 명령 세부는 구현/환경 의존 | Profile별 bootstrap 구현 시 |
| JSON Schema runtime validator 라이브러리 미선택 | 문서와 schema는 닫혔고 언어/패키징 선택 후 결정 가능 | State Engine 구현 시 |



## 9. Closure validation additions

- Gate 1A와 Gate 1B를 별도 gate key로 검증한다.
- Phase 4 advance는 `gates.gate_2_design.status == approved`가 아니면 실패한다.
- approved artifact hash drift는 해당 gate를 `invalidated`로 바꾼다.
- `qa.last_result`는 존재하는 valid JSON이어야 한다.
- `qa.open_failures[]`는 valid QA result check를 참조해야 한다.
- Gate 4 approval은 final report가 blocked가 아니고 critical/high open failure가 없을 때만 가능하다.
- accepted risk는 id, severity, owner, mitigation, expires_at을 요구한다.
- API metered budget 초과 시 `aiweb advance`는 budget blocker를 출력한다. subscription usage mode에서는 비용 대신 design generation 총 10회 cap과 QA 60분 timeout guard를 검사한다.
- adapter registry는 provider enum과 required capability를 충족해야 한다.

자세한 Phase별 guard는 [`13_PHASE_GUARDS.md`](./13_PHASE_GUARDS.md), adapter 검증은 [`14_ADAPTER_CONTRACTS.md`](./14_ADAPTER_CONTRACTS.md), QA/budget 검증은 [`15_ACCEPTANCE_QA_SCHEMAS.md`](./15_ACCEPTANCE_QA_SCHEMAS.md)를 따른다.
