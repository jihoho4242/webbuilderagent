# Deploy Plan — Profile D

## Baseline
Cloudflare Pages static deploy with sitemap/RSS release checklist

## Predeploy requirements
- Gate 4 predeploy approval must exist.
- Rollback criteria must be defined before production action.
- External deploy/provider actions require explicit human approval.

## Rollback
- Keep local `.ai-web` snapshot before deploy.
- Record deploy target and version/hash.
- Record dry-run rollback result before release.
