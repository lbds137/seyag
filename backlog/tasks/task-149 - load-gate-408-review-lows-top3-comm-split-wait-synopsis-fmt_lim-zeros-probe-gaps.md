---
id: TASK-149
title: >-
  load-gate #408 review lows: top3 comm split, --wait synopsis, fmt_lim zeros,
  probe gaps
status: To Do
assignee: []
created_date: '2026-11-24T23:39:00Z'
labels:
  - bins
dependencies: []
priority: low
ordinal: 147000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Owner: lane B (load-gate bin). Filed from #408's PASS review, 11-24. (1) top3 (bin/load-gate ~139-140) splits a comm containing a space ('Web Content'), so the CPU column misreads; sweep mem-gate's top3 for the same class. (2) usage(): the --wait synopsis line omits [--interval S] [--owner PID]. (3) fmt_lim keeps leading zeros ('08' prints '08'). (4) Probe gaps: odd NPROC default 5m (NPROC=3 -> 7.5); --owner ignored under --ok; dead owner + low load exits 0; no ps seam for top3.
<!-- SECTION:DESCRIPTION:END -->
