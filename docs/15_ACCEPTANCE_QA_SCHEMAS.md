# 15. Acceptance, QA, Risk, and Budget Contracts

이 문서는 “완벽”이라는 표현을 실행 가능한 품질 계약으로 바꾼다. AI Web Director의 목표는 추상적 완벽이 아니라 **quality-contract-compliant website**다.

## 1. 기본 품질 기준

모든 프로젝트는 `quality.yaml`에서 아래 기본값을 수용하거나 명시적으로 override한다.

```yaml
responsive:
  viewports:
    - { width: 375, height: 812, name: mobile }
    - { width: 768, height: 1024, name: tablet }
    - { width: 1440, height: 900, name: desktop }
  no_horizontal_scroll: blocker
accessibility:
  target: WCAG_2_2_AA
  keyboard_navigation: blocker
  color_contrast: blocker
performance:
  lighthouse_mobile_min: 85
  lighthouse_desktop_min: 90
  lcp_ms_max: 2500
seo:
  required: [title, description, canonical, og, sitemap_if_public_content]
security:
  secrets_in_env_only: blocker
  form_spam_protection: required_if_public_form
```

## 2. Acceptance matrix format

각 milestone과 task packet은 다음 형식으로 검증 기준을 가져야 한다.

```md
| ID | Given | When | Then | Evidence | Blocking |
|---|---|---|---|---|---|
| AC-001 | user opens 375px viewport | homepage loads | no horizontal scroll | screenshot + result JSON | yes |
```

금지 표현:

- “자연스럽다”
- “예쁘다”
- “적당히 반응형”
- “좋은 UX”

허용 표현:

- primary CTA visible above fold at 375px and 1440px
- primary flow completes in <= 5 user actions
- no `critical` or `high` open failures
- screenshot evidence exists for each required viewport

## 3. QA result schema requirements

모든 `.ai-web/qa/results/*.json`은 `docs/templates/qa-result.schema.json`을 통과해야 한다.

Required fields:

- `schema_version`
- `task_id`
- `status: pending|passed|failed|blocked`
- ISO-like `started_at` / `finished_at`
- `duration_minutes` and `timed_out`
- `environment.url`
- `environment.browser`
- `environment.viewport.width` / `height`
- `checks[].id`
- `checks[].category`
- `checks[].severity: critical|high|medium|low|info`
- `checks[].status: passed|failed|blocked|skipped`
- `checks[].evidence[]`
- `recommended_action: advance|create_fix_packet|rollback|accept_risk|none`

## 4. Open failure derivation

`qa.open_failures[]` in `state.yaml` is derived from QA result JSON checks where:

- `status` is `failed` or `blocked`
- severity is `critical`, `high`, or `medium`
- no valid accepted risk references that check

Gate 4 blocks when any `critical` or `high` open failure remains.

## 5. Accepted risk contract

Accepted risks are allowed only when they are explicit and bounded.

```yaml
accepted_risks:
  - id: "risk-001"
    source_check_id: "mobile-lcp"
    severity: medium
    owner: "user"
    rationale: "Known large hero video for launch campaign"
    mitigation: "Replace with compressed poster after launch"
    expires_at: "2026-05-15"
    release_blocker: false
```

Rules:

- `critical` risks cannot be accepted for public release unless the gate decision is `blocked` or `internal_only`.
- `high` risks require owner, mitigation, and expiry.
- risks without owner or expiry are invalid.

## 6. Budget contract

```yaml
budget:
  cost_mode: "subscription_usage"
  meter_model_cost: false
  max_model_cost_usd: null
  max_design_generations_total: 10
  max_design_candidates: 10
  max_regeneration_rounds: 10
  max_qa_runtime_minutes: 60
  qa_timeout_action: "self_diagnose_fix_rerun"
  max_qa_timeout_recovery_cycles: 3
  require_user_approval_above_usd: null
```

Budget is a guardrail, not a billing system. 이 프로젝트의 기본값은 GPT Pro/구독 사용량으로 이미지 생성을 연결하는 전제이므로 model/image cost는 기본 집계하지 않는다. API metered adapter로 바꾸는 경우에만 `meter_model_cost: true`와 `max_model_cost_usd`를 설정한다.

Design generation은 비용보다 **품질 탐색 폭과 무한 재생성 방지**가 목적이므로 총 10회까지 허용한다.

QA는 1회 실행이 60분을 넘기면 단순 실패로 멈추지 않고 `F-QA-TIMEOUT`으로 기록한 뒤 자체 진단 → fix packet 생성/수정 → 재실행 루프에 들어간다. 단, 같은 task의 `F-QA-TIMEOUT` open failure가 `max_qa_timeout_recovery_cycles`에 도달하면 다음 `qa-report`는 budget-blocked 계열로 실패하며 새 open failure/fix packet을 만들지 않는다.

## 7. Gate 4 release recommendation rules

| Condition | Recommendation |
|---|---|
| all required checks pass, rollback dry-run exists, no blocking risk | Approve Gate 4 |
| only low/medium accepted risks with owner/expiry | Approve with accepted risks |
| critical/high open failure | Block release |
| missing deploy rollback | Block release |
| missing env/DNS/monitoring plan | Block release |

## 8. Minimum automated test suite

- valid initial `state.yaml` passes schema validation
- unknown top-level key fails
- invalid phase string fails
- Phase 3.5 with one candidate blocks
- selected candidate not in candidate list blocks
- Gate 2 pending blocks Phase 4
- QA result with failed critical check blocks Gate 4
- accepted risk without owner/expiry fails
- approved artifact hash drift invalidates gate
- rollback changes invalidate downstream task/QA evidence


## 9. QA timeout recovery loop

QA가 60분을 초과하면 다음 루프를 실행한다.

```text
QA timeout > 60m
-> capture current logs/screenshots/state
-> classify timeout cause
-> create F-QA-TIMEOUT report
-> generate fix packet
-> apply fix through implementation adapter
-> rerun QA
-> repeat up to max_qa_timeout_recovery_cycles
```

Timeout cause 분류:

- local server did not start
- test precondition missing
- selector/wait condition invalid
- infinite loading / network stall
- build/runtime error
- QA checklist too broad
- adapter/browser failure

Timeout recovery는 사용자에게 매번 묻지 않는다. 같은 task의 timeout open failure가 recovery cap에 도달하거나 scope/architecture 변경이 필요할 때만 blocker로 보고한다.
