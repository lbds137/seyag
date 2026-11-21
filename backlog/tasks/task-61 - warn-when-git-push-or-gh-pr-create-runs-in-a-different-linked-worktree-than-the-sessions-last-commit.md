---
id: TASK-61
title: 'Warn when git push or gh pr create runs in a different linked worktree than the session''s last commit'
status: To Do
assignee: []
created_date: '2026-11-21T06:30:00Z'
labels:
  - guards
  - git
  - own-miss
dependencies: []
priority: high
ordinal: 61000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Own miss (2026-11-20): cwd-drift-guard covers main-vs-linked only. A push and `gh pr create` ran in one unit's worktree when the session meant another: an earlier call had cd'd there and the shell kept it.

Fix by fit: a hook check that warns once when `git push` or `gh pr create` runs in a linked worktree other than the one the session's most recent `git commit` ran in. State is per session, like cwd-drift-guard's state dir.

Probes:
- commit in A, push in B: warn;
- same tree: pass;
- no prior commit: pass.
<!-- SECTION:DESCRIPTION:END -->
