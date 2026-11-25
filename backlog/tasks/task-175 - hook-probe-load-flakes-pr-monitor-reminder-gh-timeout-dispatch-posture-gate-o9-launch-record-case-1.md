---
id: TASK-175
title: >-
  Hook probe load flakes: pr-monitor-reminder 18ai, dispatch-posture-gate O9,
  launch-record case 1 (TASK-49 hook part)
status: Done
assignee:
  - Seyag
created_date: '2026-11-25T15:00:00Z'
updated_date: '2026-11-25T18:36:00Z'
labels:
  - hooks
  - probes
  - flake
dependencies: []
priority: medium
ordinal: 175000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The hook-lane share of TASK-49 (lane B shipped its part in #427). Specs from lane B, 11-25:

1. pr-monitor-reminder case 18ai (banner assert failed, the `--head` assert passed). Hypothesis from code reading, not runtime-confirmed: `hooks/pr-monitor-reminder.sh` bounds `gh pr list` at `timeout 2`; the probe's fake gh can exceed 2 s under `-j 4` load, giving rc 124, and the hook exits 0 without a banner after the fake has already logged `--head`. Fix shape: a knob for the gh timeout (e.g. `SYG_PR_MONITOR_GH_TIMEOUT`, default 2) that the probe sets high, plus one case pinning the 124 path's stderr note with a deliberately slow fake.
2. dispatch-posture-gate case O9 ("env unset + non-JSON stdin exits 0") exited 141: a SIGPIPE race where the hook exits before reading stdin and the printf writer dies under pipefail. Fix: the hook drains stdin (`cat >/dev/null`) before its early exit, or the probe ignores the writer's status. Not a retry.
3. launch-record case 1 ("unset dir"): no cause readable, because its `bad()` prints OUT only. Fix first: print RC and the stderr file on failure so the next occurrence can be diagnosed.

When this lands, tell lane B so TASK-49 can close.
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Shipped in 0.3.227:

1. A new `SYG_PR_MONITOR_GH_TIMEOUT` knob (default 2 s). The probe runs every case with it at 30 s. Case 16 pins the 2 s default, 16b sets 1 s (the note must read "timed out after 1s"), and 16c checks that an invalid value falls back to 2 s. Each slow fake sleeps 10 s and the bound is under 6 s, so load has margin.
2. and 3. O9 and launch-record case 1 now feed the hook with here-strings, so no printf writer exists to take SIGPIPE. Before the change, a stress run of 300 per hook with a pipe gave rc 141 once (launch-record); with the here-string it gave 141 zero times. launch-record's `bad()` now prints RC and the stderr file.

The wider class is TASK-179. The knob canary was caught: hardcoding 2 s turned 16b red.
<!-- SECTION:NOTES:END -->
