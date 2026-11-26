---
id: TASK-192
title: 'long-job-chain-check: runner-dense substitutions still cost O(n) each'
status: To Do
assignee: []
created_date: '2026-11-26T01:27:00Z'
labels:
  - hooks
  - performance
dependencies: []
priority: low
ordinal: 191000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deferred from TASK-142 round 2 (2026-11-25). Text with no runner name returns at once, and a span whose interior does not name the runner skips its tail. But a command where every substitution names the runner still costs O(n) per span: 300 copies of 'echo $(date) && echo $(long-job run x -- y)' (13.5 KB) take 2.2 s. The slowest of 6710 real commands from 14 days took 16 ms. Trigger: a replay or a user report showing a real command over 0.5 s, or a hook timeout. Fix shape: build tails incrementally (one pass emitting each span's tail offset), or cap recursed spans with a stated fail-open.
<!-- SECTION:DESCRIPTION:END -->
