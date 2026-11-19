---
id: TASK-30
title: 'shellcheck: chunk the file list and serialize with the gate slot'
status: In Progress
assignee:
  - seyag-b
created_date: '2026-11-19T14:24:00Z'
updated_date: '2026-11-19T19:42:00Z'
labels:
  - probes
  - perf
dependencies: []
ordinal: 30000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
One shellcheck invocation over the repo's ~190 shell files grows memory with the file count. ORIGINAL FIX (shipped #347, 0013207): bin/shellcheck-gate chunks the list (-n 20 -P 1) under the gate lock. REOPENED by Deck re-measure 11-19 (396d1fb): one 20-file chunk still peaked 3,177 MB — chunking fixed overlap only.

PROFILED (b-t30-profile, 11-19, per-file VmHWM under deck-job+gate-lock, real binary 0.11.0, 194 files, table at .claude/dispatch/b-t30-profile.tsv in the main checkout): tests/safe-worktree-clean.probe.sh alone peaks 3,734,948 KB (~3.7 GB) / 17.4 s — 3.4x the runner-up (tests/api-credit.probe.sh 1.08 GB), median file 90 MB; 13 files over 200 MB sum ~9.4 GB. THE SPIKE IS ONE FILE. (Deck's 3,177 MB chunk = whichever chunk contained this probe.)

NEXT (bisect the cliff, then fix the construct — do not gate-dodge):
1. Binary-search the line count: shellcheck on head -n K of the probe (via stdin, -s bash) for K at powers of two, find where RSS cliffs; then narrow to the construct.
2. Expected shape (hypothesis, verify): a giant runtime fixture literal living IN the linted probe — structural fix is moving big literals out of linted files into data files the probe reads (runtime-equivalent, shellcheck never parses them). Splitting the probe file works too but is bigger surgery; decide by what the bisect shows.
3. PREMISE SWEEP (same unit): knobs.tsv SYG_SHELLCHECK_CHUNK description ('bounds one invocation's memory') over-claims — chunking bounds overlap/serialization, not per-invocation footprint; correct durable prose (knobs row + README row phrasing + any spike-fix claim).
4. Re-gate, push as follow-up PR, then Deck re-measures; WATCH closes only on a flattened spike (target: no process over ~1 GB during the documented recipe run; state the target measured, not promised).
<!-- SECTION:DESCRIPTION:END -->
