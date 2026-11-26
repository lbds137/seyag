---
id: TASK-197
title: >-
  long-job #439 review lows: StartupCPUShares probe, AllowedCPUs under --heavy,
  README knob list
status: To Do
assignee: []
created_date: '2026-11-26T08:40:00Z'
labels:
  - long-job
  - review-followup
dependencies: []
priority: low
ordinal: 197000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The Claude review lows from PR #439 (TASK-177), which landed as 943ba4f..dea8810 (code d430e8f, 514d2a4, 4e45c46) with verdict PASS. Each one is still open on main:
(1) tests/long-job.probe.sh S12 does not pass or assert `-p StartupCPUShares`. The drop arm at plugins/seyag/bin/long-job:213 lists it, so a typo in that arm would go unnoticed. Add it to S12's command and assertions.
(2) The probe's header comment, the S12 comment and S12's `ok` label still list only CPUWeight/StartupCPUWeight/CPUQuota. List all five dropped properties.
(3) `-p AllowedCPUs`/`StartupAllowedCPUs` still reach a --heavy unit, and pinning the job to a CPU subset recreates the starvation the drop prevents. CPUQuotaPeriodSec does nothing without the dropped quota. Either add AllowedCPUs|StartupAllowedCPUs to the drop with a probe case (preferred), or document in --help that only weight, share and quota properties are dropped.
(4) The "Knobs" sentence in README.md's long-job entry lists SYG_LONG_JOB_STATE_DIR and SYG_LONG_JOB_UNIT_PREFIX but not SYG_LONG_JOB_AS. Add it.
<!-- SECTION:DESCRIPTION:END -->
