---
id: TASK-10
title: 'automerge: gate on the PR''s live draft state, not the event payload'
status: To Do
assignee: []
created_date: '2026-11-19T14:23:00Z'
updated_date: '2026-11-20T02:21:00Z'
labels:
  - skills
  - deferred
dependencies: []
priority: high
ordinal: 10
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Deferred; trigger: next touch of the review workflow, or a second sighting. Observed once: a
PR opened as draft, marked ready, then pushed to within seconds; the ready run was cancelled
by the concurrency group, the push run passed with verdict PASS, yet automerge skipped —
hypothesis (not confirmed): the surviving run's event payload still carried draft=true. Fix
candidate: gate automerge on the PR's live draft state from the API. Known workaround:
`gh pr ready --undo` then `gh pr ready` fires a fresh run.

Promoted 2026-11-19 (prioritization pass): trigger fired - second sighting. The draft-then-cite race on the November 18 changelog-cite PR matches the earlier mechanism (green-PR automerge skip from a surviving draft=true payload).
<!-- SECTION:DESCRIPTION:END -->
