---
id: TASK-87
title: 'pr-open claim-shape: numeric claims need a cite'
status: Done
assignee:
  - Seyag B
created_date: '2026-11-22T16:45:00Z'
updated_date: '2026-11-27T07:05:00Z'
labels:
  - pr
  - claims
dependencies: []
priority: high
ordinal: 87000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Numeric claim shapes in PR bodies (durations/percentages/ratios/counted nouns, EXTRA only; CORE untouched so comment scans unchanged) + fail-closed unresolved --body-file/-F paths (rc 2 banner naming the raw word; documented rc contract 0/2/3; header known-gaps incl. the stale-view hazard). Probe: 9 rows flipped fail-closed + Case ll numeric/cite/hedge/non-flag rows; durations row 38.7 -> 86.1. Shipped via PR #455, merged ae8cc9fd (rebase merge, CI 14/14 green, claude-review VERDICT PASS with 6 lows), 2026-11-27; release fold into 0.3.235 or 0.3.236 is lane A's (A's gate-time check). Review lows (single-letter-unit over-blocks, stale-view sentence evidence, gh api body=@ fail-open, dead guard, header reflow, duration variance) carry on the handoff surface for the next same-area PR per core.md lows-carry; source PR #455, area pr-body-ref-gate/claim-shapes.
<!-- SECTION:DESCRIPTION:END -->
