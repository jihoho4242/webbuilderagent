# AI Web Director MVP

This repository now includes a first working `aiweb` Director CLI. The CLI is intentionally thin: it manages `.ai-web` state, templates, gates, task packets, QA results, rollback decisions, and snapshots. It does **not** scaffold application code during `init`; app scaffold is represented as a later Phase 6 task packet.

## Quick start

```bash
./bin/aiweb init --profile D
./bin/aiweb status
./bin/aiweb interview --idea "로컬 카페 웹사이트"
./bin/aiweb advance
```

Phase-sensitive commands are guarded by the Director state machine:

```bash
# Once current phase is phase-3 or phase-3.5
./bin/aiweb design-prompt

# Once current phase is phase-3.5
./bin/aiweb ingest-design --title "Candidate 1"

# Once current phase is phase-7 through phase-11
./bin/aiweb qa-checklist
./bin/aiweb qa-report --status failed --task-id golden-page --duration-minutes 61
```

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

## Verification

```bash
ruby test/test_aiweb_cli.rb
```
