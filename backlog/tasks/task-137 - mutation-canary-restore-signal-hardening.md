---
id: TASK-137
title: 'mutation-canary: restore hardening against terminal signals (TASK-110 review lows)'
status: To Do
assignee: []
created_date: '2026-11-24T04:46:00Z'
labels:
  - mutation-canary
  - tests
dependencies: []
priority: low
ordinal: 137000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Two items left open when TASK-110 shipped in 0.3.220. Both fail safe: the restore reports exit 3 and keeps the journal, and `mutation-canary --restore` recovers it.

1. A terminal Ctrl-C during the restore reaches the tool's own child processes (`cp`, `mv`, `cmp`, `stat`), because they share the terminal's foreground process group. The bash-level signal deferral in `restore_targets` and `cleanup` protects only bash itself. A killed `cp` or `mv` makes that file's restore fail, which gives exit 3 with the journal kept. This was found by reading the code; it was not reproduced. Candidate fixes: run the restore commands under `setsid`, or retry a failed restore once before reporting exit 3.
2. No test covers a signal that lands mid-restore. There is no deterministic seam to stop the tool between journal steps. Candidate fix: a test-only env hook that pauses inside `restore_targets`, if it can be added without shipping a knob that users could trip over.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Item 1 is fixed with a probe case that sends INT to the tool's process group during the restore, or ruled out with the reason recorded here
- [ ] #2 Item 2 gets a seam and a case, or is ruled out with the reason recorded here
<!-- AC:END -->
