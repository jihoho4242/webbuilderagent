# AI Web Director MVP

This repository now includes a first working `aiweb` Director CLI. The CLI is intentionally thin: it manages `.ai-web` state, templates, gates, task packets, QA results, rollback decisions, and snapshots. It does **not** scaffold application code during `init`; app scaffold is represented as a later Phase 6 task packet.

## Quick start

```bash
./bin/aiweb start \
  --path ~/Desktop/aiweb-dogfood-cafe \
  --idea "성수동 감성 로컬 카페 웹사이트. 메뉴, 위치, 영업시간, 문의 폼이 있는 소규모 브랜드 사이트."
```

`start` creates the target folder, initializes profile D by default, drafts the first interview artifacts, and advances to the phase-0.25 quality gate.
Use `--path` on later commands to keep working against that generated project:

```bash
./bin/aiweb --path ~/Desktop/aiweb-dogfood-cafe status
./bin/aiweb --path ~/Desktop/aiweb-dogfood-cafe advance
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

```bash
ruby test/test_aiweb_cli.rb
```
