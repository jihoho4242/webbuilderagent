# AI Web Director CLI

This repository currently ships a working **AI Web Director CLI**. It is the baseline orchestration layer for an AI-assisted webbuilding flow, not a full app generator yet.

Today the CLI manages the project director workspace: `.ai-web` state, phase gates, quality approvals, task packets, QA reports, rollback/blocker state, and snapshots. It can guide a web project through planning, design prompt handoff, implementation task sequencing, QA evidence, and recovery decisions. It does **not** currently generate a complete runnable website or application scaffold for you.

## Current scope

- Initialize a Director workspace with `.ai-web` state and templates.
- Move through guarded phases with explicit quality gates.
- Produce design prompts and ingest selected design candidates.
- Emit implementation task packets for later build work.
- Record QA checklists/results and gate advancement on blocking failures.
- Capture snapshots and rollback/blocker recovery evidence.
- Provide a friendly Korean entry point, `웹빌더`, over the lower-level `aiweb` CLI.

## Upgrade direction

The intended product direction is a design-first, natural-language webbuilder: turn a plain-language command into clean, high-quality web output.

1. Describe the business or service website in natural language.
2. Generate and compare premium, design-first candidates.
3. Preview the selected direction in a browser.
4. Run automated browser QA against visual, content, accessibility, and interaction expectations.
5. Repair failures automatically where possible.
6. Deploy later, once gates pass and evidence is recorded.

The current Director CLI is the foundation for that loop: state, gates, QA contracts, snapshots, and recovery are in place before the system grows into end-to-end generation, browser preview, repair, and deploy. It is not yet a full app generator.

## Quick start

The friendly entry point is `웹빌더`. Run it with no arguments for a zero-start interview:

```bash
웹빌더
```

Or pass the idea directly:

```bash
웹빌더 --path ~/Desktop/aiweb-premium-service-site \
  "프리미엄 비즈니스/서비스 웹사이트. 핵심 가치, 서비스 소개, 고객 사례, 상담 문의 섹션이 있는 고품질 랜딩 사이트."
```

`웹빌더` knows the Director sequence and calls the lower-level `aiweb` engine for you.

Low-level equivalent:

```bash
./bin/aiweb start \
  --path ~/Desktop/aiweb-premium-service-site \
  --idea "프리미엄 비즈니스/서비스 웹사이트. 핵심 가치, 서비스 소개, 고객 사례, 상담 문의 섹션이 있는 고품질 랜딩 사이트."
```

`start` creates the target folder, initializes profile D by default, drafts the first interview artifacts, and advances to the phase-0.25 quality gate.
Use `--path` on later commands to keep working against that generated project:

```bash
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site status
./bin/aiweb --path ~/Desktop/aiweb-premium-service-site advance
```

Phase-sensitive commands are guarded by the Director state machine:

```bash
# Once current phase is phase-3 or phase-3.5
./bin/aiweb design-prompt

# Once current phase is phase-3.5
./bin/aiweb ingest-design --title "Candidate 1"

# Once current phase is phase-6 through phase-11
./bin/aiweb next-task

# Once current phase is phase-7 through phase-11
./bin/aiweb qa-checklist
./bin/aiweb qa-report --status failed --task-id golden-page --duration-minutes 61
```

Quality is an explicit contract. After entering phase-0.25, review `.ai-web/quality.yaml` and set `quality.approved: true` before advancing again.

Global flags:

```bash
./bin/aiweb <command> --json
./bin/aiweb <command> --dry-run
```

Manual repair/override for guarded commands:

```bash
./bin/aiweb design-prompt --force
./bin/aiweb ingest-design --force --title "Candidate 1"
./bin/aiweb qa-report --force --status failed --task-id golden-page
```

Rollback leaves the phase blocked until recovery evidence is recorded:

```bash
./bin/aiweb rollback --failure F-QA --reason "QA root cause"
./bin/aiweb resolve-blocker --reason "root cause fixed and evidence recorded"
```

## Verification

Run the CLI test suite locally:

```bash
ruby test/test_aiweb_cli.rb
```

GitHub Actions runs the same test suite against currently supported CRuby branches.
