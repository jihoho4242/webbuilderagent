# Craft Rule: Typography

Typography must create hierarchy, trust, and reading comfort. Do not treat type as decoration after layout is done.

## Token Contract

Define type tokens before building sections:

```css
:root {
  --font-display: system-ui;
  --font-body: system-ui;
  --text-hero: clamp(3rem, 7vw, 6rem);
  --text-h1: clamp(2.5rem, 5vw, 4.5rem);
  --text-h2: clamp(1.75rem, 3vw, 3rem);
  --text-h3: clamp(1.25rem, 2vw, 1.625rem);
  --text-body: 1rem;
  --text-small: .875rem;
}
```

## Rules

- Use one display family and one body family unless the brand system explicitly allows more.
- Keep body copy between 45–72 characters per line on desktop.
- Hero headings need optical line breaks; do not let generated text wrap randomly.
- Korean copy: prefer `word-break: keep-all`; adjust max-width and line-height to avoid awkward single-syllable wraps.
- Use font weight for hierarchy sparingly: regular, semibold, bold are usually enough.
- Eyebrows must be short and useful; do not use “WELCOME” or “INTRODUCTION”.

## Type Scale Recipes

### Editorial Premium

- Hero: serif or high-contrast display, 72–160px desktop, line-height .86–.96.
- Body: humanist sans or serif, 17–19px, line-height 1.6–1.75.
- Captions: mono or small sans, 12–13px, uppercase with tracking.

### SaaS / Product

- Hero: tight sans, 52–92px desktop, line-height .92–1.0.
- Body: 16–18px, line-height 1.5–1.6.
- UI labels: 12–14px, medium weight, never below 11px in screenshots.

### Local Service

- Hero: approachable sans, 42–80px desktop.
- Body: 16–18px; practical detail text 14–16px.
- Phone/hours/location: high contrast and scannable.

## Bad Patterns

- All sections use the same heading size.
- Body copy centered across a full desktop width.
- Decorative font used for paragraphs.
- Tiny gray text for critical details like pricing, legal notices, or form errors.
- Multiple unrelated font pairings because each section was generated separately.

## QA Checklist

- Scan at 375px, 768px, and 1440px.
- Verify no heading creates a single orphan word unless intentional.
- Check text contrast in every background context.
- Ensure body paragraphs are readable without zooming.
- Confirm type tokens are reused; remove one-off `font-size` values.
