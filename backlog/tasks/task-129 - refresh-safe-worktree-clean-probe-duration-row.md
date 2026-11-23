---
id: TASK-129
title: 'Refresh the safe-worktree-clean row in tests/probe-durations.tsv'
status: To Do
assignee: []
created_date: '2026-11-23T20:05:00Z'
labels:
  - tests
dependencies: []
priority: low
ordinal: 129000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Carried over from TASK-127. The `safe-worktree-clean` row in `tests/probe-durations.tsv` reads 123.9 s, but the probe has grown since that measurement (PM9, PM10, PM10b). The runs on 11-23 took 377 s alone at load ~16 and about 340 s at load ~30-50. Both were under load, so neither is a fair number to record.

Trigger: a quiet machine (1-minute load under 4). Run the probe alone, timed, and update the row in a backlog-adjacent PR. If the quiet-machine time is still over about 150 s, also open a split or speed-up task (seyag:testing-discipline).
<!-- SECTION:DESCRIPTION:END -->
