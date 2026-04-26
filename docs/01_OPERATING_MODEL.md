# 01. 운영 모델

## 1. 핵심 운영 방식

AI Web Director는 다음 루프로 동작한다.

```text
현재 Phase 확인
-> 필요한 입력 확인
-> 산출물 생성/갱신
-> 통과 조건 검사
-> 승인 Gate 확인
-> 다음 Phase 진행
-> 실패 시 fix packet 또는 rollback
```

## 2. 역할 분리

### 2.1 사용자

사용자는 다음만 담당한다.

- 아이디어 제공
- 핵심 답변 제공
- Gate 1A/1B/2/3/4 승인 판단
- 디자인 취향 선택
- 배포 전 최종 승인

사용자가 매번 직접 하지 않아야 하는 것:

- 제품 문서 작성
- 스택 비교
- 디자인 프롬프트 작성
- 구현 task 분해
- QA 체크리스트 작성
- 오류 재현 절차 작성

### 2.2 AI Web Director

Director는 다음을 담당한다.

- 질문 생성과 요구사항 정리
- 웹 유형과 릴리즈 범위 분류
- 품질 계약 생성
- 스택 프로필 추천
- 제품/브랜드/콘텐츠/IA/데이터/보안 문서 생성
- 디자인 프롬프트 생성
- 디자인 후보 평가
- `DESIGN.md` 변환
- task packet 생성
- QA checklist 생성
- Phase/Gate/rollback 판단

### 2.3 GPT Image 2 / Claude Design

역할:

- visual mood 탐색
- hero/section 시안 생성
- 브랜드 톤 후보 생성
- high-fidelity 방향 후보 생성

금지:

- 이미지를 그대로 코드 스펙으로 삼기
- 디자인 후보를 검증 없이 구현하기
- 후보별 token/component 추출 없이 구현하기

### 2.4 Codex / Claude Code

역할:

- repo bootstrap
- 프론트엔드/백엔드 구현
- 테스트 작성
- 리팩터링
- QA 실패 수정

제약:

- task packet 없이 대규모 구현 금지
- `DESIGN.md` 위반 금지
- `quality.yaml` 기준 무시 금지
- 새 컴포넌트 variant 남발 금지

### 2.5 Codex App/CLI Browser QA Adapter

Computer Use는 독립 주체가 아니라 Codex App/CLI가 가진 브라우저 조작/검증 능력으로 취급한다.

역할:

- `.ai-web/qa/current-checklist.md`를 읽는다.
- 실제 브라우저에서 사용자 흐름을 확인한다.
- screenshot/evidence를 저장한다.
- 결과를 `.ai-web/qa/results/*.json`으로 남긴다.
- 실패를 `.ai-web/tasks/fix-*.md`로 변환한다.

## 3. 승인 게이트

Gate 1은 기존 단일 승인에서 **Gate 1A / Gate 1B**로 분리한다. 이유는 스택 승인 시점에는 아직 제품/콘텐츠/IA/데이터/보안 문서가 완성되지 않기 때문이다.

### Gate 1A. 범위 / 품질 계약 / 스택 승인

시점: Phase 0.5 이후

확인:

- 웹 유형이 맞는가
- 1차 릴리즈 범위가 과하지 않은가
- `quality.yaml`의 품질/예산 기준이 현실적인가
- 추천 스택 프로필 A/B/C/D가 적절한가
- `aiweb init --profile`이 기록할 scaffold target이 명확한가

통과 후:

- 제품/브랜드/콘텐츠/IA/데이터/보안 상세 문서 작성 진행

### Gate 1B. 제품 / 콘텐츠 / IA / 데이터 / 보안 승인

시점: Phase 2.5 이후

확인:

- 제품 정의와 primary conversion이 맞는가
- 콘텐츠 출처/claim/SEO 방향이 안전한가
- IA와 모바일 흐름이 검증 가능하게 정의됐는가
- 로그인/결제/관리자/DB/API 필요 여부가 맞는가
- security/privacy/threat model이 충분한가

통과 후:

- 디자인 취향 캘리브레이션과 디자인 후보 생성 진행

### Gate 2. 디자인 방향 승인

확인:

- 디자인 후보의 브랜드 톤이 맞는가
- 사용자 취향과 맞는가
- 구현 가능성이 충분한가
- 모바일 구조로 확장 가능한가
- 템플릿 느낌이 과하지 않은가
- 디자인 asset/source provenance가 기록됐는가

통과 후:

- `DESIGN.md`, token, component rule 생성

### Gate 3. Golden Page + Golden Flow 승인

확인:

- 대표 페이지 완성도가 `quality.yaml` 기준을 통과하는가
- 핵심 사용자 흐름이 정해진 step 수 안에서 작동하는가
- desktop/mobile evidence가 존재하는가
- 나머지 페이지로 확장 가능한가
- 디자인 시스템이 흔들리지 않는가

통과 후:

- 페이지별/기능별 반복 구현

### Gate 4. 배포 전 최종 승인

확인:

- QA checklist 통과
- desktop/mobile 확인
- 접근성/SEO/성능 최소 기준 통과
- 환경변수/도메인/모니터링/rollback dry-run 준비
- critical/high open failure 없음
- accepted risk가 있으면 owner/mitigation/expiry가 있음

통과 후:

- 배포 또는 배포 handoff

### Gate approval metadata

모든 Gate approval은 다음을 기록한다.

- `approved_by`
- `approved_at`
- `approval_scope`
- `approved_artifact_hashes`
- `accepted_risks`

승인된 artifact hash가 바뀌면 해당 Gate는 invalidated가 된다.

## 4. 닫힌 코어와 열린 실행

구현 전에 닫아야 하는 것:

- Phase 정의
- Gate 정의
- `.ai-web` 구조
- 품질 기준
- 문서 산출물 목록
- task packet 형식
- QA result 형식
- rollback 정책
- CLI MVP 명령

구현 중 확장 가능한 것:

- 디자인 preset
- 산업별 content preset
- stack bootstrap 상세
- deploy adapter
- browser adapter
- provider adapter

## 5. 운영 불변식

- `state.yaml`이 현재 Phase의 source of truth다.
- `quality.yaml`이 완성도 판단 기준이다.
- `DESIGN.md` 없이 UI 구현 Phase에 진입할 수 없다.
- `stack.md` 없이 project bootstrap을 시작할 수 없다.
- Gate approval 없이 다음 major Phase로 넘어갈 수 없다. 승인 대기 상태는 현재 Phase에서 `blocked`로 남는다.
- QA 실패는 반드시 기록되며, fix packet 또는 rollback decision을 만든다.

