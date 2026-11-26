---
id: TASK-199
title: Measure hook-count performance cost before any consolidation
status: To Do
assignee: []
created_date: '2026-11-26T09:53:26Z'
labels:
  - hooks
  - performance
dependencies: []
priority: medium
ordinal: 199000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Owner question (relayed 2026-11-26): does the number of hooks cost performance, and could they be consolidated? Count as relayed from hooks.json (re-count before use): PreToolUse 31 (22 matching Bash), Stop 7, SessionStart 3, UserPromptSubmit 3; every Bash call spawns about 22 plugin hook processes plus any settings.json hooks. Measure before redesigning. Raise the priority if measurement (1) shows a large cost.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Per-hook wall time and CPU on a representative Bash payload set (drawn from session logs), at idle and under suite load (load 20-40), with conditions recorded
- [ ] #2 Added latency per Bash call and the CPU sum, after verifying whether Claude Code runs matching hooks in parallel
- [ ] #3 List of hooks missing a cheap early exit (like long-job-chain-guard's text pre-check)
- [ ] #4 Consolidation candidates costed, e.g. one Bash dispatcher process running the text checks in one python start versus N bash plus python forks; any redesign stays per-component toggleable
- [ ] #5 Numbers reported to the Deck management session for relay to the owner
<!-- AC:END -->
