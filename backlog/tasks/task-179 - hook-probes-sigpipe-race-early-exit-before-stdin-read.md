---
id: TASK-179
title: 'Hook probes: SIGPIPE race where a hook exits before reading stdin under a printf pipe'
status: To Do
assignee: []
created_date: '2026-11-25T18:36:00Z'
labels:
  - hooks
  - probes
  - flake
dependencies: []
priority: low
ordinal: 179000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
This is the class behind TASK-175 items 2 and 3. A hook may exit before it reads stdin, for example when its toggle is off or its env is unset. If a probe feeds it with `printf … | hook` under `set -o pipefail`, the printf writer can get SIGPIPE, and the pipeline then reports 141 instead of the hook's own exit code. TASK-175 fixed only dispatch-posture-gate and launch-record. The fix was probe-side: here-strings, so no writer process exists.

The size is not measured exactly yet. A heuristic sweep on 11-25 flagged 6 hooks; it looked, per hook, for a first `exit 0` line that comes before the first `$(cat)` line. The earlier estimate of about 17 came from a looser read. Step one is an exact inventory: each hook with an early exit before its stdin read, and each probe case that pipes into it on that path.

A stress loop on 11-25 at load 17 ran `printf | hook` 300 times per hook with the early-exit env. It saw rc 141 once for launch-record and never for dispatch-posture-gate. Rare, but real.

There are two fix options: here-strings in the affected probe helpers (what TASK-175 did), or a stdin drain in the hook before its early exit. Choose per hook. Promote this task when another probe flakes with rc 141.
<!-- SECTION:DESCRIPTION:END -->
