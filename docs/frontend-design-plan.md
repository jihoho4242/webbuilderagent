# Frontend Design Plan — Conversational Agent Web Workspace

- Project: `webbuilderagent`
- Last updated: 2026-05-05
- Authoring role: Senior Frontend Architect / UI·UX Product Designer
- Primary goal: expose every existing backend engine capability through a minimal-page, conversational agent-centered web app.
- Final review status: **Complete for the current backend surface**. Verified against CLI command inventory, daemon routes, core project modules, schemas, safety gates, UI mapping, state/API design, roadmap, and tests on 2026-05-05.

## 최종 검토 체크리스트

| 검토 항목 | 결과 | 근거 |
|---|---|---|
| 백엔드 daemon API 전체 반영 | Pass | `/health`, `/api/engine`, `/api/project/status`, `/api/project/workbench`, `/api/project/runs`, `/api/project/command`, `/api/codex/agent-run` 포함 |
| CLI/엔진 command 전체 반영 | Pass | `help/version/status/intent` 및 mutation/runtime/registry command 전체 문서 내 존재 확인 |
| 기능별 입력/출력/성공/실패/프론트 노출 방식 | Pass | 1.2 전체 백엔드 기능 인벤토리 F01~F49 |
| 프론트에서 숨겨야 할 내부/위험 기능 구분 | Pass | raw shell, backend-controlled flags, `.env`, secret, non-dry-run deploy, approval-required 실행 분리 |
| 최소 페이지 구조 | Pass | `/`, `/workspace`, `/settings` 3-route 구조 |
| 대화형 에이전트 중심 UX | Pass | Chat → ActionCard → DynamicForm → Confirmation → Result/Evidence → Follow-up 흐름 |
| 디자인 엔진 기능 사용성 | Pass | brief/research/system/prompt/candidate/select/ingest/visual/component-map/edit 전체 UI 매핑 |
| 구현 가능성 | Pass | API client, state domains, component props, phase roadmap, test plan 포함 |
| 남은 한계 명시 | Pass | chat planner endpoint, streaming/job status, safe artifact read 등 백엔드 추가 필요 항목 분리 |

---

## 분석 기준과 현재 백엔드 형태

이 계획은 현재 저장소에 실제 존재하는 백엔드 표면만 기준으로 한다.

### 확인한 백엔드 소스

| 영역 | 파일/모듈 | 의미 |
|---|---|---|
| CLI 컨트롤러 | `lib/aiweb/cli.rb` | 모든 사용자 명령의 진입점. 옵션 파싱, dry-run, 승인, phase guard, adapter unavailable 처리. |
| 로컬 웹 백엔드 | `lib/aiweb/daemon.rb` | 프론트엔드가 붙을 수 있는 localhost JSON API daemon. `CodexCliBridge`, `LocalBackendApp`, `LocalBackendDaemon` 포함. |
| 핵심 프로젝트 엔진 | `lib/aiweb/project.rb` | 상태, 디자인 엔진, scaffold, setup, build, preview, QA, repair, deploy plan, agent-run 등 핵심 실행 로직. |
| Intent/Registry | `lib/aiweb/intent_router.rb`, `lib/aiweb/registry.rb` | 자연어 의도 라우팅, 디자인 시스템/스킬/craft registry 조회. |
| 디자인 엔진 | `lib/aiweb/design_brief.rb`, `lib/aiweb/design_research.rb`, `lib/aiweb/design_system_resolver.rb`, `lib/aiweb/design_candidate_generator.rb`, `lib/aiweb/lazyweb_client.rb` | 디자인 brief/research/system/candidate/prompt 생성과 외부 Lazyweb 연동 어댑터. |
| 템플릿/스키마 | `docs/templates/*`, `docs/templates/*.schema.json` | `.ai-web` 산출물 템플릿, 상태/품질/intent/QA schema. |
| 현재 프론트 상태 | repo root | 별도 프론트 앱은 아직 없음. 현재 계획상 신규 앱은 `apps/workbench/` 권장. |

### 현재 백엔드 아키텍처 요약

- 전통적인 REST CRUD 서버/DB 모델이 아니라 **로컬-first CLI engine + daemon bridge + 파일 아티팩트 저장소** 구조다.
- 영속 데이터는 DB가 아니라 프로젝트 내부 `.ai-web/` 아래 YAML/Markdown/JSON 파일로 관리된다.
- 현재 공개 API는 daemon의 7개 route이며, 대부분은 내부적으로 `bin/aiweb --path <project> <command> --json`을 실행한다.
- daemon은 shell string을 받지 않고 structured JSON만 받는다.
- 모든 `/api/*` 호출은 `X-Aiweb-Token`이 필요하다.
- 승인 실행(`agent-run`, `setup --install` 등)은 `X-Aiweb-Approval-Token` 또는 동일 API token fallback이 필요하다.
- `.env`/secret/token/path는 daemon과 CLI 양쪽에서 차단 또는 redaction된다.
- `deploy`는 daemon bridge에서는 dry-run planning only로 노출된다.

### DB 모델/권한 구조

| 항목 | 현재 구현 |
|---|---|
| DB 모델 | 없음. `.ai-web/state.yaml`, `.ai-web/runs/**/*.json`, `.ai-web/tasks/*.md`, `.ai-web/visual/*.json`, `.ai-web/workbench/*.json/html` 등 파일 기반. |
| 사용자 계정 | 없음. 로컬 daemon token 기반 단일 사용자/로컬 프로젝트 전제. |
| 권한 | daemon API token, approval token, local origin check, allowed command list, backend-controlled flags 차단. |
| 컨트롤러 | `Aiweb::CLI`, `Aiweb::LocalBackendApp`가 컨트롤러 역할. |
| 서비스 | `Aiweb::Project` 및 design/research/registry/intent modules가 service/domain 역할. |
| 스키마 | `state.schema.json`, `quality.schema.json`, `intent.schema.json`, `qa-result.schema.json`. |

---

# 1. 백엔드 기능 요약

## 1.1 daemon API 인벤토리

| API | 목적 | 입력값 | 출력값 | 성공 케이스 | 실패 케이스 | 프론트 노출 |
|---|---|---|---|---|---|---|
| `GET /health` | daemon 생존/엔진 메타 확인 | 없음 | service status, engine metadata | `status: ok` | daemon 미기동, network 오류 | 연결 상태 배지/설정 진단에 노출 |
| `GET /api/engine` | 사용 가능한 명령/guardrail/route 확인 | `X-Aiweb-Token` | engine metadata, routes, allowed commands | `status: ready` | token 없음/오류, origin 차단 | 설정/개발자 패널에 노출 |
| `GET /api/project/status?path=` | 현재 프로젝트 상태 조회 | project path, token | `aiweb status --json` envelope | phase/gate/blocker/next_action 표시 | path 없음, 초기화 안 됨, schema 오류 | 홈/워크스페이스 기본 데이터 |
| `GET /api/project/workbench?path=` | workbench snapshot 조회 | project path, token | `aiweb workbench --dry-run --json` envelope | artifacts/panels/controls 요약 | workbench adapter unavailable, path 오류 | 워크스페이스 패널 데이터 |
| `GET /api/project/runs?path=` | 최근 실행 기록 조회 | project path, token | 최근 `.ai-web/runs/*/*.json` safe summary 최대 30개 | run timeline 표시 | unreadable JSON, path 오류 | 히스토리/로그 패널 |
| `POST /api/project/command` | 허용된 aiweb command 실행 | `{path, command, args, dry_run, approved}` + token/approval token | bridge envelope + stdout_json/stderr | 명령 완료, dry-run 계획, changed_files 반환 | 명령 미허용, timeout, `.env` path, approval 누락 | 모든 action card의 실행 API |
| `POST /api/codex/agent-run` | Codex CLI bridge 실행 | `{path, task, dry_run, approved}` + token/approval token | serialized `agent-run` result | task packet 기반 agent-run 실행/계획 | approval 누락, forbidden source path, timeout | 구현 실행 drawer에서 제한 노출 |

## 1.2 전체 백엔드 기능 인벤토리

> 표의 “노출”은 프론트에서 사용자가 접근해야 하는 방식이다. 내부 helper/private method는 별도 1.3에서 제외 이유를 명시한다.

| ID | 기능명/명령 | 사용자 목적 | 관련 API/백엔드 모듈 | 입력값 | 출력값/아티팩트 | 성공/실패 케이스 | 프론트 노출 필요 여부/방식 |
|---|---|---|---|---|---|---|---|
| F01 | `health` | daemon 연결 확인 | `LocalBackendApp#health_payload` | 없음 | service/engine status | 성공: ok. 실패: daemon 미기동/네트워크 | 필요. 설정/상단 연결 배지 |
| F02 | `engine` | 사용 가능한 엔진/guardrail 확인 | `LocalBackendApp#engine_payload`, `CodexCliBridge#metadata` | API token | routes, allowed commands, guardrails | 성공: ready. 실패: token/origin | 필요. 설정/개발자 정보 |
| F03 | `project status` / CLI `status` | 프로젝트 phase, gate, blocker, next action 확인 | `/api/project/status`, `Project#status` | project path | state summary, blockers, next_action | 성공: 상태 표시. 실패: init 필요/schema 오류 | 핵심. 홈/워크스페이스 자동 로드 |
| F04 | `workbench` read/export | artifact/panel/control snapshot 생성/조회 | `/api/project/workbench`, `Project#workbench` | project path, `--export`, force/dry-run | `.ai-web/workbench/index.html`, `workbench.json`, panel data | 성공: workbench snapshot. 실패: adapter unavailable/phase blocker | 핵심. 워크스페이스 데이터 소스 + export action |
| F05 | `runs` | 최근 실행 히스토리 확인 | `/api/project/runs`, `.ai-web/runs` scan | project path | safe run summaries | 성공: 최근 30개. 실패: unreadable JSON | 핵심. HistoryPanel |
| F06 | `help`, `version` | 명령 설명/엔진 버전 확인 | `CLI#help_payload`, `Aiweb::VERSION` | 없음 | command help/version | 성공: 설명 표시. 실패 거의 없음 | 보조. 도움말/About drawer |
| F07 | `daemon`, `backend` | 로컬 backend 기동 계획/실행 | `LocalBackendDaemon`, `LocalBackendApp.plan` | host, port, dry-run | daemon plan or long-running server | 성공: local server. 실패: non-local host/port invalid | 브라우저 내부에서는 실제 start 비노출. CLI launcher 안내/상태만 노출 |
| F08 | `start` | 아이디어로 프로젝트 초기화+초기 단계 진행 | `CLI#dispatch start`, `Project#start` | idea, profile, no-advance, dry-run | `.ai-web` core docs, state, next_action | 성공: 초기 artifacts. 실패: idea empty, unsafe path | 필요. 홈 첫 진입 onboarding action |
| F09 | `init` | 빈 프로젝트를 aiweb 구조로 초기화 | `Project#init`, templates | profile, dry-run | `.ai-web/state.yaml`, templates | 성공: 초기 파일. 실패: 기존 충돌/권한 | 필요. 프로젝트 연결 후 기본 action |
| F10 | `intent route` | 자연어 아이디어를 추천 skill/design system으로 라우팅 | `IntentRouter.route` | idea | intent object, recommended skill/system | 성공: route 반환. 실패: idea empty | 핵심. Chat intent 이해 보조 |
| F11 | `interview` | 제품 요구사항/초기 질문지 생성 | `Project#interview` | idea | interview artifacts/next questions | 성공: 질문/요구 정리. 실패: idea empty/init 필요 | 필요. 채팅 기반 온보딩 |
| F12 | `runtime-plan`, `scaffold-status` | 현재 구현 준비도/누락 파일/phase blocker 확인 | `Project#runtime_plan` | project path | readiness, blockers, expected files | 성공: ready/blocked. 실패: state 오류 | 핵심. StatusPanel/Action gating |
| F13 | `run` | 현재 phase의 다음 자동 단계 실행 | `Project#run` | dry-run | phase-based next action execution | 성공: 다음 action. 실패: blocker/gate | 필요. “다음 단계 실행” 추천 action |
| F14 | `advance` | phase 전진 | `Project#advance` | dry-run | updated state/current_phase | 성공: 다음 phase. 실패: gate/blocker | 필요하나 위험. 확인 모달 + gate evidence |
| F15 | `rollback` | phase/실패 원인 기준으로 되돌림 | `Project#rollback` | to phase 또는 failure, reason | rollback note/state | 성공: state rollback. 실패: 필수값 없음 | 고급/복구 drawer. 강한 확인 필요 |
| F16 | `resolve-blocker` | blocker 수동 해소 기록 | `Project#resolve_blocker` | reason | state decision/blocker update | 성공: blocker resolved note. 실패: reason 부재 가능 | 고급. blocker card에서 확인 후 노출 |
| F17 | `snapshot` | 현재 상태 스냅샷 기록 | `Project#snapshot` | reason | snapshot manifest | 성공: snapshot created. 실패: path/write | 필요. 실행 전/복구 전 추천 action |
| F18 | `design-brief` | 제품/브랜드/콘텐츠 기반 디자인 요구 brief 생성 | `Project#design_brief`, `DesignBrief` | force, dry-run | `.ai-web/design-brief.md` | 성공: brief 생성. 실패: 선행 artifact 부족/phase block | 핵심. DesignEngine tab |
| F19 | `design-research` | 디자인 레퍼런스/패턴 리서치 수집 또는 skip 기록 | `Project#design_research`, `DesignResearch`, `LazywebClient` | provider, policy, limit, force, dry-run | `.ai-web/design-research*` state/artifacts | 성공: research rows. 실패: token 없음/adapter unavailable/policy block | 핵심. 단, 외부 토큰 요청은 설정에서만 |
| F20 | `design-system resolve` | Open design/design system 방향을 `.ai-web/DESIGN.md`로 결정 | `DesignSystemResolver` | force, dry-run | `.ai-web/DESIGN.md` | 성공: design tokens/principles. 실패: 선행 brief 부족 | 핵심. Design System panel |
| F21 | `design-prompt` | 후보 생성용 프롬프트/제약 작성 | `Project#design_prompt` | force, dry-run | `.ai-web/design-prompt.md` | 성공: prompt 생성. 실패: design system/brief 누락 | 핵심. Prompt preview |
| F22 | `design` | 복수 디자인 후보 생성 | `DesignCandidateGenerator` | candidates N, force, dry-run | `.ai-web/design-candidates/*`, comparison | 성공: 후보 생성. 실패: N invalid/선행 누락 | 핵심. CandidateGallery |
| F23 | `select-design` | 특정 후보를 선택하고 Gate 2 디자인 승인 artifact 생성 | `Project#select_design` | candidate id | `selected.md`, `gate-2-design.md`, state | 성공: selected. 실패: id 없음/없는 후보 | 핵심. 후보 card의 “선택” 확인 모달 |
| F24 | `ingest-design` | 외부/수동 디자인 후보를 등록, optional selected | `Project#ingest_design` | id,title,source,notes,selected,force | candidate md/comparison/selected/gate | 성공: 후보 등록. 실패: 필드/충돌 | 핵심. “레퍼런스/수동 후보 추가” form |
| F25 | `design-systems list` | 사용 가능한 디자인 시스템 registry 조회 | `Registry#list` | 없음 | registry items | 성공: list. 실패: registry 오류 | 필요. 디자인 설정 picker |
| F26 | `skills list` | 구현/작업 skill registry 조회 | `Registry#list` | 없음 | skill list | 성공: list. 실패: registry 오류 | 보조. Agent capability drawer |
| F27 | `craft list` | craft/pattern registry 조회 | `Registry#list` | 없음 | craft items | 성공: list. 실패: registry 오류 | 보조. 디자인/구현 레퍼런스 drawer |
| F28 | `scaffold` profile D | 기본 Astro/Tailwind 등 정적 프론트 scaffold 생성 | `Project#scaffold`, profile D file generators | profile D, force, dry-run | `package.json`, `src/*`, configs, metadata | 성공: scaffold 생성. 실패: Gate2 미승인/파일 충돌 | 핵심. 구현 준비 action, dry-run 먼저 |
| F29 | `scaffold` profile S | Supabase/Next.js 성격 scaffold 생성 | `Project#scaffold_profile_s` | profile S data, force, dry-run | Supabase client/server/schema/RLS/storage/env template | 성공: scaffold 생성. 실패: secret/RLS/profile 문제 | 고급. profile 선택 시 노출 |
| F30 | `setup --install` | 패키지 설치 | `Project#setup` | install=true, approved, dry-run | run metadata, stdout/stderr logs | 성공: deps installed. 실패: approval 필요/lifecycle warning | 위험. 승인 토큰 + 확인 UI 필요 |
| F31 | `build` | 앱 빌드 검증 | `Project#build` | dry-run | run metadata, logs, exit_code | 성공: build passed. 실패: package/scaffold 누락/build error | 핵심. QA dashboard action |
| F32 | `preview` / `preview --stop` | local preview server start/stop | `Project#preview` | stop, dry-run | pid, port, url, logs | 성공: preview running/stopped. 실패: port/process/package | 핵심. PreviewFrame + stop button |
| F33 | `qa-playwright`, `browser-qa` | 브라우저 E2E/기능 QA | `Project#qa_playwright` | url, task_id, force, dry-run | QA result JSON, logs, evidence | 성공: checks passed. 실패: preview 없음/tool 없음/test fail | 핵심. QADashboard |
| F34 | `qa-screenshot`, `screenshot-qa` | viewport screenshot evidence 생성 | `Project#qa_screenshot` | url, task_id, force, dry-run | screenshots, metadata, QA result | 성공: screenshots captured. 실패: browser/tool/url | 핵심. VisualEvidence gallery |
| F35 | `qa-a11y`, `a11y-qa` | 접근성 검사 | `Project#qa_a11y` | url, task_id, force, dry-run | accessibility report/result | 성공: no critical issues. 실패: axe/tool/report fail | 핵심. Accessibility panel |
| F36 | `qa-lighthouse`, `lighthouse-qa` | Lighthouse 성능/품질 검사 | `Project#qa_lighthouse` | url, task_id, force, dry-run | Lighthouse report/result | 성공: score/pass. 실패: tool/url/report fail | 핵심. Performance panel |
| F37 | `qa-checklist` | 의미/수동 QA 체크리스트 생성 | `Project#qa_checklist` | force, dry-run | `.ai-web/qa-checklist.md` | 성공: checklist. 실패: state/artifact issue | 핵심. QA tab |
| F38 | `qa-report` | QA 결과 수동/파일 기반 기록 | `Project#qa_report` | status, task_id, duration, timed_out, from, force | `qa-result.json`, final report | 성공: QA status recorded. 실패: schema invalid/from path unsafe | 핵심. QA report form |
| F39 | `repair` | QA 실패 기반 bounded repair task 생성/스냅샷 | `Project#repair` | from_qa, max_cycles, force, dry-run | repair record, snapshot, fix task | 성공: fix task generated. 실패: no QA, max cycles, `.env` path | 핵심. 실패 card의 “수정 작업 생성” |
| F40 | `visual-critique` | screenshot/evidence 기반 시각 품질 점수/이슈/패치계획 생성 | `Project#visual_critique` | screenshot, metadata, from_screenshots, task_id, force | `.ai-web/visual/visual-critique-*.json` | 성공: score/issues. 실패: invalid evidence path | 핵심. Visual Review panel |
| F41 | `visual-polish --repair` | visual critique 기반 bounded polish task 생성 | `Project#visual_polish` | repair flag, from_critique, max_cycles, force | polish record, snapshot, task packet | 성공: polish task. 실패: no critique/pass/max cycles | 핵심. Visual polish action |
| F42 | `component-map` | 구현된 컴포넌트와 `data-aiweb-id` 매핑 | `Project#component_map` | force, dry-run | `.ai-web/component-map.json` | 성공: component list. 실패: no components/force needed | 핵심. Visual edit target picker |
| F43 | `visual-edit` | 특정 컴포넌트에 자연어 수정 요청으로 task 생성 | `Project#visual_edit` | target, prompt, from_map, force | visual edit record, task md | 성공: task packet. 실패: target/prompt missing, map missing | 핵심. Component edit drawer |
| F44 | `agent-run` | task packet을 Codex CLI bridge로 실행 | `/api/codex/agent-run`, `Project#agent_run` | task, agent=codex, approved, dry-run | context manifest, diff, metadata, changed files | 성공: implementation run. 실패: approval/forbidden path/env guard | 핵심이나 위험. 실행 전 diff/승인 UI |
| F45 | `next-task` | 현재 상태 기반 다음 작업 packet 생성 | `Project#next_task` | type, force, dry-run | `.ai-web/tasks/*.md` | 성공: task created. 실패: blocker/force | 핵심. 추천 action |
| F46 | `supabase-secret-qa` | Supabase scaffold의 secret/env 노출 검사 | `Project#supabase_secret_qa` | force, dry-run | QA result/blockers | 성공: no leaked secrets. 실패: `.env`/secret pattern | profile S 사용 시 필수. Security panel |
| F47 | `github-sync` | Git remote/branch 동기화 계획 | `Project#github_sync` | remote, branch, dry-run | plan payload | 성공: plan. 실패: git/adapter 문제 | 보조. Release drawer에서 dry-run 중심 |
| F48 | `deploy-plan` | 배포 대상별 계획 수립 | `Project#deploy_plan` | target, dry-run | deploy plan payload | 성공: plan. 실패: target invalid | 보조. Deploy readiness panel |
| F49 | `deploy` | 로컬/배포 실행 어댑터 | `Project#deploy` | target, dry-run, force | local deploy payload / blocked | 성공: dry-run plan. 실패: bridge에서 non-dry-run 차단 | 프론트에서는 dry-run only. 실제 배포 버튼 비노출 또는 disabled |

## 1.3 프론트에서 직접 노출하지 말아야 할 내부 기능

| 내부 기능/범위 | 이유 | 대체 UX |
|---|---|---|
| raw shell command 입력 | daemon guardrail상 구조화 JSON만 허용. shell injection 방지. | ActionCard + DynamicForm이 `command/args/dry_run/approved`로만 호출. |
| `--path`, `--json`, `--dry-run`, `--approved`를 args에 직접 넣는 기능 | bridge가 backend-controlled flags로 차단. | UI state에서 path/dryRun/approved를 별도 필드로 관리. |
| `.env`, `.env.*`, secret/token/password/api key raw preview | daemon/Project에서 unsafe path/redaction 처리. | Settings에서 존재 여부/필요 여부만 표시, 값은 마스킹/미표시. |
| private helper methods in `Project` | schema validation, file writing, redaction, task path safety 등 내부 불변식. | 결과 상태/오류 메시지/guardrail 설명으로만 노출. |
| daemon 실제 start/stop을 브라우저 버튼으로 수행 | 브라우저가 daemon 미기동 상태에서는 API 호출 불가. 로컬 CLI process lifetime 문제. | Home에서 “터미널 실행 명령” 안내와 연결 테스트 제공. |
| non-dry-run `deploy` | `CodexCliBridge`가 dry-run only로 제한. 외부 production side effect 위험. | `deploy-plan`, `deploy --dry-run` 결과만 표시. 실제 배포는 “CLI에서 명시 승인 필요”로 분리. |
| `setup --install`/`agent-run` 무승인 실행 | 파일 변경/패키지 설치/코드 수정 가능. | 승인 토큰 + ConfirmationModal + dry-run preview 후 실행. |
| Lazyweb token 직접 요구 | 프로젝트 AGENTS가 implementation에서 외부 토큰/network 요구를 금지. | Settings에서 “선택 연동 상태”만 표시하고, 없으면 research skipped 상태를 설명. |

---

# 2. 추천 프론트엔드 제품 컨셉

## 2.1 제품 이름/컨셉

**AI Web Director Workbench**

사용자가 기능명을 외우지 않아도, “내 앱 만들고 싶어”, “디자인 후보 보여줘”, “빌드 오류 고쳐줘”, “이 버튼을 더 크게 바꿔줘”처럼 자연어로 말하면 에이전트가 현재 `.ai-web` 상태를 읽고 가능한 작업을 제안하고, 필요한 입력만 카드/폼으로 받은 뒤 backend command를 실행하는 로컬-first 웹앱이다.

## 2.2 핵심 사용자 경험

1. 사용자가 프로젝트 경로와 daemon token을 연결한다.
2. 앱이 `/health`, `/api/engine`, `/api/project/status`, `/api/project/workbench`, `/api/project/runs`를 읽는다.
3. 에이전트가 현재 phase/blocker/next_action을 요약한다.
4. 사용자가 자연어로 요청한다.
5. 프론트의 action planner가 백엔드 명령 후보를 생성한다. 필요하면 `intent route`를 호출해 보조한다.
6. 에이전트가 “실행 가능한 카드”를 제안한다.
7. 위험한 작업은 dry-run → 변경 요약 → 승인 순서로 진행한다.
8. 결과는 텍스트가 아니라 상태 카드, 로그, diff, 후보 gallery, QA report, screenshot, component map 등으로 표시한다.
9. 결과에 따라 다음 액션을 추천한다.

## 2.3 에이전트의 역할

| 역할 | 설명 | backend 근거 |
|---|---|---|
| 상태 해석자 | phase, gate, blockers, next_action을 사람이 이해할 말로 변환 | `status`, `runtime-plan`, `workbench` |
| 작업 제안자 | 현재 가능한 command를 ActionCard로 제안 | `engine.allowed_commands`, `workbench.controls`, `next_action` |
| 입력 수집자 | command별 필수 option을 대화/폼으로 받음 | `CLI#dispatch` option contract |
| 안전 관리자 | dry-run, approval token, `.env` 차단, deploy dry-run only를 설명 | `daemon.rb` guardrails |
| 실행 오케스트레이터 | `/api/project/command` 또는 `/api/codex/agent-run` 호출 | daemon API |
| 결과 해설자 | stdout_json/changed_files/blocking_issues를 card/table로 해석 | bridge envelope + Project payload |
| 후속 조치 추천자 | 성공/실패에 따라 다음 action 제안 | `next_action`, blockers, run status |

## 2.4 일반 UI와 대화형 UI의 역할 분담

| 대화형 UI | 일반 UI |
|---|---|
| “무엇을 하고 싶은지” 자연어 입력 | 현재 상태, 실행 결과, 로그, 파일 preview를 구조화 표시 |
| 필요한 값 질문 | DynamicForm으로 정확한 옵션 입력 |
| 다음 액션 추천 | ActionCard/Toolbar로 빠른 실행 |
| 실패 원인 설명 | ErrorPanel, BlockingIssueList, RunTimeline |
| 복잡한 흐름을 단계별 안내 | Design/QA/Settings tab으로 고급 설정 |

---

# 3. 최소 페이지 구조

## 3.1 추천 route는 3개

| Route | 페이지 | 목적 | 포함 기능 |
|---|---|---|---|
| `/` | Home / Connect | daemon 연결, 프로젝트 경로 선택, 첫 시작 | health, engine, project status, start/init/interview shortcut |
| `/workspace` | Main Agent Workspace | 대부분의 작업 수행 | chat, actions, design engine, scaffold/build/preview, QA, visual edit, agent-run, history |
| `/settings` | Settings / Safety | token, daemon, approval, registry, 고급 안전 설정 | engine metadata, auth, design-systems/skills/craft list, preferences |

추가 페이지는 만들지 않는다. 관리자/로그/데이터/템플릿/워크플로우 관리는 `/workspace` 안의 tab, drawer, modal로 흡수한다.

## 3.2 전체 IA

```text
AppShell
├─ TopBar
│  ├─ Project selector/path chip
│  ├─ Daemon status
│  ├─ Current phase/gate
│  ├─ Dry-run default toggle
│  └─ Settings/About
├─ SideRail
│  ├─ Agent
│  ├─ Design
│  ├─ Build/Preview
│  ├─ QA/Repair
│  ├─ Visual Edit
│  ├─ Release
│  └─ History
└─ Workspace
   ├─ Left: Chat/Task composer
   ├─ Center: Action cards + dynamic forms
   └─ Right: Result/Preview/Logs/Artifacts panel
```

## 3.3 페이지 간 이동 흐름

1. `/`에서 daemon/project 연결.
2. 연결 성공 시 `/workspace`로 이동.
3. `/workspace`에서 모든 command 실행.
4. token/approval/registry 설정이 필요하면 drawer 또는 `/settings`로 이동.
5. 설정 후 원래 workspace context로 복귀.

---

# 4. 메인 워크스페이스 UX

## 4.1 화면 레이아웃

데스크톱 기준 3-pane 구조를 권장한다.

| 영역 | 너비 | 역할 |
|---|---:|---|
| Left Chat Pane | 32% | 자연어 요청, agent messages, 질문/답변 |
| Center Action Pane | 36% | 추천 action cards, dynamic forms, confirmation summary |
| Right Evidence Pane | 32% | result preview, logs, QA evidence, screenshots, component map, files |

태블릿은 2-pane + bottom drawer, 모바일은 single column + bottom sheet로 전환한다.

## 4.2 채팅 입력 영역

- placeholder 예시: “무엇을 만들거나 확인할까요? 예: 디자인 후보 3개 만들어줘, 빌드 돌려줘, QA 실패 고쳐줘”
- slash shortcuts:
  - `/start`, `/design`, `/qa`, `/visual`, `/build`, `/repair`, `/agent-run`, `/deploy-plan`
- 입력 보조 chips:
  - “현재 blocker 해결”
  - “다음 단계 실행”
  - “디자인 후보 보기”
  - “빌드/QA 실행”

## 4.3 메시지 타입

| 타입 | 설명 | UI |
|---|---|---|
| `user_text` | 사용자 자연어 요청 | UserMessage bubble |
| `agent_summary` | 현재 상태/결과 요약 | AgentMessage + status chips |
| `agent_question` | 누락 입력 질문 | Inline field 또는 quick reply |
| `action_proposal` | 실행 가능한 명령 후보 | ActionCard stack |
| `tool_call_preview` | 실제 API 호출 전 요약 | ToolCallPreview + dry-run badge |
| `confirmation_required` | 위험 작업 확인 | ConfirmationModal |
| `tool_result` | 명령 결과 | ResultCard, DataTable, ArtifactList |
| `error` | 실패/차단 | ErrorPanel + suggested fixes |
| `followup` | 다음 추천 액션 | FollowUpAction chips |

## 4.4 에이전트 응답 카드

ActionCard는 사용자가 command 이름을 몰라도 이해 가능한 말로 보여준다.

예시:

```text
현재 Gate 2 디자인 선택이 필요합니다.
추천 작업:
1. 디자인 brief 만들기
2. 디자인 시스템 확정하기
3. 후보 3개 생성하기
4. 후보 선택하기
```

각 카드에는 다음을 표시한다.

- 사용자 목적
- 실제 backend command
- 필요한 입력
- 예상 변경 파일
- 위험도: safe / writes files / installs deps / code changes / external plan
- 권장 실행 방식: dry-run first / approval required
- 실행 버튼, dry-run 버튼, 자세히 보기

## 4.5 동적 폼

명령별 옵션을 form schema로 매핑한다.

| command | 필드 |
|---|---|
| `start` | idea textarea, profile select, advance toggle |
| `design` | candidates number, force toggle |
| `select-design` | candidate id picker |
| `ingest-design` | id, title, source, notes, selected toggle |
| `scaffold` | profile D/S, force toggle |
| `setup` | install fixed, approved confirmation |
| `preview` | stop toggle |
| `qa-*` | url, task_id, force |
| `qa-report` | status, task_id, duration, timed_out, from file |
| `repair` | from_qa latest/path, max_cycles |
| `visual-critique` | from screenshots/latest or screenshot path, task_id |
| `visual-polish` | repair fixed true, from_critique, max_cycles |
| `component-map` | force |
| `visual-edit` | target picker, prompt, from_map |
| `agent-run` | task latest/path, approved |
| `rollback` | to phase or failure, reason |
| `deploy-plan` | target |

## 4.6 실행 확인 UI

위험도별 확인 정책:

| 위험도 | 예 | UI 정책 |
|---|---|---|
| Read-only | health, engine, status, runtime-plan, registry list, runs | 즉시 실행 |
| Safe write | design-brief, design-prompt, qa-checklist, snapshot | dry-run 기본 + 변경 파일 표시 |
| Project mutation | scaffold, select-design, repair, visual-edit, rollback, advance | dry-run → diff/changed_files → 확인 |
| External/install/code execution | setup install, agent-run | approval token 필요 + explicit checkbox |
| Deployment | deploy | 프론트에서는 dry-run only. 실제 배포 disabled |

## 4.7 결과 표시 UI

| 결과 유형 | UI |
|---|---|
| state/phase | PhaseStepper, GateCard, BlockerList |
| changed_files | FileChangeList, ArtifactPreview |
| design candidates | CandidateGallery, CompareTable, Select button |
| design system | TokenPanel, DesignPrincipleCards |
| QA result | QADashboard, severity badges, evidence links |
| screenshot | ResponsiveScreenshotGrid |
| visual critique | ScoreRadar/ScoreCards, IssueList, PatchPlan |
| component map | ComponentTree, target picker |
| run metadata/logs | RunTimeline, stdout/stderr tabs |
| deploy plan | ReleaseReadinessChecklist |

## 4.8 오류 표시 UI

ErrorPanel은 항상 다음 정보를 포함한다.

- 사람이 읽는 요약
- backend `exit_code`
- `blocking_issues`
- 실패 command/args/dry_run/approved
- 가능한 해결책
- “dry-run으로 다시 보기”, “관련 설정 열기”, “repair task 생성” 등 후속 action

## 4.9 작업 진행 상태

현재 daemon command는 streaming/job endpoint가 없고 동기 timeout 180초다. 프론트는 다음처럼 처리한다.

- command 실행 중: local pending state + spinner + “최대 180초” 설명
- 완료 후: `/api/project/status`, `/api/project/workbench`, `/api/project/runs` 재조회
- 긴 작업 UX 개선은 backend 추가 필요: streaming logs, job id, cancellation endpoint

## 4.10 UI/UX 원칙

| 원칙 | 구현 방식 |
|---|---|
| 사용자는 기능명을 몰라도 된다 | command 이름 대신 목적 중심 ActionCard와 자연어 shortcut을 보여준다. |
| 위험한 작업은 반드시 확인한다 | scaffold/setup/agent-run/rollback/advance는 dry-run preview와 ConfirmationModal을 거친다. |
| 결과는 구조화한다 | stdout 텍스트만 보여주지 않고 카드, 표, gallery, log tab, score panel, file list로 분해한다. |
| 실패는 해결 가능해야 한다 | ErrorPanel에는 원인, backend blocking issue, exit code, 재시도/설정/repair action을 함께 제공한다. |
| 다음 행동을 항상 제안한다 | 모든 tool result 뒤에 FollowUpActions를 붙이고 `next_action`을 우선 사용한다. |
| 초보자는 대화로 완료한다 | 복잡한 옵션은 agent question과 DynamicForm으로 점진 노출한다. |
| 고급 사용자는 제어할 수 있다 | raw JSON preview, command/args preview, dry-run toggle, force toggle, registry drawer를 제공한다. |
| 안전 정책은 숨기지 않는다 | token, approval, deploy dry-run only, `.env` block을 UI copy로 명확히 설명한다. |

## 4.11 반응형/접근성 설계

| 환경 | 레이아웃 | 핵심 고려 |
|---|---|---|
| Desktop ≥ 1280px | 3-pane: Chat / Action / Evidence | 동시에 대화, 실행, 결과 확인. Right pane은 preview/log/artifact tabs. |
| Tablet 768~1279px | 2-pane: Chat+Action / Evidence drawer | ActionCard와 ResultPanel 간 전환을 segmented control로 제공. |
| Mobile < 768px | single column + bottom sheet | 채팅 우선. 실행 폼/결과는 bottom sheet, sticky execute bar 사용. |

접근성 규칙:

- 모든 action button은 keyboard focus visible 상태를 가진다.
- Modal/Drawer는 focus trap과 Escape 닫기를 지원한다.
- 실행 진행/완료/오류 toast는 `aria-live` 영역으로 알린다.
- StatusBadge는 색상 외에도 텍스트와 아이콘/label을 같이 사용한다.
- 로그/테이블은 screen reader용 summary와 caption을 제공한다.
- destructive/approval action은 버튼 label에 목적을 명확히 넣는다. 예: “승인하고 agent-run 실행”.
- skeleton/loading/empty/error state 모두 설명 문구와 다음 action을 포함한다.
- 색상 대비는 WCAG AA 이상, disabled 상태도 대비를 유지한다.

---

# 5. 기능별 UI 매핑표

| 백엔드 기능 | 사용자 목적 | 진입 방식 | UI 컴포넌트 | API 호출 | 결과 표시 | 예외 처리 |
|---|---|---|---|---|---|---|
| `/health` | daemon 연결 확인 | 앱 로드/설정 테스트 | DaemonStatusBadge | `GET /health` | ok/error chip | daemon 미기동이면 CLI 실행 안내 |
| `/api/engine` | 엔진 capabilities 확인 | 연결 성공 후 자동 | EngineInfoDrawer | `GET /api/engine` | allowed commands/guardrails | token 오류면 Settings 이동 |
| `/api/project/status` / `status` | 현재 phase와 blocker 이해 | 자동 refresh, “상태 새로고침” | PhaseStepper, BlockerList | `GET /api/project/status?path=` | current_phase, next_action | init 필요 시 start/init 제안 |
| `/api/project/workbench` / `workbench` | artifact/control snapshot 보기 | workspace 로드, export 버튼 | ArtifactMatrix, WorkbenchPanel | `GET /api/project/workbench?path=`, command `workbench` | panels, file tree, controls | adapter unavailable이면 status 기반 fallback |
| `/api/project/runs` | 실행 히스토리 확인 | History tab | RunTimeline | `GET /api/project/runs?path=` | 최근 run cards | unreadable은 warning row |
| `help`, `version` | 도움말/버전 확인 | About drawer | AboutPanel | command `help`/`version` | command docs | 없음/unknown command 처리 |
| `daemon`, `backend` | local API 준비 | Home 안내 | ConnectionGuide | command dry-run only in UI | host/port/token 설명 | non-local host 차단 설명 |
| `start` | 아이디어로 프로젝트 시작 | Home chat/onboarding | StartProjectForm | command `start` | 초기 docs/state/next action | idea 누락 질문, dry-run retry |
| `init` | 기존 폴더 초기화 | Home/Workspace action | InitProjectCard | command `init` | `.ai-web` 생성 결과 | 충돌/권한 오류 표시 |
| `intent route` | 자연어를 작업 후보로 변환 | chat submit 내부 | IntentInterpreter | command `intent route` | 추천 skill/system/action | idea empty면 질문 |
| `interview` | 요구사항 질문/정리 | chat onboarding | InterviewCard | command `interview` | 질문/요구사항 artifact | idea 필요 시 form |
| `runtime-plan`, `scaffold-status` | 구현 준비도 확인 | Status tab/자동 | RuntimeReadinessPanel | command `runtime-plan` | ready/blocked/missing files | blocker별 해결 action |
| `run` | 다음 자동 단계 수행 | “다음 단계 실행” | NextActionCard | command `run` | action_taken/next_action | gate blocker면 관련 tab 이동 |
| `advance` | phase 전진 | Gate card | GateAdvanceModal | command `advance` | phase update | approval evidence 없으면 blocked |
| `rollback` | 잘못된 phase/실패 복구 | Recovery drawer | RollbackForm | command `rollback` | rollback record | `--to`/`--failure` 누락이면 필드 강조 |
| `resolve-blocker` | blocker 수동 해소 | Blocker card | ResolveBlockerModal | command `resolve-blocker` | decision/blocker update | reason 요구 |
| `snapshot` | 변경 전 복구점 만들기 | 위험 실행 전 추천 | SnapshotButton | command `snapshot` | snapshot manifest | write 오류 표시 |
| `design-brief` | 디자인 요구사항 정리 | Design tab/chat | DesignBriefPanel | command `design-brief` | brief markdown preview | 선행 artifact 부족 시 start/interview 제안 |
| `design-research` | 디자인 레퍼런스 수집/skip | Design tab | ResearchPanel | command `design-research` | research rows/skip reason | token 없음/adapter unavailable 안내 |
| `design-system resolve` | UI 원칙/tokens 확정 | Design tab | DesignSystemPanel | command `design-system` args `resolve` | `DESIGN.md` preview | force 필요/brief 부족 |
| `design-prompt` | 후보 생성 prompt 확인 | Design tab | PromptPreview | command `design-prompt` | prompt markdown | 선행 디자인 시스템 필요 |
| `design` | 디자인 후보 생성 | Candidate gallery | CandidateGeneratorForm | command `design` | 후보 cards/comparison | candidate count/phase 오류 |
| `select-design` | 후보 선택/Gate2 준비 | Candidate card | CandidateSelectModal | command `select-design` | selected/gate artifact | id 누락/없는 후보 |
| `ingest-design` | 외부/수동 후보 추가 | Candidate gallery | IngestDesignForm | command `ingest-design` | candidate registered | 필드 누락/충돌 |
| `design-systems list` | 디자인 시스템 선택 | Settings/Design | RegistryPicker | command `design-systems list` | registry list | registry 오류 |
| `skills list` | agent capability 참고 | Settings | RegistryList | command `skills list` | skill list | registry 오류 |
| `craft list` | craft pattern 참고 | Settings/Design | CraftLibraryDrawer | command `craft list` | craft list | registry 오류 |
| `scaffold` profile D/S | 프론트 skeleton 생성 | Build tab | ScaffoldForm | command `scaffold` | generated files/metadata | Gate2 미승인/충돌 |
| `setup --install` | 의존성 설치 | Build tab | InstallDepsModal | command `setup --install` | install logs | approval token/lifecycle warning |
| `build` | 빌드 검증 | Build/QA tab | BuildCard | command `build` | build logs/status | package missing/build fail |
| `preview` | 로컬 미리보기 | Preview tab | PreviewController | command `preview` | preview URL/pid | port/process 오류 |
| `preview --stop` | 미리보기 중지 | Preview tab | StopPreviewButton | command `preview --stop` | stopped status | stale pid warning |
| `qa-playwright`, `browser-qa` | E2E QA | QA tab | E2ECard | command `qa-playwright` | checks/logs | preview/tool/url 오류 |
| `qa-screenshot`, `screenshot-qa` | screenshot evidence | QA/Visual tab | ScreenshotGallery | command `qa-screenshot` | screenshots/metadata | browser unavailable |
| `qa-a11y`, `a11y-qa` | 접근성 검사 | QA tab | AccessibilityReport | command `qa-a11y` | a11y report | critical issue badges |
| `qa-lighthouse`, `lighthouse-qa` | 성능 검사 | QA tab | LighthouseReport | command `qa-lighthouse` | scores/report | low scores/action suggestions |
| `qa-checklist` | 수동 QA 항목 생성 | QA tab | ChecklistPanel | command `qa-checklist` | checklist markdown | missing artifact |
| `qa-report` | QA 결과 기록 | QA tab | QAReportForm | command `qa-report` | status/final report | schema invalid/from unsafe |
| `repair` | QA 실패 수정 task 생성 | Failed QA card | RepairActionCard | command `repair` | repair task/snapshot | max cycles/no QA blocked |
| `visual-critique` | 시각 품질 평가 | Visual tab | VisualCritiquePanel | command `visual-critique` | scores/issues/patch plan | evidence path invalid |
| `visual-polish --repair` | 시각 품질 개선 task 생성 | Visual critique result | VisualPolishCard | command `visual-polish --repair` | polish task/snapshot | critique passed/no critique/max cycles |
| `component-map` | 컴포넌트 타겟 찾기 | Visual Edit tab | ComponentMapPanel | command `component-map` | component tree | no components/force needed |
| `visual-edit` | 특정 컴포넌트 수정 task | Component card/chat | VisualEditDrawer | command `visual-edit` | task packet | target/prompt/map missing |
| `agent-run` | task packet 실행 | Task/Agent tab | AgentRunPanel | `POST /api/codex/agent-run` | diff/changed files/logs | approval/forbidden path/env guard |
| `next-task` | 다음 작업 packet 생성 | Agent recommendation | NextTaskCard | command `next-task` | task markdown | force/blocker |
| `supabase-secret-qa` | Supabase secret 안전 확인 | Security/QA tab | SecretQACard | command `supabase-secret-qa` | secret QA result | leaked secret/.env blocked |
| `github-sync` | GitHub 동기화 계획 | Release drawer | GitSyncPlanCard | command `github-sync` | remote/branch plan | git adapter issue |
| `deploy-plan` | 배포 준비 계획 | Release drawer | DeployPlanCard | command `deploy-plan` | checklist/plan | target invalid |
| `deploy` dry-run only | 배포 실행 전 점검 | Release drawer | DeployDryRunCard | command `deploy` with `dry_run=true` | dry-run payload | non-dry-run blocked/disabled |

---

# 6. 컴포넌트 설계

## 6.1 레이아웃/프레임

| 컴포넌트 | 역할 | 주요 props | 상태 | 연결 API |
|---|---|---|---|---|
| `AppShell` | 전체 route/topbar/siderail shell | `projectPath`, `connection`, `phase` | nav open, active route | health/engine/status summary |
| `TopBar` | daemon/project/phase/dry-run 표시 | `project`, `daemonStatus`, `currentPhase`, `dryRunDefault` | dryRun toggle | health/status refresh |
| `SideRail` | workspace mode 이동 | `activeTab`, `badges` | collapsed | 없음 |
| `WorkspaceLayout` | 3-pane responsive layout | `chat`, `actions`, `evidence` | pane sizes | 없음 |
| `ResponsiveBottomSheet` | 모바일 result/action drawer | `open`, `title`, `children` | open/closed | 없음 |

## 6.2 채팅/에이전트

| 컴포넌트 | 역할 | 주요 props | 상태 | 연결 API |
|---|---|---|---|---|
| `ChatComposer` | 자연어 입력/shortcut | `disabled`, `suggestions`, `onSubmit` | draft, slash mode | `intent route` optional |
| `ChatTranscript` | 메시지 목록 | `messages` | scroll position | 없음 |
| `UserMessage` | 사용자 요청 bubble | `text`, `timestamp` | 없음 | 없음 |
| `AgentMessage` | 요약/질문/결과 설명 | `variant`, `content`, `actions` | expanded | 없음 |
| `AgentQuestion` | 누락 입력 요청 | `question`, `fieldSchema`, `quickReplies` | answer | form submit → action planner |
| `FollowUpActions` | 다음 행동 chips | `actions` | selected | command 실행 |
| `IntentInterpreter` | 자연어 → command 후보 | `text`, `projectState` | candidates, confidence | `intent route`, local command map |

## 6.3 실행/폼/확인

| 컴포넌트 | 역할 | 주요 props | 상태 | 연결 API |
|---|---|---|---|---|
| `ActionCard` | 실행 후보 카드 | `title`, `purpose`, `command`, `risk`, `inputs`, `recommended` | expanded | `/api/project/command` |
| `ToolCallPreview` | API 호출 전 요약 | `path`, `command`, `args`, `dryRun`, `approved` | show raw JSON | 없음 |
| `DynamicForm` | command별 옵션 입력 | `schema`, `initialValues`, `onSubmit` | values, validation | command planner |
| `ConfirmationModal` | 위험 실행 확인 | `risk`, `summary`, `requiresApproval`, `changedFiles` | checked, approval token entered | `/api/project/command`, `/api/codex/agent-run` |
| `ApprovalTokenGate` | 승인 토큰 처리 | `requiredFor`, `onApprove` | token masked | request headers |
| `DryRunToggle` | dry-run 우선 실행 | `value`, `onChange` | value | command payload |

## 6.4 결과/증거

| 컴포넌트 | 역할 | 주요 props | 상태 | 연결 API |
|---|---|---|---|---|
| `ResultPanel` | 현재 command 결과 통합 표시 | `result`, `command` | selected tab | status/workbench/runs refetch |
| `RunTimeline` | 최근 실행 기록 | `runs`, `selectedRun` | filters | `/api/project/runs` |
| `LogViewer` | stdout/stderr/log file 요약 | `stdout`, `stderr`, `logPaths` | wrap/search | bridge output |
| `FileChangeList` | changed_files/planned_changes | `files`, `mode` | selected file | backend 추가 필요: safe file read |
| `ArtifactPreview` | markdown/json/html artifact preview | `artifactPath`, `kind` | rendered/raw | 현재는 workbench summary, 상세 read endpoint 추가 필요 |
| `StatusBadge` | pass/fail/blocked/running | `status`, `severity` | 없음 | 없음 |
| `ErrorBoundary` | UI runtime error | `fallback` | captured error | 없음 |
| `ErrorPanel` | backend error | `error`, `blockingIssues`, `exitCode` | expanded | retry action |

## 6.5 기능군 특화 컴포넌트

| 컴포넌트 | 역할 | 주요 props | 연결 command/API |
|---|---|---|---|
| `PhaseStepper` | phase/gate 진행 표시 | `currentPhase`, `gates`, `blockers` | `status`, `advance`, `rollback` |
| `RuntimeReadinessPanel` | scaffold/build 준비도 | `readiness`, `missingFiles` | `runtime-plan` |
| `DesignEnginePanel` | 디자인 brief/research/system/prompt/candidate 통합 | `designState`, `candidates`, `selected` | design commands 전체 |
| `CandidateGallery` | 후보 비교/선택 | `candidates`, `selectedId` | `design`, `select-design`, `ingest-design` |
| `DesignSystemPanel` | tokens/principles/constraints | `designSystem` | `design-system resolve` |
| `PreviewController` | preview start/stop/iframe | `previewMetadata`, `url` | `preview`, `preview --stop` |
| `QADashboard` | QA 상태/도구별 결과 | `qaResults`, `openFailures` | `qa-*`, `qa-report`, `repair` |
| `ScreenshotGallery` | responsive screenshot evidence | `screenshots` | `qa-screenshot`, `visual-critique` |
| `VisualCritiquePanel` | scores/issues/patch plan | `critique` | `visual-critique`, `visual-polish` |
| `ComponentMapPanel` | 컴포넌트 tree/target select | `components` | `component-map`, `visual-edit` |
| `AgentRunPanel` | task packet 실행/diff/log | `task`, `dryRun`, `approved` | `/api/codex/agent-run` |
| `ReleasePanel` | Git/deploy dry-run plan | `git`, `deploy` | `github-sync`, `deploy-plan`, `deploy --dry-run` |
| `SettingsPanel` | token/approval/registry/preferences | `tokens`, `engine`, `registries` | health/engine/registry list |

---

# 7. 상태/API 설계

## 7.1 프론트 상태 도메인

```ts
type AppState = {
  connection: ConnectionState;
  project: ProjectState;
  chat: ChatState;
  planner: PlannerState;
  commandRuns: CommandRunState;
  workbench: WorkbenchState;
  settings: SettingsState;
  ui: UIState;
};
```

| 상태 | 내용 | 저장 위치 |
|---|---|---|
| `connection` | daemon base URL, health status, API token configured, approval token present | memory + localStorage token reference 정책 선택 |
| `project` | projectPath, status payload, phase, gates, blockers, next_action | memory, path는 localStorage 가능 |
| `chat` | messages, pending question, current intent | memory/sessionStorage |
| `planner` | command candidates, selected action, form values, risk level | memory |
| `commandRuns` | pending command, last result, optimistic running, errors | memory + runs API refresh |
| `workbench` | artifacts, panels, file summaries, candidates, visual/latest summaries | SWR/React Query cache |
| `settings` | dryRunDefault, theme, registry filters, token storage preference | localStorage |
| `ui` | active tab, drawer state, selected artifact/run/component | memory/router query |

## 7.2 API client 구조

```ts
class AiwebApiClient {
  constructor(baseUrl: string, getToken: () => string, getApprovalToken?: () => string)

  health(): Promise<HealthPayload>
  engine(): Promise<EnginePayload>
  projectStatus(path: string): Promise<BridgeEnvelope<ProjectStatusPayload>>
  projectWorkbench(path: string): Promise<BridgeEnvelope<WorkbenchPayload>>
  projectRuns(path: string): Promise<RunsPayload>
  runCommand(input: ProjectCommandInput): Promise<BridgeEnvelope<unknown>>
  codexAgentRun(input: CodexAgentRunInput): Promise<BridgeEnvelope<unknown>>
}
```

### `POST /api/project/command` payload

```ts
type ProjectCommandInput = {
  path: string;
  command: string;
  args?: string[];
  dry_run?: boolean;
  approved?: boolean;
};
```

프론트는 다음 flags를 `args`에 넣으면 안 된다.

- `--path`
- `--json`
- `--dry-run`
- `--approved`

이 값들은 payload top-level 또는 header로만 전달한다.

### `POST /api/codex/agent-run` payload

```ts
type CodexAgentRunInput = {
  path: string;
  task?: string; // default latest
  dry_run?: boolean; // default true
  approved?: boolean;
};
```

## 7.3 인증/승인

| 구분 | 처리 |
|---|---|
| API token | 모든 `/api/*` 요청에 `X-Aiweb-Token`. 브라우저 저장은 사용자가 선택. 기본은 session memory 권장. |
| Approval token | 위험 실행 시 `X-Aiweb-Approval-Token`. 저장하지 않고 1회 입력 권장. |
| local origin | daemon은 localhost/127.0.0.1/::1만 허용. 프론트 dev server도 localhost 사용. |
| secret masking | token 입력은 password field + reveal 버튼. 로그/preview에는 절대 표시하지 않음. |

## 7.4 에러 처리

| 에러 | UX |
|---|---|
| HTTP 400 validation | form field 오류 + backend message |
| HTTP 403 token/origin/unsafe | Settings 이동 + guardrail 설명 |
| HTTP 500 internal | ErrorPanel + raw class/message 접기 영역 |
| command exit failed | stdout_json/blocking_issues/stderr 요약 + retry/dry-run/repair 제안 |
| timeout | “180초 timeout” 설명 + runs refresh + 재시도 제안 |
| adapter unavailable | 해당 기능 disabled + backend 지원 없음 설명 |

## 7.5 캐싱/재조회

- React Query/SWR 권장.
- `status`, `workbench`, `runs`는 command 완료 후 invalidate.
- pending 중 polling은 하지 않고 spinner 유지. 완료 후 한 번에 refresh.
- preview running 상태만 5~10초 간격으로 status/runs refresh 가능.

## 7.6 백엔드 추가 필요 항목

현재 백엔드만으로 MVP UI는 가능하지만, 고품질 웹앱 구현을 위해 아래 endpoint 추가를 권장한다.

| 필요 기능 | 이유 | 제안 API |
|---|---|---|
| command job id/streaming logs | 현재 command는 동기 180초 timeout. 긴 build/agent-run UX가 답답함. | `POST /api/project/jobs`, `GET /api/project/jobs/:id`, `GET /api/project/jobs/:id/logs` |
| safe artifact read | 현재 workbench summary는 가능하지만 파일 본문 preview가 제한적. | `GET /api/project/artifact?path=&artifact=` with redaction |
| safe artifact list by type | candidates/visual/qa를 UI가 안정적으로 조회 | `GET /api/project/artifacts?type=design-candidate` |
| cancel running command | agent-run/build/preview 등 긴 작업 제어 | `POST /api/project/jobs/:id/cancel` |
| conversational action planning endpoint | 현재 full chat brain은 없음. 프론트 local planner + `intent route`로 대체 가능. | `POST /api/agent/plan` |
| multi-project profile/session | 현재 단일 local token/path 전제 | optional local config endpoint |

---

# 8. 구현 로드맵

## Phase 1 — 핵심 워크스페이스와 필수 API 연결

| 항목 | 구현 |
|---|---|
| 화면 | `/`, `/workspace`, `/settings` 기본 route |
| 컴포넌트 | AppShell, TopBar, ChatComposer, ActionCard, ResultPanel, SettingsPanel, PhaseStepper, BlockerList |
| API | health, engine, status, workbench, runs, project command wrapper |
| 기능 | project path/token 연결, 상태 요약, dry-run command 실행, 결과 카드 표시 |
| 검증 기준 | daemon token으로 연결 성공, status 표시, `runtime-plan`, `design-brief --dry-run`, `runs` refresh 동작 |

## Phase 2 — 모든 백엔드 기능 매핑

| 항목 | 구현 |
|---|---|
| 화면 | Workspace 내부 Design/Build/QA/Visual/Release tabs |
| 컴포넌트 | DynamicForm, ToolCallPreview, ConfirmationModal, DesignEnginePanel, CandidateGallery, QADashboard, RunTimeline |
| API | 모든 allowed command args schema 매핑, `/api/codex/agent-run` dry-run |
| 기능 | 디자인 엔진 전체, scaffold/setup/build/preview, QA/repair, visual/component-map/edit, next-task/agent-run, deploy dry-run |
| 검증 기준 | F01~F49 기능별 ActionCard 존재, 잘못된 입력 validation, 위험 작업 확인 modal |

## Phase 3 — 고급 UX, 히스토리, 설정, 최적화

| 항목 | 구현 |
|---|---|
| 화면 | Settings registry browser, History filters, artifact preview drawer |
| 컴포넌트 | RegistryPicker, ArtifactPreview, FileChangeList, LogViewer, VisualCritiquePanel, ReleasePanel |
| API | registry list commands, workbench/run summary 강화, safe artifact read가 생기면 연동 |
| 기능 | 후속 action 추천, command template 저장, keyboard shortcut, preview iframe, screenshot gallery |
| 검증 기준 | 사용자가 command 명을 몰라도 주요 플로우 완료, 오류 후 복구 action 제안 |

## Phase 4 — QA, 접근성, 성능 개선

| 항목 | 구현 |
|---|---|
| QA | unit/integration/E2E/a11y/responsive/security tests |
| 접근성 | keyboard-first command execution, focus trap, screen reader labels, contrast |
| 성능 | large log virtualization, result cache, memoized artifact tree |
| 안정성 | token redaction tests, `.env` path block tests, approval tests |
| 검증 기준 | 주요 E2E pass, mobile usable, axe critical 0, no secret leakage |

---

# 9. 테스트 계획

## 9.1 기능 테스트

- command schema builder가 모든 F01~F49 command를 포함하는지 테스트.
- `args`에 backend-controlled flags가 들어가지 않는지 테스트.
- DynamicForm validation:
  - `select-design` id required
  - `visual-edit` target/prompt required
  - `rollback` requires to or failure
  - `setup` requires install fixed true
  - `visual-polish` requires repair true

## 9.2 API 연동 테스트

- MSW 또는 fetch mock으로 daemon 응답 mocking.
- health success/failure.
- token missing 403.
- command success envelope with `stdout_json`.
- command failed envelope with `stderr` and `blocking_issues`.
- runs unreadable row handling.

## 9.3 E2E 테스트

대표 시나리오:

1. daemon 연결 → project path 입력 → status 표시.
2. 새 프로젝트 idea 입력 → `start --dry-run` → 확인 → 결과 표시.
3. blocked runtime-plan 표시 → 디자인 후보 생성 추천.
4. `design-brief` → `design-system resolve` → `design-prompt` → `design` → `select-design` flow.
5. `scaffold --dry-run` → changed files preview → 실제 scaffold confirmation.
6. `build` failure → ErrorPanel → `repair` task 생성.
7. `qa-screenshot` → `visual-critique` → `visual-polish --repair`.
8. `component-map` → component target 선택 → `visual-edit` task 생성.
9. `agent-run` dry-run → approval modal → approved run.
10. `deploy-plan` → `deploy --dry-run`; real deploy disabled 확인.

## 9.4 에러 케이스 테스트

- daemon down.
- invalid token.
- approval token missing.
- unsafe `.env` path.
- unknown/disallowed command.
- command timeout mock.
- adapter unavailable.
- malformed JSON/stdout parse fail.

## 9.5 권한/보안 테스트

- 모든 `/api/*` 요청에 token header 포함.
- approval 필요 command에 approval token 없으면 실행 차단.
- token이 logs/result에 렌더링되지 않음.
- `.env` 파일명/경로가 UI action input에 들어가면 client-side에서도 차단.
- non-local base URL 경고 또는 차단.

## 9.6 모바일/반응형 테스트

- 375px, 768px, 1024px, 1440px viewport.
- 모바일에서 chat → action → result bottom sheet flow가 끊기지 않는지.
- CandidateGallery, QA table, LogViewer horizontal overflow 처리.

## 9.7 접근성 테스트

- keyboard only로 command 선택/폼 입력/확인/취소 가능.
- ConfirmationModal focus trap.
- toast/error는 ARIA live region.
- status badge는 색만으로 의미 전달하지 않음.
- contrast WCAG AA 이상.
- 로딩/빈 상태/에러 상태에 screen reader label 제공.

---

# 10. 누락 위험 및 추가 확인 질문

## 10.1 누락 위험

| 위험 | 현재 판단 | 대응 |
|---|---|---|
| full conversational LLM backend 부재 | 현재 backend는 command engine이며 chat brain endpoint는 없음 | Phase 1은 프론트 planner + `intent route`로 구현, 추후 `/api/agent/plan` 추가 권장 |
| artifact 본문 preview API 부족 | workbench/runs summary는 있으나 안전한 파일 본문 조회 route 없음 | `safe artifact read` endpoint 추가 전까지 path/summary 중심 preview |
| streaming/job status 없음 | 긴 command는 동기 대기 | pending UI + 완료 후 refresh, backend job API 추가 권장 |
| 실제 deploy 실행 제한 | daemon bridge가 dry-run only | 의도된 안전 정책으로 유지. 실제 배포는 CLI 명시 승인 문서화 |
| DB/사용자 권한 없음 | 로컬 단일 사용자 전제 | settings에 로컬 보안 모델 명확히 표시 |
| profile S/Supabase 상세 UX | backend는 scaffold/secret QA까지 있고 실제 Supabase 관리 UI는 없음 | profile S 전용 Security/Setup panel로 제한 |

## 10.2 추가 확인 질문

현재 설계를 구현하기 전에 제품 방향만 확인하면 좋은 질문이다. 단, 백엔드 기능 매핑 설계 자체는 위 계획으로 진행 가능하다.

1. 프론트 앱은 `apps/workbench/`의 React/Vite SPA로 새로 두는 방향을 확정할지?
2. token 저장은 “세션 메모리만”을 기본으로 할지, “localStorage 저장 선택”을 허용할지?
3. full chat agent planner를 프론트 local planner로 먼저 갈지, backend `/api/agent/plan`을 먼저 추가할지?

---

# 부록 A. 핵심 사용자 플로우

## A1. 새 프로젝트 시작

1. 사용자가 `/`에서 “랜딩페이지 만들어줘” 입력.
2. 앱이 `intent route`로 분류하고 `start` action 제안.
3. StartProjectForm에서 idea/profile 확인.
4. `start --dry-run` 실행.
5. 생성 예정 파일과 next_action 표시.
6. 사용자가 확인하면 `start` 실행.
7. `status/workbench/runs` refresh.
8. 에이전트가 “이제 design-brief를 만들까요?” 추천.

## A2. 디자인 엔진 전체 사용

1. 사용자가 “우리 디자인 제대로 잡아줘” 입력.
2. 에이전트가 현재 design artifacts를 확인.
3. 누락 순서대로 `design-brief`, `design-research`, `design-system resolve`, `design-prompt`, `design` 제안.
4. 각 단계는 dry-run preview 후 실행.
5. CandidateGallery에서 후보를 비교.
6. 사용자가 후보 선택.
7. `select-design` 실행 후 Gate 2 artifact 표시.
8. 다음 action: `scaffold` 추천.

## A3. 구현 scaffold/build/preview

1. runtime-plan이 “selected design missing/scaffold missing” 등 blocker 표시.
2. blocker 해결 후 `scaffold --dry-run`.
3. 파일 충돌/생성 예정 파일 표시.
4. `scaffold` 실행.
5. `setup --install`은 approval token modal 후 실행.
6. `build` 실행.
7. `preview` 실행 후 PreviewFrame 표시.
8. 다음 action: QA 실행 추천.

## A4. QA/Repair

1. 사용자가 “전체 QA 돌려줘” 입력.
2. QADashboard가 preview URL을 확인.
3. `qa-playwright`, `qa-screenshot`, `qa-a11y`, `qa-lighthouse`, `qa-checklist`를 순서대로 제안.
4. 실패가 있으면 ErrorPanel에 원인/증거 표시.
5. `repair --dry-run`으로 수정 task 생성 계획 표시.
6. 확인 후 `repair` 실행.
7. `agent-run` dry-run → approval → 실행으로 이어짐.

## A5. Visual Review/Edit

1. 사용자가 “첫 화면 더 좋아 보이게 다듬어줘” 입력.
2. 최신 screenshot이 없으면 `qa-screenshot` 제안.
3. `visual-critique` 실행해 점수/이슈/patch plan 표시.
4. `visual-polish --repair`로 개선 task 생성.
5. 특정 컴포넌트를 바꾸려면 `component-map` 실행.
6. ComponentMapPanel에서 target 선택.
7. `visual-edit` prompt 입력 후 task 생성.
8. `agent-run`으로 실행.

## A6. Release/Deploy planning

1. 사용자가 “배포 준비됐는지 봐줘” 입력.
2. `github-sync --dry-run`, `deploy-plan`, `deploy --dry-run` 제안.
3. QA/gate/security blocker와 함께 ReleaseReadinessChecklist 표시.
4. 실제 deploy는 disabled이며 CLI 명시 실행 안내만 제공.

---

# 부록 B. Claude Design / Frontend Implementation Handoff Pack

이 부록은 Claude Design 투입과 실제 프론트엔드 구현 단계에서 기능 누락, UI 혼선, API 연결 혼선을 막기 위한 보조 산출물이다.

## B0. 문서 위치 판단 및 작성 방식

| 항목 | 판단 |
|---|---|
| source of truth | 이 문서 전체, 특히 1~10장과 부록 A |
| 기존 문서 구조 확인 결과 | `docs/frontend-design-plan.md`가 유일한 프론트엔드 계획 문서이며, `docs/templates/`는 aiweb 생성 템플릿이다. `.ai-web/*`는 현재 프로젝트 계약/상태 문서다. |
| 유사 문서 여부 | 기능 매핑, 컴포넌트, 상태/API, 플로우가 이미 이 문서에 존재한다. |
| 새 문서 생성 여부 | 새 파일 생성 대신 기존 `docs/frontend-design-plan.md`에 부록으로 보강한다. 이유: source of truth 분산과 내용 불일치 위험을 줄이기 위함. |
| 권장 위치/파일명 | 보강 위치: `docs/frontend-design-plan.md`의 `부록 B. Claude Design / Frontend Implementation Handoff Pack`. |
| 새로 정하지 않는 것 | 제품 방향, 페이지 수, 톤앤매너, 기능 범위, API 범위, 신규 백엔드 기능. |
| 확인 필요로 남길 것 | 플랜에 권장/후보로만 적힌 프레임워크 확정, token 저장 정책, Claude Design 산출 포맷, 미구현 backend endpoint 도입 여부. |

## B1. 필요한 보조 산출물 식별표

| 산출물 | 목적 | 포함해야 할 내용 | 기준이 되는 기존 플랜 위치 | 새 문서/보강 판단 | 권장 위치/파일명 |
|---|---|---|---|---|---|
| Claude Design 투입용 디자인 브리프 | Claude Design이 제품 방향을 새로 만들지 않고 화면을 설계하게 함 | 제품 컨셉, 3개 route, 3-pane workspace, 금지사항, 확인 필요 항목 | 2장, 3장, 4장, 4.10, 4.11 | 기존 플랜 보강 | 이 문서 B2 |
| 기능별 UI 매핑표 | 백엔드 command 누락 방지 | 기능군, 사용자 목적, UI 진입, component, API, 결과/오류 | 1.2, 5장 | 기존 표 유지 + 구현용 요약 보강 | 이 문서 B3, 전체 기준은 5장 |
| 카드/버튼/CTA 매핑표 | 버튼 이름/위험도/확인 모달 혼선 방지 | 카드명, CTA, command, dry-run, approval, 결과 panel | 4.4~4.8, 5장 | 보강 필요 | 이 문서 B4 |
| 사용자 요청별 플로우 | 자연어 요청이 어떤 action sequence로 가야 하는지 고정 | 요청 예시, 의도, 질문/폼, command 순서, 결과, follow-up | 부록 A, 2.2, 4.2 | 보강 필요 | 이 문서 B5 |
| 화면별 구조 명세 | Claude Design의 레이아웃 흔들림 방지 | route, 영역, 핵심 카드, 금지/확인 필요 | 3장, 4.1, 4.11 | 보강 필요 | 이 문서 B6 |
| 컴포넌트 설계 | 구현자가 UI 단위를 임의로 쪼개지 않게 함 | component, 책임, 상태, 연결 API | 6장 | 기존 표 유지 + 구현 기준 보강 | 이 문서 B7, 전체 기준은 6장 |
| API와 UI 연결표 | API 호출 혼선 방지 | daemon route, command, frontend owner, refresh target | 1.1, 7.2~7.5 | 보강 필요 | 이 문서 B8 |
| 상태 규칙 | 로딩/에러/빈 상태/권한/확인 모달 일관성 확보 | 상태 유형, trigger, UI, CTA, 금지사항 | 4.6~4.9, 7.3~7.4, 9장 | 보강 필요 | 이 문서 B9 |
| Claude Design 투입 전 체크리스트 | 디자인 작업 전 source-of-truth 준수 확인 | 금지사항, 필수 화면, 필수 state, 미확정 표시 | 전 문서 | 보강 필요 | 이 문서 B10 |

## B2. Claude Design 투입용 디자인 브리프

> 이 섹션은 Claude Design에 가장 먼저 전달한다. 아래 내용 밖의 기능/페이지/톤앤매너를 추가하지 않는다.

| 항목 | 브리프 |
|---|---|
| 제품명/작업명 | AI Web Director Workbench |
| 핵심 경험 | 사용자가 자연어로 요청하면 에이전트가 현재 프로젝트 상태를 읽고, 가능한 작업을 ActionCard로 제안하고, 필요한 입력은 DynamicForm/Modal로 받고, backend command 실행 결과를 Result/Evidence panel에 구조화해 보여준다. |
| 제품 유형 | 로컬-first 대화형 에이전트 웹앱. 단순 CRUD 관리자 페이지가 아니다. |
| 페이지 수 | 최소 3개 route: `/`, `/workspace`, `/settings`. 추가 페이지는 만들지 않고 tab/drawer/modal/card로 흡수한다. |
| 메인 화면 구조 | `/workspace`는 desktop 기준 3-pane: Left Chat, Center Action/Form, Right Evidence/Preview/Logs. |
| 필수 UX 흐름 | Chat → Action proposal → Dynamic form if needed → Dry-run/confirmation → API command → Structured result → Follow-up actions. |
| 주요 기능군 | Project setup/status, Design engine, Scaffold/setup/build/preview, QA/repair, Visual critique/polish/edit, Agent-run, Release dry-run planning, Settings/safety. |
| 안전 원칙 | raw shell 입력 금지, `.env`/secret 노출 금지, backend-controlled flags 직접 입력 금지, `setup`/`agent-run` 승인 필요, `deploy`는 dry-run only. |
| 결과 표현 | 텍스트만 표시하지 않고 카드, 표, 로그 탭, 후보 gallery, screenshot gallery, score panel, component tree, run timeline로 표현한다. |
| 반응형 | Desktop 3-pane, Tablet 2-pane + drawer, Mobile single column + bottom sheet. |
| 접근성 | keyboard-first, focus trap, aria-live, 색상 외 텍스트 label, WCAG AA 대비. |
| 톤앤매너 | 확인 필요. 기존 플랜은 제품 구조/상태/안전 UX를 확정했지만 상세 색상/타이포/브랜드 감성은 확정하지 않았다. Claude Design은 임의 브랜드 방향을 만들지 말고 기능 중심 wireframe/interaction 우선으로 설계한다. |
| 프론트 기술 스택 | 확인 필요. 기존 플랜은 `apps/workbench/`의 React/Vite SPA를 권장하지만 최종 확정으로 표현하지 않는다. |
| Claude Design 금지사항 | 새로운 route 추가, 새로운 backend 기능 가정, real deploy UI 활성화, 채팅만 있고 evidence panel 없는 화면, API별 버튼 나열형 관리자 UI, secret/token 값 노출. |

## B3. 기능별 UI 매핑 구현 요약

전체 기능별 매핑의 원본은 5장이다. 구현 단계에서는 아래 기능군 단위로 화면 누락을 점검한다.

| 기능군 | 포함 backend 기능 | 사용자 목적 | 주 진입 UI | 결과 UI | 확인 필요/주의 |
|---|---|---|---|---|---|
| 연결/엔진 | `/health`, `/api/engine`, `help`, `version`, `daemon`, `backend` | daemon 연결과 엔진 기능 확인 | `/`, Settings, TopBar status | 연결 badge, EngineInfoDrawer, ConnectionGuide | 브라우저에서 daemon 실제 start는 비노출. CLI 안내만. |
| 프로젝트 상태 | `status`, `/api/project/status`, `workbench`, `/api/project/workbench`, `runs`, `/api/project/runs`, `runtime-plan`, `scaffold-status` | 현재 phase/blocker/next action 파악 | Workspace load, Status tab | PhaseStepper, BlockerList, RuntimeReadinessPanel, RunTimeline | workbench 상세 파일 본문 read는 backend 추가 필요. |
| 온보딩/요구 파악 | `start`, `init`, `intent route`, `interview`, `run`, `next-task` | 자연어 idea를 프로젝트/작업으로 전환 | Home chat, ChatComposer, NextActionCard | created artifacts, task packet, next_action | `intent route`는 full chat brain이 아니라 routing helper. |
| 디자인 엔진 | `design-brief`, `design-research`, `design-system resolve`, `design-prompt`, `design`, `select-design`, `ingest-design`, `design-systems list`, `skills list`, `craft list` | 디자인 brief부터 후보 선택까지 진행 | DesignEnginePanel, CandidateGallery, RegistryPicker | brief preview, research rows, DESIGN preview, prompt, candidate cards, selected gate | 색상/타이포 상세는 확인 필요. 기능 추가 금지. |
| scaffold/build/preview | `scaffold`, `setup --install`, `build`, `preview`, `preview --stop`, `supabase-secret-qa` | 선택된 디자인을 실제 앱 skeleton/빌드/미리보기로 전환 | Build/Preview tab | FileChangeList, Install logs, Build logs, PreviewFrame, SecretQACard | `setup`은 approval required. profile S는 Supabase 전용 주의. |
| QA/repair | `qa-playwright`, `browser-qa`, `qa-screenshot`, `screenshot-qa`, `qa-a11y`, `a11y-qa`, `qa-lighthouse`, `lighthouse-qa`, `qa-checklist`, `qa-report`, `repair` | 기능/시각/접근성/성능 검사와 실패 수정 task 생성 | QA tab, failed result card | QADashboard, ScreenshotGallery, AccessibilityReport, LighthouseReport, RepairActionCard | tool unavailable/preview missing state 필요. |
| Visual edit | `visual-critique`, `visual-polish --repair`, `component-map`, `visual-edit` | screenshot/component 기반 시각 개선 task 생성 | Visual tab, ComponentMapPanel, VisualEditDrawer | ScoreCards, IssueList, PatchPlan, ComponentTree, task record | 최신 screenshot/map 없으면 먼저 생성 제안. |
| Agent execution | `/api/codex/agent-run`, `agent-run` | task packet을 Codex CLI bridge로 실행 | AgentRunPanel, task card | diff/changed files/logs/run metadata | approval required. forbidden path/env guard 표시. |
| release planning | `github-sync`, `deploy-plan`, `deploy --dry-run` | Git/deploy 준비 상태와 계획 확인 | Release drawer | ReleaseReadinessChecklist, dry-run plan | real deploy disabled. 새 배포 기능 가정 금지. |
| 복구/운영 | `snapshot`, `advance`, `rollback`, `resolve-blocker` | 상태 전진/복구/수동 blocker 처리 | GateCard, Recovery drawer, Blocker card | state update, snapshot/rollback record | 위험 작업. dry-run + confirmation 필요. |

## B4. 카드/버튼/CTA 매핑표

| UI 카드/영역 | Primary CTA | Secondary CTA | Backend 연결 | 위험도/확인 규칙 | 결과 표시 |
|---|---|---|---|---|---|
| Daemon connection card | 연결 테스트 | 설정 열기 | `GET /health`, `GET /api/engine` | token 필요 시 Settings 이동 | DaemonStatusBadge, guardrails |
| Project status card | 상태 새로고침 | Runtime plan 보기 | `GET /api/project/status`, `runtime-plan` | read-only | PhaseStepper, BlockerList |
| Start project card | dry-run으로 시작 계획 보기 | 질문부터 시작 | `start --dry-run`, `interview` | 실제 `start`는 확인 후 | changed_files, next_action |
| Init card | 초기화 dry-run | 실제 초기화 | `init` | 파일 생성 가능. confirmation | `.ai-web` 생성 결과 |
| Next action card | 다음 단계 실행 | task 생성 | `run`, `next-task` | command별 위험도 상속 | action_taken, next_action |
| Design brief card | brief 생성 | force 옵션 | `design-brief` | safe write. dry-run 기본 | markdown preview |
| Research card | research 실행/skip 기록 | provider/policy 설정 | `design-research` | 외부 token 상태 설명. 임의 token 요구 금지 | research rows/skip reason |
| Design system card | design system resolve | registry 보기 | `design-system resolve`, `design-systems list` | safe write. force 확인 | DESIGN preview |
| Design prompt card | prompt 생성 | raw prompt 보기 | `design-prompt` | safe write | prompt preview |
| Candidate generator card | 후보 생성 | 후보 수 조정 | `design` | safe write. candidates N validation | CandidateGallery |
| Candidate card | 이 후보 선택 | 비교 보기 | `select-design` | Gate 영향. confirmation | selected/gate artifact |
| Ingest design card | 후보 등록 | selected로 등록 | `ingest-design` | fields validation, force 확인 | candidate registered |
| Scaffold card | scaffold dry-run | 실제 scaffold | `scaffold` | file writes. Gate/blocker 확인 | FileChangeList, metadata |
| Install deps card | 승인하고 설치 | dry-run 보기 | `setup --install` | approval token required | install logs |
| Build card | 빌드 실행 | 로그 보기 | `build` | scaffold/package 필요 | Build status/log tabs |
| Preview card | preview 시작 | preview 중지 | `preview`, `preview --stop` | local process. 상태 표시 | PreviewFrame, url/pid |
| E2E QA card | Playwright QA 실행 | task id 설정 | `qa-playwright`/`browser-qa` | preview/url 필요 | QA result/logs |
| Screenshot QA card | screenshot 캡처 | viewport 보기 | `qa-screenshot`/`screenshot-qa` | preview/url 필요 | ScreenshotGallery |
| A11y QA card | 접근성 검사 | report 보기 | `qa-a11y`/`a11y-qa` | preview/url 필요 | AccessibilityReport |
| Lighthouse QA card | Lighthouse 실행 | report 보기 | `qa-lighthouse`/`lighthouse-qa` | preview/url 필요 | LighthouseReport |
| QA checklist card | checklist 생성 | report 기록 | `qa-checklist`, `qa-report` | safe write | ChecklistPanel, QA status |
| Repair card | repair task dry-run | repair task 생성 | `repair` | max cycles/blocker 확인 | repair record, task path |
| Visual critique card | 시각 평가 실행 | screenshot 먼저 생성 | `visual-critique`, `qa-screenshot` | evidence path validation | scores/issues/patch plan |
| Visual polish card | polish task 생성 | max cycles 설정 | `visual-polish --repair` | critique 필요, max cycles | polish record, task path |
| Component map card | component map 생성 | force scan | `component-map` | component source 필요 | ComponentTree |
| Visual edit drawer | 수정 task 생성 | target 다시 선택 | `visual-edit` | target/prompt required | visual edit task |
| Agent run panel | dry-run 실행 | 승인하고 실행 | `/api/codex/agent-run`, `agent-run` | approval token required for real run | diff, logs, changed files |
| Snapshot card | snapshot 만들기 | 이유 입력 | `snapshot` | safe write | snapshot manifest |
| Advance gate card | phase 전진 | blocker 보기 | `advance` | gate confirmation | phase update |
| Rollback card | rollback dry-run | rollback 실행 | `rollback` | destructive-ish. strong confirmation | rollback record |
| Resolve blocker card | blocker 해소 기록 | 이유 수정 | `resolve-blocker` | reason required | blocker update |
| Release plan card | deploy plan 보기 | git sync dry-run | `deploy-plan`, `github-sync` | planning only | readiness checklist |
| Deploy dry-run card | deploy dry-run | CLI 안내 보기 | `deploy --dry-run` | real deploy disabled | dry-run payload |

## B5. 사용자 요청별 플로우

| 사용자 요청 예시 | 의도 | 필요한 질문/폼 | 실행 순서 | 결과 UI | 후속 추천 |
|---|---|---|---|---|---|
| “새 앱 시작해줘” | 프로젝트 시작 | idea, profile, advance 여부 | `intent route` optional → `start --dry-run` → confirm → `start` | changed_files, status, next_action | `design-brief` 또는 `interview` |
| “요구사항부터 정리하자” | 인터뷰/요구 파악 | idea | `interview` | AgentQuestion/requirements artifact | `design-brief` |
| “현재 뭐가 막혔어?” | 상태/blocker 확인 | project path only | `status` → `runtime-plan` → `workbench` | PhaseStepper, BlockerList, missing files | blocker별 ActionCard |
| “디자인 후보 만들어줘” | 디자인 엔진 실행 | candidates N, force 여부 | `design-brief` if missing → `design-system resolve` if missing → `design-prompt` → `design` | CandidateGallery, comparison | `select-design` |
| “이 디자인으로 가자” | 후보 선택 | candidate id | `select-design --dry-run` → confirm → `select-design` | selected badge, gate artifact | `scaffold` |
| “외부 디자인도 후보로 넣어줘” | 수동 후보 등록 | id/title/source/notes/selected | `ingest-design` | candidate card | compare/select |
| “구현 뼈대 만들어줘” | scaffold | profile D/S, force | `runtime-plan` → `scaffold --dry-run` → confirm → `scaffold` | FileChangeList | `setup --install` |
| “설치하고 빌드해줘” | dependencies/build | approval token for setup | `setup --install --dry-run` → approval → `setup --install` → `build` | install/build logs | `preview` |
| “미리보기 띄워줘” | local preview | stop 여부 없음 | `preview` | PreviewFrame/url/pid | QA 실행 |
| “전체 QA 해줘” | QA suite | url/task_id optional | `qa-playwright` → `qa-screenshot` → `qa-a11y` → `qa-lighthouse` → `qa-checklist` | QADashboard, evidence tabs | 실패 시 `repair` |
| “오류 고쳐줘” | QA 기반 repair | from_qa latest/path, max_cycles | `repair --dry-run` → confirm → `repair` | repair task/snapshot | `agent-run` dry-run |
| “화면 더 예쁘게 다듬어줘” | visual critique/polish | screenshot source, max_cycles | `qa-screenshot` if needed → `visual-critique` → `visual-polish --repair` | visual scores/issues/task | `agent-run` |
| “이 버튼/컴포넌트 바꿔줘” | visual edit task | target, prompt, from_map | `component-map` if needed → `visual-edit` | component task card | `agent-run` |
| “작업 실행해줘” | Codex bridge 실행 | task, approval | `/api/codex/agent-run` dry-run → approval → `/api/codex/agent-run` | diff/logs/changed files | build/QA |
| “배포 준비됐나 봐줘” | release planning | target optional | `github-sync --dry-run` → `deploy-plan` → `deploy --dry-run` | ReleaseReadinessChecklist | blocker 해결 |
| “되돌려줘” | recovery | to phase or failure, reason | `snapshot` recommended → `rollback --dry-run` → confirm → `rollback` | rollback record | status refresh |

## B6. 화면별 구조 명세

### `/` Home / Connect

| 영역 | 포함 요소 | 연결 기능 | 상태 규칙 |
|---|---|---|---|
| Connection panel | daemon URL, API token 입력, 연결 테스트 | `/health`, `/api/engine` | daemon down/token fail/connected |
| Project selector | project path 입력/최근 path chip | `/api/project/status` | path required, unsafe `.env` path 금지 |
| Onboarding prompt | idea textarea, quick actions | `intent route`, `start`, `init`, `interview` | idea missing이면 질문 |
| Safety summary | local-only, token, approval, deploy dry-run 설명 | engine guardrails | secret 값 표시 금지 |

금지: Home에 전체 기능별 버튼을 나열하지 않는다. 연결/시작/상태 진입만 제공한다.

### `/workspace` Main Agent Workspace

| Pane/영역 | 포함 요소 | 연결 기능 | 디자인 주의 |
|---|---|---|---|
| TopBar | project chip, daemon status, phase/gate, dry-run toggle | health/status | 항상 현재 context 표시 |
| Left Chat | ChatTranscript, ChatComposer, suggestions | `intent route`, planner | 자연어 중심. command 이름을 먼저 노출하지 않음 |
| Center Action | ActionCard stack, DynamicForm, ToolCallPreview | `/api/project/command` | 위험도 badge와 dry-run 우선 |
| Right Evidence | ResultPanel, PreviewFrame, Logs, Artifact/QA/Visual tabs | workbench/runs/command result | 결과는 구조화, raw logs는 보조 tab |
| SideRail | Agent, Design, Build/Preview, QA/Repair, Visual Edit, Release, History | tab state | 새 route로 늘리지 않음 |

### `/settings` Settings / Safety

| 영역 | 포함 요소 | 연결 기능 | 상태 규칙 |
|---|---|---|---|
| Auth settings | API token, approval token one-time entry | headers only | 저장 정책 확인 필요. 기본은 session memory 권장. |
| Engine info | routes, allowed commands, guardrails | `/api/engine` | read-only |
| Registry browser | design-systems, skills, craft | registry list commands | 선택은 디자인/agent 보조. 새 기능 추가 금지 |
| Preferences | dry-run default, theme if implemented | local UI state | theme/tone 확인 필요 |
| Safety docs | `.env` block, real deploy disabled | daemon guardrails | secret raw value 금지 |

## B7. 컴포넌트 구현 기준

전체 컴포넌트 목록은 6장이다. 구현자는 아래 책임 경계를 지킨다.

| 컴포넌트 그룹 | 반드시 포함 | API/상태 연결 | 금지/확인 필요 |
|---|---|---|---|
| Layout | `AppShell`, `TopBar`, `SideRail`, `WorkspaceLayout`, responsive bottom sheet | connection/project/ui state | route 추가 금지 |
| Chat | `ChatComposer`, `ChatTranscript`, `AgentMessage`, `AgentQuestion`, `FollowUpActions` | chat/planner state, optional `intent route` | full LLM chat backend 있다고 가정 금지 |
| Action execution | `ActionCard`, `DynamicForm`, `ToolCallPreview`, `ConfirmationModal`, `ApprovalTokenGate` | command payload, dry_run, approved, headers | raw shell 입력 금지 |
| Evidence/result | `ResultPanel`, `RunTimeline`, `LogViewer`, `FileChangeList`, `ArtifactPreview`, `ErrorPanel` | command result, runs, workbench | safe artifact read endpoint 없음은 확인 필요로 표시 |
| Design | `DesignEnginePanel`, `CandidateGallery`, `DesignSystemPanel`, `PromptPreview` | design commands, registry list | 새 design system/tone 임의 생성 금지 |
| Build/Preview | `RuntimeReadinessPanel`, `ScaffoldForm`, `PreviewController`, `BuildCard` | runtime-plan, scaffold/setup/build/preview | setup approval 필수 |
| QA/Visual | `QADashboard`, `ScreenshotGallery`, `VisualCritiquePanel`, `ComponentMapPanel`, `VisualEditDrawer` | qa/visual/component commands | screenshot/map 선행 상태 필요 |
| Release/Safety | `ReleasePanel`, `SettingsPanel`, `SecretQACard`, `DaemonStatusBadge` | deploy dry-run, github-sync, engine/health | real deploy 활성화 금지 |

## B8. API와 UI 연결표

| Frontend owner | API/command | Request source | 성공 후 refresh | 실패 UI |
|---|---|---|---|---|
| ConnectionProvider | `GET /health` | app load, manual retry | engine if ok | daemon down guide |
| EngineProvider | `GET /api/engine` | token connected | settings/allowed command cache | token/origin ErrorPanel |
| ProjectProvider | `GET /api/project/status?path=` | project path set, command complete | workbench/runs if changed | init/start suggestion |
| WorkbenchProvider | `GET /api/project/workbench?path=` | workspace load, command complete | panels/artifacts | fallback to status summary |
| RunsProvider | `GET /api/project/runs?path=` | history tab, command complete | run timeline | unreadable row warning |
| CommandRunner | `POST /api/project/command` | ActionCard submit | status/workbench/runs | command-specific ErrorPanel |
| AgentRunner | `POST /api/codex/agent-run` | AgentRunPanel submit | status/workbench/runs/build suggestion | approval/forbidden path ErrorPanel |
| IntentInterpreter | command `intent route` | chat submit optional | planner candidates | ask for clearer idea |
| DesignEnginePanel | design commands | Design tab forms | workbench/status | blocker-specific action |
| BuildPreviewPanel | scaffold/setup/build/preview | Build/Preview tab | status/runs/preview metadata | logs and next action |
| QADashboard | qa/report/repair commands | QA tab/result cards | runs/workbench/open failures | repair suggestion |
| VisualPanel | visual/component commands | Visual tab/drawer | workbench/visual summaries | screenshot/map prerequisite card |
| ReleasePanel | github/deploy dry-run commands | Release drawer | runs/release checklist | disabled real deploy explanation |

## B9. 상태 규칙

| 상태 유형 | Trigger | UI 규칙 | CTA | 금지사항 |
|---|---|---|---|---|
| Loading | health/status/workbench/runs/command pending | skeleton 또는 spinner + 현재 command label + 최대 180초 안내 | 취소는 backend endpoint 없어 확인 필요 | 무한 spinner만 표시 금지 |
| Empty project | `.ai-web` 없음 또는 status init 필요 | 시작 카드와 init/start/interview 제안 | `start --dry-run`, `init --dry-run` | 빈 dashboard만 표시 금지 |
| Blocked | `blocking_issues` 존재 | BlockerList + 원인 + 해결 action | blocker별 command | blocker를 숨기고 다음 단계 실행 금지 |
| Error | HTTP error/command failed | ErrorPanel: message, exit_code, blocking_issues, command summary | retry dry-run, settings, repair | stderr만 raw로 던지기 금지 |
| Auth required | `/api/*` 403 token | Settings drawer로 이동 | token 입력/연결 테스트 | token 값을 결과/로그에 표시 금지 |
| Approval required | approved run without approval token | ConfirmationModal + ApprovalTokenGate | 승인하고 실행, dry-run만 실행 | 무승인 `setup`/`agent-run` 금지 |
| Confirmation required | scaffold/setup/agent-run/advance/rollback/select-design/real writes | command summary, changed/planned files, risk badge | dry-run, confirm, cancel | primary CTA를 위험하게 숨기기 금지 |
| Dry-run result | `dry_run: true` command success | “계획/예상 변경” badge | 실제 실행, 수정, 취소 | 실제 완료처럼 표현 금지 |
| Success | command passed | ResultCard + changed_files + next_action | next recommended action | 성공 후 status refresh 누락 금지 |
| Partial/unavailable | adapter unavailable/tool missing | disabled card + 이유 + 대체 action | settings/check docs/retry | 없는 기능을 있는 것처럼 활성화 금지 |
| Secret/path blocked | `.env`/secret pattern | security warning + safe explanation | 입력 수정 | path/value preview 금지 |
| Real deploy blocked | non-dry-run deploy 시도 | deploy dry-run only 안내 | deploy-plan, CLI explicit 안내 | 웹에서 실제 deploy 버튼 활성화 금지 |

## B10. Claude Design 투입 전 체크리스트

| 체크 | 기준 | 상태 |
|---|---|---|
| source of truth 확인 | `docs/frontend-design-plan.md` 전체, 특히 1~10장과 부록 A/B | 필수 |
| route 수 고정 | `/`, `/workspace`, `/settings`만 사용 | 필수 |
| workspace 구조 고정 | Chat / Action / Evidence 3-pane, responsive 변형 포함 | 필수 |
| API 기능 누락 방지 | 1.2 F01~F49와 5장 매핑 확인 | 필수 |
| 디자인 엔진 노출 | brief/research/system/prompt/candidate/select/ingest/visual/component-map/edit 모두 포함 | 필수 |
| 안전 UX 포함 | token, approval, dry-run, `.env` block, real deploy disabled | 필수 |
| 상태 UX 포함 | loading/error/empty/blocked/auth/confirmation/success/partial | 필수 |
| 결과 패널 포함 | cards/tables/logs/previews/screenshot/score/component tree/run timeline | 필수 |
| 신규 기능 금지 | 플랜에 없는 backend/API/page 추가 금지 | 필수 |
| 톤앤매너 | 상세 brand/color/type은 확인 필요로 표시 | 확인 필요 |
| 프론트 스택 | React/Vite SPA 권장은 있으나 최종 확정 여부 확인 필요 | 확인 필요 |
| token 저장 정책 | session memory 기본 권장이나 최종 정책 확인 필요 | 확인 필요 |
| backend 추가 endpoint | streaming/job/safe artifact read/agent planner 도입 여부 확인 필요 | 확인 필요 |
| Claude Design 산출 형식 | wireframe, high-fidelity mock, component spec 중 무엇을 받을지 확인 필요 | 확인 필요 |

## B11. Claude Design에 우선 전달할 산출물 순서

| 우선순위 | 전달 산출물 | 이유 |
|---|---|---|
| 1 | B2 Claude Design 투입용 디자인 브리프 | 제품 방향/금지사항/화면 구조를 가장 짧게 고정한다. |
| 2 | B6 화면별 구조 명세 | `/`, `/workspace`, `/settings`의 화면 구조 흔들림을 막는다. |
| 3 | B4 카드/버튼/CTA 매핑표 | Claude Design이 실제 실행 카드와 CTA를 시각화할 수 있다. |
| 4 | B9 상태 규칙 | 로딩/오류/권한/확인 모달 누락을 막는다. |
| 5 | B3 기능별 UI 매핑 구현 요약 + 5장 전체 표 | backend command 누락을 최종 점검한다. |
| 6 | B8 API와 UI 연결표 | 구현자가 mock/API client를 바로 연결할 수 있다. |
| 7 | B10 체크리스트 | Claude Design 투입 직전/결과 검토 시 gate로 사용한다. |

## B12. Claude Design / 구현 전달 파일 패킷

이 섹션은 파일 전달 시 혼선을 막기 위한 패킷 정의다. 새 source of truth를 만들지 않고, 기존 파일의 역할만 구분한다.

| 우선순위 | 파일/범위 | 전달 대상 | 역할 | 해석 규칙 |
|---|---|---|---|---|
| 필수 1 | `docs/frontend-design-plan.md` 전체 | Claude Design, 구현자 | 최상위 source of truth | 제품 방향, 페이지 수, 기능 범위, API 연결, 상태 규칙은 이 문서를 따른다. |
| 필수 1-A | `docs/frontend-design-plan.md` B2 | Claude Design | 디자인 브리프 | Claude Design은 이 범위를 벗어난 기능/페이지/톤을 만들지 않는다. |
| 필수 1-B | `docs/frontend-design-plan.md` B6 | Claude Design, 구현자 | 화면별 구조 명세 | `/`, `/workspace`, `/settings` 구조를 고정한다. |
| 필수 1-C | `docs/frontend-design-plan.md` B4, B9 | Claude Design, 구현자 | CTA/state 규칙 | 카드, 버튼, 확인 모달, 로딩/오류/권한 상태를 그대로 반영한다. |
| 필수 1-D | `docs/frontend-design-plan.md` B3, 5장, B8 | 구현자 | 기능/API 연결 기준 | backend command와 daemon API 매핑 누락 방지용 기준이다. |
| 보조 | `AGENTS.md` | 구현자 | 작업/안전 지침 | 구현 시 프로젝트 지침과 금지사항을 따른다. |
| 보조 | `.ai-web/product.md`, `.ai-web/brand.md`, `.ai-web/content.md`, `.ai-web/ia.md` | Claude Design, 구현자 | 프로젝트 문맥 | 내용이 비어 있거나 약하면 임의 보강하지 말고 `확인 필요`로 둔다. |
| 보조 | `DESIGN.md`, `.ai-web/DESIGN.md` | Claude Design, 구현자 | 디자인 시스템 계약 placeholder | 현재 상세 색상/타이포/컴포넌트 토큰은 확정되지 않았다. Claude Design 결과를 반영하기 전까지 최종 visual spec으로 오해하지 않는다. |
| 보조 | `.ai-web/quality.yaml`, `.ai-web/stack.md` | 구현자 | 품질/스택 문맥 | 기존 값과 충돌하면 확인 필요로 표시한다. |

### 구현자가 이 패킷을 기반으로 시작하는 순서

| 순서 | 작업 | 기준 |
|---|---|---|
| 1 | `docs/frontend-design-plan.md` 1~10장, 부록 A/B를 읽고 기능 범위 고정 | source of truth |
| 2 | 프론트 앱 위치/스택 확정 여부 확인 | `apps/workbench/` React/Vite SPA는 권장, 최종 확정은 확인 필요 |
| 3 | `/`, `/workspace`, `/settings` route skeleton 생성 | 3장, B6 |
| 4 | daemon API client 작성 | 7.2, B8 |
| 5 | connection/status/workbench/runs read flow 구현 | 1.1, B8 |
| 6 | Chat / ActionCard / DynamicForm / Confirmation / ResultPanel 기본 컴포넌트 구현 | 4장, 6장, B4, B7, B9 |
| 7 | Design → Build/Preview → QA/Repair → Visual/Edit → Agent-run → Release tab 순으로 기능군 연결 | B3, 5장 |
| 8 | 위험 작업에 dry-run/approval/secret-path guard UI 적용 | 4.6, 7.3, B9 |
| 9 | 반응형/접근성/테스트 기준 적용 | 4.11, 9장 |
| 10 | 플랜에 없는 기능, route, 실제 deploy, raw shell UI는 추가하지 않음 | B10 |
