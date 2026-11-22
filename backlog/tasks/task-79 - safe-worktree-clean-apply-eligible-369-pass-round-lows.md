---
id: TASK-79
title: 'safe-worktree-clean --apply-eligible: #369 PASS-round lows'
status: To Do
assignee: []
created_date: '2026-11-22T07:25:00Z'
labels:
  - worktrees
dependencies: []
priority: low
ordinal: 79000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Lows from the #369 PASS review (claude-review on 1e8a67d):

1. **`SYG_WORKTREE_ELIGIBLE_WARNED` is honoured in any run.** An inherited env, a nested run, or a project settings env block (the TASK-78 class) silently suppresses the "never eligible" warning. Honour it only in a child run (for example, when `SYG_WORKTREE_RUN_STAMP` is also set), or document it in the knobs.tsv row.
2. **`--json` `hold_plan` / `hold_plan_trees` hold the eligible-only plan in this mode.** Text mode hides it. A JSON consumer might read it as an approval token; `--apply-hold` would refuse it on mismatch anyway. Null it out, or document it.
3. **Missing probes:**
   - a tree whose only reason is `untracked-differs`;
   - one whose only reason is `ignored`, if P48(f)/(g)'s `.log` fixture judges SAFE rather than `ignored`;
   - `SYG_WORKTREE_BASE` from the environment still applying under `--apply-eligible`.
4. **Knob docs:** say that `untracked-differs` can mean un-transferred work (a newer version of a file), so the owner opts in knowingly. The universe itself is the owner's ruling; this is documentation only.
<!-- SECTION:DESCRIPTION:END -->
