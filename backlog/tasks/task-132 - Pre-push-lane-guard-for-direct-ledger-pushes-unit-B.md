---
id: TASK-132
title: 'Pre-push lane guard for direct ledger pushes (TASK-130 unit B)'
status: To Do
assignee: []
created_date: '2026-11-24T01:02:02Z'
labels:
  - policy
  - git-hooks
  - deferred
dependencies:
  - TASK-130
priority: low
ordinal: 132000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
DEFERRED (owner ruling 2026-11-23 ~20:00: "Not now"). Trigger: a repo that clears 10 standalone ledger-only PRs a month opts in. Measure the rate with `change-class replay` over its merged PRs (see TASK-130's notes). The only surveyed repo that clears the bar today runs at about 11 a month and has declined for now.

Scope is as designed in TASK-130 lane 2:
- an opt-in pre-push guard in the plugin's git-hooks dispatcher (`git config --type=bool seyag.laneGuard`);
- policy read with `git cat-file blob` at the remote's old sha, never through the project config loader;
- create, delete, non-fast-forward and merges refused; every outgoing commit checked against its parent with `change-class`;
- control files hard-denied; the repo's own hook chained.
v1 checks path and mode confinement only. A validator picked by ID stays deferred until an adopter's rules require a store lint.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 pre-push lane guard is opt-in (toggle), chains the repo hook, and its probe covers create/delete/non-FF/merge/revert-hiding/config-widening cases
<!-- AC:END -->
