---
id: TASK-9
title: >-
  rules: encourage the ask-the-owner tool for non-blocking decisions with a
  recommendation
status: Done
assignee: []
created_date: '2026-11-19T14:23:00Z'
updated_date: '2026-11-20T00:16:00Z'
labels:
  - rules
dependencies: []
ordinal: 9000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
The always-loaded rules currently cover BLOCKING owner asks only; a session once parked two
yes/no asks with recommendations for days. Rule change: a non-blocking owner decision that
already has a recommendation goes out through the harness's ask-the-owner tool when it
arises, while work continues, not batched into a later review. Fold into the existing
blocking-questions bullet in the always-loaded core rules (cut words elsewhere to pay — the
file has a hard budget). Name the tool generically so other harnesses' drivers are reached
too (evidence: the ask tool fired once in ~500 transcripts of the other harness, against a
read-file positive control in the thousands).

**Disposition:** Shipped as PR #332: the core rules ask rule names the harness's ask tool generically (AskUserQuestion; the other harness's ask_question) and covers non-blocking owner decisions that already have a recommendation - they go out at the next turn end with background work left running, instead of waiting for a later batch. Status moved to Done by the store-reconciliation sweep (2026-11-19, changelog evidence; the flip rides the TASK-4 PR).
<!-- SECTION:DESCRIPTION:END -->
