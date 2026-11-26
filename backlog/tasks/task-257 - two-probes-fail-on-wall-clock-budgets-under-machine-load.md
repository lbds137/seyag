---
id: TASK-257
title: 'probes: turn-end-shape-gate and mutation-canary fail on wall-clock budgets under machine load'
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

Both assert a wall-clock budget, so a loaded machine turns them red with no defect, and a red gate on unrelated code costs a re-run. Fix shape: keep each budget's intent (catching a quadratic regex, catching a restore that never runs) without the wall clock, for example by measuring CPU time of the child instead of elapsed time, scaling the budget by a measured baseline, or retrying once only on a timeout exit. Pin it by re-running both probes under artificial load (e.g. `stress-ng`-free: N busy loops) before and after.
<!-- SECTION:DESCRIPTION:END -->
