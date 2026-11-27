---
id: TASK-266
title: 'claude-usage: CLAUDE_USAGE_WEEK_STOP env seam (per-caller wind-down exemption)'
status: Done
assignee: []
created_date: '2026-11-27T17:06:00Z'
updated_date: '2026-11-27T17:54:00Z'
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

**DISPOSITION 2026-11-27: OBSOLETE** (checked against the code, not assumed). The mechanism never landed: no `--week` flag exists (`grep -n '\-\-week' plugins/seyag/bin/claude-usage` → no hits), `CLAUDE_USAGE_WEEK_STOP` is posture-only with no gate reading it (`bin/claude-usage:122`), and the `--ok` plan gate already takes its week_reserve from `CLAUDE_USAGE_WEEK_RESERVE_CMD` (`resolve_plan_week_reserve`, `bin/claude-usage:166-176`; static env is the failure fallback). DP's TASK-410 route delivers the exemption caller-side: anthropic-week-reserve becomes exemption-aware (role-file `week-exempt: true` → max(computed reserve, 98); explicit role-path env else `claude-role --path`), wired by deck-platform `lib/week-reserve.sh:7-11` + `bin/fleet:327` + `bin/peer-send:483-489`. The owner ruling's intent (exempt roles run to the hard stop, toggleable by command) is met by the caller shape; the ruling's seyag-side remainder (claude-role toggle + core.md clause) is TASK-267. This body's original spec is preserved above for the record.
