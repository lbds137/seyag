---
id: TASK-60
title: 'Repo byproducts in worktrees: gate logs and PR-body scratch go to scratch-dir or a worktree-regenerable list'
status: To Do
assignee: []
created_date: '2026-11-21T06:30:00Z'
labels:
  - worktrees
  - peer-ask
dependencies: []
priority: medium
ordinal: 60000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Peer ask (machine-management session, 2026-11-21): this repo's own byproducts left in unit worktrees (gate logs, PR-body scratch) make the cleaner HOLD trees as untracked-new.

Either:
- write them to the `scratch-dir` location instead (preferred: the delegation skill's and the gate's documented output paths change), or
- add a `.claude/worktree-regenerable` listing their globs.

Sweep first: the delegation skill, the `tests/run-probes.sh` output options and the pr-body tooling, for in-tree writes. Record which path each byproduct takes.
<!-- SECTION:DESCRIPTION:END -->
