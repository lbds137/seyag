---
id: TASK-127
title: 'PR #385 review lows: safe-worktree-clean pr check'
status: To Do
assignee: []
created_date: '2026-11-23'
labels:
  - safe-worktree-clean
dependencies: []
priority: high
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The claude-review of PR #385 (TASK-122, release 0.3.215) passed with six low findings. All six are fixes, not rule-outs. This entry finishes the pr-merged theme, so it goes before TASK-123.

1. Fix the documented default of `SYG_WORKTREE_PR_CHECK` in `knobs.tsv` and the regenerated `docs/config.md`. The docs say the default is `1`, but the code treats unset as "lookup on, quiet" and explicit `1` as "lookup on, plus stderr notes" (`PR_NOTE_ON`). Document unset as the default with those semantics.
2. CHANGELOG and header: say the lookup is on by default. A tree held as `unmerged` can then report `pr-merged`, which changes its verdict string and plan id with no change to the eligibility list.
3. Probe L7 (the `pm9` block in `phase_pm`) calls `"$TOOL"` directly, so a runner with a real `gh` makes a network call to `example.invalid`, which can take up to 20 s. Run it through `pm_run` with the stub, or with `SYG_WORKTREE_PR_CHECK=0`.
4. Bound the total lookup time. Stop calling the forge for the rest of the run after the first timeout, or cap the total time. Today it is N trees × 20 s against a slow forge. Add a probe for it.
5. Add probes for the `git@host:owner/repo.git` and `ssh://git@host/owner/repo` remote forms that assert the stub log's `--hostname` and `repos/...` arguments. Today only https and a local path are probed.
6. In the swc header, document the URL forms that fail closed: `ssh://` with no user, a port, and nested paths.

Also refresh the `tests/probe-durations.tsv` row for `safe-worktree-clean` (123.9 s) on a quiet machine. The full run on 11-23 took 377 s alone at load ~16 and hit the 600 s per-probe ceiling at `-j 4` under load ~20.
<!-- SECTION:DESCRIPTION:END -->
