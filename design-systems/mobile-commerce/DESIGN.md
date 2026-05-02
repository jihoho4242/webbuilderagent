# Mobile Commerce Design System

Use this system for boutique ecommerce, product drops, curated catalogs, creator merch, food products, and small-brand storefronts where mobile conversion and product clarity matter most.

## Design Principles

- **Product first:** imagery, price, variant, availability, and add-to-cart are always visible at decision points.
- **Touch confidence:** every control is thumb-friendly, labeled, and forgiving.
- **Merchandising rhythm:** combine editorial product story with practical shopping paths.
- **No dark patterns:** urgency, discounts, and scarcity must be truthful and source-backed.

## Color Tokens

```css
:root {
  --color-bg: #FBFAF7;
  --color-surface: #FFFFFF;
  --color-ink: #191A1C;
  --color-muted: #6B7280;
  --color-line: #E8E3DA;
  --color-primary: #111827;
  --color-accent: #E11D48;
  --color-sale-bg: #FFF1F2;
  --color-success: #15803D;
  --color-focus: #2563EB;
}
```

### Usage Rules

- Product content stays mostly neutral; accent red is for sale/limited labels only.
- Add-to-cart button uses `--color-primary`, not sale red.
- Use line color for card boundaries; avoid heavy catalog boxes.

## Typography

```css
:root {
  --font-display: "Satoshi", "Inter", system-ui, sans-serif;
  --font-body: "Inter", "Pretendard", system-ui, sans-serif;
  --text-hero: clamp(2.75rem, 8vw, 5.5rem);
  --text-h1: clamp(2.25rem, 6vw, 4.25rem);
  --text-h2: clamp(1.75rem, 4vw, 3rem);
  --text-h3: 1.25rem;
  --text-body: 1rem;
  --text-price: clamp(1.375rem, 3vw, 2rem);
  --text-small: .875rem;
}
```

- Product names: 16–18px in grid, 24–32px on detail.
- Prices must be visually adjacent to product names.
- Avoid all-caps long labels; reserve uppercase for small badges.

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
  --space-14: 56px;
  --space-18: 72px;
}
```

- Mobile grid gap: 12–16px.
- Product detail gap: 24px mobile, 48px desktop.
- Sticky cart bar padding accounts for safe area.

## Layout Grid

```css
.store-shell { width: min(100% - 24px, 1200px); margin-inline: auto; }
.product-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(160px, 1fr)); gap: clamp(12px, 2vw, 24px); }
.pdp-grid { display: grid; grid-template-columns: minmax(0, 1.05fr) minmax(360px, .95fr); gap: clamp(32px, 5vw, 72px); align-items: start; }
```

- Mobile category grid: 2 columns if product imagery remains legible; 1 column for high-ticket products.
- PDP desktop: sticky purchase panel aligned to image gallery.
- PDP mobile: product image, title/price, variant, add-to-cart, shipping/returns, story.

## Radius / Shadow / Elevation

```css
:root {
  --radius-xs: 6px;
  --radius-sm: 10px;
  --radius-md: 16px;
  --radius-lg: 24px;
  --shadow-popover: 0 18px 50px rgba(25,26,28,.14);
}
```

- Product images use `--radius-md` unless brand is sharp/editorial.
- Avoid shadows on every product card; use hover border or image zoom instead.

## Components

### Header

- Mobile: logo, search, cart; category menu below or drawer.
- Desktop: categories, search, account/cart.
- Cart count must be text-accessible.

### Product Card

- Required: image, product name, price, availability/sale if relevant, quick action.
- Image ratio: 4:5 for fashion/beauty, 1:1 for packaged goods, 3:2 for home/objects.
- Hover: second image or subtle scale `1.02`; no dramatic tilt.

### Button

```css
.button-cart {
  min-height: 52px;
  width: 100%;
  border-radius: 14px;
  background: var(--color-primary);
  color: white;
  font-weight: 800;
}
.button-cart:disabled { background: #A3A8B1; cursor: not-allowed; }
.button-quiet { background: var(--color-surface); color: var(--color-ink); border: 1px solid var(--color-line); }
```

- Add-to-cart is full width in mobile purchase panels.
- Disabled state must explain why: out of stock, select size, unavailable region.

### Variant Picker

- Minimum tap target: 44px.
- Selected state uses border + background + accessible text.
- Unavailable variant remains visible but disabled with reason.

### Cart Drawer

- Width: 420px desktop; full width mobile.
- Shows item image, name, variant, quantity controls, price, subtotal, shipping note, checkout CTA.
- Never hide fees until final step; show “shipping calculated at checkout” if unknown.

### Promo Banner

- One line, dismissible, truthful.
- No countdown timers unless backed by an actual campaign end time.

## Layout Recipes

### Drop Landing Page

- Hero: product lifestyle image, collection name, launch detail, CTA.
- Follow with featured products, story module, social proof, shipping/returns, final collection CTA.

### Category Page

- Top: category title, short filter summary, sorting.
- Filters: drawer on mobile, left rail on desktop.
- Empty state suggests alternatives; do not show blank grids.

### Product Detail Page

- Image gallery, purchase panel, trust accordions, reviews, related products.
- Keep add-to-cart visible before long story content.

## Motion Rules

- Image hover zoom max `scale(1.03)`.
- Cart drawer opens within 220ms; never block with long animation.
- Respect reduced motion; avoid auto-advancing carousels.

## Accessibility Rules

- Product images need descriptive alt text for differentiating variants.
- Quantity controls expose current value and buttons have labels.
- Price/sale text must be readable by screen readers: include original and sale price.
- Forms support browser autocomplete for checkout fields.

## Forbidden Patterns

- Fake scarcity: “Only 2 left” without inventory basis.
- Hidden shipping/return policies.
- Variant chips too small for thumbs.
- Product cards with only image and no price.
- Infinite carousels as the only way to browse products.
