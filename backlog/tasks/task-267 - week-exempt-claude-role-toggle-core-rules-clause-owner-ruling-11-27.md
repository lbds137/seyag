---
id: TASK-267
title: 'week-exempt: claude-role toggle + core rules clause (owner ruling 11-27)'
status: Done
assignee:
  - Seyag
created_date: '2026-11-27T17:54:00Z'
labels:
  - rules
  - owner-decision
dependencies: []
priority: high
ordinal: 267000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Owner ruling 2026-11-27 (via Deck), superseding the mechanism half of TASK-266 (see its disposition): (a) claude-role --set week-exempt=true|false writes/removes the week-exempt frontmatter key (false/empty removes; other values rejected); (b) core.md line-45 clause: a week-exempt session skips the wind-down trigger, defers to the live metadata, mirrors the owner Usage Windows line (skip 75 wind-down + 80 soft stop, run to hard stop 98, heavy work still delegated); core.md at 22927/22957 so compensating cuts ride the same PR; (c) driver-choice skill line. Exemption delivery is caller-side (DP TASK-410: anthropic-week-reserve exemption-aware, max(computed,98)); no claude-usage change. One PR per the ruling, lane A drives, B fresh-eyes the claude-role diff; bump+CHANGELOG 0.3.237 (plugin content).
<!-- SECTION:DESCRIPTION:END -->

Shipped via #463 (merged 254b6e4, automerge, all 13 checks green). Code half agy gemini (claude-role toggle: bare boolean write, line removal on false/empty, bash-side refusal; plus the stray-line write-loop fallback fix), prose half z.ai glm-flash (core.md clause + 7 cuts to 22916/22957 lines-check budget, driver-choice skill line, 0.3.237 bump + CHANGELOG citing #463). Probe 279/0 (21 new cases incl. the fallback pin, any-indent removal normalization, absent-key no-op, --json shape); suite 133/0; shellcheck clean; lines-check rc 0. Review: headless Fable cross-family (gemini + glm author halves); fix round via the unit worker; 1 low carried (no-role-line indent fallback, pre-existing class) per lows-carry. Exemption delivery stays caller-side (DP TASK-410, live read).
