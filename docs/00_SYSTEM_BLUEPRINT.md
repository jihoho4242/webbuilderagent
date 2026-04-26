# 00. AI Web Director 시스템 블루프린트

## 1. 한 줄 정의

`AI Web Director`는 사용자의 아이디어를 완성형 웹사이트로 만들기 위해 **제품기획, 콘텐츠, 브랜드, 디자인, 스택, 구현, QA, 배포 전 검증**을 Phase/Gate 기반으로 지휘하는 로컬 우선 AI 웹 제작 운영체계다.

## 2. 만들지 않는 것

이 시스템은 다음이 아니다.

- 단순 웹사이트 생성기
- 단순 Lovable/Bolt/v0 클론
- 단순 UI 컴포넌트 생성기
- 단순 Codex wrapper
- 단순 프롬프트 모음

## 3. 만드는 것

이 시스템은 다음 역할을 합친다.

```text
AI PM
+ AI Tech Lead
+ AI Design Director
+ AI Content Strategist
+ AI QA Manager
+ AI Release Coordinator
```

핵심은 “AI가 코드를 만든다”가 아니라 **AI가 웹사이트 제작 전체를 통제 가능한 순서로 지휘한다**는 점이다.

## 4. 최종 사용자 경험

사용자는 이렇게 시작한다.

```text
AI Web Director로 시작해.
내 아이디어는 "프리미엄 로컬 카페 웹사이트"야.
필요한 질문을 하고, 문서를 만든 뒤, 내가 승인하면 구현까지 진행해.
```

Director는 다음을 수행한다.

```text
1. 아이디어 인터뷰
2. 웹 유형 / 릴리즈 범위 분류
3. 품질 계약 생성
4. 스택 프로필 추천
5. 제품/브랜드/콘텐츠/IA/보안 문서 생성
6. 디자인 취향 캘리브레이션
7. GPT Image 2 / Claude Design 프롬프트 생성
8. 디자인 후보 평가
9. DESIGN.md / token / component rule 변환
10. Codex/Claude Code task packet 생성
11. 구현 진행
12. Codex App/CLI Browser QA 실행
13. 실패 시 fix packet 또는 phase rollback
14. 배포 전 최종 승인
```

## 5. 기존 오픈소스 대비 위치

| 범주 | 대표 프로젝트 | 역할 | AI Web Director와의 관계 |
|---|---|---|---|
| AI 앱 빌더 | bolt.diy, Dyad | 코드 생성/수정/preview | 구현 UX와 provider 구조 참고 |
| Full-stack 생성 | Cofounder | 앱 구조+UI+backend 생성 | 장기 방향 참고, 직접 복제 금지 |
| UI 생성 | OpenUI, openv0 | UI/컴포넌트 생성 | 디자인 후보와 component recipe 참고 |
| Spec-driven | GitHub Spec Kit | spec/plan/tasks/implement | 문서 기반 상태 머신 참고 |
| 브라우저 자동화 | browser-use, Playwright MCP | 브라우저 조작/검증 | QA adapter 참고 |
| 개발 에이전트 | Codex, Claude Code, OpenHands | 코드 구현 | 실행 엔진 또는 대체 adapter |

차별점:

```text
기존: AI가 코드를 생성한다.
우리: AI가 웹사이트 제작을 정책/문서/게이트/QA로 지휘한다.
```

## 6. 설계 원칙

### 6.1 문서 우선

구현 전에 실행에 필요한 문서를 만든다. 문서는 보고서가 아니라 **AI 구현 에이전트의 입력 계약**이다.

### 6.2 Phase/Gate 우선

AI가 다음 단계를 마음대로 선택하지 않는다. 현재 Phase, 필수 산출물, 통과 조건, 승인 상태를 기준으로만 진행한다.

### 6.3 디자인은 이미지가 아니라 규칙으로 변환

GPT Image 2 / Claude Design 결과물은 최종 코드 스펙이 아니다. 반드시 `DESIGN.md`, token, component rule로 추출한다.

### 6.4 task packet 단위 구현

Codex/Claude Code에게 “전체 만들어줘”를 금지한다. 모든 구현은 `Goal / Inputs / Constraints / Acceptance Criteria / Verification`이 포함된 task packet으로 수행한다.

### 6.5 QA는 후반 이벤트가 아니라 상시 레이어

Phase 7 이후부터 QA는 계속 붙는다. 브라우저 QA 실패는 fix packet으로 바뀌거나 이전 Phase rollback을 유발한다.

### 6.6 로컬 우선

프로젝트 상태는 `.ai-web/`에 남는다. provider, model, browser adapter, deploy adapter는 교체 가능해야 한다.

## 7. 성공 기준

AI Web Director MVP는 다음을 달성해야 한다.

- 아이디어 한 문장에서 필요한 인터뷰 질문을 만든다.
- 답변 기반으로 `.ai-web` 문서를 생성한다.
- 품질 기준을 `quality.yaml`로 수치화한다.
- 스택 프로필을 추천하고 승인 게이트를 만든다.
- 디자인 프롬프트와 후보 평가표를 만든다.
- 선택된 디자인을 `DESIGN.md`로 변환한다.
- Golden Page task packet을 만든다.
- Codex/Claude Code가 흔들리지 않고 구현할 수 있는 작업 단위를 제공한다.
- Codex App/CLI Browser QA checklist를 만든다.
- QA 실패를 fix packet 또는 rollback decision으로 변환한다.



## 8. Capability Matrix

AI Web Director가 말하는 “완성형”은 무제한 완벽이 아니라 **quality-contract-compliant**를 뜻한다. 각 프로젝트는 `quality.yaml`과 Gate 승인 범위 안에서만 완성으로 판정된다.

| 구분 | MVP 지원 | Expansion 전 비지원 / 제한 |
|---|---|---|
| 사이트 유형 | static/content/SEO site, 랜딩, 브랜드 사이트, 간단한 문의 폼 | 복잡한 SaaS billing, multi-tenant admin, 복잡한 migration |
| 데이터 | 단순 form, content collection, 제한적 API | 고위험 개인정보, 복잡한 권한 모델, regulated workflow |
| 디자인 | 후보 생성, 비교, `DESIGN.md` 변환, token/component rule | 이미지를 픽셀 단위로 무비판 복제 |
| 배포 | local-first handoff, Cloudflare Pages/Workers, Kamal 계획 | 자동 production 배포 기본값, credential-gated 작업 |
| 고위험 도메인 | 일반 비즈니스/콘텐츠 | 의료/법률/금융/투자 claim은 별도 legal/content provenance 승인 필요 |

Unsupported 항목이 발견되면 범위를 줄이거나 Expansion backlog로 보낸다.
