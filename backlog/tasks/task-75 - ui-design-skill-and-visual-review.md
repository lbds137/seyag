---
id: TASK-75
title: 'ui-design skill: per-project design system and a pixel-based visual-review procedure'
status: To Do
assignee: []
created_date: '2026-11-22T05:50:00Z'
labels:
  - ui
  - skills
dependencies: []
priority: medium
ordinal: 75000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
(a) A `ui-design` skill that sets up and maintains a per-project design system and checks new UI against it. The system covers tokens, type scale, spacing, layout grid, and shared patterns such as legends, tables and chips. It composes with the existing `accessibility` skill and does not duplicate it.

(b) A visual-review procedure:
- capture every changed page at phone and desktop widths, in light and dark;
- a capture timeout fails the review; it is never skipped;
- the reviewer works from pixels, not code;
- each finding carries its screenshot;
- a fix is verified by a re-capture.

The capture tool must be configurable (headless browser command via env/config), not tied to one machine's browser setup.

Guards are in TASK-76.
<!-- SECTION:DESCRIPTION:END -->
