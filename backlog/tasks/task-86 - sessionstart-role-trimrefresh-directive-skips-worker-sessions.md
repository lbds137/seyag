---
id: TASK-86
title: 'SessionStart role trim/refresh directive skips worker sessions'
status: Done
assignee: []
created_date: '2026-11-22T16:45:00Z'
updated_date: '2026-11-28T06:05:00Z'
labels:
  - session
dependencies: []
priority: medium
ordinal: 86000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Mining row w1122-08 (counts 7/7: items/sessions). The role trim/refresh directive reaches worker sessions whose worktree name matches a live role. Detect a worker session, either a linked worktree on an agent branch or the headless worker marker, and skip the directive for it.
<!-- SECTION:DESCRIPTION:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Shipped by lane A (B parked). claude-role hook mode skips the role in a linked worktree whose branch matches SYG_ROLE_WORKER_BRANCHES (default `worktree-agent-*`, the delegation branch convention; empty = never skip), printing a "Worker worktree: not a role session" line instead. The headless-marker half was already covered by the SYG_ROLE_HEADLESS skip. Main checkouts, other branches and detached HEADs keep the role; any git failure falls through. Council review (openai) round 1: match the full ref under refs/heads/ (`--short` prints `heads/<name>` when a tag shares the name; positive-controlled) and pin IFS on the glob split. Ruled out: an inside-work-tree check (a session never starts in .git) and clearing GIT_* overrides (folder_of honours the same env, so the two agree).
<!-- SECTION:FINAL_SUMMARY:END -->
