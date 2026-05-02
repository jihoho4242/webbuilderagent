# Luxury Editorial Design System

Use this system for premium consultants, boutique studios, culture brands, private clinics, architects, and high-ticket services where restraint signals value.

## Design Principles

- **Quiet hierarchy:** one dominant idea per viewport; everything else supports it.
- **Editorial rhythm:** alternate dense copy bands with generous image or whitespace bands.
- **Material cues:** use thin rules, soft paper tones, refined serif display, and measured motion.
- **Conversion without shouting:** primary CTA is visible, but never styled like a discount banner.

## Color Tokens

```css
:root {
  --color-ink-950: #15120F;
  --color-ink-800: #332D27;
  --color-stone-600: #756B5F;
  --color-paper-50: #F8F4EC;
  --color-paper-100: #EFE8DC;
  --color-sand-200: #D8C7AD;
  --color-gold-500: #B08A4A;
  --color-burgundy-700: #5E1F2E;
  --color-focus: #7A4DFF;
}
```

### Usage Rules

- Page background: `--color-paper-50` or `--color-ink-950`; never pure white.
- Text on light: `--color-ink-950`; secondary text `--color-stone-600`.
- Accent limit: gold or burgundy appears in at most 10% of any screen.
- Borders: use `rgba(21,18,15,.14)` on light and `rgba(248,244,236,.18)` on dark.

## Typography

```css
:root {
  --font-display: "Cormorant Garamond", "Iowan Old Style", Georgia, serif;
  --font-body: "Inter", "Helvetica Neue", Arial, sans-serif;
  --font-mono: "IBM Plex Mono", ui-monospace, monospace;

  --text-hero: clamp(4.25rem, 11vw, 10rem);
  --text-h1: clamp(3rem, 7vw, 6rem);
  --text-h2: clamp(2rem, 4.2vw, 3.75rem);
  --text-h3: clamp(1.35rem, 2.2vw, 2rem);
  --text-body: clamp(1rem, 1.1vw, 1.125rem);
  --text-small: .875rem;
}
```

- Hero line-height: `.86`; letter-spacing: `-.055em`.
- Body line-height: `1.65`; max measure: `64ch`.
- Eyebrows: mono, uppercase, `0.11em` letter spacing, 12–13px.
- Never use more than one display font and one body font.

## Spacing Scale

```css
:root {
  --space-1: .25rem;
  --space-2: .5rem;
  --space-3: .75rem;
  --space-4: 1rem;
  --space-6: 1.5rem;
  --space-8: 2rem;
  --space-12: 3rem;
  --space-16: 4rem;
  --space-24: 6rem;
  --space-32: 8rem;
  --space-40: 10rem;
}
```

- Section padding desktop: `--space-32` top/bottom.
- Section padding mobile: `--space-16` top/bottom.
- Use whitespace as a component; do not fill every column.

## Layout Grid

```css
.page-shell {
  width: min(100% - 32px, 1440px);
  margin-inline: auto;
}
.editorial-grid {
  display: grid;
  grid-template-columns: repeat(12, minmax(0, 1fr));
  column-gap: clamp(16px, 2vw, 32px);
}
```

- Hero copy spans 8 columns on desktop; supporting proof spans 3–4 columns.
- Use asymmetry: image `2 / span 5`, copy `8 / span 4` or inverse.
- Mobile collapses to one column with image after the core value proposition unless image is the proof.

## Radius / Shadow / Elevation

```css
:root {
  --radius-none: 0;
  --radius-soft: 10px;
  --radius-panel: 24px;
  --shadow-card: 0 24px 80px rgba(21,18,15,.10);
  --shadow-image: 0 32px 120px rgba(21,18,15,.18);
}
```

- Prefer square editorial images; use radius only on functional cards/forms.
- Never combine thick shadows with gold borders.

## Components

### Header

- Height: 84px desktop, 64px mobile.
- Left: wordmark; center: 3–5 links; right: understated CTA.
- Sticky only after first scroll; initial hero should breathe.
- Header background may blur after scroll: `rgba(248,244,236,.78)` plus `backdrop-filter: blur(18px)`.

### Hero

- Required elements: one-line proposition, 1 proof point, primary CTA, optional secondary text link.
- Preferred composition: oversized serif headline, small mono context, image or quote occupying the negative space.
- Avoid centered generic hero unless the brand is ceremonial or event-led.

### Button

```css
.button-primary {
  min-height: 48px;
  padding: 0 22px;
  border: 1px solid var(--color-ink-950);
  background: var(--color-ink-950);
  color: var(--color-paper-50);
  border-radius: 999px;
  font-weight: 600;
}
.button-primary:hover { background: var(--color-burgundy-700); border-color: var(--color-burgundy-700); }
.button-secondary { background: transparent; color: var(--color-ink-950); border: 1px solid rgba(21,18,15,.18); }
```

- Maximum variants: primary, secondary, text.
- Never use gradient CTA fills.

### Card

- Use cards sparingly for proof, services, or process.
- Padding: 28–40px desktop, 22px mobile.
- Border: `1px solid rgba(21,18,15,.12)`; background: `rgba(255,255,255,.32)`.
- Card title should be specific: “Private diagnosis in 48 hours,” not “Quality service.”

### Form Field

- Label above input; never placeholder-only.
- Border bottom or 1px full border; no heavy filled gray fields.
- Focus ring: `2px solid --color-focus` offset 2px.

### Section

- Each section has a role: proof, offer, process, founder note, FAQ, final conversion.
- Use a small section label aligned to grid before large content.

## Layout Recipes

### Founder / Expert Note

- 12-column grid.
- Portrait: columns 2–5, aspect ratio 4:5.
- Quote/copy: columns 7–11.
- Add credential line under quote, not a separate badge cloud.

### Service Menu

- Left rail: section label + intro, 4 columns.
- Right rail: stacked services, 7 columns, each with outcome, duration, best-for, CTA.

### Proof Strip

- 3–4 metrics max.
- Each metric: serif number 48–72px, mono label, one sentence context.

## Motion Rules

- Use opacity + `translateY(12px)` reveal; duration 500–700ms.
- Stagger no more than 80ms.
- Disable parallax on mobile and under `prefers-reduced-motion`.
- Motion must clarify reading order, not decorate.

## Accessibility Rules

- Minimum contrast: 4.5:1 for body, 3:1 for display over 32px.
- Focus styles visible on every interactive element.
- Do not render critical text inside images.
- Maintain 44px minimum tap targets.

## Forbidden Patterns

- Stock “luxury” clichés: gold-on-black everywhere, marble texture overlays, fake awards.
- Placeholder testimonials without attribution status.
- Centered wall of copy wider than 70ch.
- More than two accent colors in one viewport.
- Random type scale outside tokens.
