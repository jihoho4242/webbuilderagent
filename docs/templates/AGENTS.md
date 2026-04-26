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

Implementation rules:

- Work from the current task packet only.
- Do not invent new design tokens or component variants unless `DESIGN.md` is updated.
- Run verification listed in the task packet.
- Create or update QA evidence for browser-visible changes.
- Record blockers instead of silently expanding scope.


Approval and QA rules:

- Gate approval hashes invalidate if approved artifacts change.
- Do not enter Phase 4 unless Gate 2 is approved.
- Do not release with critical/high open QA failures unless the release is explicitly blocked or a valid accepted-risk policy allows it.
- Respect adapter contracts in `.ai-web/state.yaml`.
- Do not run external deploy/provider actions without explicit approval.
