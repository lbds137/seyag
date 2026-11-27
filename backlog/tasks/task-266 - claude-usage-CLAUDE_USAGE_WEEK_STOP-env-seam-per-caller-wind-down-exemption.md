---
id: TASK-266
title: 'claude-usage: CLAUDE_USAGE_WEEK_STOP env seam (per-caller wind-down exemption)'
status: To Do
assignee: []
created_date: '2026-11-27T17:06:00Z'
labels:
  - lane-b
dependencies: []
priority: medium
ordinal: 266000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Routed from Deck Platform (2026-11-27, mechanism ask, no private context). The plan-week wind-down threshold is baked at 75 percent in --ok and --posture; a fleet consumer needs certain roles available until the hard stop (98). Smallest agreed shape: a CLAUDE_USAGE_WEEK_STOP env seam honored by BOTH --ok and --posture on the plan lane, default unset = today behavior, keeping the 5h gate at --ok own value; matches the CLOUD_GATE_WEEK_STOP convention the canonical cloud-gate body just landed (TASK-263). Callers pass it only for exempt roles; the exempt fact stays caller-side, claude-usage stays name-blind. The wind-down posture line (past X percent of the week) must read the raised stop too, or exempt callers driver-choice fires at 75 anyway. Consumer context: DP callers (deck-gate passthrough seam, fleet, peer-send) land on deck-platform 408 branch and are NOT blocked — they build against this contract. Adjacent: deck-platform task-355 (claude-usage-and-deck-gate-read-week-gates-at-call-time) — read before picking the shape. File: plugins/seyag/bin/claude-usage; its probe needs the new cases (default unset unchanged; set: --ok week gate moves; --posture line reflects it).
<!-- SECTION:DESCRIPTION:END -->
