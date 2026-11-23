---
id: TASK-126
title: 'safe-worktree-clean: per-repo base in multi-repo sweeps'
status: To Do
assignee: []
created_date: '2026-11-23T18:19:00Z'
labels:
  - bin
  - worktrees
dependencies: []
priority: low
ordinal: 126000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Found while building TASK-122. In a multi-repo sweep (`--repo` repeated or `--repos-file`), one `SYG_WORKTREE_BASE` value (env or user config) reaches every child, and project-scope config is refused for that knob. A repo that integrates on another branch (git-flow `develop`) therefore cannot be judged against its own base in the same sweep; today it is swept separately with its own env. That also decides which branch the `pr-merged` lookup matches the PR's base against, since it follows the effective base.

Mechanism candidate: an optional second column in `--repos-file` naming that repo's base ref, host-controlled. It must also work under `--apply-eligible`, which refuses `--base`, so a flag cannot carry it.

Trigger: a second repo on a host adopts a non-default integration branch, or a repo with a non-default integration branch joins the host's repos file. Until then the header's one-sentence limit (sweep it separately with its own env) is the documented answer.
<!-- SECTION:DESCRIPTION:END -->
