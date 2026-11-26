---
id: TASK-251
title: claude-usage probe "plan CMD timeout" case flakes under suite load
status: To Do
assignee: []
created_date: '2026-11-26T12:16:00Z'
labels:
  - tests
  - flaky
dependencies: []
priority: low
ordinal: 251000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Seen 2026-11-26 in the TASK-191 full gate (`bash tests/run-probes.sh -j 4`, machine under load from other sessions' gates): `FAIL: plan CMD timeout: rc=1 elapsed=7299ms`. The reserve command timed out (exit 124), so the week reserve fell back to 75, and `--ok` failed at week=85%. Run alone right after, `bash tests/claude-usage.probe.sh` exits 0. The case's timing budget does not survive -j 4 under load. Fix direction: make the case independent of wall-clock (a stub CMD that exits on a signal or sentinel, or a budget derived from a measured baseline), then re-run it under `-j 4` with load.
<!-- SECTION:DESCRIPTION:END -->
