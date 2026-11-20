---
id: TASK-12
title: 'worker-tree-check: close the two confirmed refusal holes'
status: Done
assignee: []
created_date: '2026-11-19T14:23:00Z'
updated_date: '2026-11-20T00:16:00Z'
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

**Disposition:** Shipped as PR #337: worker-tree-check refuses the bare-shaped-gitdir tree under --linked/--repo and, without them, runs a HEAD walk that refuses a HEAD anywhere above DIR; a real .git directory honours --repo (it must be the main checkout's own); a linked tree whose repo still registers but whose .git file is gone is refused; symlinked gitdir and malformed gitfile refusals added; probes red-first with a payload positive control. Exposure answers: worker-sandbox runs the check pre-bind (PR #325) and the opt-in main-checkout anchoring knobs landed as PR #340. Status moved to Done by the store-reconciliation sweep (2026-11-19; the flip rides the TASK-4 PR).
<!-- SECTION:DESCRIPTION:END -->
