---
id: TASK-49
title: >-
  Probes fail under suite load: pr-monitor-reminder 18ai and safe-worktree-clean
  timeout
status: To Do
assignee: []
created_date: '2026-11-21T02:47:00Z'
updated_date: '2026-11-24T17:36:00Z'
labels:
  - probes
  - flake
dependencies: []
priority: medium
ordinal: 49000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Full gate on the 0.3.198 branch (2026-11-20, swap ~5.5 GB) failed two probes this branch does not touch, both pass run alone: pr-monitor-reminder case 18ai ('git push origin feat-y:@' banner rev refs/heads/main) failed only under -j 4; safe-worktree-clean hit the run-probes timeout (exit 124) and took 4m17s alone vs 123.9 s in probe-durations.tsv. Find what in 18ai depends on timing or shared state, and whether safe-worktree-clean's timeout or duration needs revisiting (or splitting).
<!-- SECTION:DESCRIPTION:END -->

## Implementation Notes

<!-- SECTION:NOTES:BEGIN -->
Related: TASK-30 profiled tests/safe-worktree-clean.probe.sh as the shellcheck memory outlier (~3.7 GB); its runtime under load may share a cause.

2026-11-24 (Seyag B): timed out (exit 124 at the 600 s cap) in `bash tests/run-probes.sh -j 4` on worktree-agent-b82 rebased on 9450989; alone right after, `timeout 600 bash tests/safe-worktree-clean.probe.sh` passed in 594 s, against 123.9 s recorded at tests/probe-durations.tsv:88. Not separated yet: probe regression vs machine load (other lanes ran suites concurrently). Next check: time it alone on an idle machine.
<!-- SECTION:NOTES:END -->
