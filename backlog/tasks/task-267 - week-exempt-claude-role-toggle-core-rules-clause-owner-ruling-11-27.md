---
id: TASK-267
title: 'week-exempt: claude-role toggle + core rules clause (owner ruling 11-27)'
status: In Progress
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
