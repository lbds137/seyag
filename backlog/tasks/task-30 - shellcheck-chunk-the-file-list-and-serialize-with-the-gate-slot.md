---
id: TASK-30
title: 'shellcheck: chunk the file list and serialize with the gate slot'
status: To Do
assignee: []
created_date: '2026-11-19T14:24:00Z'
updated_date: '2026-11-19T14:27:00Z'
labels:
  - probes
  - perf
dependencies: []
ordinal: 30000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
One shellcheck invocation over the whole file list grows memory with the file count (it
follows sources across all of them): observed spikes of 1.4-3.2 GB RSS on this repo's ~190
shell files, enough to push a 14 GB machine into swap and get another session's background
work reaped (sightings 11-11 and 11-19, the second traced to the documented one-call gate
recipe overlapping a probe suite run).

Structural fix lives in the gate recipe (repo docs) and/or a small wrapper:
- chunk the file list (`xargs -n 20 -P 1`) so one invocation never holds every file;
- serialize the shellcheck step with the probe suite through the machine gate lock — the
  documented command today runs OUTSIDE the lock, so it can overlap a suite run;
- long or machine-shared runs go through the long-job runner after the memory gate.
<!-- SECTION:DESCRIPTION:END -->
