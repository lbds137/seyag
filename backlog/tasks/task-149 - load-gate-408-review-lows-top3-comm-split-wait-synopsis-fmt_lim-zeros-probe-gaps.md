---
id: TASK-149
title: >-
  load-gate #408 review lows: top3 comm split, --wait synopsis, fmt_lim zeros,
  probe gaps
status: Done
assignee:
  - Seyag B
created_date: '2026-11-24T23:39:00Z'
updated_date: '2026-11-25T11:51:00Z'
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

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
2026-11-25 (Seyag B). (1) load-gate and mem-gate top3 put comm last (`pid,pcpu,comm` / `pid,rss,comm`) and rebuild it from $3..NF; mem-gate had the same class. (2) --wait synopsis lists [--interval S] and [--owner PID]. (3) fmt_lim strips integer leading zeros (08 -> 8, 08.50 -> 8.5, 00 -> 0). (4) Probe cases 28a-28e in load-gate (NPROC=3 limits 6 / 7.5; 08 limits; --owner ignored under --ok; dead owner + low load under --wait exits 0, pinned as current behaviour; spaced comm via a fake ps on PATH that refuses any call but the bin's exact one), plus the spaced-comm case in mem-gate. Mutation: reverting load-gate's column order turns 28e red. Council gpt-5.5 review: took the strict fake-ps args; declined headerless ps (procps header is stable), LC_ALL=C on ps (no evidence of a localized %cpu), MB rounding (existing %d truncation is the contract), eager --owner validation (usage already scopes --owner to waiting).
#425 claude-review lows, both ruled out: (1) the rebuilt comm collapses repeated spaces: display-only, and the kernel comm is at most 15 chars; (2) case 28d pins the check order: its comment already says to update it with any order change.
<!-- SECTION:NOTES:END -->
