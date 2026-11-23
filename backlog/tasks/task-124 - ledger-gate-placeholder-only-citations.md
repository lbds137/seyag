---
id: TASK-124
title: 'dispatch-spec-ledger-gate: a row whose only backticked spans are <…> placeholders passes as cited'
status: To Do
assignee: []
created_date: '2026-11-23T16:15:00Z'
labels:
  - hooks
dependencies: []
priority: low
ordinal: 124000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
From the #383 review. The gate's cite test (`CITE_RE` in `plugins/seyag/hooks/dispatch-spec-ledger-gate.sh`) counts any backticked span. The delegation template's absence-claim row and its `Already built?` and `Already covered?` rows hold backticked placeholders like `` `<the sweep>` ``. So a spec that leaves one of those rows verbatim passes the gate with a fake citation.

- The gate's header calls the cite test a presence floor by design ("the gate nudges, review judges").
- Rejecting a row whose only backticked spans are `<…>` placeholders is a mechanical case within that floor.
- Fix: treat a backticked span matching `^<[^>]*>$` as no citation, plus a probe case for each of the three template rows left verbatim.
<!-- SECTION:DESCRIPTION:END -->
