---
id: TASK-141
title: 'Extraction step 7a: long-job runner and long-job-chain-check move into seyag'
status: Done
assignee:
  - Seyag
created_date: '2026-11-24T17:52:00Z'
updated_date: '2026-11-25T01:48:00Z'
labels:
  - extraction
dependencies: []
priority: high
ordinal: 141000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Move the machine's long-job runner (transient systemd user unit, memory-gated, wait/poll/status/cmd/rc/log) and its && chain detector into plugins/seyag/bin as generic tools (long-job, long-job-chain-check), with knobs for the state dir and unit prefix; runner aliases come from the first word of SYG_LONG_JOB_CMD. Bins only; hooks.json wiring of --hook is TASK-142.
<!-- SECTION:DESCRIPTION:END -->
