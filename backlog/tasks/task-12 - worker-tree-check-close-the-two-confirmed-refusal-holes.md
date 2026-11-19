---
id: TASK-12
title: 'worker-tree-check: close the two confirmed refusal holes'
status: To Do
assignee: []
created_date: '2026-11-19T14:23:00Z'
labels:
  - bin
  - probes
dependencies: []
ordinal: 12000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Runtime-confirmed (repro script archived in the private ledger):
1. A linked worktree whose .git file was deleted, with a bare-shaped gitdir planted at its
   top: the upward walk finds no .git and exits 0 while rev-parse discovers the planted dir;
   --linked/--repo are ignored on this path.
2. A sibling tree whose .git file was swapped for a real repo dir: the -d branch exits 0
   before the --repo check runs.
Help text promises both are refused. Fix + probe cases from the archived findings. Also
check exposure: does the worker sandbox's read-only bind of .git make both unreachable
inside the sandbox, and which callers pass --repo/--linked?
<!-- SECTION:DESCRIPTION:END -->
