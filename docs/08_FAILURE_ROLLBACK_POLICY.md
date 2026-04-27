# 08. 실패와 Rollback 정책

## 1. 원칙

실패는 단순히 “수정”하지 않는다. 실패 원인이 문서/디자인/구현/QA 중 어디에 있는지 분류한 뒤 올바른 Phase로 되돌린다.

## 2. 실패 분류

| 코드 | 유형 | 예시 | 기본 처리 |
|---|---|---|---|
| F-PRODUCT | 제품 방향 실패 | 타깃이 바뀜 | Phase 1 rollback |
| F-SCOPE | 범위 실패 | 1차 릴리즈 과대 | Phase 0 rollback |
| F-STACK | 스택 실패 | DB 필요하지만 static 선택 | Phase 0.5 rollback |
| F-CONTENT | 콘텐츠 실패 | 카피가 설득력 없음 | Phase 1.5 rollback |
| F-IA | UX/IA 실패 | flow가 헷갈림 | Phase 2 rollback |
| F-DATA | 데이터 설계 실패 | admin 권한 누락 | Phase 2.5 rollback |
| F-DESIGN | 디자인 실패 | 브랜드 톤 불일치 | Phase 3/3.5 rollback |
| F-DESIGN-SYSTEM | 디자인 시스템 실패 | token 부족 | Phase 4 rollback |
| F-IMPLEMENTATION | 구현 실패 | 버그/빌드 실패 | fix packet |
| F-QA | QA 실패 | 모바일 깨짐 | fix packet 또는 원인 Phase rollback |
| F-DEPLOY | 배포 실패 | env/도메인 문제 | Phase 11 fix |
| F-SECURITY | 보안 실패 | auth/privacy/secrets/XSS | Phase 2.5 rollback 또는 security fix packet |
| F-ABUSE | 악용/스팸/프롬프트 인젝션 | form abuse, malicious reference | Phase 2.5 rollback |
| F-SUPPLY-CHAIN | 의존성/생성 코드 위험 | unsafe package/license | Phase 5/6 rollback |
| F-LEGAL-CONTENT | 저작권/claim/규제 콘텐츠 | 무단 이미지/과장 claim | Phase 1.5 rollback |
| F-BUDGET | metered adapter 비용 초과 | API 과금형 모델/도구 한도 초과 | scope 축소 또는 budget 변경 |
| F-QA-TIMEOUT | QA 시간 초과 | 60분 초과, 무한 로딩, test precondition 누락 | 자체 진단 → fix packet → QA 재실행 |

## 3. Rollback 방식

rollback은 다음을 수행한다.

1. 현재 실패를 `.ai-web/decisions.md`에 기록
2. 영향받는 artifacts를 `invalidated`로 표시
3. target Phase로 이동
4. 필요한 문서만 재생성
5. downstream task/QA를 재생성

## 4. Snapshot 정책

중요 지점에서 snapshot을 만든다.

- Gate 1A 승인 후와 Gate 1B 승인 후
- Gate 2 승인 후
- Gate 3 승인 후
- 배포 전

snapshot에는 다음을 포함한다.

- `.ai-web/state.yaml`
- 모든 approved artifacts
- current task/QA result
- 주요 decision log

## 5. Invalidation 예시

### DESIGN.md 변경

무효화:

- UI primitive task
- Golden Page QA result
- page-level screenshots

재검증:

- Phase 7 component QA
- Phase 8 Golden Page QA

### Stack 변경

무효화:

- scaffold task
- data/security/deploy docs
- implementation tasks

재진입:

- Phase 0.5

### Content 변경

무효화:

- affected page tasks
- SEO QA
- screenshot evidence 일부

재진입:

- Phase 1.5 또는 Phase 2

## 6. 실패 보고 형식

```md
# Failure Report

## Summary

## Failure Type

## Evidence

## Root Cause

## Affected Artifacts

## Recommended Action

## Rollback Target

## Fix Task Packet
```

## 7. 금지

- QA 실패를 기록 없이 수정 금지
- Gate rejection 후 다음 Phase 진행 금지
- 문서 원인 실패를 코드 수정으로만 덮기 금지
- 스택 변경 후 기존 task packet 재사용 금지



## 8. 실제 코드/배포 snapshot

Snapshot은 `.ai-web`만 보호하지 않는다. 중요 지점 snapshot에는 다음을 포함한다.

- git commit hash / branch 또는 no-git marker
- working tree diff status
- package lock checksum
- DB migration version
- deploy version/build id
- env var names, never values
- generated asset manifest
- rollback command dry-run result

`aiweb rollback --dry-run`은 state mutation 없이 invalidation 대상, 복원 대상, 예상 삭제/변경 파일, deploy rollback command를 출력해야 한다.


## 9. QA timeout recovery

QA가 60분을 넘기면 `F-QA-TIMEOUT`으로 분류한다. 기본 처리 순서는 다음이다.

1. 현재 server/build/browser 로그와 screenshot을 저장한다.
2. timeout 원인을 precondition, selector, runtime, network, adapter, checklist 과다 중 하나로 분류한다.
3. fix packet을 생성하고 implementation adapter로 수정한다.
4. QA를 재실행한다.
5. 같은 task의 `F-QA-TIMEOUT` open failure가 `max_qa_timeout_recovery_cycles`에 도달하면 다음 `qa-report`는 budget-blocked 계열로 실패하며 새 timeout open failure/fix packet을 만들지 않는다.
