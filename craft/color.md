# Craft Rule: Color

Color must communicate hierarchy, emotion, and state. It must not be random decoration or a substitute for content quality.

## Token Contract

Every project needs at least:

```css
:root {
  --color-bg: #ffffff;
  --color-surface: #ffffff;
  --color-ink: #111111;
  --color-muted: #666666;
  --color-line: #dddddd;
  --color-primary: #2563eb;
  --color-accent: #f97316;
  --color-success: #15803d;
  --color-warning: #b45309;
  --color-danger: #dc2626;
  --color-focus: #7c3aed;
}
```

## Rules

- Choose one primary action color. Do not assign a new CTA color per section.
- Accent color appears in small quantities: badges, highlights, active states, or section markers.
- Semantic colors are reserved: success, warning, danger, focus must not be reused as brand confetti.
- Text contrast must pass WCAG AA: 4.5:1 for normal text, 3:1 for large text and UI boundaries.
- Never place paragraph text over busy gradients or unmasked photos.
- Dark sections need their own muted text and border tokens; do not reuse light-mode grays blindly.

## Palette Recipes

### Premium Neutral

- Background: warm paper.
- Text: near-black ink.
- Accent: muted gold, oxblood, or deep green.
- Use high whitespace and low saturation.

### Trustworthy SaaS

- Background: cool gray or white.
- Primary: blue, indigo, or teal.
- Accent: cyan/violet gradient only for product aura, not text backgrounds.

### Local Warmth

- Background: cream or soft neutral.
- Primary: teal, forest, clay, or navy.
- Accent: warm orange/yellow for calls or practical highlights.

### Commerce

- Neutral product canvas.
- Strong black/navy add-to-cart.
- Red only for sale/danger; green only for availability/success.

## Bad Patterns

- Gradient mesh behind important copy with insufficient contrast.
- Five unrelated accent colors in one landing page.
- Red CTA buttons on non-sale pages because they feel “urgent”.
- Disabled states that are only lower opacity and become unreadable.
- Color-only chart, filter, or validation meaning.

## QA Checklist

- Run contrast checks for all text/background pairs.
- View the page in grayscale or mentally remove color: hierarchy should still work.
- Confirm link states are distinguishable beyond color.
- Check hover/focus/active/disabled states for each interactive color.
- Remove any decorative color that does not repeat intentionally elsewhere.
