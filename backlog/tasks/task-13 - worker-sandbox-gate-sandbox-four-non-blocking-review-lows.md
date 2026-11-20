---
id: TASK-13
title: 'worker-sandbox/gate-sandbox: four non-blocking review lows'
status: To Do
assignee: []
created_date: '2026-11-19T14:23:00Z'
updated_date: '2026-11-20T02:21:00Z'
labels:
  - bin
dependencies: []
priority: medium
ordinal: 90
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From the merged unit's PASS review:
- A file as a middle path component in a toolchain entry is refused as "unreadable" instead
  of skipped (strict-safe but undocumented): document it, or treat a non-directory parent as
  absent.
- The changelog does not state the oversize-pointer refusal: add it.
- The child-refusal message names the entry, not the offending child: the probe pins the
  entry text, so change both together.
- pointer() and the own-entry loop duplicate the -r/size/NUL checks: optional
  pointer_problem helper to stop drift.
Also from the merge follow-up (host-side, tracked here so it is not lost): host launchers
should set the main-checkout repo knob explicitly, and the sibling deployment lane's wrapper
makes the same no-flag pre-launch check — both are host-config actions recorded privately.
<!-- SECTION:DESCRIPTION:END -->
