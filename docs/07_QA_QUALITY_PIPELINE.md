# 07. QA와 품질 파이프라인

## 1. 핵심 원칙

QA는 마지막에 한 번 하는 작업이 아니다. Phase 7 이후 계속 붙는 상시 검증 레이어다.

```text
Implementation
-> local checks
-> Browser QA
-> evidence capture
-> result json
-> fix packet or advance
```

## 2. 품질 계약

`quality.yaml`은 “완벽한 웹사이트”의 판단 기준이다.

필수 영역:

- responsive
- accessibility
- performance
- SEO
- content clarity
- design consistency
- security baseline
- QA evidence

## 3. Codex Browser QA Adapter

정의:

```text
Codex App/CLI가 .ai-web/qa/current-checklist.md를 기준으로 실제 브라우저를 조작하고, 결과와 evidence를 저장하는 QA 실행 계층.
```

가능한 구현 방식:

- Codex App Computer Use
- Codex CLI browser plugin
- Playwright MCP
- browser-use 계열 adapter
- fallback: Playwright test script

## 4. QA checklist 구조

```md
# QA Checklist: <scope>

## Target

## Preconditions

## Desktop checks

## Mobile checks

## Accessibility checks

## SEO checks

## Performance checks

## Evidence required

## Failure handling
```

## 5. QA result 구조

결과는 JSON으로 저장한다.

```json
{
  "schema_version": 1,
  "task_id": "002-golden-page",
  "status": "failed",
  "started_at": "",
  "finished_at": "",
  "duration_minutes": 0,
  "timed_out": false,
  "environment": {
    "url": "http://localhost:3000",
    "viewport": "375x812",
    "browser": "chromium"
  },
  "checks": [
    {
      "id": "mobile-no-horizontal-scroll",
      "status": "failed",
      "evidence": [".ai-web/qa/screenshots/mobile-overflow.png"],
      "notes": "Hero image causes horizontal scroll at 375px."
    }
  ],
  "recommended_action": "create_fix_packet"
}
```

## 6. 실패 처리

QA 실패는 다음 중 하나로 처리한다.

| 실패 유형 | 처리 |
|---|---|
| 단순 구현 버그 | fix packet 생성 |
| 디자인 규칙 모호 | Phase 4 `DESIGN.md` 갱신 |
| 콘텐츠 길이 문제 | Phase 1.5 `content.md` 갱신 |
| UX flow 문제 | Phase 2 `ia.md` 갱신 |
| 품질 기준 과도/부족 | Phase 0.25 `quality.yaml` 갱신 |
| 스택 한계 | Phase 0.5 rollback |

## 7. QA evidence

필수 evidence:

- desktop screenshot
- mobile screenshot
- primary flow screenshot 또는 step log
- form validation evidence
- 실패 screenshot
- build/test logs

## 8. Release QA

배포 전 Gate 4에서 확인할 것:

- 모든 critical QA 통과
- open failures 없음 또는 accepted risk 기록
- SEO 필수 메타 존재
- accessibility minimum 통과
- performance target 충족 또는 예외 승인
- environment variables 준비
- rollback 기준 존재

## 9. 자동화 우선순위

MVP:

- checklist 생성
- 수동/Computer Use 기반 실행
- result json 기록
- fix packet 생성

다음 단계:

- Playwright MCP adapter
- screenshot diff
- Lighthouse 자동 실행
- accessibility 자동 검사
- CI gate



## 10. Schema and blocker rules

QA result는 `docs/templates/qa-result.schema.json`을 통과해야 한다. `quality.yaml`은 `docs/templates/quality.schema.json`으로 검증한다.

기본 severity 규칙:

| Severity | Release effect |
|---|---|
| critical | Gate 4 block, accepted risk 불가 for public release |
| high | Gate 4 block unless accepted risk has owner/mitigation/expiry |
| medium | accepted risk 또는 fix packet 필요 |
| low | backlog 가능 |
| info | 기록만 |

기본 측정 기준은 [`15_ACCEPTANCE_QA_SCHEMAS.md`](./15_ACCEPTANCE_QA_SCHEMAS.md)를 따른다.

## 11. Reproducibility requirements

QA checklist/result는 다음을 기록한다.

- local server command
- tested commit SHA 또는 snapshot id
- browser/version
- viewport matrix
- test data/fixtures
- exact step log
- expected result per step
- screenshot naming convention
- console/network error summary
