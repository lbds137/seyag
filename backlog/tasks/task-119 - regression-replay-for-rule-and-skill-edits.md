---
id: TASK-119
title: 'regression replay for rule and skill edits: old vs new on past turns, ship only if net positive'
status: Deferred
assignee: []
created_date: '2026-11-23T05:55:00Z'
labels:
  - deferred
  - rules
  - skills
dependencies: []
priority: medium
ordinal: 119000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deferred. Trigger: after TASK-118 and the mining queue (TASK-109..117) are done. Do not start before then.

Gap: hook edits get a session-log replay before merge (`tests/replay-hook.sh`), but rule and skill edits (most of them from session mining) are never replayed against past turns to see what they break, and nothing pins rules that have proven themselves.

Prior art: "GUARD: Stabilizing Recursive Self-Improvement with Regret Guidance" (arXiv 2611.23476, 2026-11-17). Its loop:
1. A per-task self-check checklist is derived from the prompt, and each check is graded 0/1 after the run.
2. Paired regret: the same tasks are re-run under the old and new rules, and checks are split into broke-by-this-edit, never-solved and working. Working rules are pinned.
3. A rule that broke something gets an "only if" scope instead of being deleted.
4. Several candidate edits are written and the best one is kept.
5. A Soft-HURT gate ships an edit only when gains exceed regressions. Rejected edits go to a ledger.

What we already have: hook replay, the mining closure ledger, paths-scoped rules, per-component toggles.

Ask (generic): a regression replay for rule and skill edits. Run the old text and the new text on a sample of past turns, score each turn with per-turn checks, and ship only when the result is net positive. The shape is to be decided when this is promoted. Measure the cost per sampled turn first, because replaying rule text means model calls, unlike the deterministic hook replay.
<!-- SECTION:DESCRIPTION:END -->
