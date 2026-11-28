---
id: TASK-265
title: >-
  Store-direct commits bypass coupling-lint: backlog-only direct pushes run only
  backlog-lint
status: Done
assignee: []
created_date: '2026-11-27T16:30:00Z'
updated_date: '2026-11-28T05:30:00Z'
labels:
  - ci
  - lint
dependencies: []
priority: medium
ordinal: 265000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The backlog-only direct path (owner ruling 2026-11-19, CLAUDE.md) gates a store commit on backlog-lint alone; coupling-lint runs only in the full probe suite, which store-direct commits never trigger. So a store body can carry an owner name into the public repo undetected until the next PR whose merge ref crosses it fails CI.

Observed 2026-11-27: TASK-264's description shipped on main via the direct path with `gh api repos/OWNER/REPO` carrying the real owner token in an example command; caught only by coupling-lint inside PR #458's CI (a NEW COUPLING hit naming backlog/tasks/task-264), blocking a PR whose own diff was clean. Genericised in the same-session store push — and this task's own first draft carried the same token and was genericised before commit, which is the failure mode: the gate that would have caught it does not run on this path.

Fix shapes to weigh (engineering call at pickup):
1. backlog-lint grows a coupling check for the coupling-lint TOKENS over store text (one lint, one gate — the direct path's contract is 'the store lint passes').
2. Or the direct-path ruling gains 'run coupling-lint on changed store files' as a second command.
3. Probe: a store file carrying a TOKEN fails the chosen gate.

Related: TASK-37 (coupling-lint TOKENS widening) — different defect: that one is what the lint matches; this one is where the lint is invoked. A/TASK-263 (cloud-gate re-vendor) unaffected.
<!-- SECTION:DESCRIPTION:END -->

## Final Summary

<!-- SECTION:FINAL_SUMMARY:BEGIN -->
Shipped shape 2 as one entry point (lane A, B parked): `tests/store-lint.sh` runs backlog-lint and tests/coupling-lint.probe.sh, silent on pass, and CLAUDE.md now names it as the direct path's store lint. Shape 1 ruled out: the coupling TOKENS are this repo's policy, and copying them into the generic plugin bin would itself be new coupling and would lose the allowlist. Probe tests/store-lint.probe.sh: clean store, coupling token in a task body, missing priority, empty allowlist, live repo. Fixed in passing: coupling-lint died under `set -u` on an empty allowlist (bare `declare -A`), found by the worker.
<!-- SECTION:FINAL_SUMMARY:END -->
