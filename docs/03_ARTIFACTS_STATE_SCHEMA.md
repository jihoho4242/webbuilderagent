# 03. 산출물과 상태 스키마

## 1. repo-local `.ai-web` 구조

`aiweb init`은 프로젝트 루트에 다음 구조를 만든다.

```text
.ai-web/
  state.yaml
  quality.yaml
  decisions.md
  project.md
  product.md
  stack.md
  brand.md
  content.md
  ia.md
  data.md
  security.md
  design-brief.md
  design-candidates/
    candidate-a.md
    candidate-b.md
    comparison.md
    selected.md
  DESIGN.md
  deploy.md
  post-launch-backlog.md
  tasks/
    current.md
    completed/
  qa/
    current-checklist.md
    final-report.md
    results/
    screenshots/
  gates/
    gate-1a-scope-quality-stack.md
    gate-1b-product-content-ia-data-security.md
    gate-2-design.md
    gate-3-golden-flow.md
    gate-4-predeploy.md
  snapshots/
  logs/
```

## 2. Source of truth

| 정보 | Source of truth |
|---|---|
| 현재 Phase | `.ai-web/state.yaml` |
| 품질 기준 | `.ai-web/quality.yaml` |
| 제품 방향 | `.ai-web/product.md` |
| 스택 | `.ai-web/stack.md` |
| 브랜드/말투 | `.ai-web/brand.md` |
| 카피/CTA/SEO | `.ai-web/content.md` |
| 사이트 구조 | `.ai-web/ia.md` |
| 데이터/API/권한 | `.ai-web/data.md` |
| 보안/개인정보 | `.ai-web/security.md` |
| 디자인 후보 목록 | `.ai-web/design-candidates/candidate-*.md` + `state.yaml` |
| 디자인 후보 비교 | `.ai-web/design-candidates/comparison.md` |
| 선택된 디자인 후보 | `.ai-web/design-candidates/selected.md` + `state.yaml.design_candidates.selected_candidate` |
| 디자인 규칙 | `.ai-web/DESIGN.md` 및 root `DESIGN.md` |
| 현재 구현 작업 | `.ai-web/tasks/current.md` |
| 현재 QA | `.ai-web/qa/current-checklist.md` |
| 최종 QA | `.ai-web/qa/final-report.md` |
| 배포 계획 | `.ai-web/deploy.md` |
| 출시 후 backlog | `.ai-web/post-launch-backlog.md` |
| 승인 상태 | `.ai-web/gates/*.md` + `state.yaml` |

## 3. `state.yaml` 핵심 스키마

```yaml
schema_version: 1
project:
  id: ""
  name: ""
  created_at: ""
  updated_at: ""

phase:
  current: "phase-0"
  completed: []
  blocked: false
  block_reason: ""

gates:
  gate_1a_scope_quality_stack:
    status: "pending"
    approved_at: null
    approved_by: null
    approval_scope: []
    approved_artifact_hashes: {}
    accepted_risks: []
    artifact: ".ai-web/gates/gate-1a-scope-quality-stack.md"
  gate_1b_product_content_ia_data_security:
    status: "pending"
    approved_at: null
    approved_by: null
    approval_scope: []
    approved_artifact_hashes: {}
    accepted_risks: []
    artifact: ".ai-web/gates/gate-1b-product-content-ia-data-security.md"
  gate_2_design:
    status: "pending"
    approved_at: null
    approved_by: null
    approval_scope: []
    approved_artifact_hashes: {}
    accepted_risks: []
    artifact: ".ai-web/gates/gate-2-design.md"
  gate_3_golden_flow:
    status: "pending"
    approved_at: null
    approved_by: null
    approval_scope: []
    approved_artifact_hashes: {}
    accepted_risks: []
    artifact: ".ai-web/gates/gate-3-golden-flow.md"
  gate_4_predeploy:
    status: "pending"
    approved_at: null
    approved_by: null
    approval_scope: []
    approved_artifact_hashes: {}
    accepted_risks: []
    artifact: ".ai-web/gates/gate-4-predeploy.md"

artifacts:
  project: { path: ".ai-web/project.md", status: "missing" }
  quality: { path: ".ai-web/quality.yaml", status: "missing" }
  product: { path: ".ai-web/product.md", status: "missing" }
  stack: { path: ".ai-web/stack.md", status: "missing" }
  brand: { path: ".ai-web/brand.md", status: "missing" }
  content: { path: ".ai-web/content.md", status: "missing" }
  ia: { path: ".ai-web/ia.md", status: "missing" }
  data: { path: ".ai-web/data.md", status: "missing" }
  security: { path: ".ai-web/security.md", status: "missing" }
  design_brief: { path: ".ai-web/design-brief.md", status: "missing" }
  design_candidates: { path: ".ai-web/design-candidates/", status: "missing", min_required: 2, count: 0 }
  design_comparison: { path: ".ai-web/design-candidates/comparison.md", status: "missing" }
  selected_design_candidate: { path: ".ai-web/design-candidates/selected.md", status: "missing" }
  design_system: { path: ".ai-web/DESIGN.md", status: "missing" }
  deploy: { path: ".ai-web/deploy.md", status: "missing" }
  final_qa_report: { path: ".ai-web/qa/final-report.md", status: "missing" }
  post_launch_backlog: { path: ".ai-web/post-launch-backlog.md", status: "missing" }

design_candidates:
  min_required: 2
  max_allowed: 10
  candidates: []
  comparison_path: ".ai-web/design-candidates/comparison.md"
  selected_path: ".ai-web/design-candidates/selected.md"
  selected_candidate: null
  regeneration_requested: false
  regeneration_rounds: 0
  gate_2_draft_path: ".ai-web/gates/gate-2-design.md"

implementation:
  stack_profile: null
  scaffold_target: null
  scaffold_created: false
  current_task: null
  completed_tasks: []

qa:
  current_checklist: null
  final_report: ".ai-web/qa/final-report.md"
  last_result: null
  open_failures: []

deploy:
  plan: ".ai-web/deploy.md"
  post_launch_backlog: ".ai-web/post-launch-backlog.md"
  rollback_defined: false
  rollback_dry_run_result: null

invalidations: []
decisions: []
snapshots: []
```

## 4. strict validation schema

`state.yaml`의 기계 검증 기준은 `docs/templates/state.schema.json`과 `docs/12_STATE_VALIDATION_SPEC.md`가 닫는다. `aiweb status/advance`는 YAML parse, JSON Schema shape validation, Phase-specific cross-field validation 순서로 실패해야 한다.

## 4. artifact status

허용 상태:

```text
missing
stub
draft
ready_for_gate
approved
invalidated
archived
```

## 5. 산출물 lifecycle

```text
missing -> stub -> draft -> ready_for_gate -> approved
                                      ↓
                                  invalidated -> draft
```

## 6. 디자인 후보 상태 규칙

Phase 3.5의 상태는 aggregate artifact와 전용 `design_candidates` 블록으로 추적한다.

필수 규칙:

- `design_candidates.min_required` 기본값은 2다.
- `design_candidates.max_allowed` 기본값은 10이다. design generation 총량도 `budget.max_design_generations_total: 10`을 따른다.
- `design_candidates.candidates`에는 후보 ID와 path를 기록한다.
- `artifacts.design_candidates.count`는 후보 파일 수와 일치해야 한다.
- `.ai-web/design-candidates/comparison.md`는 후보별 comparison matrix를 포함해야 한다.
- `.ai-web/design-candidates/selected.md`는 선택된 후보 ID, 선택 이유, 재생성 여부를 포함해야 한다.
- `design_candidates.selected_candidate`가 null이면 Phase 4로 advance할 수 없다.
- Gate 2 승인 상태는 `gates.gate_2_design.status`로 추적한다.

## 7. Phase 11 deploy 산출물 규칙

Phase 11 advance 조건에는 다음 artifact가 포함된다.

- `.ai-web/deploy.md`
- `.ai-web/qa/final-report.md`
- `.ai-web/post-launch-backlog.md`

필수 규칙:

- `deploy.rollback_defined`가 true이거나 `deploy.md`에 rollback 기준이 있어야 한다.
- `final_qa_report`는 critical open failure가 없거나 accepted risk를 명시해야 한다.
- `post_launch_backlog`는 analytics, monitoring, SEO indexing, follow-up improvements 중 최소 하나 이상을 포함해야 한다.
- Gate 4 승인 상태는 `gates.gate_4_predeploy.status`로 추적한다.

## 8. 문서별 생성/사용 규칙

| 문서 | 생성 Phase | 읽는 명령 | 무효화 트리거 |
|---|---:|---|---|
| `project.md` | 0 | status, interview, run | 아이디어 pivot |
| `quality.yaml` | 0.25 | qa-checklist, advance, next-task | 품질 목표 변경 |
| `product.md` | 1 | design-prompt, next-task, qa-checklist | 타깃/전환 목표 변경 |
| `stack.md` | 0.5 | init, run, next-task, deploy | 스택 변경 |
| `brand.md` | 1.5 | design-prompt, content, DESIGN.md | 브랜드 톤 변경 |
| `content.md` | 1.5 | design-prompt, next-task, QA | 카피/CTA 변경 |
| `ia.md` | 2 | next-task, QA | sitemap/flow 변경 |
| `data.md` | 2.5 | next-task, security, backend tasks | DB/API 변경 |
| `security.md` | 2.5 | next-task, QA, deploy | auth/privacy 변경 |
| `design-brief.md` | 3 | design-prompt | 디자인 취향 변경 |
| `design-candidates/candidate-*.md` | 3.5 | ingest-design, advance | 디자인 재생성 |
| `design-candidates/comparison.md` | 3.5 | ingest-design, advance | 후보 변경 |
| `design-candidates/selected.md` | 3.5 | ingest-design, DESIGN.md, advance | 선택 후보 변경 |
| `DESIGN.md` | 4 | all UI tasks, QA | 디자인 방향 변경 |
| `deploy.md` | 11 | deploy, advance | 배포 대상/환경 변경 |
| `qa/final-report.md` | 11 | advance, Gate 4 | 최종 QA 재실행 |
| `post-launch-backlog.md` | 11 | advance, release retrospective | 운영 목표 변경 |

## 9. 결정 기록

모든 주요 결정은 `.ai-web/decisions.md`에 남긴다.

형식:

```md
## YYYY-MM-DD — Decision title

Decision: 무엇을 결정했는가
Drivers: 왜 필요한가
Alternatives: 고려한 대안
Rejected: 버린 대안과 이유
Impact: 영향받는 문서/Phase
Rollback: 되돌릴 수 있는 방법
```



## 10. Closure additions

### Gate metadata

모든 gate는 단순 `status/approved_at`만으로는 부족하다. `state.yaml`과 schema는 다음 필드를 포함해야 한다.

```yaml
status: pending|approved|rejected|invalidated
approved_at: null
approved_by: null
approval_scope: []
approved_artifact_hashes: {}
accepted_risks: []
artifact: ".ai-web/gates/<gate>.md"
```

승인된 artifact hash가 바뀌면 gate는 `invalidated`가 된다.

### Budget

`quality.yaml`의 budget guard는 state에도 요약된다. 기본 cost mode는 GPT Pro/구독 사용량 기반 `subscription_usage`이며 model/image cost는 집계하지 않는다. API metered adapter일 때만 `F-BUDGET`으로 model/deploy action을 block한다. design generation은 총 10회 cap으로 제한하고, QA는 60분 초과 시 `F-QA-TIMEOUT` recovery loop로 전환한다. `aiweb init`이 복사한 기본 `quality.yaml`은 `quality.approved: false`이며, Phase 0.25를 통과하려면 사람이 품질 계약을 검토한 뒤 `true`로 명시해야 한다.

### Adapter registry

`adapters`는 implementation, image generation, browser QA, deploy adapter를 기록한다. 상세 계약은 [`14_ADAPTER_CONTRACTS.md`](./14_ADAPTER_CONTRACTS.md)를 따른다.

### QA open failures

`qa.open_failures`는 문자열 배열이 아니라 구조화된 객체 배열이다.

```yaml
open_failures:
  - id: ""
    source_result: ".ai-web/qa/results/...json"
    check_id: ""
    task_id: ""
    severity: critical|high|medium|low|info
    blocking: true
    accepted_risk_id: null
```

`qa.open_failures[]`는 Phase 7 이상에서 일반 `advance` blocker가 된다. Phase 0~6 rollback/re-entry는 해당 Phase 자체 guard가 만족되면 QA failure 때문에 영구 차단되지 않는다.

### Snapshot / rollback metadata

Snapshot은 `.ai-web`만 저장하지 않는다. git commit, working tree 상태, lockfile checksum, DB migration version, deploy build id, rollback dry-run result를 기록한다.
