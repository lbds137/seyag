---
name: accessibility
description: 'Accessibility floor for any UI, chart, theme, status-colour or visual work, wherever it lands (web, Discord, docs, dashboards): colour never carries a signal alone, contrast meets WCAG AA in light and dark themes, changed visuals are verified under a colour-vision-deficiency simulation or by luminance reasoning with the method stated, interactive targets are at least 24px, images and charts carry text alternatives, and nothing is hover-only. Use when building, changing or reviewing any user-facing visual surface.'
---

# Accessibility

Run before review on any change that alters what a user sees. The floor is the point: a feature that only some users can read is a bug, not a preference.

## The four checks

- **Colour is never the only signal.** Every distinction made by colour alone also carries text, pattern, shape or position: a status pairs its colour with a word or icon, chart series get distinct markers or line styles, legends repeat the exact swatch each series uses. Prefer palettes whose adjacent entries differ in luminance, not only in hue.
- **Contrast meets WCAG AA in both themes.** 4.5:1 for text, 3:1 for UI components and meaningful graphical parts (chart lines, status dots, focus rings). Light and dark are separate checks, not one — a value that passes one theme fails the other often enough that measuring only one measures nothing.
- **Verify the changed visual with a stated method.** Run the changed surface through a colour-vision-deficiency simulation (deuteranopia, protanopia, tritanopia) or reason through the luminance values; state which method was used in the PR or the report. "Looks fine" is not a method.
- **Reachable without fine pointing or hover.** Interactive targets are at least 24px (larger where the surface allows); images and charts carry text alternatives (`aria-label` or the surface's equivalent, structured text in chat surfaces); nothing is carried by hover alone — every hover disclosure has a keyboard or persistent equivalent.

## In practice

- The floor applies wherever the surface lives: web (`aria-*`, visible focus states), Discord (embed colour paired with title or emoji wording, button labels that survive without colour), docs and dashboards (status words, not traffic-light cells alone; tables that sort by more than colour).
- A surface that cannot meet a check (platform-fixed button sizes, a host-controlled theme) says so in the review with the reason and pairs the constraint with its best available substitute. The remaining risk is stated, not silent.
