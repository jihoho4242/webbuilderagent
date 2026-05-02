# Expert Webbuilder Upgrade Plan

This document records the upgrade direction for turning AI Web Director from a phase-driven website builder into an expert-feeling web app builder that can interpret intent, make product decisions, preview work, and verify that the result matches the requested experience.

## 1. Problem Diagnosis

The current system has a strong process skeleton, but the user experience can feel like a scripted state machine.

Observed gaps:

- The MVP scope is still biased toward static/content/SEO sites, landing pages, brand sites, and simple forms.
- The initial interview path writes project artifacts, but many outputs remain TODO-driven instead of expert-interpreted.
- Quality checks are mostly generic: responsive layout, console errors, metadata, accessibility, and CTA placement.
- The builder does not yet enforce semantic fit, such as "this must be a conversational stock assistant app, not a product landing page."
- The user cannot see an expert making product decisions, critiquing the result, and iterating inside a live preview loop.

The key failure mode is not only weak generation. It is weak intent preservation.

## 2. External Reference Patterns

Reference tools and projects suggest the following patterns.

| Reference | Useful pattern | What AI Web Director should adopt |
| --- | --- | --- |
| Lovable | Plan mode, agent mode, visual edits, browser testing | Separate planning from execution, show active work, support visual/local edits, verify in browser |
| bolt.diy | Local app generation, live preview, terminal/file workflow, provider flexibility | Provide an integrated build surface with preview, logs, files, and task state |
| Dyad | Local-first, BYOK, no lock-in, app ownership | Keep generated projects local and user-owned; avoid platform lock-in assumptions |
| GitHub Spec Kit | Spec-driven development | Convert user intent into a stable spec before implementation |
| Onlook / OpenUI | Visual UI editing and UI generation references | Add selectable UI regions and component-aware edits |
| E2B Fragments | Sandboxed preview and generated app execution | Treat preview/runtime isolation as a first-class adapter layer |
| Playwright MCP / browser-use | Browser automation for agents | Use real browser interaction for QA, screenshots, and regression evidence |
| OpenHands | Agentic coding loop with terminal/browser/code surfaces | Make the builder's actions observable and recoverable |

Reference links:

- Lovable Plan Mode: https://docs.lovable.dev/features/plan-mode
- Lovable Agent Mode: https://docs.lovable.dev/features/agent-mode
- Lovable Browser Testing: https://docs.lovable.dev/features/browser-testing
- bolt.diy: https://github.com/stackblitz-labs/bolt.diy
- Dyad: https://github.com/dyad-sh/dyad
- GitHub Spec Kit: https://github.com/github/spec-kit
- Onlook: https://github.com/onlook-dev/onlook
- OpenUI: https://github.com/wandb/openui
- E2B Fragments: https://github.com/e2b-dev/fragments
- Playwright MCP: https://github.com/microsoft/playwright-mcp
- OpenHands: https://github.com/All-Hands-AI/OpenHands

## 3. Target Experience

The builder should feel like a web-making expert sitting next to the user.

Target behavior:

1. Interpret the user's request, including what the user did not explicitly spell out.
2. Detect the product archetype before generating anything.
3. Name likely misunderstandings and prevent them.
4. Produce a first-screen contract that preserves the core product intent.
5. Build a working preview quickly.
6. Inspect the preview with browser automation.
7. Critique the result against the original intent.
8. Iterate until the result is usable, not merely present.

Example:

For "주비서, a conversational domestic stock assistant," the builder must conclude:

- This is a web app, not a landing page.
- The first screen must be a chat console.
- Stock quote/status, AI response, order preview, and safety lock state must be visible.
- Real account access, tokens, approval keys, and real order execution must be absent.
- QA must fail if the screen is hero/CTA-first or lacks a chat input.

## 4. Proposed Architecture

### 4.1 Intent Classifier

Add an intent classification artifact:

`.ai-web/intent.yaml`

Recommended fields:

```yaml
archetype: chat-assistant-webapp
surface: app
not_surface: landing-page
primary_user: individual domestic stock investor
primary_interaction: ask stock questions in chat
must_have_first_view:
  - chat_input
  - ai_answer_panel
  - stock_status_panel
  - order_preview
  - safety_lock_reason
must_not_have:
  - real_broker_order_execution
  - real_account_token
  - landing_page_hero_as_primary_experience
semantic_risks:
  - mistaking app UI for marketing site
  - implying investment advice without safety framing
  - showing real trading capability
```

This file becomes the source of truth for downstream product, IA, design, implementation, and QA.

### 4.2 First View Contract

Add:

`.ai-web/first-view-contract.md`

Purpose:

- Define what the user must see without scrolling.
- Define the main interaction available immediately.
- Define disallowed first-screen patterns.
- Define mobile and desktop expectations.

For app-like requests, this contract is more important than sitemap depth.

### 4.3 Expert Brief Builder

Replace TODO-heavy interview output with an expert interpretation layer.

The builder should generate:

- What the user is actually asking for.
- What common wrong interpretation must be avoided.
- What the first usable version should contain.
- What will be mocked, blocked, or excluded for safety.
- What proof will show the build is correct.

### 4.4 Mode Split

Introduce clear operating modes:

| Mode | Purpose |
| --- | --- |
| Plan Mode | Interpret intent, produce contracts, define QA criteria |
| Build Mode | Generate code, run dev server, inspect preview |
| Visual Edit Mode | Modify selected UI regions and components |
| QA Mode | Run browser, semantic, accessibility, and safety checks |

The CLI can keep phase gates, but the user-facing experience should show these modes in plain language.

### 4.5 Live Preview Workbench

Recommended layout:

- Left: conversation with the expert builder.
- Center: live preview.
- Right: task board, files changed, QA status, logs.

The preview should be treated as the primary artifact, not only the generated files.

### 4.6 Semantic QA Layer

Extend QA beyond generic quality checks.

New semantic QA sources:

- `intent.yaml`
- `first-view-contract.md`
- `product.md`
- `security.md`
- generated DOM snapshot
- browser screenshot

Example semantic assertions for a conversational stock assistant:

- The first viewport includes a visible chat input.
- Sending a stock question creates a user message and assistant response.
- The UI includes stock status or quote context.
- Any order action opens preview/confirmation only.
- The UI clearly communicates that real trading is locked or unavailable.
- No real account token, approval key, or broker execution path exists.
- The first screen is not a marketing hero as the main experience.

### 4.7 Component Mapping for Visual Edits

During generation, add stable identifiers:

```html
<section data-aiweb-id="stock-chat-console">
```

Maintain a mapping:

`.ai-web/component-map.json`

This enables future commands like:

- "Make the chat input taller."
- "Move safety lock above order preview."
- "Turn this panel into tabs."

The builder can map visual selections to source files without guessing.

## 5. Phase Changes

Recommended additions to the phase model:

| New stage | Insert before | Output |
| --- | --- | --- |
| Intent classification | product artifact generation | `intent.yaml` |
| First-view contract | IA/design | `first-view-contract.md` |
| Semantic acceptance criteria | QA checklist | intent-specific QA items |
| Preview checkpoint | after first implementation | screenshot, DOM summary, console/network result |
| Critique loop | before gate approval | pass/fail explanation tied to original intent |

Existing gates should fail if semantic artifacts are missing or contradicted.

## 6. Implementation Roadmap

### Phase A: Stop Major Misunderstandings

Implement first:

1. Generate `.ai-web/intent.yaml`.
2. Generate `.ai-web/first-view-contract.md`.
3. Make phase advancement fail when required first-view elements are missing from the contract.
4. Add semantic QA items to `qa_checklist_markdown`.

Expected result:

The builder should no longer create a landing page when the user asked for a real app interface.

### Phase B: Expert Interpretation

Implement next:

1. Replace TODO-oriented interview output with interpreted product artifacts.
2. Add "wrong interpretation to avoid" to product and design artifacts.
3. Add explicit "mocked / blocked / excluded" section for safety-sensitive apps.
4. Add archetype-specific templates for chat apps, dashboards, tools, commerce, games, and landing pages.

Expected result:

The builder sounds and acts like it understood the product before coding.

### Phase C: Live Preview and Browser QA

Implement next:

1. Start dev server automatically after first build.
2. Capture desktop and mobile screenshots.
3. Collect console and network errors.
4. Run DOM assertions from semantic QA.
5. Store evidence under `.ai-web/qa/evidence/`.

Expected result:

The builder can prove that the generated web app is visible, interactive, and aligned with intent.

### Phase D: Visual Edit Foundation

Implement next:

1. Add `data-aiweb-id` to generated major regions.
2. Generate `.ai-web/component-map.json`.
3. Support text commands that target component IDs.
4. Later, add click-to-select visual editing.

Expected result:

The user can modify the app by referring to visible UI pieces, not file names.

### Phase E: Full Expert Workbench

Implement later:

1. Conversation + preview + task board UI.
2. Visible agent tasks and current reasoning summary.
3. File diff and rollback snapshots.
4. Provider/runtime adapters.
5. Project memory for repeated user preferences.

Expected result:

The product feels closer to Lovable/Bolt-style expert web creation.

## 7. Acceptance Criteria

The upgrade is successful when:

- The builder classifies a request as app/tool/site before generating files.
- The first screen contract is produced and used by QA.
- App requests do not silently become landing pages.
- QA can fail a visually polished but semantically wrong result.
- The builder can run a preview and inspect it through a browser.
- The user sees what the builder is doing, what failed, and what will be fixed next.
- Safety-sensitive domains generate mock/locked flows by default.

## 8. Recommended First Commit Scope

Start with the smallest high-impact change:

1. Add `intent.yaml` template/schema.
2. Add `first-view-contract.md` template.
3. Update interview generation to create both.
4. Update QA checklist generation to include semantic checks.
5. Add one regression fixture for "conversational stock assistant must not become landing page."

This is the shortest path from scripted builder to intent-preserving expert builder.
