---
id: TASK-49
title: >-
  Probes fail under suite load: pr-monitor-reminder 18ai and safe-worktree-clean
  timeout
status: To Do
assignee: []
created_date: '2026-11-21T02:47:00Z'
updated_date: '2026-11-21T03:21:00Z'
labels:
  - probes
  - flake
dependencies: []
ordinal: 49000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Full gate on the 0.3.198 branch (2026-11-20, swap ~5.5 GB) failed two probes this branch does not touch, both pass run alone: pr-monitor-reminder case 18ai ('git push origin feat-y:@' banner rev refs/heads/main) failed only under -j 4; safe-worktree-clean hit the run-probes timeout (exit 124) and took 4m17s alone vs 123.9 s in probe-durations.tsv. Find what in 18ai depends on timing or shared state, and whether safe-worktree-clean's timeout or duration needs revisiting (or splitting).
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Related: TASK-30 profiled tests/safe-worktree-clean.probe.sh as the shellcheck memory outlier (~3.7 GB); its runtime under load may share a cause.
<!-- SECTION:NOTES:END -->
