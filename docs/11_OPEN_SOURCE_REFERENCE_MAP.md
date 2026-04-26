# 11. 오픈소스 참고 지도

이 문서는 AI Web Director 설계 시 참고할 오픈소스와 차용/회피 기준을 정리한다.

## 1. GitHub Spec Kit

링크: https://github.com/github/spec-kit

가져올 점:

- spec-driven development 철학
- constitution/spec/plan/tasks/implement 흐름
- predictable outcome 중심 사고
- extension/preset 구조
- spec drift, QA, review gate 아이디어

우리식 변환:

```text
constitution -> .ai-web/project.md + AGENTS.md
specify -> product.md/content.md/ia.md
plan -> stack.md/data.md/security.md
tasks -> task packet
implement -> Codex/Claude Code handoff
```

회피할 점:

- 범용 소프트웨어 개발에 너무 맞춘 복잡도
- 웹사이트 디자인/콘텐츠 특화 부족

## 2. bolt.diy

링크: https://github.com/stackblitz-labs/bolt.diy

가져올 점:

- AI web app generation UX
- provider registry
- diff view
- file locking
- snapshot restore
- deploy integration
- integrated terminal/preview

회피할 점:

- 채팅 기반 즉흥 구현으로 흐르는 것
- Director 문서/Gate 없이 코드부터 만드는 것

## 3. Dyad

링크: https://github.com/dyad-sh/dyad

가져올 점:

- local-first
- BYOK
- no lock-in
- desktop app 가능성
- power user용 app builder UX

회피할 점:

- 앱 빌더 자체 UX를 먼저 만드는 것
- Director CLI/상태 시스템보다 GUI를 먼저 키우는 것

## 4. Cofounder

링크: https://github.com/nraiden/cofounder

가져올 점:

- full-stack generative web apps
- backend + DB + stateful app 생성 관점
- AI-guided mockup designer
- modular design system
- DAG/node 기반 생성 pipeline 아이디어

회피할 점:

- early alpha 수준의 불안정성
- token-heavy generation을 MVP 기본값으로 삼는 것

## 5. OpenUI / openv0

링크:

- https://github.com/wandb/openui
- https://github.com/nraiden/openv0

가져올 점:

- UI live render
- HTML -> framework conversion
- multipass generation
- component/library 기반 생성
- validation pass 개념

우리식 변환:

```text
visual candidate
-> DESIGN.md extraction
-> component recipe
-> primitive implementation task
```

회피할 점:

- UI 컴포넌트 생성에만 머무는 것
- 제품/콘텐츠/QA 맥락 없는 visual generation

## 6. E2B Fragments

링크: https://github.com/e2b-dev/fragments

가져올 점:

- sandbox execution
- template registry
- provider registry
- generated code preview isolation

회피할 점:

- 초기부터 cloud sandbox 의존
- 로컬 Codex CLI/App 흐름을 복잡하게 만드는 것

## 7. browser-use / Playwright MCP

링크:

- https://github.com/browser-use/browser-use
- https://github.com/microsoft/playwright-mcp

가져올 점:

- browser automation
- real user flow validation
- screenshot/evidence
- QA automation adapter

우리식 변환:

```text
Computer Use QA -> Codex App/CLI Browser QA Adapter
```

회피할 점:

- QA를 독립 agent 제품으로 만들기
- checklist/result schema 없이 자동화만 붙이기

## 8. OpenHands

링크: https://github.com/OpenHands/OpenHands

가져올 점:

- coding agent architecture
- CLI/GUI/SDK 구분
- local GUI + REST API 가능성

회피할 점:

- 범용 개발 에이전트 복제
- Codex/Claude Code와 중복되는 구현 엔진 만들기

## 9. 최종 포지셔닝

AI Web Director는 다음 조합이다.

```text
Spec Kit의 문서/상태 철학
+ bolt.diy/Dyad의 local AI app builder UX
+ Cofounder의 full-stack/design-system 방향성
+ OpenUI/openv0의 multipass UI generation
+ browser-use/Playwright의 browser QA
+ Codex/Claude Code의 구현 실행력
```

하지만 최종 제품은 이들과 다르다.

```text
기존 오픈소스 = AI가 앱/코드/UI를 생성
AI Web Director = AI가 완성형 웹사이트 제작 프로세스를 지휘
```



## 10. Reference risk table

오픈소스는 직접 의존이 아니라 참고 수준을 명확히 기록한다. 특정 코드를 복사하거나 dependency로 채택하기 전에는 license/security/maintenance 확인이 필요하다.

| Project | Use level | License / terms note | Maintenance | Production risk | Allowed use |
|---|---|---|---|---|---|
| GitHub Spec Kit | workflow philosophy | project license 확인 필요 | active ecosystem | medium | spec-first, drift, QA guard 아이디어 참고 |
| bolt.diy | provider UX ideas | MIT + WebContainer commercial caveat 확인 | active | medium | provider/diff/preview UX 참고, WebContainer 의존 설계는 license 확인 전 금지 |
| Dyad | local-first UX/provider ideas | Apache-2.0 + pro source license split 주의 | active | medium | UX/provider 구조 참고, pro-derived code 금지 |
| Cofounder | pattern only | MIT 확인 필요 | early alpha/no releases risk | high | DAG/mockup 아이디어 참고, dependency 금지 |
| OpenUI | UI generation reference | license 확인 필요 | project status 확인 필요 | medium | component recipe 참고 |
| openv0 | historical only | MIT 확인 필요 | unmaintained risk | high | concept reference only |
| browser-use | browser automation adapter option | MIT / Python runtime 확인 | active | medium | adapter option, hosted cloud 사용 시 terms 확인 |
| Playwright MCP | browser QA adapter option | Microsoft project license 확인 | active | medium | localhost-limited QA adapter |
| OpenHands | coding agent architecture | license 확인 필요 | active | medium | 범용 agent 아키텍처 참고, 중복 구현 금지 |

## 11. Last-verified policy

외부 프로젝트의 구체 기능을 문서나 구현에 복사할 때는 다음을 기록한다.

- source URL
- last_verified date
- copied concept
- not copied / rejected 부분
- license/security note
