# 09. `aiweb` CLI 스펙

## 1. CLI 목표

`aiweb`은 거대한 웹 빌더가 아니라 `.ai-web` 상태와 산출물을 관리하는 얇은 Director CLI다.

역할:

- 초기화
- 상태 확인
- 인터뷰 산출물 생성
- Phase 진행
- 디자인 프롬프트 생성
- task packet 생성
- QA checklist/result 관리
- rollback/snapshot

## 2. MVP 명령

```bash
aiweb init
aiweb init --profile <A|B|C|D>
aiweb status
aiweb interview
aiweb run
aiweb design-prompt [--force]
aiweb ingest-design [--id ID] [--title TITLE] [--source SOURCE] [--notes NOTES] [--selected] [--force]
aiweb next-task [--type TYPE] [--force]
aiweb qa-checklist [--force]
aiweb qa-report [--from PATH] [--status passed|failed|blocked] [--duration-minutes N] [--timed-out] [--force]
aiweb advance
aiweb rollback
aiweb resolve-blocker --reason "..."
aiweb snapshot
```

## 3. 명령 상세

### `aiweb init`

생성:

- `.ai-web/` 구조
- `state.yaml`
- packaged/copied `state.schema.json` reference
- `quality.yaml`
- 기본 markdown stubs
- `.ai-web/design-candidates/` directory
- `.ai-web/qa/final-report.md` stub
- `.ai-web/deploy.md` stub
- `.ai-web/post-launch-backlog.md` stub
- root `AGENTS.md`
- root `DESIGN.md` placeholder

성공 기준:

- `aiweb status`가 현재 Phase와 missing artifacts를 출력한다.

### `aiweb init --profile <A|B|C|D>`

선택 profile의 canonical default를 기준으로 scaffold target을 고정한다.

| Profile | scaffold target |
|---|---|
| A | Rails 8 + PostgreSQL + Hotwire/Turbo + Tailwind + Kamal + Cloudflare DNS/CDN/WAF notes |
| B | Astro + Cloudflare Pages + Tailwind + optional Pages Functions for forms |
| C | Rails 8 main app + PostgreSQL + Hotwire/Turbo + Tailwind + Kamal + Cloudflare DNS/CDN/WAF + optional R2 notes |
| D | Astro + MDX/Content Collections + Cloudflare Pages + Tailwind + sitemap/RSS |

처리:

- `state.yaml`의 `implementation.stack_profile` 설정
- `state.yaml`의 `implementation.scaffold_target` 설정
- `.ai-web/stack.md`에 `canonical default`, `allowed override`, `when to override`, `scaffold target` 기록
- `.ai-web/deploy.md`에 profile별 deploy baseline 기록

### `aiweb status`

출력:

- current phase
- gate status including Gate 1A/1B
- required artifacts status
- design candidate count / selected candidate / provenance status
- deploy/final-report/post-launch status
- current task
- open QA failures, accepted risks, budget status
- next recommended command

### `aiweb interview`

입력:

- 사용자 아이디어
- 기존 답변

출력:

- 다음 질문 또는 문서 초안
- `project.md`, `product.md`, `brand.md`, `content.md` 갱신

MVP에서는 한 번에 전체 질문을 묻기보다, 필요한 질문 목록과 초안 문서를 생성해도 된다.

### `aiweb run`

현재 Phase에서 해야 할 일을 수행하거나 지시한다.

예:

- Phase 0.25 → `quality.yaml` 생성
- Phase 3 → design prompt 생성 필요 알림
- Phase 3.5 → design candidate templates/checklist 생성
- Phase 8 → Golden Page task packet 생성
- Phase 11 → deploy.md/final-report/post-launch-backlog 생성 필요 알림

### `aiweb design-prompt`

입력 문서:

- product.md
- brand.md
- content.md
- ia.md
- design-brief.md

출력:

- GPT Image 2 prompt
- Claude Design prompt
- candidate evaluation rubric
- `.ai-web/design-candidates/candidate-*.md` 작성 지침

### `aiweb ingest-design`

입력:

- `--id ID`로 기존 후보를 업데이트하거나 stable 후보 ID를 지정
- `--title TITLE`
- `--source SOURCE`
- `--notes NOTES`
- `--selected`
- 디자인 후보 설명
- 이미지 분석 결과
- 후보 비교 결과

출력:

- `.ai-web/design-candidates/candidate-*.md`
- `.ai-web/design-candidates/comparison.md`
- `.ai-web/design-candidates/selected.md`
- `state.yaml.design_candidates` 갱신
- Gate 2 draft 갱신

### `aiweb next-task`

현재 Phase에 맞는 task packet을 생성한다.
Phase 6~11에서 실행 가능하며, 수동 복구/정비 상황에서만 `--force`를 사용한다.

예:

- bootstrap task
- design token task
- golden page task
- feature task
- QA fix task
- deploy preparation task

### `aiweb qa-checklist`

현재 task 또는 Phase에 맞는 QA checklist를 생성한다.
Phase 7~11에서 실행 가능하며, 수동 복구/정비 상황에서만 `--force`를 사용한다.

출력:

- `.ai-web/qa/current-checklist.md`

### `aiweb qa-report`

입력:

- browser QA 실행 결과
- screenshot/evidence path

출력:

- `.ai-web/qa/results/*.json`
- 실패 시 fix packet
- Phase 11에서는 `.ai-web/qa/final-report.md`

### `aiweb advance`

공통 검사:

- YAML parse validation
- `state.schema.json` shape validation
- cross-field validation
- required artifacts
- required fields
- gate approval
- QA failures, accepted risks, budget status
- invalidations

Phase-specific 검사:

- Phase 3.5 → 디자인 후보 최소 2개 이상, `design-candidates/comparison.md`, `design-candidates/selected.md`, Gate 2 draft 존재
- Phase 11 → `deploy.md`, `qa/final-report.md`, `post-launch-backlog.md`, Gate 4 approval, rollback 기준 존재

조건 충족 시 다음 Phase로 이동한다.

### `aiweb rollback`

옵션:

```bash
aiweb rollback --to phase-4 --reason "DESIGN.md token mismatch"
aiweb rollback --failure F-IA
```

처리:

- state 갱신
- invalidation 기록
- affected tasks 무효화
- approved artifact hash drift 기록
- snapshot restore 또는 dry-run 결과 기록

### `aiweb resolve-blocker`

옵션:

```bash
aiweb resolve-blocker --reason "recovery evidence recorded"
```

처리:

- rollback으로 설정된 `phase.blocked`를 명시적으로 해제
- 해제 사유를 `decisions[]`에 기록
- 이후 `aiweb advance`가 현재 Phase의 일반 guard를 다시 평가

### `aiweb snapshot`

중요 승인 지점의 `.ai-web` 상태를 저장한다.

## 4. 출력 형식 원칙

모든 명령은 다음을 포함한다.

```text
Current phase
Action taken
Artifacts changed
Blocking issues
Next command
```

## 5. 구현 우선순위

MVP 1:

- init
- init --profile
- status
- advance validation skeleton

MVP 2:

- interview draft generation
- design-prompt
- ingest-design candidate tracking
- next-task
- qa-checklist

MVP 3:

- qa-report
- final-report generation
- rollback
- snapshot

## 6. 비목표

초기 CLI가 직접 모든 코드를 생성하지 않는다. Codex/Claude Code 실행은 task packet과 handoff prompt로 분리한다.



## 7. Global CLI contract

모든 mutation command는 다음 옵션을 지원해야 한다.

```bash
aiweb <cmd> --dry-run
aiweb <cmd> --json
```

공통 규칙:

- repeated command는 입력이 바뀌지 않으면 같은 결과를 낸다.
- state write는 `.ai-web/.lock`으로 동시 실행을 막는다.
- 외부 deploy/provider action은 명시 승인 전 실행하지 않는다.
- blockers는 non-zero exit code를 반환한다.
- `--json` output은 machine-readable status, blockers, next_action, changed_files를 포함한다.

## 8. `init` responsibility closure

- `aiweb init`: `.ai-web` 구조와 stub, root `AGENTS.md`/`DESIGN.md` placeholder 생성.
- `aiweb init --profile <A|B|C|D>`: profile과 scaffold target을 state/stack/deploy 문서에 기록. 실제 app scaffold는 하지 않음.
- 실제 app scaffold: Phase 6 `next-task bootstrap`으로 생성된 task packet을 implementation adapter가 수행.

## 9. Exit code convention

| Code | Meaning |
|---:|---|
| 0 | success/no blockers |
| 1 | validation failed |
| 2 | phase/gate blocked |
| 3 | budget blocked |
| 4 | adapter unavailable |
| 5 | unsafe external action refused |
| 10 | unexpected internal error |
