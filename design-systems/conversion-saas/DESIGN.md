# Conversion SaaS Design System

Use this system for B2B SaaS landing pages, AI tools, dashboards, developer products, and product-led growth sites that need credibility, clarity, and high conversion.

## Design Principles

- **Show the product early:** above the fold includes a real UI artifact, workflow preview, or output sample.
- **Specific beats clever:** headings name the buyer, job, and measurable outcome.
- **Trust through structure:** use comparison, proof, integration, and security sections rather than vague claims.
- **Fast scan path:** every section has a visible headline, one-sentence takeaway, and one action or proof object.

## Color Tokens

```css
:root {
  --color-bg: #F7F9FC;
  --color-surface: #FFFFFF;
  --color-ink: #101828;
  --color-muted: #667085;
  --color-line: #D9E2EF;
  --color-primary-600: #2563EB;
  --color-primary-700: #1D4ED8;
  --color-cyan-400: #22D3EE;
  --color-violet-500: #7C3AED;
  --color-green-600: #16A34A;
  --color-red-600: #DC2626;
  --color-focus: #F59E0B;
}
```

### Usage Rules

- Default background: `--color-bg`; cards and nav: `--color-surface`.
- Primary CTA: blue; success states: green; warnings/errors: red only.
- Decorative gradients may combine blue/cyan/violet but must sit behind UI, not behind paragraphs.
- Borders should be visible but quiet: `1px solid --color-line`.

## Typography

```css
:root {
  --font-sans: "Inter", "SF Pro Text", system-ui, sans-serif;
  --font-display: "Inter Tight", "Inter", system-ui, sans-serif;
  --font-code: "JetBrains Mono", "SFMono-Regular", monospace;
  --text-hero: clamp(3rem, 7vw, 5.75rem);
  --text-h1: clamp(2.5rem, 5vw, 4.5rem);
  --text-h2: clamp(1.875rem, 3.2vw, 3rem);
  --text-h3: clamp(1.25rem, 2vw, 1.625rem);
  --text-body: 1rem;
  --text-large: 1.125rem;
  --text-small: .875rem;
}
```

- Hero line-height: `.95`; letter-spacing: `-.045em`.
- Body line-height: `1.55`.
- Use code font only for API snippets, CLI commands, config keys, or tiny product labels.

## Spacing Scale

```css
:root {
  --space-1: 4px;
  --space-2: 8px;
  --space-3: 12px;
  --space-4: 16px;
  --space-5: 20px;
  --space-6: 24px;
  --space-8: 32px;
  --space-10: 40px;
  --space-12: 48px;
  --space-16: 64px;
  --space-20: 80px;
  --space-28: 112px;
}
```

- Section padding desktop: 96–128px.
- Section padding mobile: 56–72px.
- Dense dashboard previews may use 8px internal grid; marketing copy uses 16/24/32px rhythm.

## Layout Grid

```css
.container { width: min(100% - 32px, 1180px); margin-inline: auto; }
.hero-grid { display: grid; grid-template-columns: .95fr 1.05fr; gap: clamp(32px, 5vw, 72px); align-items: center; }
.feature-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 20px; }
```

- Desktop hero: copy left, product visual right, unless developer tool where terminal can lead.
- Tablet: hero visual below copy but still above first proof section.
- Mobile: CTA row stacks; product visual may crop horizontally inside a rounded frame, never shrink into illegibility.

## Radius / Shadow / Elevation

```css
:root {
  --radius-sm: 8px;
  --radius-md: 14px;
  --radius-lg: 22px;
  --radius-xl: 32px;
  --shadow-soft: 0 14px 40px rgba(16,24,40,.08);
  --shadow-product: 0 28px 90px rgba(37,99,235,.18);
}
```

- Product screenshots: `--radius-xl` and `--shadow-product`.
- Feature cards: `--radius-lg`; never use excessive neumorphism.

## Components

### Header

- 72px desktop, 64px mobile.
- Required: logo, product/solutions/resources links, sign-in if relevant, primary CTA.
- Header can be sticky; keep background opaque enough to preserve contrast.

### Hero

- Required: buyer-specific headline, subheadline under 28 words, primary CTA, secondary CTA, UI proof, trust row.
- Trust row format: “Used by ops teams at …” or metric badges with source.
- Product visual must include realistic data labels, not lorem ipsum.

### Button

```css
.button-primary {
  min-height: 48px;
  padding: 0 20px;
  border-radius: 12px;
  background: var(--color-primary-600);
  color: white;
  font-weight: 700;
  box-shadow: 0 10px 24px rgba(37,99,235,.22);
}
.button-primary:hover { background: var(--color-primary-700); transform: translateY(-1px); }
.button-secondary { background: white; color: var(--color-ink); border: 1px solid var(--color-line); }
```

- Max button variants: primary, secondary, ghost.
- Do not create separate “AI gradient button” variants.

### Product Card

- Header bar with three dots or contextual tabs only if it clarifies the UI.
- Include one highlighted action/result using accent outline or glow.
- Keep fake UI controls keyboard-legible at 12px minimum.

### Feature Card

- Contains icon, outcome heading, 1–2 sentence explanation, proof detail.
- Icon container 40px; use one icon style across page.

### Pricing Card

- Three tiers max unless comparison table is needed.
- Show best-fit label, not “Most popular” by default.
- Price, included limits, CTA, objection note, and security/payment reassurance.

### Form Field

- Label, helper text, validation state, and error copy.
- Error color red; success color green; never rely on color alone.

## Layout Recipes

### Feature Bento

- 2x2 or 3-column layout.
- One large card demonstrates workflow; smaller cards cover integrations, automation, reporting.
- Avoid six identical cards with generic icons.

### How It Works

- Three steps: input, system action, user outcome.
- Each step includes screenshot fragment or data artifact.
- Use arrows or numbered badges; do not over-animate.

### Security / Trust

- Four cards: data handling, permissions, uptime, compliance/export.
- Include concrete statements and policy-page links only when real URLs or approved content are available; otherwise list required policy pages as launch follow-ups without placeholder links.

## Motion Rules

- Button hover may lift 1px; cards can lift 2px max.
- Product visual may animate one highlight path over 6–10 seconds.
- Avoid infinite spinning AI or sparkle loops.
- Respect `prefers-reduced-motion`.

## Accessibility Rules

- Product screenshots need text alternative summarizing the shown workflow.
- Keyboard order follows visual order: nav, hero copy, CTAs, product preview.
- Do not use blue-only distinction for links; underline text links in body copy.
- Charts require labels, not color-only series.

## Forbidden Patterns

- “All-in-one AI platform” without a named job or buyer.
- Fake dashboard numbers with no context.
- Ten logos without permission/provenance status.
- Gradient mesh backgrounds reducing text contrast.
- Feature cards that repeat the same sentence structure.
