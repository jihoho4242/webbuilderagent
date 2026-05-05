# Stack Profile D — Astro content site + MDX

## Canonical default
Astro content site + MDX

## Scaffold target
Astro + MDX/Content Collections + Cloudflare Pages + Tailwind + sitemap/RSS

## Allowed override
Canonical default for content/SEO/brand sites without server-side app complexity.

## When to override
Override only when Gate 1A records the reason, affected deployment/runtime tradeoffs, and rollback path.

## Implementation note
`aiweb init --profile D` records this scaffold target only. Actual app scaffold happens later through a Phase 6 task packet.
