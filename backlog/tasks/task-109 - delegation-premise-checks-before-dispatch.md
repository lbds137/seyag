---
id: TASK-109
title: 'delegation: run every spec command and must-fail input before dispatch; reviews attack premises'
status: To Do
assignee: []
created_date: '2026-11-23T03:31:00Z'
labels:
  - mining
  - delegation
dependencies: []
priority: high
ordinal: 109000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From session mining (the most recurrent row: ~130 items across ~90 sessions in one week): driver-written spec premises turn out wrong and are caught downstream; review briefs scoped to the spec pass the spec's own premise errors; a long gate run inside a worker's turn ends the turn mid-gate.

Owner ruling: re-queue as delegation-skill lines. Shape:
- the driver runs every command the spec quotes, and every must-fail input, before dispatch;
- an absence claim in the ledger states the sweep it rests on (patterns, positive control);
- the review brief tells the reviewer to attack the premise ledger, not only check the diff against the spec;
- the driver, not the worker, runs gates over a few minutes.
Check each against the current skill text first; parts may already be there.
<!-- SECTION:DESCRIPTION:END -->
