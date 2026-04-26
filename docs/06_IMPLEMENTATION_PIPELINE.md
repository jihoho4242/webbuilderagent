# 06. 구현 파이프라인

## 1. 핵심 원칙

Codex/Claude Code는 자유롭게 전체 웹사이트를 만들지 않는다. Director가 생성한 task packet 단위로 구현한다.

```text
문서 산출물
-> task packet
-> 구현
-> 로컬 검증
-> Browser QA
-> 결과 기록
-> 다음 task 또는 fix packet
```

## 2. 구현 전 필수 문서

UI 구현 전 필수:

- `.ai-web/product.md`
- `.ai-web/quality.yaml`
- `.ai-web/stack.md`
- `.ai-web/brand.md`
- `.ai-web/content.md`
- `.ai-web/ia.md`
- `.ai-web/DESIGN.md`

backend/data 구현 전 추가 필수:

- `.ai-web/data.md`
- `.ai-web/security.md`

## 3. task packet 형식

모든 task packet은 다음 구조를 따른다.

```md
# Task Packet: <id-title>

## Phase

## Goal

## Inputs

## Context

## Constraints

## Acceptance Criteria

## Verification

## QA Evidence Required

## Rollback
```

## 4. task packet 생성 규칙

좋은 task packet:

- 한 번에 완료 가능한 범위
- 입력 문서가 명확함
- 금지 사항이 명확함
- acceptance criteria가 검증 가능함
- QA evidence 요구가 있음
- 실패 시 rollback 위치가 있음

나쁜 task packet:

- “전체 사이트 완성”
- “예쁘게 만들기”
- “적당히 반응형”
- “필요하면 새 컴포넌트 추가”
- 검증 명령 없음

## 5. 구현 순서

```text
1. Project scaffold
2. Design token implementation
3. UI primitives
4. Golden Page
5. Golden Flow
6. Gate 3 approval
7. Remaining pages
8. Data/API/admin features
9. QA hardening
10. Deploy preparation
```

## 6. Golden Page 원칙

Golden Page는 전체 웹사이트의 기준 페이지다.

조건:

- 가장 중요한 전환 목표를 포함한다.
- 대부분의 디자인 시스템 요소를 포함한다.
- mobile/desktop 모두 검증한다.
- 이후 페이지가 이 기준을 재사용할 수 있어야 한다.

Gate 3 이전에는 전체 페이지를 무리하게 확장하지 않는다.

## 7. 컴포넌트 정책

- Button, Card, Input, Section, Header, Footer는 먼저 primitive로 구현한다.
- 새 variant는 `DESIGN.md`에 추가된 경우만 허용한다.
- 페이지별 ad-hoc style은 QA 실패 사유다.
- design token 없이 색상/간격을 직접 쓰는 것을 금지한다.

## 8. Codex/Claude Code handoff

Handoff prompt는 다음을 포함한다.

```text
현재 task packet을 완료해.
입력 문서를 반드시 읽어.
DESIGN.md와 quality.yaml을 위반하지 마.
완료 후 Verification 명령을 실행하고 결과를 보고해.
QA checklist가 필요한 경우 생성하거나 갱신해.
```

## 9. 완료 기준

task 완료는 다음을 모두 만족해야 한다.

- acceptance criteria 충족
- lint/typecheck/test/build 통과 또는 명시적 not-tested 기록
- browser QA checklist 통과 또는 실패 결과 기록
- 변경된 파일 요약
- 남은 위험 명시

## 10. 구현 중 문서 갱신

구현 중 다음이 발견되면 문서를 갱신한다.

- DESIGN.md에 없는 variant가 실제로 필요함
- content.md의 카피가 레이아웃에 맞지 않음
- IA flow가 모바일에서 부자연스러움
- security.md에 누락된 form/auth 경계가 있음

단, 문서 변경이 Gate에 영향을 주면 해당 Gate로 되돌아간다.



## 11. Task packet lifecycle

Task packet은 frontmatter를 포함한다.

```yaml
id: "task-001"
phase: "phase-8"
type: bootstrap|design-token|golden-page|feature|qa-fix|deploy
status: draft|ready|in_progress|done|failed|invalidated
depends_on: []
allowed_files: []
qa_required: true
rollback_target: "phase-4"
```

전이는 다음만 허용한다.

```text
draft -> ready -> in_progress -> done
                         -> failed
ready/in_progress/done -> invalidated
```

한 task packet은 독립 검증 가능한 하나의 behavior 또는 flow만 다룬다.

## 12. Implementation adapter handoff

Codex/Claude Code handoff는 [`14_ADAPTER_CONTRACTS.md`](./14_ADAPTER_CONTRACTS.md)의 Implementation Agent Adapter 계약을 따른다. 완료 보고에는 changed files, commands run, tests passed, not tested, QA evidence, risks가 있어야 한다.
