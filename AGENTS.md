# Project Agent Instructions

Follow `.ai-web/state.yaml` as the source of truth for current phase and gate status.

Before implementation, read:

- `.ai-web/product.md`
- `.ai-web/quality.yaml`
- `.ai-web/stack.md`
- `.ai-web/brand.md`
- `.ai-web/content.md`
- `.ai-web/ia.md`
- `.ai-web/DESIGN.md`
- `.ai-web/design-reference-brief.md` when present

Implementation rules:

- Work from the current task packet only.
- Treat GPT Image 2 outputs, screenshots, URLs, and reference images as input evidence only. They must pass through reference ingestion / `.ai-web/design-reference-brief.md`, `.ai-web/DESIGN.md`, candidate generation, and selected-design review before any source implementation.
- Do not route raw images or reference screenshots directly to Codex/source patching. Codex implements from task packets, `.ai-web/DESIGN.md`, selected candidate artifacts, and persisted pattern constraints only.
- Source implementation tasks that touch app/UI source require a recorded selected design candidate unless the task is explicitly non-implementation.
- Do not invent new design tokens or component variants unless `DESIGN.md` is updated.
- Do not call Lazyweb or external design-research tools during implementation; use persisted markdown pattern guidance only.
- Do not copy exact reference screenshots, layouts, copy, prices, trademarks, or brand-specific claims.
- Run verification listed in the task packet.
- Create or update QA evidence for browser-visible changes.
- Record blockers instead of silently expanding scope.
- Treat Lazyweb/design-research artifacts as read-only design evidence.
- Do not request or use Lazyweb tokens, network access, or MCP servers from implementation task packets.


Approval and QA rules:

- Gate approval hashes invalidate if approved artifacts change.
- Do not enter Phase 4 unless Gate 2 is approved.
- Do not release with critical/high open QA failures unless the release is explicitly blocked or a valid accepted-risk policy allows it.
- Respect adapter contracts in `.ai-web/state.yaml`.
- Preserve `adapters.implementation_agent.network_allowed: false` and `mcp_servers_allowed: []` unless a human explicitly approves a contract change.
- Do not run external deploy/provider actions without explicit approval.
