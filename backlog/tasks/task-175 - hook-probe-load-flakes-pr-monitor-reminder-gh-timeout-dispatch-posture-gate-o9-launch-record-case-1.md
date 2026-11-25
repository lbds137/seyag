---
id: TASK-175
title: >-
  Hook probe load flakes: pr-monitor-reminder 18ai, dispatch-posture-gate O9,
  launch-record case 1 (TASK-49 hook part)
status: In Progress
assignee:
  - Seyag
created_date: '2026-11-25T15:00:00Z'
updated_date: '2026-11-25T17:01:00Z'
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
