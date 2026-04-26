# AI Web Director 문서 인덱스

이 디렉터리는 `AI Web Director`의 단일 통합 계획서를 실행 가능한 정책/운영/구현 문서 세트로 분리한 **새 canonical 문서 체계**다.

기존 `AI_WEB_DIRECTOR_PLAN.md`는 아래 문서들로 대체되며, 새 문서 생성 후 삭제한다.

## 읽는 순서

1. [`00_SYSTEM_BLUEPRINT.md`](./00_SYSTEM_BLUEPRINT.md) — 시스템 정체, 목표, 차별점
2. [`01_OPERATING_MODEL.md`](./01_OPERATING_MODEL.md) — 사람/AI/도구 역할과 운영 방식
3. [`02_PHASE_STATE_MACHINE.md`](./02_PHASE_STATE_MACHINE.md) — Phase, Gate, 통과 조건, rollback
4. [`03_ARTIFACTS_STATE_SCHEMA.md`](./03_ARTIFACTS_STATE_SCHEMA.md) — `.ai-web` 상태 시스템과 산출물 스키마
5. [`04_STACK_PROFILES.md`](./04_STACK_PROFILES.md) — Rails / Cloudflare / Hybrid / Content 스택 정책
6. [`05_CONTENT_BRAND_DESIGN_PIPELINE.md`](./05_CONTENT_BRAND_DESIGN_PIPELINE.md) — 콘텐츠, 브랜드, 디자인 파이프라인
7. [`06_IMPLEMENTATION_PIPELINE.md`](./06_IMPLEMENTATION_PIPELINE.md) — Codex/Claude Code task packet 구현 방식
8. [`07_QA_QUALITY_PIPELINE.md`](./07_QA_QUALITY_PIPELINE.md) — 품질 계약과 Codex Browser QA Adapter
9. [`08_FAILURE_ROLLBACK_POLICY.md`](./08_FAILURE_ROLLBACK_POLICY.md) — 실패 분류, 문서 무효화, rollback 정책
10. [`09_AIWEB_CLI_SPEC.md`](./09_AIWEB_CLI_SPEC.md) — `aiweb` CLI 명령 스펙
11. [`10_IMPLEMENTATION_ROADMAP.md`](./10_IMPLEMENTATION_ROADMAP.md) — 구현 마일스톤과 dogfooding 계획
12. [`11_OPEN_SOURCE_REFERENCE_MAP.md`](./11_OPEN_SOURCE_REFERENCE_MAP.md) — 참고 오픈소스와 차용/회피 기준
13. [`12_STATE_VALIDATION_SPEC.md`](./12_STATE_VALIDATION_SPEC.md) — `state.yaml` strict validation 계약
14. [`13_PHASE_GUARDS.md`](./13_PHASE_GUARDS.md) — 모든 Phase의 advance guard matrix
15. [`14_ADAPTER_CONTRACTS.md`](./14_ADAPTER_CONTRACTS.md) — Codex/Claude/Image/Browser/Deploy adapter 계약
16. [`15_ACCEPTANCE_QA_SCHEMAS.md`](./15_ACCEPTANCE_QA_SCHEMAS.md) — acceptance, QA, risk, budget 계약

## 실행 템플릿

구현 시 `aiweb init`이 프로젝트에 복사하거나 생성할 기본 템플릿은 [`templates/`](./templates/)에 있다.

핵심 템플릿:

- [`templates/state.yaml`](./templates/state.yaml)
- [`templates/state.schema.json`](./templates/state.schema.json)
- [`templates/quality.schema.json`](./templates/quality.schema.json)
- [`templates/qa-result.schema.json`](./templates/qa-result.schema.json)
- [`templates/quality.yaml`](./templates/quality.yaml)
- [`templates/project.md`](./templates/project.md)
- [`templates/product.md`](./templates/product.md)
- [`templates/brand.md`](./templates/brand.md)
- [`templates/content.md`](./templates/content.md)
- [`templates/ia.md`](./templates/ia.md)
- [`templates/data.md`](./templates/data.md)
- [`templates/security.md`](./templates/security.md)
- [`templates/design-brief.md`](./templates/design-brief.md)
- [`templates/design-candidate.md`](./templates/design-candidate.md)
- [`templates/design-comparison.md`](./templates/design-comparison.md)
- [`templates/design-selected.md`](./templates/design-selected.md)
- [`templates/DESIGN.md`](./templates/DESIGN.md)
- [`templates/task-packet.md`](./templates/task-packet.md)
- [`templates/qa-checklist.md`](./templates/qa-checklist.md)
- [`templates/qa-result.json`](./templates/qa-result.json)
- [`templates/final-qa-report.md`](./templates/final-qa-report.md)
- [`templates/deploy.md`](./templates/deploy.md)
- [`templates/post-launch-backlog.md`](./templates/post-launch-backlog.md)
- [`templates/gate-approval.md`](./templates/gate-approval.md)
- [`templates/gate-4-predeploy.md`](./templates/gate-4-predeploy.md)
- [`templates/AGENTS.md`](./templates/AGENTS.md)

## 문서 닫힘 원칙

구현 전에 닫아야 하는 것은 다음이다.

- Phase/Gate 정의와 Gate 1A/1B 분리
- `.ai-web` 파일 구조
- `state.yaml` 핵심 필드
- `quality.yaml` 품질 계약
- 스택 프로필 정책
- `DESIGN.md` 변환 원칙
- task packet 형식
- QA checklist / result 형식
- 실패/rollback 규칙
- `aiweb` CLI MVP 명령과 검증 기준
- adapter registry / provider contract
- acceptance matrix / QA result schema / budget guard

구현 중 열어둘 수 있는 것은 다음이다.

- 사이트 유형별 세부 카피 프리셋
- 디자인 스타일 프리셋 추가
- 배포 플랫폼 adapter 추가
- 스택별 bootstrap script 확장
- 브라우저 QA 실행 adapter 추가

