# Local Service Trust Design System

Use this system for restaurants, clinics, repair shops, education centers, salons, gyms, local experts, and appointment-driven service businesses that need warmth, trust, and immediate action.

## Design Principles

- **Action is local:** phone, booking, map, hours, and service area are always easy to find.
- **Trust before polish:** real photos, credentials, reviews, and process clarity beat abstract illustrations.
- **Friendly density:** visitors should answer “Can they help me?” within 5 seconds.
- **Mobile-first conversion:** thumb-reachable CTAs and sticky contact patterns are mandatory.

## Color Tokens

```css
:root {
  --color-cream: #FFF8ED;
  --color-surface: #FFFFFF;
  --color-ink: #1F2933;
  --color-muted: #677489;
  --color-line: #E6D9C8;
  --color-primary: #0F766E;
  --color-primary-dark: #115E59;
  --color-accent: #F97316;
  --color-sage: #DCEADF;
  --color-warning: #B45309;
  --color-focus: #2563EB;
}
```

### Usage Rules

- Use cream background for warmth; white cards for content and booking panels.
- Primary color communicates trust; accent only for urgent actions or highlights.
- Never combine more than one saturated accent per section.

## Typography

```css
:root {
  --font-heading: "Manrope", "Pretendard", system-ui, sans-serif;
  --font-body: "Pretendard", "Inter", system-ui, sans-serif;
  --text-hero: clamp(2.75rem, 6vw, 5rem);
  --text-h1: clamp(2.25rem, 4.8vw, 4rem);
  --text-h2: clamp(1.75rem, 3vw, 2.75rem);
  --text-h3: clamp(1.25rem, 2vw, 1.5rem);
  --text-body: 1rem;
  --text-large: 1.125rem;
  --text-small: .875rem;
}
```

- Headings: line-height `1.02`, letter-spacing `-.035em`.
- Body: line-height `1.6`.
- Korean body copy should use `word-break: keep-all` with responsive max-width.

## Spacing Scale

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
  --space-20: 80px;
}
```

- Mobile section padding: 48–64px.
- Desktop section padding: 80–104px.
- Contact cards use 16px internal rhythm for quick scanning.

## Layout Grid

```css
.container { width: min(100% - 32px, 1120px); margin-inline: auto; }
.hero-booking-grid { display: grid; grid-template-columns: 1.1fr .9fr; gap: clamp(24px, 4vw, 56px); align-items: center; }
.service-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 18px; }
```

- Desktop hero: copy and real photo/booking card side-by-side.
- Mobile: headline, trust row, primary CTA, photo, then booking details.
- Always include visible address/service area in footer and contact section.

## Radius / Shadow / Elevation

```css
:root {
  --radius-sm: 10px;
  --radius-md: 18px;
  --radius-lg: 28px;
  --shadow-card: 0 12px 34px rgba(31,41,51,.10);
  --shadow-sticky: 0 -10px 28px rgba(31,41,51,.12);
}
```

- Radius should feel approachable; avoid sharp luxury edges unless brand requires.
- Shadows are for cards and sticky mobile CTA, not every section.

## Components

### Header

- Desktop: logo, services, reviews, location, FAQ, CTA.
- Mobile: logo, menu, sticky bottom action bar with call/book/map.
- Show current open/closed state only if backed by accurate hours.

### Hero

- Required: service + location + outcome, primary action, proof count/rating, photo or booking panel.
- Example heading shape: “Same-week physiotherapy in Bundang for runners who want to train pain-free.”
- Avoid vague “Welcome to our homepage.”

### Button

```css
.button-primary {
  min-height: 50px;
  padding: 0 20px;
  border-radius: 999px;
  background: var(--color-primary);
  color: white;
  font-weight: 800;
}
.button-accent { background: var(--color-accent); color: white; }
.button-outline { background: white; color: var(--color-primary-dark); border: 1px solid rgba(15,118,110,.28); }
```

- Mobile CTA labels are verbs: “전화하기”, “예약하기”, “길찾기”.
- Do not use more than one high-emphasis CTA in the hero.

### Trust Card

- Includes review quote, reviewer context, source label, and permission/provenance status.
- If reviews are synthetic or unapproved, mark as draft copy and do not present as real.

### Service Card

- Required fields: service name, best for, duration/price range if allowed, expected result, CTA.
- Include real constraints: “Not for emergency symptoms,” “Requires consultation,” etc.

### Hours / Location Panel

- Show today’s hours, full weekly hours, address, parking/transit note, map link.
- If operating hours are unknown, use “Hours to be confirmed” rather than inventing.

### Form Field

- Large labels, simple inputs, inline validation.
- Ask only for necessary fields; avoid long forms before trust is established.

## Layout Recipes

### Mobile Sticky Contact Bar

- Fixed bottom, 3 actions max: call, book, map.
- Height: 64–72px; safe-area padding included.
- Hide if it overlaps an active form input.

### Service Area Section

- Left: map or neighborhood list.
- Right: service radius, parking/transit, emergency/out-of-scope notice.

### Review Wall

- 3 featured reviews + link to more.
- Balance warm language with outcome specifics.

## Motion Rules

- Small slide-up reveals are acceptable; avoid bouncing icons.
- Do not animate phone/map/book CTAs in a distracting loop.
- Motion must not delay access to contact details.

## Accessibility Rules

- Phone links use `tel:` and include visible text, not icon-only.
- Map links include accessible label: “Open directions to [business name]”.
- Sticky bottom bar must not trap keyboard focus.
- Color contrast for accent orange on cream must be checked; use dark text if contrast fails.

## Forbidden Patterns

- Fake reviews, fake certifications, fake “as seen in” logos.
- Generic stock photos that contradict the service location or audience.
- Hiding phone/location in footer only.
- Booking forms with excessive required fields.
- Auto-playing video with sound.
