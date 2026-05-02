# Service Business Site Skill

Use this skill for local or appointment-based businesses: clinics, studios, restaurants, tutors, repair services, agencies, gyms, salons, and professional practices.

## Inputs to Read First

- Business category and location/service area.
- Primary conversion: call, booking, map directions, quote request, order.
- Opening hours, address, phone, pricing constraints, emergency constraints.
- Real photos, reviews, certifications, staff credentials.
- Required disclaimers or regulated-claim boundaries.

## Good Patterns

- Hero names the service, location, and outcome.
- Contact actions are visible on desktop and sticky on mobile.
- Hours, location, parking/transit, and service area are easy to find.
- Reviews and credentials are close to conversion points.
- Forms ask for the minimum information needed for the next step.

## Bad Patterns

- Hiding phone or booking in footer only.
- Generic “About us” above actual service details.
- Fake review snippets or invented star ratings.
- Stock photos that do not match the business environment.
- Long intake forms before explaining trust and fit.

## Section Recipes

### 1. Local Trust Hero

Required:

- Service + audience + location in headline.
- Primary CTA: call/book/request quote.
- Secondary CTA: directions or service list.
- Trust signal: rating, certification, years, client count, or real review.
- Practical details: open state, neighborhood, parking, response time, or service radius.

### 2. Service List

Each service card includes:

- Service name.
- Best-for statement.
- What happens during the service.
- Duration or price range if available.
- Relevant caution/exclusion.
- CTA or “Ask about this”.

### 3. Why Choose Us

Use proof, not adjectives:

- Credentials.
- Process safeguards.
- Equipment/materials.
- Response time.
- Before/after examples with permission.

### 4. Booking / Contact Section

Include:

- Phone, booking link, address, hours.
- What happens after inquiry.
- Expected response time.
- Form with name, contact, requested service, preferred time, short message.

### 5. FAQ

Answer practical objections:

- Pricing.
- Timing.
- Cancellation.
- Parking/location.
- First visit expectations.
- Safety/regulatory limits.

### 6. Footer

Required:

- Business name, address/service area, phone, hours.
- Policy links if needed.
- License/registration identifiers if required by domain.

## Component Recipes

### Mobile Sticky CTA

- Three actions max.
- Suggested labels: Call, Book, Directions.
- Use icons only with visible text labels.
- Hide or compress while keyboard is open.

### Review Block

- 3–6 reviews max on homepage.
- Include source label and permission state.
- Do not show star aggregate unless real.

### Map Panel

- Use static map screenshot or embedded map only if allowed.
- Provide text fallback with address and directions link.

## QA Notes

- Test tap targets on mobile; CTA minimum height 44px.
- Verify `tel:` links, booking links, and map links.
- Check sticky CTA does not obscure footer or form fields.
- Confirm all claims are sourced or framed as business-provided draft copy.
- Check Korean text wrapping with `word-break: keep-all` where relevant.

## Done Criteria

- A mobile visitor can call/book/get directions without searching.
- The page communicates fit, trust, and logistics before asking for sensitive info.
- No invented reviews, hours, addresses, certifications, or prices remain.
