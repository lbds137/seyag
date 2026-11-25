---
id: TASK-145
title: >-
  long-job: carry run --heavy (gate-lock wrapper, memory wait from lock time,
  per-job nested lock file)
status: To Do
assignee: []
created_date: '2026-11-24T19:44:00Z'
updated_date: '2026-11-24T21:01:00Z'
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
<!-- SECTION:NOTES:END -->
