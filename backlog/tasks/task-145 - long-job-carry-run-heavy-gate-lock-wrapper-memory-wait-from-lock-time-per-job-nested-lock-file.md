---
id: TASK-145
title: >-
  long-job: carry run --heavy (gate-lock wrapper, memory wait from lock time,
  per-job nested lock file)
status: In Progress
assignee:
  - Seyag
created_date: '2026-11-24T19:44:00Z'
updated_date: '2026-11-25T09:19:00Z'
labels:
  - extraction
dependencies: []
priority: high
ordinal: 144000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Upstream machine runner gained run --heavy (upstream runner repo commit e3bb37c, local at filing; port from the origin sha once sent): the unit wrapper runs under gate-lock, then a memory wait (default 900 s from taking the lock), then CMD with SYG_GATE_LOCK_FILE/GATE_LOCK_FILE set to a per-job lock file so a nested gate-lock does not deadlock on the job's own lock; the caller's lock-file variables are forwarded into the unit. Trigger: TASK-141 merged AND the upstream sha is on origin. Probe cases: lock held during CMD, nested gate-lock inside CMD does not deadlock, the memory wait counts from lock time.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Upstream on origin (11-24): 4 commits ending 0299c1c (check: git log --oneline -4 0299c1c in the runner's repo). Feature, then fix: CMD gets only SYG_GATE_LOCK_FILE, GATE_LOCK_FILE unset (the old name leaked into nested jobs since the gate-lock wrapper lets a set old name win), then placement: heavy units leave the low-weight jobs slice (weight 20 starved suite timeouts, 1829 s vs 672 s same tree). Upstream probes: --heavy section of its job-runner probe, 6 asserts. Port all three.

Exact upstream commits (corrected by sender): b317643 feature, 335b7c9 notes, 5ea1d38 GATE_LOCK_FILE leak fix, 0299c1c app.slice placement (range 53869c1..0299c1c).

Scope addition (11-24, from the upstream runner's owner): also port bdc86c2 (feature) + 60e0fef (notes): --heavy waits on CPU load too. Order inside the unit: gate-lock -> mem-gate wait -> `load-gate --wait --owner ""` -> CMD; a non-zero load-gate exit logs "load-gate exited N; running anyway" and runs CMD. Seam: an internal SYG_LONG_JOB_* knob (path, empty = no load wait). Forward SYG_LOAD_GATE_1M/5M into the unit. Upstream probe cases F-I.

Port dispositions (11-25, Seyag):
- Old-name leak fix (5ea1d38): ruled out as not applicable. seyag's gate-lock reads only SYG_GATE_LOCK_FILE, and the unit gets no caller env beyond what run forwards, so CMD cannot see an old name. The upstream "CMD doesn't inherit GATE_LOCK_FILE" assert has nothing to pin here.
- Placement (0299c1c): ruled out as not applicable today. long-job has no slice, so its units already run in the default slice and there is no low-weight slice to leave and no slice backstop to keep (upstream's MemoryHigh=4G replaced that backstop). TASK-160's slice passthrough must keep --heavy out of any low-weight slice (acceptance line added there).
- Per-job lock file: NAME.gate.lock collides with the start lock of a job named NAME.gate (NAME may hold '.'), so the port uses a filename no valid NAME can produce.
<!-- SECTION:NOTES:END -->
