---
id: TASK-64
title: 'worktree-branch-guard: judge the branch git DWIM-creates from a remote'
status: To Do
assignee: []
created_date: '2026-11-21T13:00:00Z'
labels:
  - guards
  - worktrees
dependencies: []
priority: medium
ordinal: 64000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
`git worktree add <path> <name>` where `<name>` exists only as a remote-tracking branch makes git create local branch `<name>`. The guard passes this form (no `-b`, commit-ish given) as a known bound. Judge it when `<name>` has no local branch and exactly one remote has it (or `--guess-remote` / `worktree.guessRemote` applies), with probe cases.
<!-- SECTION:DESCRIPTION:END -->
