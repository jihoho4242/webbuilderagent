# Ecommerce Category Page Skill

Use this skill for product category, collection, drop, and curated storefront pages where visitors need to browse, compare, filter, and buy confidently.

## Inputs to Read First

- Product catalog shape: count, variants, price range, categories.
- Brand merchandising angle: luxury, playful, technical, handmade, food, fashion.
- Product media availability and license/provenance.
- Shipping, returns, discounts, stock, and sale rules.
- Primary conversion: add to cart, product detail, preorder, inquiry.

## Good Patterns

- Category headline explains the collection and buyer need.
- Filters reflect real decisions: size, color, use case, availability, price.
- Product cards show name, price, image, availability, and quick comparison cue.
- Mobile browsing works without tiny controls or carousel dependence.
- Shipping/returns reassurance appears before checkout anxiety.

## Bad Patterns

- Product grid with images only and hidden prices.
- Fake countdowns, fake stock scarcity, or unclear discounts.
- Filters that return empty states without recovery suggestions.
- Product names truncated so items cannot be compared.
- Forced account creation before cart review.

## Section Recipes

### 1. Collection Hero

Required:

- Collection name.
- One-sentence merchandising angle.
- Featured product or lifestyle image.
- CTA to shop or filter anchor.
- Shipping/returns or launch timing note.

### 2. Product Grid

Each product card requires:

- Image with meaningful alt text.
- Product name.
- Price and sale state if any.
- Variant indicator: colors/sizes/flavors.
- Availability.
- Quick action or detail link.

### 3. Filters and Sorting

- Mobile: drawer with applied-filter chips.
- Desktop: left rail or top bar depending on count.
- Sorting options: featured, newest, price, popularity only if data exists.
- Empty state includes clear filters button and recommended alternatives.

### 4. Product Education Band

Use when products need explanation:

- Size guide.
- Ingredients/materials.
- Care instructions.
- Fit/use-case guide.
- Comparison table.

### 5. Trust / Policy Strip

Include:

- Shipping threshold or timing.
- Returns/exchanges.
- Secure checkout.
- Support/contact.

### 6. Related / Recently Viewed

- Use after grid or PDP summary.
- Do not distract before primary add-to-cart action.

## Component Recipes

### Product Card

- Image ratio consistent per category.
- Text stack: brand/collection label, name, price, metadata.
- Hover reveals secondary image or quick action; mobile shows persistent quick action.

### Filter Drawer

- Opens from bottom or side.
- Contains clear all, apply, and result count.
- Does not require precise taps on tiny checkboxes.

### Sale Badge

- Small, text-based, not flashing.
- Sale label must match price math.
- Do not style regular products as urgent.

## QA Notes

- Check 375px viewport for two-column grid readability.
- Verify product cards remain useful when images fail or load slowly.
- Confirm disabled/out-of-stock states explain next action.
- Test filter empty states and clear-all behavior.
- Ensure sale/original prices are announced correctly to assistive tech.

## Done Criteria

- Shopper can compare products from the grid without opening every item.
- Filters match real catalog attributes.
- No false urgency or hidden cost patterns are introduced.
