# 14. Adapter Contracts

AI Web Director는 특정 도구에 잠기지 않는다. 하지만 “교체 가능”하려면 각 외부 도구가 같은 최소 계약을 만족해야 한다. 이 문서는 구현 에이전트, 이미지/디자인 생성, Browser QA, 배포 adapter의 공통 계약을 닫는다.

## 1. Adapter registry

`state.yaml`과 `stack.md`는 다음 adapter registry를 기록한다.

```yaml
adapters:
  implementation_agent:
    provider: codex
    command: "codex"
    model: "repo-default"
    permissions: "edit"
    instruction_file: "AGENTS.md"
    network_allowed: false
    mcp_servers_allowed: []
    command_timeout_minutes: 30
  image_generation:
    provider: openai
    tool: "gpt-image"
    model: "gpt-image-2"
    model_snapshot: null
    api_surface: "image_api"
    usage_mode: "subscription_usage"
    meter_cost: false
  browser_qa:
    provider: codex_browser
    allowed_hosts: ["localhost", "127.0.0.1"]
    evidence_schema: "qa-result-v1"
    file_access: "workspace_only"
  deploy:
    provider: manual
    target: null
    config_files: []
```

## 2. Implementation Agent Adapter

### Required inputs

- working directory
- task packet path
- instruction files: `AGENTS.md`; optional `CLAUDE.md` mapping
- allowed file scope
- permission mode
- network policy
- command timeout
- verification commands

### Required output report

```md
## Changed Files
## Commands Run
## Tests Passed
## Not Tested
## QA Evidence
## Risks
## Follow-up Tasks
```

### Defaults

- `may_commit: false` unless explicitly enabled.
- implementation agents must not expand scope beyond the task packet.
- any need for new dependency creates a dependency decision record before install.

## 3. Image / Design Generation Adapter

Design candidates must record provenance so `DESIGN.md` extraction is reproducible.

Required fields per candidate:

```yaml
provider: openai|anthropic|manual
tool: gpt-image|claude-design|manual-reference
model: "gpt-image-2"
model_snapshot: null
api_surface: image_api|responses_api|claude_design_ui|manual
prompt: ""
revised_prompt: ""
input_assets:
  - path: ""
    rights_status: user_owned|licensed|generated|unknown
output_assets:
  - path: ""
    export_format: png|jpg|webp|svg|html|other
license_or_terms_note: ""
design_extraction_notes: ""
```

Rules:

- generated image is visual reference only, never direct code spec.
- unknown asset rights block Gate 2 unless explicitly accepted as non-release reference.
- design generations must respect `quality.budget.max_design_generations_total` (default 10).
- GPT Pro/subscription-connected image generation uses `usage_mode: subscription_usage` and is not counted as API cost by default.
- API metered image generation must set `meter_cost: true` and use budget guards.

## 4. Browser QA Adapter

### Required capabilities

- `navigate(url)`
- `snapshot/dom_state()`
- `screenshot(path)`
- `click(selector|role|text)`
- `type(selector, text)`
- `set_viewport(width, height)`
- `capture_console()`
- `capture_network_errors()`
- `export_result_json(schema_version)`

### Security defaults

- localhost-only unless `allowed_hosts` is configured.
- no unrestricted `file://` access.
- auth profile reuse must be explicit.
- secrets must be redacted from screenshots/logs.
- evidence paths must stay under `.ai-web/qa/`.

### Required evidence

- viewport-specific screenshot
- step log
- console/network error summary
- result JSON validating against `qa-result.schema.json`

## 5. Deploy Adapter

### Common fields

```yaml
deploy:
  provider: cloudflare_pages|cloudflare_workers|kamal|manual
  target: pages|workers|vps|manual
  build_command: ""
  output_dir: ""
  config_files: []
  environment_names: []
  rollback_command: ""
  rollback_dry_run_result: ""
```

### Cloudflare Pages / Workers distinction

Profile B/D defaults may use Cloudflare Pages for MVP static hosting, but the deploy adapter must allow Workers static assets when SSR/API/observability/Durable Objects/Cron/Workers-first features are needed.

Required Cloudflare fields:

- `target: pages|workers`
- `compatibility_date`
- `wrangler_config_path`
- `assets.directory`
- `pages_build_output_dir` only when `target=pages`
- `functions_mode: none|pages_functions|worker_script`

### Kamal / Rails fields

- Ruby version
- Rails minor version
- PostgreSQL version
- Kamal major version
- image registry policy
- app server/process model
- DB migration rollback note
- env var names, never values

## 6. Adapter failure handling

| Failure | Failure code | Default action |
|---|---|---|
| metered provider quota/cost limit | F-BUDGET | block and ask for explicit budget increase |
| QA runtime exceeds 60m | F-QA-TIMEOUT | self-diagnose, create fix packet, rerun QA |
| browser cannot access target | F-QA | fix local server/precondition or swap adapter |
| deploy credentials missing | F-DEPLOY | Phase 11 block |
| unsafe dependency/license | F-SUPPLY-CHAIN | Phase 5/6 rollback |
| unknown image/content rights | F-LEGAL-CONTENT | Phase 1.5 or Gate 2 block |
