---
id: TASK-122
title: 'safe-worktree-clean: resolve a tree whose HEAD is a merged PR''s head commit as pr-merged'
status: To Do
assignee: []
created_date: '2026-11-23T16:15:00Z'
labels:
  - bin
  - worktrees
dependencies: []
priority: high
ordinal: 122000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Request from the machine-management session (2026-11-23), owner priority: worktree-removal asks reach the owner several times a day. In repos that rebase-merge or squash-merge, the base gets new SHAs, so a finished PR's worktree carries commits that nothing on the base points at. It is held as unmerged/refs, and the session asks.

- Add a resolution `pr-merged`. It applies when the tree's only commit-carrying hold reasons are unmerged/refs, the tree is clean and is no session's live cwd, and its HEAD equals the `headRefOid` of a PR the forge reports MERGED (`gh pr list --state merged --search <sha> --json number,headRefOid`). The backup is still taken. The forge call is optional and fails closed: with no gh or no network the tree stays HOLD.
- Make `pr-merged` part of the `--apply-eligible` default set, or put it behind an opt-in env the host sets.
- A repo that integrates on a non-default branch (for example `develop`) must be judged against that branch. Check that `SYG_WORKTREE_BASE` is honoured per repo in `--all` sweeps.
<!-- SECTION:DESCRIPTION:END -->
