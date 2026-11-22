---
id: TASK-94
title: 'safe-worktree-clean: the dry run prints the ready-to-run apply line; unknown flags list the accepted ones'
status: To Do
assignee: []
created_date: '2026-11-22T17:10:00Z'
labels:
  - worktrees
dependencies: []
priority: medium
ordinal: 94000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Mining row w1122-26 (about 14 items in about 11 sessions). Sessions invoke `safe-worktree-clean` wrongly:
- they run `--apply-hold` without the dry run's `--only` (the plan id then mismatches);
- they pass bare names instead of paths;
- they pass a `--dry-run` flag that does not exist.

The plan-id check always held, but each miss cost a retry, and once a second round of asking the owner.

Fix:
- When the dry run prints a hold plan, it also prints the exact apply command, ready to run: every `--only` from the dry run, the plan id, and absolute paths. Do the same for the `--apply-eligible` and plain `--apply` forms where they apply.
- An unknown flag exits 2 and lists the accepted flags.

Probes:
- the printed line, run verbatim, applies the same plan;
- `--dry-run` exits 2 and names the accepted flags.
<!-- SECTION:DESCRIPTION:END -->
