---
id: TASK-117
title: 'guard block-text audit: every block prints a runnable compliant retry'
status: To Do
assignee: []
created_date: '2026-11-23T03:31:00Z'
labels:
  - mining
  - guards
dependencies: []
priority: high
ordinal: 117000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From session mining (the most-tripped row: ~225 items across ~143 sessions in one week, up from ~104/89 the week before): a guard's block text that does not print the compliant retry costs a re-learn per trip. Owner ruling: a one-time audit of every guard's block text, lossy-pipe-guard included; text only, no matcher change.

For each guard (lossy-pipe, pr-body-ref-gate, private-term-guard (the matched term is not shown), python-heredoc-edit-guard, temporal-marker-guard, broad-walk-guard, recursive-rm-guard, and the rest of the guard families): the block prints a retry the session can run as-is, built from the blocked command where possible; probes pin it. Known instance: recursive-rm-guard blocked a single literal path inside a worker's job-scratch folder although its own text says that shape is allowed; reproduce, then fix the text or the matcher (the latter is a matcher change: separate commit, own probe).

Moved out of TASK-20 (its mining-residuals bucket).
<!-- SECTION:DESCRIPTION:END -->
