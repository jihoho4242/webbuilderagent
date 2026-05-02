# Craft Rule: Anti-AI-Slop

AI-generated web output often looks plausible but empty. This rule blocks generic filler, fake proof, random visual systems, and sections that exist only because templates commonly include them.

## Definition of Slop

A section is slop if it is visually polished but does not help the visitor decide, trust, understand, compare, or act.

## Hard Rules

- No lorem ipsum, placeholder names, fake logos, fake reviews, fake metrics, or invented certifications.
- No generic hero claims: “innovative solutions”, “transform your business”, “next-generation platform”, “unlock your potential”.
- No section may exist without a named job: orient, prove, explain, compare, convert, reassure, or support SEO.
- No random one-off colors, font sizes, border radii, shadows, or button styles outside the design system.
- No AI sparkle/glow/gradient motifs unless the brand direction explicitly requires them and contrast passes.
- No testimonial, case study, logo, award, price, legal, or medical/financial claim without provenance or draft status.

## Replace Generic Copy

| Slop phrase | Replace with |
|---|---|
| Innovative solutions for modern teams | Concrete job + audience + outcome |
| Seamless experience | What becomes easier and how |
| Trusted by many customers | Named proof type or “proof pending” |
| Learn more | Specific action: View services, Book consult, See pricing |
| We help businesses grow | Which businesses, which growth lever, expected path |

## Section Acceptance Test

For each section, answer:

1. What decision does this section help the visitor make?
2. What new information does it add?
3. What proof or mechanism supports the claim?
4. What should the visitor do next, if anything?
5. Can this section be deleted without losing meaning? If yes, delete it.

## Visual Slop Detectors

- Same icon style repeated across unrelated claims.
- Card grids where titles differ but body copy says the same thing.
- Hero image unrelated to the product/service.
- Decorative blobs filling space because layout lacks structure.
- Excessive glassmorphism, neon gradients, or shadows masking weak hierarchy.

## Content Provenance Rules

- Mark generated draft copy as draft until owner-approved.
- Real customer names/logos require permission status.
- Metrics require source, date, and measurement context.
- Regulated claims require disclaimer/review path.
- If source is unknown, write neutral copy that does not imply proof.

## QA Checklist

- Delete duplicate feature cards and merge overlapping claims.
- Search for banned vague phrases before handoff.
- Inspect every CTA for a real destination or explicit intended target.
- Verify all visual styles map back to `DESIGN.md` tokens.
- Confirm mobile first screen is not just decoration; value and action must appear.

## Done Criteria

- Every section has a job and unique content.
- Every proof claim has source/provenance or is clearly marked draft.
- The page would still make sense if visual effects were disabled.
- The system feels intentionally designed, not assembled from unrelated AI defaults.
