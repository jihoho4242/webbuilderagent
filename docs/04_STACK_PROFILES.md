# 04. 스택 프로필 정책

## 1. 원칙

스택은 구현 직전에 즉흥적으로 고르지 않는다. Phase 0에서 웹 유형과 릴리즈 범위를 자른 뒤, Phase 0.5에서 스택 프로필을 확정한다.

```text
웹 유형 + 릴리즈 범위 + 품질 기준
-> 스택 프로필 추천
-> Gate 1A 승인
-> aiweb init --profile <A|B|C|D>
-> canonical scaffold target 기록
-> Phase 6 task packet에서 실제 app scaffold 생성
```

각 Profile은 반드시 다음 네 항목을 가진다.

- `canonical default`: `aiweb init --profile`이 기본으로 기록하는 확정 스택
- `allowed override`: 허용되는 변형
- `when to override`: 변형을 허용하는 조건
- `scaffold target`: Phase 6 task packet이 만들어야 하는 구체 app scaffold 목표. `aiweb init --profile`은 이 target을 기록만 한다

`Astro or Next`, `Hotwire or React islands`, `Rails API or Workers API`처럼 scaffold 시점에 모호한 표현은 금지한다. 모호한 선택지는 canonical default가 아니라 allowed override에 기록한다.

## 2. Profile A — Product App

### canonical default

```text
Rails 8
PostgreSQL
Hotwire/Turbo
Tailwind
Kamal
Cloudflare DNS/CDN/WAF
```

### scaffold target

`aiweb init --profile A`는 다음을 목표 scaffold로 설정한다.

```text
Rails 8 app
PostgreSQL database config
Hotwire/Turbo enabled
Tailwind installed
Kamal deploy skeleton
Cloudflare DNS/CDN/WAF deploy notes in .ai-web/deploy.md
```

### allowed override

- React islands for isolated highly interactive widgets
- Solid Queue/Cache/Cable tuning for production workloads
- Redis only when the product requirement needs it
- S3/R2-compatible object storage for uploads
- Alternative deploy target only if Kamal is not viable

### when to override

- 사용자가 rich dashboard나 canvas-level interaction을 요구하는 경우 React islands 허용
- 파일 업로드/이미지 처리 요구가 있는 경우 R2/S3 추가
- 조직의 기존 hosting 표준이 Kamal과 맞지 않는 경우 deploy override 허용

### 적합

- 로그인
- 관리자
- 결제
- 예약/신청
- CRUD가 많은 서비스
- SaaS
- 내부 운영 도구

### 주의

- 단순 랜딩/브랜드 사이트에는 무거울 수 있음
- edge-first 배포와는 별도 전략 필요

## 3. Profile B — Edge Marketing

### canonical default

```text
Astro
Cloudflare Pages
Tailwind
Cloudflare Pages Functions for forms only when needed
```

### scaffold target

`aiweb init --profile B`는 다음을 목표 scaffold로 설정한다.

```text
Astro static/SSR-capable marketing site
Tailwind installed
Cloudflare Pages config notes
Optional functions/ endpoint for contact forms
Turnstile/spam-protection notes when public form exists
```

### allowed override

- Next.js only when React-heavy interactivity is required
- Cloudflare Workers instead of Pages Functions when API surface grows
- Headless CMS integration when non-developer editing is required
- D1/KV only for small edge-native state

### when to override

- 단순 marketing site를 넘어 client-side app 수준의 interactivity가 필요할 때 Next.js 허용
- form 외 API가 2개 이상 필요하거나 background workflow가 필요할 때 Workers 허용
- 운영자가 콘텐츠를 자주 수정해야 할 때 CMS 허용

### 적합

- 랜딩페이지
- 브랜드 사이트
- 문의 폼
- 캠페인 사이트
- 빠른 글로벌 응답

### 주의

- 복잡한 DB/admin 기능은 Profile A 또는 C로 이동
- form spam/security 정책을 반드시 설계해야 함

## 4. Profile C — Hybrid

### canonical default

```text
Rails 8 main app
PostgreSQL
Hotwire/Turbo
Tailwind
Kamal
Cloudflare DNS/CDN/WAF
Cloudflare R2 for public assets/uploads when needed
```

Profile C의 canonical default는 **Rails main app + Cloudflare edge services**다. Cloudflare frontend + Rails API 방식은 allowed override로만 허용한다.

### scaffold target

`aiweb init --profile C`는 다음을 목표 scaffold로 설정한다.

```text
Rails 8 app as primary application
PostgreSQL database config
Hotwire/Turbo frontend baseline
Tailwind installed
Kamal deploy skeleton
Cloudflare DNS/CDN/WAF notes
Optional R2 storage notes for uploads/static assets
API boundary notes only where external frontend is explicitly approved
```

### allowed override

- Cloudflare Pages frontend + Rails API backend
- Astro marketing frontend + Rails app subdomain
- R2 for media-heavy sites
- Workers for edge redirects, geolocation, lightweight webhook fanout

### when to override

- SEO marketing site와 authenticated app을 명확히 다른 배포 단위로 나눠야 할 때
- marketing team이 frontend를 독립적으로 배포해야 할 때
- edge routing/media workload가 Rails app과 분리되어야 할 때

### 적합

- SEO와 앱 기능이 모두 중요
- 마케팅 사이트 + 로그인 앱
- 콘텐츠와 transaction이 섞인 제품
- 파일/이미지 자산과 app workflow가 함께 있음

### 주의

- repo 구조와 deploy pipeline이 복잡해짐
- API/auth boundary 문서가 필수

## 5. Profile D — Content/SEO Site

### canonical default

```text
Astro
MDX / Content Collections
Cloudflare Pages
Tailwind
sitemap
RSS
```

### scaffold target

`aiweb init --profile D`는 다음을 목표 scaffold로 설정한다.

```text
Astro content site
MDX/Content Collections enabled
Tailwind installed
Cloudflare Pages config notes
sitemap generation
RSS feed generation
SEO metadata template
```

### allowed override

- Headless CMS when non-developer editing is required
- Pagefind or similar static search for content-heavy sites
- Workers function for newsletter/contact forms
- i18n routing when multilingual SEO is required

### when to override

- 글/페이지를 비개발자가 자주 수정해야 할 때 CMS 허용
- 콘텐츠가 많고 검색 UX가 필요한 경우 static search 허용
- 글로벌 SEO가 목표인 경우 i18n override 허용

### 적합

- 블로그
- 지식 사이트
- 포트폴리오
- 로컬 비즈니스 SEO
- 병원/학원/카페/서비스 소개

### 주의

- 동적 기능은 Workers/API 추가 필요
- 로그인/관리자/결제 요구가 생기면 Profile A 또는 C로 이동

## 6. 선택 매트릭스

| 조건 | 추천 |
|---|---|
| DB 없음, SEO 중요 | Profile D |
| 랜딩 + 문의 폼 | Profile B |
| 콘텐츠 중심 + 블로그/RSS | Profile D |
| 로그인/관리자 필요 | Profile A |
| 결제/예약/신청 workflow | Profile A |
| 마케팅 사이트 + 앱 dashboard | Profile C |
| 빠른 MVP, 데이터 적음 | Profile B |
| 운영 기능 많음 | Profile A |
| Rails app이 필요하지만 CDN/R2도 중요 | Profile C |

## 7. `aiweb init --profile <A|B|C|D>` 계약

`aiweb init --profile`은 다음을 반드시 수행한다.

1. `state.yaml`의 `implementation.stack_profile`에 선택 profile 기록
2. `state.yaml`의 `implementation.scaffold_target`에 canonical scaffold target 기록
3. `.ai-web/stack.md`에 canonical default, allowed override, when to override, scaffold target 기록
4. `.ai-web/deploy.md`에 profile별 deploy baseline 기록
5. Profile이 없으면 scaffold를 만들지 않고 Phase 0.5에서 block

## 8. 스택 변경 정책

Gate 1A 승인 후 스택 변경은 큰 변경으로 간주한다.

스택 변경 시 무효화:

- `.ai-web/stack.md`
- `.ai-web/deploy.md`
- `.ai-web/data.md` 일부
- `.ai-web/security.md` 일부
- 구현 task packet 전체
- QA checklist 일부

`aiweb rollback --to phase-0.5`가 필요하다.



## 8. Dependency and version lifecycle

Scaffold 전에는 다음을 반드시 수행한다.

- 현재 공식 install/scaffold 명령 확인
- major version pin 기록
- dependency decision을 `.ai-web/decisions.md`에 기록
- license/security advisory 확인
- upgrade path 기록
- package lock checksum snapshot 기록

### Rails Profile A/C version lock fields

Profile A/C의 `stack.md`는 다음을 비워둘 수 없다.

- Ruby version
- Rails minor: 8.0.x 또는 8.1.x
- PostgreSQL version
- Kamal major version
- Tailwind integration
- Asset pipeline: Propshaft 기본
- Jobs: Solid Queue process command 또는 override
- Cable: Solid Cable 또는 external adapter
- Cache: Solid Cache 또는 external adapter
- Reverse proxy: Thruster/Kamal proxy notes

## 9. Cloudflare Pages / Workers deploy target

Profile B/D MVP 기본값은 Cloudflare Pages static hosting일 수 있다. 단, profile identity를 Pages에 고정하지 않는다. 다음 조건이면 Cloudflare Workers static assets를 allowed default upgrade로 허용한다.

- SSR/API/observability가 필요함
- Durable Objects, Cron, Queues, Workflows 등 Workers-first 기능이 필요함
- Pages Functions보다 Worker script 경계가 명확함

`deploy.md`에는 다음을 기록한다.

- `target: pages|workers`
- `compatibility_date`
- `wrangler_config_path`
- `assets.directory`
- `pages_build_output_dir` only when target=pages
- `functions_mode: none|pages_functions|worker_script`
