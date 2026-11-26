---
id: TASK-257
title: 'probes: wall-clock budgets fail under machine load (turn-end-shape-gate, mutation-canary, lossy-pipe-guard)'
status: To Do
assignee: []
created_date: '2026-11-26T17:22:00Z'
labels:
  - tests
  - lane-a
dependencies: []
priority: medium
ordinal: 257000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A full `bash tests/run-probes.sh -j 4` run on 2026-11-26 (load average about 30–40 on 8 cores) failed 2 of 132 probes. The same two probes then passed when run alone at load 20, and the change under test touched neither of them:

- `turn-end-shape-gate` case (payload-y), "a 200000-space text run finishes inside 5 s": exit 124 (its timeout) where 0 was expected.
- `mutation-canary` case 15, "TERM mid-run": exit 143 after 3232 ms, while the probe's timing window expected something else (the child was then Killed).

- `lossy-pipe-guard`, "20k nested $( around a pushed pipeline is backtracking": 2355 ms against its < 2000 ms bound (reported by a consumer session, same day, a full -j 4 run at load about 30; it passed alone at load about 28).

All three assert a wall-clock budget, so a loaded machine turns them red with no defect, and a red gate on unrelated code costs a re-run. Fix shape: sweep the probes for every wall-clock bound (this list is a sample, not an inventory), and keep each budget's intent (catching a quadratic regex, catching a restore that never runs) without the wall clock. For example, measure the child's CPU time instead of elapsed time, scale the budget by a measured baseline, or retry once only on a timeout exit. Pin it by re-running the probes under artificial load (N busy loops) before and after.
<!-- SECTION:DESCRIPTION:END -->
