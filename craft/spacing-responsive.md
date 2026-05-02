# Craft Rule: Spacing and Responsive Layout

Spacing is the invisible system that makes a page feel designed. Responsive behavior must be planned, not left to default wrapping.

## Token Contract

Use a spacing scale and containers:

```css
:root {
  --space-1: 4px;
  --space-2: 8px;
  --space-3: 12px;
  --space-4: 16px;
  --space-6: 24px;
  --space-8: 32px;
  --space-12: 48px;
  --space-16: 64px;
  --space-24: 96px;
  --space-32: 128px;
  --container: 1180px;
}
.container { width: min(100% - 32px, var(--container)); margin-inline: auto; }
```

## Rules

- Pick a section rhythm: small 48–64px, standard 80–104px, major 112–144px desktop.
- Mobile sections should usually be 48–72px, not collapsed to cramped 24px bands.
- Use grid for macro layout; use flex for component alignment.
- Define collapse behavior for every 2+ column layout.
- Keep first-screen CTA visible or reachable on 375x812.
- Avoid horizontal scroll; treat it as a blocker unless it is an intentional carousel with controls.

## Responsive Recipes

### Two-Column Hero

Desktop:

- `grid-template-columns: 1fr 1fr` or weighted columns.
- Gap 48–80px.
- Align center for balanced hero, start for product/UI hero.

Mobile:

- Single column.
- Order: message, CTA, proof, visual unless visual is required to understand product.
- Gap 24–32px.

### Card Grid

Desktop:

- 3 columns for equal feature cards.
- 2 columns for richer case studies.
- Bento only when content lengths differ meaningfully.

Mobile:

- 1 column for text-heavy cards.
- 2 columns only for compact product cards with short names.

### Sticky CTA

- Reserve bottom padding so sticky CTA does not cover content.
- Include safe-area inset.
- Disable sticky behavior near footer if it duplicates visible footer actions.

## Bad Patterns

- Section padding randomly changes per generated section.
- Cards with equal heights hiding uneven copy quality.
- Desktop-only composition where mobile order becomes nonsensical.
- 12-column grids used inside every small component.
- Image crops that remove the subject on mobile.

## QA Checklist

- Test 375x812, 768x1024, 1024x768, 1440x900.
- Check every breakpoint for horizontal scroll.
- Verify sticky elements do not cover forms, cookie banners, or footer links.
- Confirm section spacing creates groups: related content close, unrelated content separated.
- Inspect image focal points after responsive cropping.
