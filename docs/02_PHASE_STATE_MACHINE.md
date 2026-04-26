# 02. Phase 상태 머신

## 1. 전체 Phase

```text
Phase -1. Director 템플릿 / 스택 프로필 준비
Phase 0. 아이디어 인터뷰 / 웹 유형 분류
Phase 0.25. 품질 계약 생성
Phase 0.5. 스택 프로필 선택
Phase 1. 제품 정의 / 사용자 / 가치 제안
Phase 1.5. 브랜드 / 콘텐츠 / 카피라이팅 설계
Phase 2. 페이지 구조 / UX flow / IA 설계
Phase 2.5. 데이터 / API / 권한 / 보안 / 관리자 설계
Phase 3. 디자인 취향 캘리브레이션 / 디자인 프롬프트 생성
Phase 3.5. 디자인 후보 생성 / 비교 / 선택
Phase 4. DESIGN.md / token / component rule 변환
Phase 5. repo 구조 / AGENTS.md / 개발 규칙 확정
Phase 6. 프로젝트 세팅
Phase 7. 디자인 토큰 / 공통 UI 구현
Phase 8. Golden Page + Golden Flow 구현
Phase 9. 페이지별 / 기능별 task packet 반복 구현
Phase 10. Codex Browser QA 상시 검증
Phase 11. 배포 / 모니터링 / 운영 개선
```

Phase 10은 마지막 단계가 아니라 Phase 7 이후 계속 실행되는 QA layer다.

## 2. Phase 상세

### Phase -1. Director 템플릿 / 스택 프로필 준비

목적:

- 매 프로젝트마다 운영 규칙을 다시 만들지 않도록 기본 템플릿을 준비한다.

필수 산출물:

- stack profile registry
- artifact templates
- task packet template
- QA checklist template
- default quality policy

통과 조건:

- `aiweb init`이 기본 `.ai-web` 구조를 만들 수 있다.
- `aiweb init --profile <A|B|C|D>`가 각 profile의 canonical scaffold target을 결정할 수 있다.

### Phase 0. 아이디어 인터뷰 / 웹 유형 분류

목적:

- 사용자의 아이디어를 웹 유형과 1차 릴리즈 범위로 자른다.

핵심 질문:

- 누구를 위한 웹인가?
- 방문자가 최종적으로 무엇을 해야 하는가?
- 1순위 전환 목표는 무엇인가?
- 콘텐츠는 사용자가 제공하는가, AI가 초안을 만드는가?
- 로그인/결제/관리자/DB가 필요한가?
- SEO가 중요한가?
- 참고 사이트와 싫어하는 스타일은 무엇인가?

산출물:

- `.ai-web/project.md`
- `.ai-web/product.md` 초안

통과 조건:

- “일단 다 만들자”가 금지되어 있다.
- 1차 릴리즈 범위가 명확하다.

### Phase 0.25. 품질 계약 생성

목적:

- “완벽한 웹사이트”의 기준을 감이 아니라 수치와 체크리스트로 정의한다.

산출물:

- `.ai-web/quality.yaml`

필수 기준:

- responsive breakpoints
- accessibility target
- performance target
- SEO 필수 항목
- content/CTA 기준
- design token 준수
- QA evidence 기준

통과 조건:

- 구현/QA가 자동으로 판단할 수 있는 기준이 존재한다.

### Phase 0.5. 스택 프로필 선택

목적:

- 제품 문서와 구현 계획 전에 기술 방향과 scaffold 기준을 고정한다.

산출물:

- `.ai-web/stack.md`
- Gate 1A approval draft

통과 조건:

- Profile A/B/C/D 중 하나가 선택됨
- 선택 profile의 `canonical default`, `allowed override`, `when to override`, `scaffold target`이 문서화됨
- `aiweb init --profile <A|B|C|D>`가 생성할 scaffold target이 명확함
- 선택 이유와 배포 방식이 문서화됨

승인:

- Gate 1A 필요

### Phase 1. 제품 정의 / 사용자 / 가치 제안

산출물:

- `.ai-web/product.md` 확정

통과 조건:

- target user
- problem
- value proposition
- primary conversion
- release scope
- success metrics

### Phase 1.5. 브랜드 / 콘텐츠 / 카피라이팅 설계

산출물:

- `.ai-web/brand.md`
- `.ai-web/content.md`

통과 조건:

- 브랜드 톤과 말투가 정해짐
- 페이지별 핵심 카피와 CTA가 있음
- SEO title/description 초안이 있음

### Phase 2. 페이지 구조 / UX flow / IA 설계

산출물:

- `.ai-web/ia.md`

통과 조건:

- sitemap
- navigation
- primary flow
- section order
- mobile flow

### Phase 2.5. 데이터 / API / 권한 / 보안 / 관리자 설계

산출물:

- `.ai-web/data.md`
- `.ai-web/security.md`

통과 조건:

- 필요한 데이터 모델이 정의됨
- public/private/admin boundary가 정의됨
- form, auth, payment, privacy, spam protection 여부가 정의됨
- threat model과 abuse case가 정의됨
- Gate 1B approval draft가 존재함
- Gate 1B 필요

### Phase 3. 디자인 취향 캘리브레이션 / 디자인 프롬프트 생성

산출물:

- `.ai-web/design-brief.md`
- GPT Image 2 prompt
- Claude Design prompt

통과 조건:

- 선호/비선호 무드
- 색상 방향
- layout density
- typography mood
- motion intensity
- reference direction

### Phase 3.5. 디자인 후보 생성 / 비교 / 선택

목적:

- 디자인 후보를 최소 2개 이상 만들고, 비교/선택 상태를 Gate 2 전까지 추적 가능하게 만든다.

산출물:

- `.ai-web/design-candidates/candidate-*.md`
- `.ai-web/design-candidates/comparison.md`
- `.ai-web/design-candidates/selected.md`
- `.ai-web/gates/gate-2-design.md` draft

통과 조건:

- 디자인 후보가 최소 2개 이상 존재한다.
- `.ai-web/design-candidates/comparison.md`에 comparison matrix가 존재한다.
- `.ai-web/design-candidates/selected.md`에 선택된 후보 ID와 선택 이유가 존재한다.
- 재생성 여부가 `state.yaml`의 `design_candidates.regeneration_requested`에 기록되어 있다.
- Gate 2 draft가 존재한다.

승인:

- Gate 2 필요

### Phase 4. DESIGN.md / token / component rule 변환

산출물:

- `.ai-web/DESIGN.md`
- root `DESIGN.md` 또는 symlink/copy

통과 조건:

- color tokens
- typography tokens
- spacing scale
- layout rules
- component variants
- forbidden patterns
- 선택된 디자인 후보의 시각 언어가 추출되어 있음

### Phase 5. repo 구조 / AGENTS.md / 개발 규칙 확정

산출물:

- root `AGENTS.md`
- project README 초안
- development rules

통과 조건:

- Codex/Claude Code가 지켜야 할 규칙이 repo에 존재함

### Phase 6. 프로젝트 세팅

산출물:

- 실제 app scaffold
- package/script/config
- baseline tests

통과 조건:

- install/build/test가 실행 가능함
- scaffold가 선택 profile의 canonical scaffold target과 일치함

### Phase 7. 디자인 토큰 / 공통 UI 구현

산출물:

- theme/token implementation
- Button/Card/Input/Section primitives

통과 조건:

- `DESIGN.md` 기준 component primitives가 존재함
- random inline style 금지

QA:

- Phase 10 병행 시작

### Phase 8. Golden Page + Golden Flow 구현

산출물:

- 대표 페이지
- 대표 사용자 flow
- QA evidence
- Gate 3 approval draft

통과 조건:

- desktop/mobile 모두 주요 flow가 자연스러움
- 나머지 페이지로 확장 가능한 기준이 됨

승인:

- Gate 3 필요

### Phase 9. 페이지별 / 기능별 task packet 반복 구현

산출물:

- `.ai-web/tasks/*.md`
- 구현 코드
- QA 결과

통과 조건:

- task packet 단위로 완료/검증됨

### Phase 10. Codex Browser QA 상시 검증

산출물:

- `.ai-web/qa/current-checklist.md`
- `.ai-web/qa/results/*.json`
- screenshot evidence
- fix packet

통과 조건:

- quality.yaml 기준에 맞는 검증 결과가 있음

### Phase 11. 배포 / 모니터링 / 운영 개선

목적:

- 배포 전 검증, 운영 handoff, post-launch 개선 루프를 문서로 닫는다.

산출물:

- `.ai-web/deploy.md`
- `.ai-web/qa/final-report.md`
- `.ai-web/post-launch-backlog.md`
- `.ai-web/gates/gate-4-predeploy.md` approval

통과 조건:

- `.ai-web/deploy.md`에 배포 대상, 환경변수, 도메인/DNS, rollback 기준이 있다.
- `.ai-web/qa/final-report.md`에 최종 QA 요약, open failures, accepted risks, evidence 링크가 있다.
- `.ai-web/post-launch-backlog.md`에 analytics/monitoring/indexing/follow-up 개선 항목이 있다.
- Gate 4가 승인되어 있다.

승인:

- Gate 4 필요

## 3. Advance 규칙

`aiweb advance`는 다음을 검사한다.

1. 현재 Phase의 required artifacts 존재 여부
2. required fields 충족 여부
3. quality/gate 조건 충족 여부
4. blocked 상태 여부
5. 승인 필요 여부
6. rollback/invalidation 필요 여부
7. Phase-specific guard 충족 여부

조건이 충족되지 않으면 다음 Phase로 이동하지 않는다.

## 4. Phase-specific advance guard

### Phase 3.5 → Phase 4

`aiweb advance`는 다음을 검사한다.

- `.ai-web/design-candidates/` 아래 후보가 최소 2개 이상 존재
- `.ai-web/design-candidates/comparison.md` 존재
- `.ai-web/design-candidates/selected.md` 존재
- `state.yaml`의 `design_candidates.selected_candidate`가 null이 아님
- `.ai-web/gates/gate-2-design.md` draft 존재
- Gate 2 상태가 반드시 `approved`임. approval 대기 상태는 Phase 3.5에서 `blocked`로 남음

### Phase 11 완료

`aiweb advance` 또는 release completion check는 다음을 검사한다.

- `.ai-web/deploy.md` 존재
- `.ai-web/qa/final-report.md` 존재
- `.ai-web/post-launch-backlog.md` 존재
- Gate 4 상태가 `approved`
- final QA report에 critical/high open failure가 없음. accepted risk는 owner/mitigation/expiry가 있어야 함
- deploy plan에 rollback 기준이 있고 rollback dry-run evidence가 있음

## 5. 문서 무효화 규칙

- `stack.md` 변경 → implementation tasks, deploy plan, data/security 일부 무효화
- `product.md` primary conversion 변경 → content, IA, design brief, QA checklist 무효화
- `design-candidates/selected.md` 변경 → `DESIGN.md`, UI tasks, Gate 2 이후 산출물 무효화
- `DESIGN.md` 변경 → UI tasks, golden page QA 재검증
- `quality.yaml` 변경 → QA checklist/result/final-report 재생성
- `deploy.md` 변경 → Gate 4 재검토
- Gate rejection → 해당 Gate 이전 Phase로 rollback



## 6. 폐쇄 결정

- `aiweb init`은 `.ai-web` 구조와 기본 stub만 만든다.
- `aiweb init --profile <A|B|C|D>`는 선택 profile과 scaffold target을 state/stack/deploy 문서에 기록한다. 실제 app scaffold는 만들지 않는다.
- 실제 app scaffold는 Phase 6 task packet으로 Codex/Claude Code 같은 implementation adapter가 수행한다.
- 전체 Phase별 advance guard는 [`13_PHASE_GUARDS.md`](./13_PHASE_GUARDS.md)를 따른다.
- “approval wait”은 advance 성공이 아니라 현재 Phase block 상태다.
