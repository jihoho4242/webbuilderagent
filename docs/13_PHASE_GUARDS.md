# 13. Phase Guard Matrix

이 문서는 `aiweb advance`가 사람의 감이 아니라 기계적으로 판단해야 하는 최소 계약이다. 기존 Phase 설명은 제품/운영 의도를 설명하고, 이 문서는 **advance 차단/통과 규칙**을 닫는다.

## 1. Gate 폐쇄 결정

기존 Gate 1은 승인 대상 문서가 아직 생성되기 전인 Phase 0.5에 배치되어 있었다. 이를 다음처럼 분리한다.

| Gate | 시점 | 승인 범위 | 통과 후 효과 |
|---|---|---|---|
| Gate 1A — Scope / Quality / Stack | Phase 0.5 이후 | 1차 릴리즈 범위, 품질 계약, 스택 프로필 | 제품/콘텐츠/IA/보안 상세 문서 작성 진행 |
| Gate 1B — Product / Content / IA / Data / Security | Phase 2.5 이후 | 제품 정의, 콘텐츠 방향, IA, 데이터/API/권한/보안 | 디자인 생성 Phase 진입 |
| Gate 2 — Design Direction | Phase 3.5 이후 | 디자인 후보 선택과 `DESIGN.md` 변환 방향 | 디자인 시스템 변환 Phase 진입 |
| Gate 3 — Golden Page / Flow | Phase 8 이후 | 대표 페이지와 핵심 흐름 완성도 | 나머지 페이지/기능 반복 구현 |
| Gate 4 — Predeploy | Phase 11 | 최종 QA, 배포, rollback, accepted risks | 배포 또는 배포 handoff |

승인 대기 상태는 다음 Phase로 advance하지 않는다. `phase.blocked=true`와 `block_reason`을 기록하고 현재 Phase에 머문다.

## 2. 공통 advance 규칙

모든 `aiweb advance`는 다음 순서로 검사한다.

1. `.ai-web/state.yaml` YAML parse
2. `state.schema.json` shape validation
3. 현재 Phase의 required artifact 존재 여부
4. required field가 비어 있지 않은지 검사
5. Gate가 필요한 경우 `approved`인지 검사
6. 승인된 artifact hash가 변경되지 않았는지 검사
7. invalidation 중 blocking 항목이 남아 있는지 검사
8. Phase 7 이상에서는 QA open failure 중 blocking 항목이 남아 있는지 검사
9. design generation cap, QA runtime cap, metered adapter budget 초과 여부 검사
10. 다음 Phase로 state mutation

## 3. Phase Guard Matrix

| Current Phase | Required artifacts / fields | Required gate | Blocking conditions | Allowed next phase | State mutations on success |
|---|---|---|---|---|---|
| phase--1 | template registry, stack profile registry, `state.schema.json`, `quality.schema.json`, `qa-result.schema.json` | none | missing templates, schema parse failure | phase-0 | mark template artifacts ready |
| phase-0 | `.ai-web/project.md`, draft `.ai-web/product.md`; `project.idea`, website type, primary conversion, release scope | none | open questions that affect stack/profile, “다 만들자” scope | phase-0.25 | update project/product draft status |
| phase-0.25 | `.ai-web/quality.yaml`; `quality.approved: true`; budget, responsive, accessibility, performance, SEO, security, QA thresholds | none | missing hard-blocker thresholds, budget unset, quality contract not explicitly approved | phase-0.5 | set quality status draft/ready |
| phase-0.5 | `.ai-web/stack.md`; selected profile A/B/C/D, canonical default, scaffold target, deploy baseline | Gate 1A | unsupported profile, ambiguous scaffold target, design generation cap exceeded, QA timeout recovery exhausted, or metered adapter budget over limit | phase-1 | record Gate 1A approval hash |
| phase-1 | `.ai-web/product.md`; target user, problem, value proposition, primary journey, MVP scope, non-goals | none | missing conversion goal, MVP scope not bounded | phase-1.5 | mark product ready_for_gate |
| phase-1.5 | `.ai-web/brand.md`, `.ai-web/content.md`; content provenance, SEO title/description, CTA strategy | none | unverified regulated/legal claims, missing content owner/source | phase-2 | mark brand/content ready_for_gate |
| phase-2 | `.ai-web/ia.md`; sitemap, navigation, primary flow, mobile flow, edge cases | none | primary flow cannot be tested, mobile flow missing | phase-2.5 | mark IA ready_for_gate |
| phase-2.5 | `.ai-web/data.md`, `.ai-web/security.md`; data models/forms, public/private/admin boundaries, threat model | Gate 1B | unresolved auth/payment/admin/privacy boundary, missing spam/rate-limit policy | phase-3 | record Gate 1B approval hash |
| phase-3 | `.ai-web/design-brief.md`; preferred/non-preferred mood, prompt inputs, reference policy | none | missing reference rights/provenance, prompt lacks responsive constraints | phase-3.5 | mark design brief ready |
| phase-3.5 | `design-candidates/candidate-*.md` count >= min_required, `comparison.md`, `selected.md`, Gate 2 draft | Gate 2 | selected candidate missing, selected ID not in list, regeneration requested, Gate 2 not approved | phase-4 | record selected candidate and Gate 2 approval hash |
| phase-4 | `.ai-web/DESIGN.md` and root `DESIGN.md`; tokens, typography, spacing, components, forbidden patterns | none | arbitrary tokens, missing accessibility rules, candidate not traceable | phase-5 | mark design system approved/ready |
| phase-5 | root `AGENTS.md`, project README draft, implementation adapter config | none | missing instruction mapping for Codex/Claude, missing permissions policy | phase-6 | mark repo rules ready |
| phase-6 | app scaffold task packet done; install/build/test commands exist; lockfile checksum recorded | none | scaffold target mismatch, install/build/test unavailable | phase-7 | record scaffold baseline |
| phase-7 | design tokens and primitives implemented; component audit passes; `implementation.completed_tasks[]` records design-token, component-primitive, and component-audit completion evidence | none | missing completion evidence, inline random style, variant count exceeds quality contract | phase-8 | mark UI primitives complete |
| phase-8 | Golden Page task done, Golden Flow QA result, Gate 3 draft | Gate 3 | no desktop/mobile evidence, primary flow exceeds allowed steps, critical QA open | phase-9 | record Gate 3 approval hash |
| phase-9 | remaining page/feature tasks completed; `implementation.completed_tasks[]` records remaining page/feature completion evidence | none | task dependencies unresolved, missing completion evidence, blocking QA failure | phase-10 or phase-11 | update task completion state |
| phase-10 | current QA checklist, valid QA result JSON, fix packets or accepted risks | none | invalid result schema, evidence missing, blocking failure unresolved | phase-9 or phase-11 | close QA loop or generate fix task |
| phase-11 | `.ai-web/deploy.md`, final QA report, post-launch backlog, rollback dry-run, Gate 4 draft | Gate 4 | deploy rollback not defined, high/critical failure without accepted risk, env/DNS/monitoring missing | complete | record release readiness |

## 4. Required state mutation rules

- Gate approval stores `approved_by`, `approved_at`, `approval_scope`, `approved_artifact_hashes`.
- Any approved artifact hash change invalidates the corresponding gate.
- `aiweb init --profile` records `implementation.stack_profile` and `implementation.scaffold_target`; it does **not** scaffold application code.
- Actual application scaffold belongs to Phase 6 task packet.
- `qa.open_failures[]` is derived from valid QA result JSON, not manually typed strings.
- `qa.open_failures[]` blocks general `advance` only from Phase 7 onward; pre-QA phases must still be able to re-enter after rollback when their own phase guard is satisfied.
- `accepted_risks[]` must include owner, severity, mitigation, expiry, and release-blocker flag.

## 5. Negative test fixtures required

Implementation must include fixtures for:

- invalid YAML parse
- unknown top-level state key
- invalid phase string
- Phase 3.5 with one design candidate
- selected candidate ID not in candidate list
- Gate 2 pending while trying to enter Phase 4
- Phase 11 without rollback dry-run
- QA critical failure without accepted risk
- accepted risk without owner or expiry
- approved artifact hash drift


## 6. QA timeout guard

- `max_qa_runtime_minutes` 기본값은 60이다.
- QA run이 60분을 넘기면 `F-QA-TIMEOUT`을 생성한다.
- Director는 logs/screenshots/state를 읽고 원인을 분류한 뒤 fix packet을 생성한다.
- 같은 task에서 timeout recovery는 기본 3회까지 자동 반복한다.
- 3회 초과 시 `qa-report`는 budget-blocked 계열로 실패하며 새 `F-QA-TIMEOUT` open failure 또는 fix packet을 생성하지 않는다.
