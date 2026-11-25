---
id: TASK-176
title: 'Branch-commit guard, slice B (the commit-blocking half): deferred'
status: To Do
assignee: []
created_date: '2026-11-25T15:00:00Z'
labels:
  - hooks
  - guard
dependencies: []
priority: low
ordinal: 176000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Disposition: deferred. Trigger: the non-Anthropic audit is finished.

The branch-commit guard design was accepted on 10-29; slice A shipped as 6c57d0c. Slice B (`commit-branch-guard.sh`, its probe and `lib/commit_branch_guard.py`) sits uncommitted in the `guardB` agent worktree. Its round-3 review (11-01) left about a dozen bypass findings open; the findings live in the driver's gitignored dispatch folder as `branch-commit-unitB-round3-review.md`.

Until now this deferral was recorded only in that gitignored file. Keep the guardB worktree until this task is picked up or ruled out. When picked up, start from the round-3 findings and rebase the worktree onto current main.
<!-- SECTION:DESCRIPTION:END -->
