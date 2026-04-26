# 10. 구현 로드맵

## 1. 구현 전략

문서/상태 시스템을 먼저 닫고, 얇은 CLI부터 구현한다. 웹 빌더 전체 UI를 먼저 만들지 않는다.

```text
Docs + Templates
-> State Engine
-> CLI MVP
-> Generators
-> QA Adapter
-> Dogfood Project
-> Expansion
```

## 2. Milestone 0 — Thin Vertical Slice

목표: 전체 CLI를 크게 만들기 전에 가장 위험한 end-to-end loop가 실제로 품질을 올리는지 검증한다.

범위:

- Profile D 한 페이지
- 디자인 후보 1개 이상
- task packet 1개
- browser QA result 1개
- fix packet 1개
- rollback decision 1개

완료 기준:

- 실제 작은 사이트가 quality.yaml 기준 일부를 통과한다.
- QA 실패가 fix packet 또는 rollback decision으로 변환된다.
- 산출물/상태/증거 경로가 재현 가능하다.

## 3. Milestone 1 — Canonical 문서와 템플릿

목표:

- 현재 문서 세트를 canonical로 확정한다.
- templates를 `aiweb init` 입력으로 사용할 수 있게 만든다.
- Phase 3.5 디자인 후보와 Phase 11 deploy 산출물까지 scaffold 기준을 닫는다.

완료 기준:

- docs/README.md 존재
- 정책/운영/Phase/CLI/QA/rollback 문서 존재
- deploy/final-report/post-launch-backlog 템플릿 존재
- design candidate/comparison/selected 템플릿 존재
- stack profile의 canonical default / allowed override / scaffold target 존재
- 기존 통합 계획서 삭제

## 4. Milestone 2 — `.ai-web` State Engine

목표:

- state.yaml을 읽고 `state.schema.json`으로 strict shape validation을 수행한 뒤 현재 Phase, Gate, artifact 상태를 판단한다.

기능:

- load state
- parse YAML
- validate against state.schema.json
- list missing artifacts
- mark artifact status
- track design candidate count and selected candidate
- track deploy/final-report/post-launch artifact status
- record decision

완료 기준:

- unit test로 phase/gate/artifact status 판단 가능
- Phase 3.5 guard가 후보 2개/comparison/selected/Gate 2 draft를 검사
- Phase 11 guard가 deploy.md/final-report/post-launch-backlog/Gate 4를 검사

## 5. Milestone 3 — `aiweb init/status/advance`

목표:

- 새 프로젝트에서 Director 환경을 만들고 상태를 확인한다.

기능:

- template copy
- directory creation
- `aiweb init --profile <A|B|C|D>` canonical scaffold target 기록
- status output
- advance guard

완료 기준:

- 빈 폴더에서 `aiweb init` 후 `.ai-web` 생성
- `aiweb init --profile D`가 Astro/MDX/Cloudflare Pages/sitemap/RSS scaffold target을 기록
- `aiweb status`가 next command 출력
- 필수 artifact 없으면 `advance` 차단

## 6. Milestone 4 — Interview / Artifact Generator

목표:

- 아이디어를 문서 초안으로 변환한다.

기능:

- question generator
- project/product/brand/content draft
- quality.yaml draft
- stack recommendation

완료 기준:

- “로컬 카페 웹사이트” 한 문장으로 Phase 0~1.5 초안 생성

## 7. Milestone 5 — Design Pipeline Generator

목표:

- 디자인 프롬프트와 `DESIGN.md` 변환 흐름을 만든다.

기능:

- design taste calibration prompt
- GPT Image 2 prompt
- Claude Design prompt
- candidate template generation
- candidate comparison template
- selected candidate record
- DESIGN.md generator

완료 기준:

- 최소 2개 design candidate를 기록
- `design-candidates/comparison.md`와 `design-candidates/selected.md` 생성
- 선택 디자인 설명을 token/component rule로 변환

## 8. Milestone 6 — Task Packet Generator

목표:

- Codex/Claude Code가 실행 가능한 task packet 생성

기능:

- bootstrap task
- design token task
- golden page task
- page/feature task
- QA fix task
- deploy preparation task

완료 기준:

- Phase 8 Golden Page task packet 생성
- Phase 11 deploy preparation task 생성

## 9. Milestone 7 — QA Adapter Skeleton

목표:

- Codex App/CLI browser QA를 위한 checklist/result/fix loop 완성

기능:

- qa checklist generation
- result json ingestion
- failure classification
- fix packet generation
- final-report generation

완료 기준:

- 실패 result JSON으로 fix task 생성
- release readiness 입력으로 `.ai-web/qa/final-report.md` 생성

## 10. Milestone 8 — Dogfooding

첫 샘플:

```text
로컬 카페 웹사이트
- 브랜드 랜딩
- 메뉴 소개
- 위치/영업시간
- 예약/문의 폼
- 모바일 우선
- SEO 필수
- Profile D canonical default 우선
```

검증할 것:

- 인터뷰가 충분한가
- quality.yaml이 현실적인가
- 스택 추천이 맞는가
- content.md가 구현에 충분한가
- DESIGN.md가 흔들림을 막는가
- design candidate 최소 2개 비교가 실제로 도움 되는가
- task packet이 과하지 않은가
- Browser QA가 실제 문제를 잡는가
- deploy.md/final-report/post-launch-backlog가 release readiness 판단에 충분한가

## 11. Milestone 9 — Expansion

추가:

- Rails Profile A bootstrap
- Hybrid Profile C bootstrap
- deploy adapter
- Playwright MCP adapter
- Lighthouse/a11y automation
- project dashboard
- reusable industry presets

## 12. MVP 완료 정의

MVP는 다음 시나리오를 끝까지 통과해야 한다.

```text
사용자 아이디어 입력
-> aiweb init --profile D
-> interview 문서 생성
-> Gate 1A draft
-> design prompt 생성
-> design candidate 2개 이상 기록
-> comparison/selected 생성
-> DESIGN.md 생성
-> Golden Page task packet 생성
-> Codex 구현
-> QA checklist 생성
-> Browser QA result 저장
-> 실패 시 fix packet 생성
-> deploy.md/final-report/post-launch-backlog 생성
```

## 13. 리스크

| 리스크 | 대응 |
|---|---|
| 문서가 과도해져 실행이 느려짐 | MVP artifact set 최소화, lazy generation |
| 디자인 품질이 낮음 | taste calibration + 후보 비교 + DESIGN.md 추출 강화 |
| AI가 task 범위를 키움 | task packet size guard |
| QA가 형식적임 | evidence required + failure result JSON + final-report |
| 스택 선택 오류 | Gate 1A/1B와 rollback 정책 강화, canonical default 우선 |
| 사용자가 승인 피로를 느낌 | Gate 1A/1B는 하나의 Gate family로 UI에서 묶어 보여줌 |
| 모델/이미지/QA 폭주 | 구독형 이미지 생성은 비용 집계 제외, 디자인 총 10회 cap, QA 60분 timeout recovery loop |
| provider quota/API 변화 | adapter registry와 공식 문서 확인 정책 |
| rollback이 코드/배포를 못 되돌림 | git/deploy/DB snapshot + rollback dry-run |

